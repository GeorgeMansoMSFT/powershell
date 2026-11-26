<#
.SYNOPSIS
    One-command offline test: starts the mock Graph server, runs the collector
    against it, checks every user's result against the mock's expected output,
    then stops the mock. No tenant or sign-in is needed.

.PARAMETER Scope
    All             every user
    Filter          -UserFilter "accountEnabled eq true and userType eq 'Member'"
    Groups          -GroupId for two overlapping groups (every 3rd and every 5th user)
    GroupsAndFilter both groups plus -UserFilter "accountEnabled eq true"

.PARAMETER ForbiddenEveryNth
    Every Nth user (index % N == 1) returns 403 so the read-error path is tested.
    0 disables it, which should produce a report marked complete.

.EXAMPLE
    .\Tests\Invoke-MockTest.ps1 -UserCount 5000

.EXAMPLE
    .\Tests\Invoke-MockTest.ps1 -UserCount 2000 -Scope GroupsAndFilter
#>
param(
    [int]$UserCount = 5000,
    [ValidateSet('All', 'Filter', 'Groups', 'GroupsAndFilter')]
    [string]$Scope = 'All',
    [int]$Port = 18080,
    [int]$ThrottleEveryNthItem = 20,
    [int]$FailEveryNthBatch = 50,
    [int]$ForbiddenEveryNth = 1000,
    [int]$MaxConcurrency = 8,
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MockHarness.ps1')
$outDir = Join-Path $PSScriptRoot 'out'
$expectedPath = Join-Path $PSScriptRoot 'expected.json'
$endpoint = "http://localhost:$Port"

$mockGroups = @('11111111-1111-4111-8111-000000000003', '11111111-1111-4111-8111-000000000005')
switch ($Scope) {
    'All'             { $userFilter = $null; $groupIds = $null; $inScope = { $true } }
    'Filter'          { $userFilter = "accountEnabled eq true and userType eq 'Member'"; $groupIds = $null; $inScope = { $_.Enabled -and $_.UserType -eq 'Member' } }
    'Groups'          { $userFilter = $null; $groupIds = $mockGroups; $inScope = { $_.Index % 3 -eq 0 -or $_.Index % 5 -eq 0 } }
    'GroupsAndFilter' { $userFilter = 'accountEnabled eq true'; $groupIds = $mockGroups; $inScope = { ($_.Index % 3 -eq 0 -or $_.Index % 5 -eq 0) -and $_.Enabled } }
}

Reset-OutDir $outDir
$mock = Start-MockServer -Port $Port -OutDir $outDir -ExpectedPath $expectedPath -MockArgs @{
    UserCount = $UserCount; ThrottleEveryNthItem = $ThrottleEveryNthItem; FailEveryNthBatch = $FailEveryNthBatch; ForbiddenEveryNth = $ForbiddenEveryNth
}
Write-Host "Mock is up with $UserCount users. Scope: $Scope"

$failures = New-Object System.Collections.Generic.List[string]
$counts = $null
try {
    $collectorArgs = @{ CompareWithReport = $true; MaxConcurrency = $MaxConcurrency }
    if ($userFilter) { $collectorArgs.UserFilter = $userFilter }
    if ($groupIds) { $collectorArgs.GroupId = $groupIds }
    $run = Invoke-Collector -Endpoint $endpoint -OutDir $outDir -CollectorArgs $collectorArgs -TimeoutMinutes $TimeoutMinutes -ShowOutput
    if ($run.State -ne 'Completed') { $failures.Add("Collector job ended in state $($run.State): $($run.Error)") }

    $files = Get-RunFiles $outDir
    if (-not $files.Csv) { throw 'No AuthMethods CSV was produced.' }
    if (-not $files.Html) { $failures.Add('No HTML report was produced.') }

    $csvRows = @(Import-Csv -LiteralPath $files.Csv.FullName)
    $rows = @{}
    foreach ($r in $csvRows) { $rows[$r.UserPrincipalName] = $r }
    # Parenthesised so PS 5.1 enumerates the JSON array instead of passing it down the pipeline as one object.
    $expected = @((Get-Content -LiteralPath $expectedPath -Raw | ConvertFrom-Json) | Where-Object $inScope)
    if ($rows.Count -ne $expected.Count) { $failures.Add("Row count $($rows.Count) <> expected $($expected.Count)") }

    $checked = 0
    foreach ($e in $expected) {
        $r = $rows[$e.UserPrincipalName]
        if (-not $r) { $failures.Add("$($e.UserPrincipalName): missing from CSV"); continue }
        $checked++
        # Expected values are $null (-> '') for users whose methods could not be read.
        $pairs = @(
            @('ReadStatus', $r.ReadStatus, $e.Status),
            @('DisplayName', $r.DisplayName, $e.DisplayNameCsv),
            @('HasPasskey', $r.HasPasskey, "$($e.HasPasskey)"),
            @('HasPasskeyInAuthenticator', $r.HasPasskeyInAuthenticator, "$($e.HasPasskeyInAuthenticator)"),
            @('HasMfaMethodRegistered', $r.HasMfaMethodRegistered, "$($e.HasMfaMethodRegistered)"),
            @('MethodCount', $r.MethodCount, "$($e.MethodCount)")
        )
        foreach ($p in $pairs) {
            if ("$($p[1])" -cne "$($p[2])") { $failures.Add("$($e.UserPrincipalName): $($p[0]) '$($p[1])' <> expected '$($p[2])'") }
        }
        if ($e.Status -eq 'Error') {
            foreach ($c in 'HasPhishingResistantMethodRegistered', 'HasMicrosoftAuthenticator', 'HasPhone', 'MethodsRegistered', 'PasskeyCount') {
                if ("$($r.$c)" -ne '') { $failures.Add("$($e.UserPrincipalName): $c should be empty (unknown) for a read error but is '$($r.$c)'") }
            }
        }
        $disc = "$($r.Discrepancy)"
        if ($e.Discrepancy) {
            if (-not $disc.StartsWith($e.Discrepancy)) { $failures.Add("$($e.UserPrincipalName): Discrepancy '$disc' <> expected '$($e.Discrepancy)'") }
        }
        elseif ($disc) { $failures.Add("$($e.UserPrincipalName): unexpected Discrepancy '$disc'") }
    }
    if ($csvRows.Count -and -not ($csvRows[0].PSObject.Properties.Name -contains 'HasMfaMethodRegistered')) { $failures.Add('CSV is missing the HasMfaMethodRegistered column') }
    if ($csvRows.Count -and ($csvRows[0].PSObject.Properties.Name -contains 'IsMfaCapable')) { $failures.Add('CSV still has the old IsMfaCapable column') }

    # Formula guard on authenticator device names (main CSV) and method display names (detail CSV).
    $u6 = $rows['user6@contoso.test']
    if ($u6 -and $u6.AuthenticatorDevices -cne "'=iPhone") { $failures.Add("user6 AuthenticatorDevices '$($u6.AuthenticatorDevices)' should be '=iPhone with a leading '") }
    if ($files.Details) {
        $d24 = @(Import-Csv -LiteralPath $files.Details.FullName | Where-Object { $_.UserPrincipalName -eq 'user24@contoso.test' -and $_.MethodType -eq 'fido2' })
        if ($rows.ContainsKey('user24@contoso.test') -and ($d24.Count -ne 1 -or $d24[0].DisplayName -cne "'@evil")) { $failures.Add("user24 passkey DisplayName in the details CSV should be '@evil with a leading '") }
    }

    $expectedErrors = @($expected | Where-Object { $_.Status -eq 'Error' }).Count
    if ($expectedErrors) {
        if (-not $files.Errors) { $failures.Add('Expected an AuthMethodErrors CSV (403 users) but none was produced.') }
        elseif (@(Import-Csv -LiteralPath $files.Errors.FullName).Count -ne $expectedErrors) {
            $failures.Add("Errors CSV has $(@(Import-Csv -LiteralPath $files.Errors.FullName).Count) rows, expected $expectedErrors")
        }
    }
    elseif ($files.Errors) { $failures.Add('No read errors were expected but an AuthMethodErrors CSV was produced.') }

    $summary = $files.Summary
    if (-not $summary) { $failures.Add('No RunSummary JSON was produced.') }
    else {
        if ($ThrottleEveryNthItem -and [int]$summary.ThrottledItems -eq 0) { $failures.Add('Mock injected 429s but RunSummary shows ThrottledItems = 0') }
        if ([int]$summary.UsersEnumerated -ne $expected.Count) { $failures.Add("UsersEnumerated $($summary.UsersEnumerated) <> expected $($expected.Count)") }
        if (($summary.Scope -eq 'All users') -ne ($Scope -eq 'All')) { $failures.Add("RunSummary Scope '$($summary.Scope)' does not match test scope $Scope") }
        $expectedInNative = @($expected | Where-Object { $_.Enabled -and ($_.Index % 250 -ne 3) }).Count
        if ([int]$summary.NativeReportUsersInScope -ne $expectedInNative) { $failures.Add("NativeReportUsersInScope $($summary.NativeReportUsersInScope) <> expected $expectedInNative") }
        if ($summary.NativeComparisonStatus -ne 'Completed') { $failures.Add("NativeComparisonStatus '$($summary.NativeComparisonStatus)' <> 'Completed'") }
        $shouldBeComplete = ($expectedErrors -eq 0)
        if ([bool]$summary.ReportComplete -ne $shouldBeComplete) { $failures.Add("ReportComplete $($summary.ReportComplete) <> expected $shouldBeComplete (issues: $($summary.CompletenessIssues -join ' | '))") }
        if ($summary.GraphEndpoint -ne $endpoint) { $failures.Add("RunSummary GraphEndpoint '$($summary.GraphEndpoint)' <> '$endpoint'") }
        $okExpected = @($expected | Where-Object { $_.Status -eq 'OK' })
        $mfaExpected = @($okExpected | Where-Object { $_.HasMfaMethodRegistered }).Count
        if ([int]$summary.UsersWithMfaMethodRegistered -ne $mfaExpected) { $failures.Add("UsersWithMfaMethodRegistered $($summary.UsersWithMfaMethodRegistered) <> expected $mfaExpected") }
    }

    if ($files.Html) {
        $hd = Get-HtmlData $files.Html.FullName
        if (-not $hd.Meta -or -not $hd.Rows) { $failures.Add('Could not read META/ROWS from the HTML report') }
        else {
            if ($hd.Rows.Count -ne $csvRows.Count) { $failures.Add("HTML has $($hd.Rows.Count) rows, CSV has $($csvRows.Count)") }
            if ($summary -and [bool]$hd.Meta.complete -ne [bool]$summary.ReportComplete) { $failures.Add('HTML META.complete disagrees with RunSummary.ReportComplete') }
            if ($hd.Meta.nativeStatus -ne 'Completed') { $failures.Add("HTML META.nativeStatus '$($hd.Meta.nativeStatus)' <> 'Completed'") }
            $countMismatch = 0
            foreach ($hr in $hd.Rows) {
                $r = $rows[$hr[0]]
                if (-not $r) { $failures.Add("HTML row $($hr[0]) has no CSV row"); continue }
                $want = if ($r.ReadStatus -eq 'OK') { [int]$r.MethodCount } else { -1 }
                if ([int]$hr[12] -ne $want) { $countMismatch++ }
                # The HTML keeps the raw display name; only the CSV gets the formula guard.
                if ($r.DisplayName.StartsWith("'") -and $hr[1] -cne $r.DisplayName.Substring(1)) { $failures.Add("HTML display name for $($hr[0]) should be the raw value") }
            }
            if ($countMismatch) { $failures.Add("$countMismatch HTML rows have a method count that differs from the CSV MethodCount") }
            if ($Scope -ne 'All') {
                if ($groupIds -and $hd.Meta.scope -notmatch '^Members of') { $failures.Add('HTML meta does not show the group scope') }
                if ($userFilter -and $hd.Meta.scope -notmatch 'Filter: ') { $failures.Add('HTML meta does not show the filter scope') }
            }
        }
    }

    Write-Host ''
    Write-Host ('Collector run: {0:N0} s for {1} in-scope users of {2} ({3:N1} users/s)' -f $run.Seconds, $expected.Count, $UserCount, ($expected.Count / [Math]::Max(1, $run.Seconds)))
    $build = $run.Output | Where-Object { $_ -match 'Building output' } | Select-Object -First 1
    $done = $run.Output | Where-Object { $_ -match 'Done in' } | Select-Object -First 1
    $ts = { param($l) if ($l -match '(\d{2}:\d{2}:\d{2})') { [datetime]::ParseExact($Matches[1], 'HH:mm:ss', $null) } }
    if ($build -and $done) { Write-Host ('Building output took about {0:N0} s' -f ((& $ts $done) - (& $ts $build)).TotalSeconds) }
    if ($summary) { $summary | Format-List | Out-String | Write-Host }
    Write-Host "Users checked: $checked"
}
finally {
    $counts = Stop-MockServer -Port $Port -Process $mock
    if ($counts) {
        Write-Host ("Mock counters: items={0} batches={1} throttled={2} failed503={3} advancedQueries={4} unauthorized={5}" -f $counts.Items, $counts.Batches, $counts.Throttled, $counts.Failed503, $counts.AdvancedQueries, $counts.Unauthorized)
    }
}

if ($failures.Count) {
    Write-Host "FAILED: $($failures.Count) problem(s)" -ForegroundColor Red
    $failures | Select-Object -First 25 | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host 'PASSED: every user matched the expected result.' -ForegroundColor Green
