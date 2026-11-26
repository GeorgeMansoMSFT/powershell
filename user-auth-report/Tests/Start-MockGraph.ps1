<#
.SYNOPSIS
    Minimal Microsoft Graph mock for testing Get-EntraAuthMethodReport.ps1 offline.

.DESCRIPTION
    Serves /v1.0/users (paged, simple $filter), /v1.0/groups/{id} and
    /v1.0/groups/{id}/transitiveMembers/microsoft.graph.user, /v1.0/$batch (auth
    methods, with injected 429/503/403) and
    /v1.0/reports/authenticationMethods/userRegistrationDetails (with injected
    omissions and wrong passkey data). Like Graph, filters and group member casts
    require ConsistencyLevel: eventual and $count=true on every page.
    Group 11111111-1111-4111-8111-000000000003 holds every 3rd user and group
    11111111-1111-4111-8111-000000000005 every 5th user.
    Writes the expected per-user results to -ExpectedPath. Stop it with GET /shutdown.

    Failure injection for the regression tests:
      -ForbiddenEveryNth N      every Nth user (i % N == 1) returns 403; 0 disables
      -ExpireTokenAfterItems N  after N batch items the original token 'test' is rejected
                                (-ExpireTokenMode Item: per batch item; Request: whole requests).
                                Refreshed test tokens ('test-r<n>') are accepted unless
                                -RejectRefreshedTokens is set.
      -CanaryPort P             a second origin on localhost:P that counts any request it
                                receives (it should never receive one)
      -ForeignNextLink users|native   first page's @odata.nextLink points at the canary
      -Redirect users|batch     answer with 302 to the canary
      -CountOffset N            add N to @odata.count so it no longer matches the users returned
      -NativeForbidden          userRegistrationDetails returns 403
#>
param(
    [int]$Port = 18080,
    [int]$UserCount = 5000,
    [string]$ExpectedPath = (Join-Path $PSScriptRoot 'expected.json'),
    [int]$ThrottleEveryNthItem = 20,
    [int]$FailEveryNthBatch = 50,
    [int]$ForbiddenEveryNth = 1000,
    [int]$ExpireTokenAfterItems = 0,
    [ValidateSet('Item', 'Request')]
    [string]$ExpireTokenMode = 'Item',
    [switch]$RejectRefreshedTokens,
    [int]$CanaryPort = 0,
    [ValidateSet('', 'users', 'native')]
    [string]$ForeignNextLink = '',
    [ValidateSet('', 'users', 'batch')]
    [string]$Redirect = '',
    [int]$CountOffset = 0,
    [switch]$NativeForbidden
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web
$AuthenticatorAaGuid = '90a3ccdf-635c-4729-a248-9b709135078f'
$YubiKeyAaGuid = 'cb69481e-8ff7-4039-93ec-0a2729a154a8'
$nowIso = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Display names that a spreadsheet would treat as formulas; the CSV must prefix them with '.
$FormulaNames = @{
    6  = '=HYPERLINK("https://example.invalid","click")'
    12 = '@SUM(1+1)'
    14 = '+15555550100'
    18 = '-2+3'
}

$users = @{}
$expected = New-Object System.Collections.Generic.List[object]
for ($i = 1; $i -le $UserCount; $i++) {
    $id = '00000000-0000-4000-8000-{0:D12}' -f $i
    $enabled = ($i % 20) -ne 0
    $displayName = if ($i -eq 2) { 'O''Brien "<script>alert(1)</script>" & Co' } elseif ($FormulaNames.ContainsKey($i)) { $FormulaNames[$i] } else { "User $i" }
    $u = [ordered]@{
        id                    = $id
        userPrincipalName     = "user$i@contoso.test"
        displayName           = $displayName
        accountEnabled        = $enabled
        userType              = $(if ($i % 10 -eq 0) { 'Guest' } else { 'Member' })
        onPremisesSyncEnabled = $(if ($i % 2) { $true } else { $null })
        createdDateTime       = $(if ($i % 500 -eq 3) { $nowIso } else { '2021-03-04T05:06:07Z' })
    }
    $methods = New-Object System.Collections.Generic.List[object]
    $methods.Add(@{ '@odata.type' = '#microsoft.graph.passwordAuthenticationMethod'; id = '28c10230-6103-485e-b985-444c60001490'; createdDateTime = $null })
    if ($i % 3 -eq 0) { $methods.Add(@{ '@odata.type' = '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'; id = "a-$i"; displayName = $(if ($i -eq 6) { '=iPhone' } else { "iPhone $i" }); deviceTag = 'SoftwareTokenActivated'; phoneAppVersion = '6.8.7'; createdDateTime = '2023-01-01T00:00:00Z' }) }
    $hasPasskey = ($i % 4 -eq 0)
    if ($hasPasskey) {
        $inAuth = ($i % 8 -eq 0)
        $methods.Add(@{ '@odata.type' = '#microsoft.graph.fido2AuthenticationMethod'; id = "f-$i"; displayName = $(if ($i -eq 24) { '@evil' } else { 'My key' })
            aaGuid = $(if ($inAuth) { $AuthenticatorAaGuid } else { $YubiKeyAaGuid })
            model = $(if ($inAuth) { 'Microsoft Authenticator - iOS' } else { 'YubiKey 5 Series' })
            attestationLevel = 'attested'; creationDateTime = $(if ($i % 400 -eq 4) { $nowIso } else { '2025-06-01T10:00:00Z' }) })
    }
    if ($i % 5 -eq 0) { $methods.Add(@{ '@odata.type' = '#microsoft.graph.phoneAuthenticationMethod'; id = "p-$i"; phoneNumber = '+1 5555550100'; phoneType = 'mobile'; smsSignInState = 'notAllowedByPolicy' }) }
    if ($i % 7 -eq 0) { $methods.Add(@{ '@odata.type' = '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod'; id = "w-$i"; displayName = "LAPTOP-$i"; keyStrength = 'normal'; createdDateTime = '2024-02-02T00:00:00Z' }) }
    if ($i % 11 -eq 0) { $methods.Add(@{ '@odata.type' = '#microsoft.graph.softwareOathAuthenticationMethod'; id = "s-$i"; secretKey = $null }) }
    if ($i % 13 -eq 0) { $methods.Add(@{ '@odata.type' = '#microsoft.graph.temporaryAccessPassAuthenticationMethod'; id = "t-$i"; isUsable = $true; createdDateTime = '2025-01-01T00:00:00Z' }) }
    if ($i % 17 -eq 0) { $methods.Add(@{ '@odata.type' = '#microsoft.graph.emailAuthenticationMethod'; id = "e-$i"; emailAddress = "u$i@example.com" }) }
    if ($i % 97 -eq 0) { $methods.Add(@{ '@odata.type' = '#microsoft.graph.futureThingAuthenticationMethod'; id = "x-$i" }) }

    $forbidden = $ForbiddenEveryNth -gt 0 -and ($i % $ForbiddenEveryNth -eq 1)
    $isMfa = ($i % 3 -eq 0) -or $hasPasskey -or ($i % 5 -eq 0) -or ($i % 7 -eq 0) -or ($i % 11 -eq 0)

    # Native report behaviour: disabled users are excluded (as in Entra); some
    # enabled users are omitted (the bug); some passkeys are missing or stale.
    $nativeOmitted = (-not $enabled) -or ($i % 250 -eq 3)
    $nativeMethods = New-Object System.Collections.Generic.List[string]
    if ($i % 3 -eq 0) { $nativeMethods.Add('microsoftAuthenticatorPush') }
    $nativeDropsPasskey = $hasPasskey -and ($i % 100 -eq 4)
    if ($hasPasskey -and -not $nativeDropsPasskey) { $nativeMethods.Add('passKeyDeviceBound') }
    $nativeStalePasskey = (-not $hasPasskey) -and ($i % 300 -eq 7)
    if ($nativeStalePasskey) { $nativeMethods.Add('passKeyDeviceBound') }
    if ($i % 5 -eq 0) { $nativeMethods.Add('mobilePhone') }
    if ($i % 7 -eq 0) { $nativeMethods.Add('windowsHelloForBusiness') }
    if ($i % 11 -eq 0) { $nativeMethods.Add('softwareOneTimePasscode') }

    $disc = ''
    if (-not $forbidden) {
        if ($nativeOmitted) { if ($enabled) { $disc = 'Missing from native report' } }
        elseif ($nativeDropsPasskey) { $disc = 'Passkey not shown in native report' }
        elseif ($nativeStalePasskey) { $disc = 'Native report shows passkey that is no longer registered' }
    }

    $users[$id] = @{ User = $u; Methods = $methods; Forbidden = $forbidden; NativeOmitted = $nativeOmitted; Native = @{
        id = $id; userPrincipalName = $u.userPrincipalName; userDisplayName = $u.displayName; isMfaCapable = $isMfa
        isMfaRegistered = $isMfa; isPasswordlessCapable = $hasPasskey; methodsRegistered = $nativeMethods.ToArray() } }
    # Values that could not be read are expected to be empty (unknown), not False/0.
    $expected.Add([pscustomobject]@{
        Index = $i; Enabled = $enabled; UserType = $u.userType
        UserPrincipalName = $u.userPrincipalName; Status = $(if ($forbidden) { 'Error' } else { 'OK' })
        DisplayNameCsv = $(if ($FormulaNames.ContainsKey($i)) { "'" + $displayName } else { $displayName })
        HasPasskey = $(if ($forbidden) { $null } else { $hasPasskey })
        HasPasskeyInAuthenticator = $(if ($forbidden) { $null } else { $hasPasskey -and ($i % 8 -eq 0) })
        HasMfaMethodRegistered = $(if ($forbidden) { $null } else { $isMfa })
        MethodCount = $(if ($forbidden) { $null } else { $methods.Count - 1 }); Discrepancy = $disc
    })
}
$expected | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ExpectedPath -Encoding UTF8
$ids = @($users.Keys | Sort-Object)
$groups = @{
    '11111111-1111-4111-8111-000000000003' = @{ Name = 'Every 3rd user'; Ids = @($ids | Where-Object { [int]$_.Substring(24) % 3 -eq 0 }) }
    '11111111-1111-4111-8111-000000000005' = @{ Name = 'Every 5th user'; Ids = @($ids | Where-Object { [int]$_.Substring(24) % 5 -eq 0 }) }
}

$counters = @{ Items = 0; Batches = 0; Throttled = 0; Failed503 = 0; AdvancedQueries = 0; Unauthorized = 0; CanaryHits = 0; CanaryHitsWithToken = 0 }
$canaryRoot = "http://localhost:$CanaryPort"

function Test-TokenAccepted([string]$Header) {
    if ($Header -eq 'Bearer test') { return -not ($ExpireTokenAfterItems -and $counters.Items -ge $ExpireTokenAfterItems) }
    if ($Header -match '^Bearer test-r\d+$') { return -not $RejectRefreshedTokens }
    return $false
}

function Test-AdvancedQuery($ctx, $query) {
    $ok = ($ctx.Request.Headers['ConsistencyLevel'] -eq 'eventual') -and ($query['$count'] -eq 'true')
    if ($ok) { $counters.AdvancedQueries++ }
    return $ok
}

function Select-FilteredIds([string[]]$Pool, [string]$Filter) {
    # Supports "<clause> and <clause>" with accountEnabled eq true|false and userType eq '<value>'.
    # Returns $null for anything else so the caller can answer 400.
    if (-not $Filter) { return , $Pool }
    $clauses = foreach ($c in ($Filter -split ' and ')) {
        if ($c.Trim() -match '^accountEnabled eq (true|false)$') { @{ Prop = 'accountEnabled'; Value = ($Matches[1] -eq 'true') } }
        elseif ($c.Trim() -match "^userType eq '(\w+)'$") { @{ Prop = 'userType'; Value = $Matches[1] } }
        else { return $null }
    }
    $result = @($Pool | Where-Object {
        $u = $users[$_].User
        $match = $true
        foreach ($cl in $clauses) { if ($u[$cl.Prop] -ne $cl.Value) { $match = $false } }
        $match
    })
    return , $result
}

function Send-UserPage($ctx, [string[]]$Pool, $query, [string]$Path) {
    $top = [int]$query['$top']; if (-not $top) { $top = 100 }
    $skip = [int]$query['$skiptoken']
    $body = [ordered]@{}
    if ($query['$count'] -eq 'true') { $body['@odata.count'] = $Pool.Count + $CountOffset }
    $body['value'] = @($Pool | Select-Object -Skip $skip -First $top | ForEach-Object { $users[$_].User })
    if ($skip + $top -lt $Pool.Count) {
        $origin = if ($ForeignNextLink -eq 'users') { $canaryRoot } else { "http://localhost:$Port" }
        $next = "$origin$Path`?`$select=$($query['$select'])&`$top=$top&`$skiptoken=$($skip + $top)"
        if ($query['$filter']) { $next += '&$filter=' + [uri]::EscapeDataString($query['$filter']) }
        if ($query['$count']) { $next += '&$count=' + $query['$count'] }
        $body['@odata.nextLink'] = $next
    }
    Send-Json $ctx 200 $body
}

$unsupportedQuery = @{ error = @{ code = 'Request_UnsupportedQuery'; message = 'Advanced query requires ConsistencyLevel: eventual and $count=true.' } }

function Send-Json($ctx, [int]$Status, $Object, [hashtable]$Headers) {
    $json = if ($Object -is [string]) { $Object } else { $Object | ConvertTo-Json -Depth 10 -Compress }
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode = $Status
    $ctx.Response.ContentType = 'application/json'
    if ($Headers) { foreach ($k in $Headers.Keys) { $ctx.Response.Headers[$k] = $Headers[$k] } }
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
if ($CanaryPort) { $listener.Prefixes.Add("$canaryRoot/") }
$listener.Start()
Write-Host "Mock Graph listening on http://localhost:$Port/ with $UserCount users"
$redirectTarget = "$canaryRoot/v1.0/stolen"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        $query = [System.Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query)
        try {
            if ($CanaryPort -and $ctx.Request.Url.Port -eq $CanaryPort) {
                # A request here means the collector left the Graph origin.
                $counters.CanaryHits++
                if ($ctx.Request.Headers['Authorization']) { $counters.CanaryHitsWithToken++ }
                Send-Json $ctx 200 @{ value = @(); responses = @() }; continue
            }
            if ($path -eq '/shutdown') { Send-Json $ctx 200 $counters; break }
            if ($path -eq '/ready') { Send-Json $ctx 200 @{ ready = $true }; continue }
            $auth = $ctx.Request.Headers['Authorization']
            $requestLevelCheck = ($ExpireTokenMode -eq 'Request') -or ($auth -ne 'Bearer test')
            if ($requestLevelCheck -and -not (Test-TokenAccepted $auth)) {
                $counters.Unauthorized++
                Send-Json $ctx 401 @{ error = @{ code = 'InvalidAuthenticationToken'; message = 'Bad token' } }; continue
            }
            if ($Redirect -and $path -eq $(if ($Redirect -eq 'users') { '/v1.0/users' } else { '/v1.0/$batch' })) {
                $ctx.Response.StatusCode = 302
                $ctx.Response.RedirectLocation = $redirectTarget
                $ctx.Response.Close(); continue
            }

            if ($path -eq '/v1.0/users') {
                if ($query['$filter'] -and -not (Test-AdvancedQuery $ctx $query)) { Send-Json $ctx 400 $unsupportedQuery; continue }
                $pool = Select-FilteredIds $ids $query['$filter']
                if ($null -eq $pool) { Send-Json $ctx 400 @{ error = @{ code = 'Request_UnsupportedQuery'; message = 'Mock does not support this filter.' } }; continue }
                Send-UserPage $ctx $pool $query $path
            }
            elseif ($path -match '^/v1\.0/groups/([0-9a-fA-F-]+)/transitiveMembers/microsoft\.graph\.user$') {
                $g = $groups[$Matches[1].ToLower()]
                if (-not $g) { Send-Json $ctx 404 @{ error = @{ code = 'Request_ResourceNotFound'; message = 'Group not found' } }; continue }
                if (-not (Test-AdvancedQuery $ctx $query)) { Send-Json $ctx 400 $unsupportedQuery; continue }
                $pool = Select-FilteredIds $g.Ids $query['$filter']
                if ($null -eq $pool) { Send-Json $ctx 400 @{ error = @{ code = 'Request_UnsupportedQuery'; message = 'Mock does not support this filter.' } }; continue }
                Send-UserPage $ctx $pool $query $path
            }
            elseif ($path -match '^/v1\.0/groups/([0-9a-fA-F-]+)$') {
                $gid = $Matches[1].ToLower()
                if (-not $groups.ContainsKey($gid)) { Send-Json $ctx 404 @{ error = @{ code = 'Request_ResourceNotFound'; message = 'Group not found' } }; continue }
                Send-Json $ctx 200 @{ id = $gid; displayName = $groups[$gid].Name }
            }
            elseif ($path -eq '/v1.0/$batch') {
                $counters.Batches++
                $reader = New-Object IO.StreamReader($ctx.Request.InputStream)
                $req = $reader.ReadToEnd() | ConvertFrom-Json
                if ($FailEveryNthBatch -and ($counters.Batches % $FailEveryNthBatch -eq 0)) {
                    $counters.Failed503++
                    Send-Json $ctx 503 @{ error = @{ code = 'ServiceUnavailable'; message = 'Mock outage' } } @{ 'Retry-After' = '1' }; continue
                }
                $responses = foreach ($r in $req.requests) {
                    $counters.Items++
                    $uid = ([regex]::Match($r.url, '^/users/([^/]+)/authentication/methods$')).Groups[1].Value
                    if ($ThrottleEveryNthItem -and ($counters.Items % $ThrottleEveryNthItem -eq 0)) {
                        $counters.Throttled++
                        @{ id = $r.id; status = 429; headers = @{ 'Retry-After' = '1' }; body = @{ error = @{ code = 'TooManyRequests'; message = 'Throttled' } } }
                    }
                    elseif (-not (Test-TokenAccepted $auth)) {
                        $counters.Unauthorized++
                        @{ id = $r.id; status = 401; body = @{ error = @{ code = 'InvalidAuthenticationToken'; message = 'Lifetime validation failed, the token is expired.' } } }
                    }
                    elseif (-not $users.ContainsKey($uid)) {
                        @{ id = $r.id; status = 404; body = @{ error = @{ code = 'Request_ResourceNotFound'; message = 'Not found' } } }
                    }
                    elseif ($users[$uid].Forbidden) {
                        @{ id = $r.id; status = 403; body = @{ error = @{ code = 'accessDenied'; message = 'Request Authorization failed' } } }
                    }
                    else {
                        @{ id = $r.id; status = 200; body = @{ value = $users[$uid].Methods.ToArray() } }
                    }
                }
                Send-Json $ctx 200 @{ responses = @($responses) }
            }
            elseif ($path -eq '/v1.0/reports/authenticationMethods/userRegistrationDetails') {
                if ($NativeForbidden) { Send-Json $ctx 403 @{ error = @{ code = 'Authentication_RequestFromUnsupportedUserRole'; message = 'Insufficient privileges' } }; continue }
                $top = 1000
                $skip = [int]$query['$skiptoken']
                $visible = @($ids | Where-Object { -not $users[$_].NativeOmitted })
                $slice = @($visible | Select-Object -Skip $skip -First $top | ForEach-Object { $users[$_].Native })
                $body = @{ value = $slice }
                if ($skip + $top -lt $visible.Count) {
                    $origin = if ($ForeignNextLink -eq 'native') { $canaryRoot } else { "http://localhost:$Port" }
                    $body['@odata.nextLink'] = "$origin/v1.0/reports/authenticationMethods/userRegistrationDetails?`$skiptoken=$($skip + $top)"
                }
                Send-Json $ctx 200 $body
            }
            else {
                Send-Json $ctx 404 @{ error = @{ code = 'NotFound'; message = "No mock for $path" } }
            }
        }
        catch {
            try { Send-Json $ctx 500 @{ error = @{ code = 'MockError'; message = $_.Exception.Message } } } catch { }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
