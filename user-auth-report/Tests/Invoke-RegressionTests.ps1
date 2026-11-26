<#
.SYNOPSIS
    Regression tests for Get-EntraAuthMethodReport.ps1, run against the local mock
    Graph server (Start-MockGraph.ps1). Nothing is sent to Microsoft Graph.

.DESCRIPTION
    Each scenario starts its own mock with one failure injected, runs the collector
    against it and checks the outcome. A second "canary" origin on the mock counts any
    request that leaves the expected origin; every scenario requires zero canary hits.

    Covered:
      - parameter validation (GraphEndpoint limited to the Global/US Gov HTTPS endpoints, loopback-only TestGraphEndpoint,
        TestGraphEndpoint requires -AccessToken and excludes -GraphEndpoint)
      - next-page links to another origin (users and native report) are refused
      - HTTP redirects (users and $batch) are not followed
      - per-item and whole-request 401s trigger one coordinated token refresh
      - a refresh that does not help leaves the report marked incomplete
      - completeness: @odata.count mismatch, -MaxUsers truncation, clean run
      - native report comparison status when the native report fails
      - the end-to-end check in Invoke-MockTest.ps1 (renamed fields, unknown values for
        failed reads, CSV formula guard, PowerShell/HTML method counts)

.PARAMETER BasePort
    First local port to use. Each scenario uses two ports.

.PARAMETER Only
    Run only scenarios whose name matches this wildcard pattern.

.EXAMPLE
    .\Tests\Invoke-RegressionTests.ps1
#>
param(
    [int]$BasePort = 18120,
    [string]$Only = '*'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MockHarness.ps1')
$outRoot = Join-Path $PSScriptRoot 'out\regression'
$script:NextPort = $BasePort
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Name, [string[]]$Problems, [double]$Seconds)
    $Problems = @($Problems | Where-Object { $_ })
    $results.Add([pscustomobject]@{ Scenario = $Name; Result = $(if ($Problems.Count) { 'FAIL' } else { 'PASS' }); Seconds = [int]$Seconds; Detail = ($Problems -join ' | ') })
    $color = if ($Problems.Count) { 'Red' } else { 'Green' }
    Write-Host ("{0,-4} {1}" -f $results[-1].Result, $Name) -ForegroundColor $color
    foreach ($p in $Problems) { Write-Host "       $p" }
}

function Invoke-Scenario {
    <#
        Runs one mock scenario. -Assert receives an object with Run (job result),
        Counts (mock counters), Files (output files) and Summary, and returns a list of
        problems (empty = pass).
    #>
    param([string]$Name, [hashtable]$MockArgs = @{}, [hashtable]$CollectorArgs = @{}, [int]$UserCount = 300, [scriptblock]$Assert)
    if ($Name -notlike $Only) { return }
    $port = $script:NextPort; $canary = $port + 1; $script:NextPort += 2
    $outDir = Join-Path $outRoot $Name
    Reset-OutDir $outDir
    $m = @{ UserCount = $UserCount; ThrottleEveryNthItem = 0; FailEveryNthBatch = 0; ForbiddenEveryNth = 0; CanaryPort = $canary }
    foreach ($k in $MockArgs.Keys) { $m[$k] = $MockArgs[$k] }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $problems = @()
    $mock = $null
    try {
        $mock = Start-MockServer -Port $port -OutDir $outDir -ExpectedPath (Join-Path $outDir 'expected.json') -MockArgs $m
        $run = Invoke-Collector -Endpoint "http://localhost:$port" -OutDir $outDir -CollectorArgs $CollectorArgs -TimeoutMinutes 5
        $counts = Stop-MockServer -Port $port -Process $mock
        $mock = $null
        $files = Get-RunFiles $outDir
        $ctx = [pscustomobject]@{ Run = $run; Counts = $counts; Files = $files; Summary = $files.Summary }
        if (-not $counts) { $problems += 'Could not read the mock counters.' }
        elseif ([int]$counts.CanaryHits -ne 0) { $problems += "Collector sent $($counts.CanaryHits) request(s) to another origin ($($counts.CanaryHitsWithToken) with a token)." }
        $problems += @(& $Assert $ctx)
    }
    catch { $problems += "Scenario error: $($_.Exception.Message)" }
    finally { if ($mock) { Stop-MockServer -Port $port -Process $mock | Out-Null } }
    Add-Result $Name $problems $sw.Elapsed.TotalSeconds
}

function Test-Completed {
    # Problems if the run did not finish normally and write a RunSummary.
    param($c)
    if ($c.Run.State -ne 'Completed' -or $c.Run.Error) { "Collector did not complete: $($c.Run.State) $($c.Run.Error)" }
    elseif (-not $c.Summary) { 'No RunSummary JSON was produced.' }
}

function Test-Failed {
    # Problems unless the run stopped with an error matching $Pattern and wrote no report.
    param($c, [string]$Pattern)
    $text = "$($c.Run.Error) $($c.Run.Output -join ' ')"
    if ($c.Run.State -eq 'Completed' -and -not $c.Run.Error) { 'Collector completed but should have stopped.' }
    elseif ($text -notmatch $Pattern) { "Error did not match '$Pattern': $($c.Run.Error)" }
    if ($c.Files.Csv) { 'A report CSV was written although the run should have stopped.' }
}

function Invoke-ValidationCase {
    # Runs the collector with arguments that must be rejected before any request is made.
    param([string]$Name, [hashtable]$CollectorArgs, [string]$Endpoint, [string]$Pattern)
    if ($Name -notlike $Only) { return }
    $outDir = Join-Path $outRoot $Name
    Reset-OutDir $outDir
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-Collector -Endpoint $Endpoint -OutDir $outDir -CollectorArgs $CollectorArgs -TimeoutMinutes 2
    $problems = @()
    if ($run.State -eq 'Completed' -and -not $run.Error) { $problems += 'Collector accepted the arguments.' }
    elseif ("$($run.Error)" -notmatch $Pattern) { $problems += "Error did not match '$Pattern': $($run.Error)" }
    Add-Result $Name $problems $sw.Elapsed.TotalSeconds
}

New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

#region Parameter validation (no mock; arguments are rejected at binding or before sign-in)
Invoke-ValidationCase 'Param-GraphEndpointHttp' @{ GraphEndpoint = 'http://graph.microsoft.com' } $null 'GraphEndpoint'
Invoke-ValidationCase 'Param-GraphEndpointOther' @{ GraphEndpoint = 'https://evil.example' } $null 'GraphEndpoint'
# The authentication methods API isn't available in the China (21Vianet) cloud.
Invoke-ValidationCase 'Param-GraphEndpointChina' @{ GraphEndpoint = 'https://microsoftgraph.chinacloudapi.cn' } $null 'GraphEndpoint'
Invoke-ValidationCase 'Param-TestEndpointNotLoopback' @{} 'http://example.com:18080' 'loopback'
Invoke-ValidationCase 'Param-TestEndpointWithPath' @{} 'http://localhost:18080/v1.0' 'loopback'
Invoke-ValidationCase 'Param-TestEndpointPlusGraphEndpoint' @{ GraphEndpoint = 'https://graph.microsoft.com' } 'http://localhost:18080' 'cannot be combined'

if ('Param-TestEndpointNeedsAccessToken' -like $Only) {
    # A missing mandatory parameter would prompt; -NonInteractive turns the prompt into an error.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # Windows PowerShell turns redirected native stderr into errors; don't let 'Stop' abort the suite.
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -NonInteractive -Command "& '$CollectorPath' -TestGraphEndpoint 'http://localhost:18080' -OutputPath '$outRoot\noToken'" 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    $problems = @()
    if ($out -notmatch 'AccessToken') { $problems += "Expected a missing -AccessToken error. Output: $($out.Trim())" }
    if ($out -match 'Signed in') { $problems += 'Collector signed in without -AccessToken.' }
    Add-Result 'Param-TestEndpointNeedsAccessToken' $problems $sw.Elapsed.TotalSeconds
}
#endregion

#region Origin, redirect and token handling
Invoke-Scenario 'Origin-ForeignNextLinkUsers' -UserCount 1200 -MockArgs @{ ForeignNextLink = 'users' } -Assert {
    param($c) Test-Failed $c 'next-page link outside'
}
Invoke-Scenario 'Origin-ForeignNextLinkNative' -UserCount 1200 -MockArgs @{ ForeignNextLink = 'native' } -CollectorArgs @{ CompareWithReport = $true } -Assert {
    param($c)
    Test-Completed $c
    if ($c.Summary) {
        if ($c.Summary.NativeComparisonStatus -ne 'Failed') { "NativeComparisonStatus '$($c.Summary.NativeComparisonStatus)' <> 'Failed'" }
        if ("$($c.Summary.NativeComparisonError)" -notmatch 'outside') { "NativeComparisonError does not mention the foreign link: $($c.Summary.NativeComparisonError)" }
        if (-not $c.Summary.ReportComplete) { 'A failed native comparison must not make the method report incomplete.' }
    }
}
Invoke-Scenario 'Redirect-Users' -MockArgs @{ Redirect = 'users' } -Assert { param($c) Test-Failed $c 'redirect' }
Invoke-Scenario 'Redirect-Batch' -MockArgs @{ Redirect = 'batch' } -Assert { param($c) Test-Failed $c 'redirect' }

$refreshOk = {
    param($c)
    Test-Completed $c
    if ($c.Summary) {
        if ([int]$c.Summary.TokenRefreshes -lt 1) { 'TokenRefreshes is 0; the expired token was not refreshed.' }
        if ([int]$c.Summary.UsersFailed -ne 0) { "$($c.Summary.UsersFailed) user(s) failed after the token refresh." }
        if (-not $c.Summary.ReportComplete) { "ReportComplete is false: $($c.Summary.CompletenessIssues -join ' | ')" }
    }
    if ($c.Counts -and [int]$c.Counts.Unauthorized -lt 1) { 'The mock never returned 401, so the scenario did not test anything.' }
}
Invoke-Scenario 'Token-ExpiredPerItem' -MockArgs @{ ExpireTokenAfterItems = 100; ExpireTokenMode = 'Item' } -Assert $refreshOk
Invoke-Scenario 'Token-ExpiredPerRequest' -MockArgs @{ ExpireTokenAfterItems = 100; ExpireTokenMode = 'Request' } -Assert $refreshOk
Invoke-Scenario 'Token-RefreshRejected' -MockArgs @{ ExpireTokenAfterItems = 100; ExpireTokenMode = 'Item'; RejectRefreshedTokens = $true } -CollectorArgs @{ MaxRetries = 3 } -Assert {
    param($c)
    if ($c.Run.State -eq 'Completed' -and $c.Summary) {
        if ($c.Summary.ReportComplete) { 'ReportComplete is true although users could not be read.' }
        if ([int]$c.Summary.UsersFailed -lt 1) { 'No failed users were recorded.' }
        if ($c.Files.Errors -and -not (@(Import-Csv -LiteralPath $c.Files.Errors.FullName) | Where-Object { $_.Error -match '401' })) { 'The errors CSV does not mention HTTP 401.' }
    }
    elseif ("$($c.Run.Error)" -notmatch '401') { "Run stopped without a 401 error: $($c.Run.Error)" }
}
#endregion

#region Completeness and native comparison status
Invoke-Scenario 'Complete-CleanRun' -MockArgs @{ ThrottleEveryNthItem = 20 } -CollectorArgs @{ CompareWithReport = $true } -Assert {
    param($c)
    Test-Completed $c
    if ($c.Summary) {
        if (-not $c.Summary.ReportComplete) { "ReportComplete is false: $($c.Summary.CompletenessIssues -join ' | ')" }
        if (@($c.Summary.CompletenessIssues).Count) { 'CompletenessIssues should be empty.' }
        if ($c.Summary.NativeComparisonStatus -ne 'Completed') { "NativeComparisonStatus '$($c.Summary.NativeComparisonStatus)' <> 'Completed'" }
        if ([int]$c.Summary.ThrottledItems -lt 1) { 'Mock throttled items but ThrottledItems is 0.' }
    }
    if ($c.Files.Errors) { 'An errors CSV was written for a clean run.' }
    if ($c.Files.Html) {
        $meta = (Get-HtmlData $c.Files.Html.FullName).Meta
        if (-not $meta -or $meta.complete -ne $true) { 'HTML META.complete is not true.' }
    }
}
Invoke-Scenario 'Complete-CountMismatch' -MockArgs @{ CountOffset = 5 } -CollectorArgs @{ UserFilter = 'accountEnabled eq true' } -Assert {
    param($c)
    Test-Completed $c
    if ($c.Summary) {
        if ($c.Summary.ReportComplete) { 'ReportComplete is true although @odata.count did not match.' }
        if (-not (@($c.Summary.CompletenessIssues) -match 'reported')) { "No count-mismatch issue: $($c.Summary.CompletenessIssues -join ' | ')" }
    }
    if ($c.Files.Html) {
        $meta = (Get-HtmlData $c.Files.Html.FullName).Meta
        if (-not $meta -or $meta.complete -ne $false) { 'HTML META.complete is not false.' }
    }
}
Invoke-Scenario 'Complete-MaxUsersTruncated' -CollectorArgs @{ MaxUsers = 100 } -Assert {
    param($c)
    Test-Completed $c
    if ($c.Summary) {
        if ($c.Summary.ReportComplete) { 'ReportComplete is true although -MaxUsers stopped enumeration.' }
        if (-not (@($c.Summary.CompletenessIssues) -match 'MaxUsers')) { "No MaxUsers issue: $($c.Summary.CompletenessIssues -join ' | ')" }
        if ([int]$c.Summary.UsersEnumerated -ne 100) { "UsersEnumerated $($c.Summary.UsersEnumerated) <> 100" }
    }
}
Invoke-Scenario 'Native-Forbidden' -MockArgs @{ NativeForbidden = $true } -CollectorArgs @{ CompareWithReport = $true } -Assert {
    param($c)
    Test-Completed $c
    if ($c.Summary) {
        if ($c.Summary.NativeComparisonStatus -ne 'Failed') { "NativeComparisonStatus '$($c.Summary.NativeComparisonStatus)' <> 'Failed'" }
        if (-not $c.Summary.ReportComplete) { 'A failed native comparison must not make the method report incomplete.' }
    }
    if ($c.Files.Html) {
        $meta = (Get-HtmlData $c.Files.Html.FullName).Meta
        if (-not $meta -or $meta.nativeStatus -ne 'Failed') { 'HTML META.nativeStatus is not Failed.' }
    }
}
Invoke-Scenario 'Native-NotRequested' -Assert {
    param($c)
    Test-Completed $c
    if ($c.Summary -and $c.Summary.NativeComparisonStatus -ne 'NotRequested') { "NativeComparisonStatus '$($c.Summary.NativeComparisonStatus)' <> 'NotRequested'" }
}
#endregion

#region End-to-end per-user check
if ('EndToEnd-MockTest' -like $Only) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $log = Join-Path $outRoot 'EndToEnd-MockTest.log'
    & powershell.exe -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Invoke-MockTest.ps1') -UserCount 1200 -Port $script:NextPort -TimeoutMinutes 10 *> $log
    $code = $LASTEXITCODE
    $problems = @()
    if ($code -ne 0) { $problems += "Invoke-MockTest.ps1 failed (exit $code). See $log"; $problems += @(Get-Content $log | Select-String '^\s{2}\S' | Select-Object -First 5 | ForEach-Object { $_.Line.Trim() }) }
    Add-Result 'EndToEnd-MockTest' $problems $sw.Elapsed.TotalSeconds
}
#endregion

Write-Host ''
$results | Format-Table Scenario, Result, Seconds -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host ("{0} passed, {1} failed" -f ($results.Count - $failed), $failed) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
if ($failed) { exit 1 }
