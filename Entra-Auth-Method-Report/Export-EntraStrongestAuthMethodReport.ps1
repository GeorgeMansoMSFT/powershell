<#
.SYNOPSIS
Exports a customer-ready Microsoft Entra authentication posture report.

.DESCRIPTION
The report separates authentication-method registration from the methods that
were explicitly recorded in successful interactive sign-ins. It never equates
missing sign-in detail with a user not using MFA.

OUTPUTS
* Per-user posture CSV: registered strength, explicitly observed strength, and
  evidence coverage.
* Summary CSV: tier distribution and sign-in evidence coverage.
* Evidence CSV: auditable source records for each explicitly observed method.
* Executive HTML summary: aggregate customer-facing posture overview.
* XLSX workbook: created automatically when desktop Excel is available.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3650)]
    [int] $DaysBack = 30,

    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path (Join-Path $PSScriptRoot 'output') ("Entra-AuthPosture-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))),

    [string] $TenantId,

    [bool] $IncludeGuests = $true,

    [bool] $IncludeSignInActivity = $true,

    [bool] $ExportEvidence = $true,

    [bool] $PackageDeliverables = $true,

    [bool] $GenerateHtmlSummary = $true,

    [ValidateRange(1, 168)]
    [int] $SignInQueryChunkHours = 24,

    [ValidateRange(1, 10)]
    [int] $GraphMaxRetryAttempts = 6,

    [ValidateRange(0, 1000000)]
    [int] $MaxEvidenceRowsInWorkbook = 100000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)][object] $Object,
        [Parameter(Mandatory)][string] $Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-GraphRetryDelaySeconds {
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord,
        [Parameter(Mandatory)][int] $Attempt
    )

    $retryAfter = $null
    $response = Get-OptionalPropertyValue -Object $ErrorRecord.Exception -Name 'Response'
    $headers = Get-OptionalPropertyValue -Object $response -Name 'Headers'
    if ($null -ne $headers) {
        try {
            $headerValues = $null
            if ($headers.TryGetValues('Retry-After', [ref]$headerValues)) {
                $retryAfterText = @($headerValues | Select-Object -First 1)[0]
                $parsed = 0
                if ([int]::TryParse($retryAfterText, [ref]$parsed) -and $parsed -gt 0) { $retryAfter = $parsed }
            }
        }
        catch { }
    }

    if ($null -ne $retryAfter) { return [Math]::Min($retryAfter, 300) }
    return [Math]::Min([int][Math]::Pow(2, $Attempt), 60)
}

function Test-TransientGraphFailure {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord] $ErrorRecord)

    $statusCode = $null
    $response = Get-OptionalPropertyValue -Object $ErrorRecord.Exception -Name 'Response'
    $responseStatusCode = Get-OptionalPropertyValue -Object $response -Name 'StatusCode'
    if ($null -ne $responseStatusCode) { $statusCode = [int]$responseStatusCode }
    if ($null -eq $statusCode) {
        $match = [regex]::Match($ErrorRecord.Exception.Message, 'HTTP/\d(?:\.\d)?\s+(429|500|502|503|504)')
        if ($match.Success) { $statusCode = [int]$match.Groups[1].Value }
    }
    return $statusCode -in @(429, 500, 502, 503, 504)
}

function Invoke-GraphGetWithRetry {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][int] $MaxAttempts
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        }
        catch {
            if ($attempt -ge $MaxAttempts -or -not (Test-TransientGraphFailure -ErrorRecord $_)) { throw }
            $delaySeconds = Get-GraphRetryDelaySeconds -ErrorRecord $_ -Attempt $attempt
            Write-Verbose "Microsoft Graph request failed transiently (attempt $attempt of $MaxAttempts). Retrying after $delaySeconds seconds."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][int] $MaxAttempts
    )

    do {
        $response = Invoke-GraphGetWithRetry -Uri $Uri -MaxAttempts $MaxAttempts
        foreach ($item in @(Get-OptionalPropertyValue -Object $response -Name 'value')) { $item }
        $nextLink = Get-OptionalPropertyValue -Object $response -Name '@odata.nextLink'
        $Uri = if ([string]::IsNullOrWhiteSpace($nextLink)) { $null } else { $nextLink }
    } while (-not [string]::IsNullOrWhiteSpace($Uri))
}

function Get-AuthTier {
    param([AllowNull()][object] $Score)

    if ($null -eq $Score -or [int]$Score -le 0) { return 'None / unclassified' }
    if ([int]$Score -ge 90) { return 'Phishing-resistant MFA' }
    if ([int]$Score -ge 80) { return 'Passwordless MFA' }
    if ([int]$Score -ge 50) { return 'Strong MFA (app, token, or TAP)' }
    if ([int]$Score -ge 30) { return 'Phone-based MFA' }
    return 'Single-factor / SSPR only'
}

function ConvertTo-AuthMethod {
    param(
        [AllowNull()][string] $Method,
        [AllowNull()][string] $Detail
    )

    $methodText = if ($null -eq $Method) { '' } else { $Method.Trim() }
    $detailText = if ($null -eq $Detail) { '' } else { $Detail.Trim() }
    $text = "$methodText $detailText".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    # These entries tell us a previous token or session satisfied a requirement;
    # they are not a fresh authentication method for this specific sign-in.
    if ($text -match '(?i)satisfied by token|previously satisfied') { return $null }

    # The score is a transparent reporting policy, not a Microsoft assurance
    # claim. Adjust this one function to match the customer's approved methods.
    $classification = if ($text -match '(?i)fido|passkey|security\s*key') {
        @{ Name = 'FIDO2 security key / passkey'; Score = 100 }
    }
    elseif ($text -match '(?i)windows\s*hello') {
        @{ Name = 'Windows Hello for Business'; Score = 95 }
    }
    elseif ($text -match '(?i)certificate|x509|x\.509|cba') {
        @{ Name = 'Certificate-based authentication'; Score = 90 }
    }
    elseif ($text -match '(?i)authenticator.*passwordless|passwordless.*authenticator|passwordless phone sign-in') {
        @{ Name = 'Microsoft Authenticator passwordless'; Score = 85 }
    }
    elseif ($text -match '(?i)authenticator app|microsoftauthenticatorpush|authenticator.*push|mobile\s*app\s*notification') {
        @{ Name = 'Microsoft Authenticator push'; Score = 70 }
    }
    elseif ($text -match '(?i)temporary.*access.*pass|temporaryaccesspass') {
        @{ Name = 'Temporary Access Pass'; Score = 60 }
    }
    elseif ($text -match '(?i)hardware.*oath|hardwareonetimepasscode|hardwareoath') {
        @{ Name = 'Hardware OATH token'; Score = 55 }
    }
    elseif ($text -match '(?i)software.*oath|softwareonetimepasscode|softwareoath|oath verification code|mobile\s*app\s*verification\s*code') {
        @{ Name = 'Software OATH token'; Score = 50 }
    }
    elseif ($text -match '(?i)sms|text message|voice|phone|mobilephone|officephone') {
        @{ Name = 'Phone (SMS or voice)'; Score = 30 }
    }
    elseif ($text -match '(?i)email') {
        @{ Name = 'Email one-time passcode'; Score = 20 }
    }
    elseif ($text -match '(?i)password') {
        @{ Name = 'Password'; Score = 10 }
    }
    elseif ($text -match '(?i)security question') {
        @{ Name = 'Security question'; Score = 10 }
    }
    else {
        @{ Name = "Unclassified: $methodText"; Score = 0 }
    }

    [pscustomobject]@{
        Name  = $classification.Name
        Score = [int]$classification.Score
        Raw   = $methodText
        Detail = $detailText
    }
}

function Get-HighestMethod {
    param([AllowEmptyCollection()][object[]] $Methods)

    $highest = $null
    foreach ($method in $Methods) {
        if ($null -eq $method) { continue }
        if ($null -eq $highest -or $method.Score -gt $highest.Score) { $highest = $method }
    }
    return $highest
}

function Get-ObservationStatus {
    param(
        [Parameter(Mandatory)][string] $SignInStatus,
        [Parameter(Mandatory)][int] $SuccessfulSignIns,
        [Parameter(Mandatory)][int] $ExplicitMethodSignIns
    )

    if ($SignInStatus -eq 'disabled') { return 'Sign-in activity was not requested' }
    if ($SignInStatus -eq 'failed') { return 'Sign-in activity retrieval failed' }
    if ($SuccessfulSignIns -eq 0) { return 'No successful interactive sign-in in the window' }
    if ($ExplicitMethodSignIns -eq 0) { return 'No explicit method in returned sign-in details' }
    if ($ExplicitMethodSignIns -lt $SuccessfulSignIns) { return 'Partial explicit-method evidence' }
    return 'Explicit method observed in all successful sign-ins'
}

function ConvertTo-CsvField {
    param([AllowNull()][object] $Value)
    $text = if ($null -eq $Value) { '' } else { $Value.ToString() }
    return '"' + $text.Replace('"', '""') + '"'
}

function Write-EvidenceCsvRow {
    param(
        [Parameter(Mandatory)][System.IO.StreamWriter] $Writer,
        [Parameter(Mandatory)][object] $Row,
        [Parameter(Mandatory)][string[]] $Columns
    )

    $fields = foreach ($column in $Columns) {
        $property = $Row.PSObject.Properties[$column]
        ConvertTo-CsvField -Value $(if ($null -eq $property) { $null } else { $property.Value })
    }
    $Writer.WriteLine(($fields -join ','))
}

function Test-TrueLikeValue {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $false }
    return $Value -eq $true -or $Value.ToString().Equals('True', [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-ConsoleSummary {
    param(
        [Parameter(Mandatory)][object[]] $Report,
        [Parameter(Mandatory)][object[]] $Summary
    )

    $totalUsers = $Report.Count
    $tierRows = @($Summary | Where-Object { $_.RecordType -eq 'Tier distribution' })
    $coverageRow = @($Summary | Where-Object { $_.RecordType -eq 'Evidence coverage' } | Select-Object -First 1)[0]

    Write-Host ''
    Write-Host '=== Entra authentication posture - tenant summary ===' -ForegroundColor Yellow
    Write-Host ('{0,-38} {1,7} {2,10}' -f 'Registered strength tier', 'Users', '% of scope') -ForegroundColor Gray
    Write-Host ('{0,-38} {1,7} {2,10}' -f ('-' * 38), ('-' * 7), ('-' * 10)) -ForegroundColor DarkGray
    foreach ($tierRow in $tierRows) {
        $count = [int]$tierRow.RegisteredUserCount
        $percent = if ($totalUsers -gt 0) { $count / $totalUsers } else { 0 }
        $color = switch ($tierRow.StrengthTier) {
            'Phishing-resistant MFA' { 'Green' }
            'Passwordless MFA' { 'Cyan' }
            'Strong MFA (app, token, or TAP)' { 'Green' }
            'Phone-based MFA' { 'Yellow' }
            'Single-factor / SSPR only' { 'Yellow' }
            'None / unclassified' { 'Red' }
            default { 'White' }
        }
        Write-Host ('{0,-38} {1,7} {2,10:P1}' -f $tierRow.StrengthTier, $count, $percent) -ForegroundColor $color
    }

    $mfaCapable = @($Report | Where-Object { Test-TrueLikeValue -Value $_.IsMfaCapable }).Count
    $passwordlessCapable = @($Report | Where-Object { Test-TrueLikeValue -Value $_.IsPasswordlessCapable }).Count
    $phishingResistant = @($Report | Where-Object { $_.StrongestRegisteredTier -eq 'Phishing-resistant MFA' }).Count
    $unclassified = @($Report | Where-Object { $_.StrongestRegisteredTier -eq 'None / unclassified' }).Count
    $successfulSignIns = if ($null -ne $coverageRow) { [int]$coverageRow.SuccessfulInteractiveSignInCount } else { 0 }
    $explicitMethodSignIns = if ($null -ne $coverageRow) { [int]$coverageRow.ExplicitMethodSignInCount } else { 0 }
    $coverage = if ($successfulSignIns -gt 0) { $explicitMethodSignIns / $successfulSignIns } else { 0 }

    Write-Host ''
    Write-Host ('{0,-38}: {1,7}' -f 'Total users', $totalUsers) -ForegroundColor White
    Write-Host ('{0,-38}: {1,7} ({2:P1})' -f 'MFA-capable', $mfaCapable, $(if ($totalUsers -gt 0) { $mfaCapable / $totalUsers } else { 0 })) -ForegroundColor Green
    Write-Host ('{0,-38}: {1,7} ({2:P1})' -f 'Passwordless-capable', $passwordlessCapable, $(if ($totalUsers -gt 0) { $passwordlessCapable / $totalUsers } else { 0 })) -ForegroundColor Cyan
    Write-Host ('{0,-38}: {1,7} ({2:P1})' -f 'Phishing-resistant registration', $phishingResistant, $(if ($totalUsers -gt 0) { $phishingResistant / $totalUsers } else { 0 })) -ForegroundColor Green
    Write-Host ('{0,-38}: {1,7} ({2:P1})' -f 'No classified registration', $unclassified, $(if ($totalUsers -gt 0) { $unclassified / $totalUsers } else { 0 })) -ForegroundColor Red
    if ($successfulSignIns -gt 0) {
        $evidenceColor = if ($coverage -ge 0.75) { 'Green' } elseif ($coverage -ge 0.25) { 'Yellow' } else { 'Red' }
        Write-Host ('{0,-38}: {1,7} of {2,7} ({3:P1})' -f 'Explicit-method evidence', $explicitMethodSignIns, $successfulSignIns, $coverage) -ForegroundColor $evidenceColor
    }
    else {
        Write-Host ('{0,-38}: {1}' -f 'Explicit-method evidence', 'No successful interactive sign-ins') -ForegroundColor DarkYellow
    }
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Microsoft.Graph.Authentication is required. Install it with: Install-Module Microsoft.Graph -Scope CurrentUser'
}

# Keep Graph module loader diagnostics out of this script's useful -Verbose output.
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop -Verbose:$false 4>$null
$context = Get-MgContext
$needsConnection = $null -eq $context -or $context.Scopes -notcontains 'AuditLog.Read.All'
if ($TenantId -and ($null -eq $context -or $context.TenantId -ne $TenantId)) { $needsConnection = $true }
if ($needsConnection) {
    $connectParams = @{ Scopes = 'AuditLog.Read.All'; NoWelcome = $true }
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    Connect-MgGraph @connectParams
}

$runUtc = (Get-Date).ToUniversalTime()
$startUtc = $runUtc.AddDays(-$DaysBack)
$startText = $startUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$endText = $runUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$outputDirectory = Split-Path -Parent $OutputPath
if ([string]::IsNullOrWhiteSpace($outputDirectory)) { $outputDirectory = '.' }
if (-not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
$outputBase = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
$summaryPath = Join-Path $outputDirectory "$outputBase-summary.csv"
$evidencePath = Join-Path $outputDirectory "$outputBase-evidence.csv"

Write-Verbose 'Retrieving registration details from Microsoft Graph v1.0.'
$registrations = @(Get-GraphCollection -Uri 'https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails?$top=999' -MaxAttempts $GraphMaxRetryAttempts)

$usageByUser = @{}
$evidenceColumns = @('UserPrincipalName','UserId','SignInId','CreatedDateTimeUtc','AppDisplayName','ClientAppUsed','AuthenticationRequirement','ConditionalAccessStatus','ExplicitMethodForSignIn','ExplicitMethodScore','RawAuthenticationSteps','IpAddress','DeviceName','OperatingSystem','Browser','IsManaged','IsCompliant')
$evidenceWriter = $null
$evidenceCount = 0
$unmappedRegistered = @{}
$unmappedSignIn = @{}
$signInStatus = if ($IncludeSignInActivity) { 'ok' } else { 'disabled' }

if ($IncludeSignInActivity) {
    try {
        Write-Verbose "Retrieving interactive sign-ins from $startText through $endText in $SignInQueryChunkHours-hour chunks (Graph beta)."
        $processedSignIns = 0
        $chunkCount = 0

        for ($chunkStart = $startUtc; $chunkStart -lt $runUtc; $chunkStart = $chunkEnd) {
            $chunkEnd = if ($chunkStart.AddHours($SignInQueryChunkHours) -lt $runUtc) { $chunkStart.AddHours($SignInQueryChunkHours) } else { $runUtc }
            $chunkCount++
            $chunkStartText = $chunkStart.ToString('yyyy-MM-ddTHH:mm:ssZ')
            $chunkEndText = $chunkEnd.ToString('yyyy-MM-ddTHH:mm:ssZ')
            $filter = "createdDateTime ge $chunkStartText and createdDateTime lt $chunkEndText"
            # The beta sign-ins endpoint supports filtering but rejects $select when
            # authenticationDetails is requested, so the full sign-in is retrieved.
            $signInUri = 'https://graph.microsoft.com/beta/auditLogs/signIns?$top=1000&$filter={0}' -f [uri]::EscapeDataString($filter)
            Write-Verbose "Retrieving sign-in chunk $($chunkCount): $chunkStartText through (exclusive) $chunkEndText."

            foreach ($signIn in (Get-GraphCollection -Uri $signInUri -MaxAttempts $GraphMaxRetryAttempts)) {
            $processedSignIns++
            $status = Get-OptionalPropertyValue -Object $signIn -Name 'status'
            $errorCode = Get-OptionalPropertyValue -Object $status -Name 'errorCode'
            if ($null -eq $errorCode -or [int]$errorCode -ne 0) { continue }

            $userId = Get-OptionalPropertyValue -Object $signIn -Name 'userId'
            if ([string]::IsNullOrWhiteSpace($userId)) { continue }
            $userKey = $userId.ToString().ToLowerInvariant()
            $when = [datetimeoffset](Get-OptionalPropertyValue -Object $signIn -Name 'createdDateTime')

            if (-not $usageByUser.ContainsKey($userKey)) {
                $usageByUser[$userKey] = [pscustomobject]@{
                    SuccessfulSignInCount       = 0
                    ExplicitMethodSignInCount   = 0
                    MfaRequiredSignInCount      = 0
                    LastSuccessfulSignIn        = $null
                    MethodStats                 = @{}
                }
            }
            $usage = $usageByUser[$userKey]
            $usage.SuccessfulSignInCount++
            if ($null -eq $usage.LastSuccessfulSignIn -or $when -gt $usage.LastSuccessfulSignIn) { $usage.LastSuccessfulSignIn = $when }
            if ((Get-OptionalPropertyValue -Object $signIn -Name 'authenticationRequirement') -eq 'multiFactorAuthentication') { $usage.MfaRequiredSignInCount++ }

            $methodsForEvent = @()
            $rawSteps = @()
            foreach ($step in @(Get-OptionalPropertyValue -Object $signIn -Name 'authenticationDetails')) {
                $stepSucceeded = Get-OptionalPropertyValue -Object $step -Name 'succeeded'
                if ($null -ne $stepSucceeded -and -not [bool]$stepSucceeded) { continue }
                $rawMethod = Get-OptionalPropertyValue -Object $step -Name 'authenticationMethod'
                $rawDetail = Get-OptionalPropertyValue -Object $step -Name 'authenticationMethodDetail'
                if (-not [string]::IsNullOrWhiteSpace($rawMethod)) {
                    $rawSteps += if ([string]::IsNullOrWhiteSpace($rawDetail)) { $rawMethod } else { "$rawMethod ($rawDetail)" }
                }
                $classified = ConvertTo-AuthMethod -Method $rawMethod -Detail $rawDetail
                if ($null -eq $classified) { continue }
                if ($classified.Score -eq 0) {
                    $rawKey = if ([string]::IsNullOrWhiteSpace($rawMethod)) { '<blank>' } else { $rawMethod }
                    if (-not $unmappedSignIn.ContainsKey($rawKey)) { $unmappedSignIn[$rawKey] = 0 }
                    $unmappedSignIn[$rawKey]++
                    continue
                }
                $methodsForEvent += $classified
            }

            $eventHighest = Get-HighestMethod -Methods $methodsForEvent
            if ($null -eq $eventHighest) { continue }
            $usage.ExplicitMethodSignInCount++

            if (-not $usage.MethodStats.ContainsKey($eventHighest.Name)) {
                $usage.MethodStats[$eventHighest.Name] = [pscustomobject]@{ Name = $eventHighest.Name; Score = $eventHighest.Score; Count = 0; LastObserved = $null }
            }
            $methodStat = $usage.MethodStats[$eventHighest.Name]
            $methodStat.Count++
            if ($null -eq $methodStat.LastObserved -or $when -gt $methodStat.LastObserved) { $methodStat.LastObserved = $when }

            if ($ExportEvidence) {
                $device = Get-OptionalPropertyValue -Object $signIn -Name 'deviceDetail'
                if ($null -eq $evidenceWriter) {
                    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
                    $evidenceWriter = New-Object System.IO.StreamWriter($evidencePath, $false, $utf8Bom)
                    $evidenceWriter.WriteLine((@($evidenceColumns | ForEach-Object { ConvertTo-CsvField -Value $_ }) -join ','))
                }
                $evidenceRow = [pscustomobject][ordered]@{
                    UserPrincipalName             = Get-OptionalPropertyValue -Object $signIn -Name 'userPrincipalName'
                    UserId                        = $userId
                    SignInId                      = Get-OptionalPropertyValue -Object $signIn -Name 'id'
                    CreatedDateTimeUtc            = $when.UtcDateTime.ToString('o')
                    AppDisplayName                = Get-OptionalPropertyValue -Object $signIn -Name 'appDisplayName'
                    ClientAppUsed                 = Get-OptionalPropertyValue -Object $signIn -Name 'clientAppUsed'
                    AuthenticationRequirement     = Get-OptionalPropertyValue -Object $signIn -Name 'authenticationRequirement'
                    ConditionalAccessStatus       = Get-OptionalPropertyValue -Object $signIn -Name 'conditionalAccessStatus'
                    ExplicitMethodForSignIn       = $eventHighest.Name
                    ExplicitMethodScore           = $eventHighest.Score
                    RawAuthenticationSteps        = $rawSteps -join '; '
                    IpAddress                     = Get-OptionalPropertyValue -Object $signIn -Name 'ipAddress'
                    DeviceName                    = Get-OptionalPropertyValue -Object $device -Name 'displayName'
                    OperatingSystem               = Get-OptionalPropertyValue -Object $device -Name 'operatingSystem'
                    Browser                       = Get-OptionalPropertyValue -Object $device -Name 'browser'
                    IsManaged                      = Get-OptionalPropertyValue -Object $device -Name 'isManaged'
                    IsCompliant                   = Get-OptionalPropertyValue -Object $device -Name 'isCompliant'
                }
                Write-EvidenceCsvRow -Writer $evidenceWriter -Row $evidenceRow -Columns $evidenceColumns
                $evidenceCount++
            }
            }
        }
        Write-Verbose "Processed $processedSignIns interactive sign-in records across $chunkCount chunk(s)."
    }
    catch {
        $signInStatus = 'failed'
        $usageByUser = @{}
        $evidenceCount = 0
        if ($null -ne $evidenceWriter) {
            try { $evidenceWriter.Close() } catch { }
            $evidenceWriter = $null
        }
        if (Test-Path -LiteralPath $evidencePath) { [System.IO.File]::Delete($evidencePath) }
        Write-Warning "Sign-in activity retrieval failed. The registration report will still be exported. $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $evidenceWriter) {
            $evidenceWriter.Close()
            $evidenceWriter.Dispose()
            $evidenceWriter = $null
        }
    }
}

$report = @(foreach ($registration in $registrations) {
    $userType = Get-OptionalPropertyValue -Object $registration -Name 'userType'
    if (-not $IncludeGuests -and $userType -eq 'guest') { continue }

    $registrationId = Get-OptionalPropertyValue -Object $registration -Name 'id'
    $registeredMethods = @(Get-OptionalPropertyValue -Object $registration -Name 'methodsRegistered')
    $registeredClassifications = @()
    foreach ($registeredMethod in $registeredMethods) {
        $classified = ConvertTo-AuthMethod -Method $registeredMethod -Detail $null
        if ($null -eq $classified) { continue }
        if ($classified.Score -eq 0) {
            if (-not $unmappedRegistered.ContainsKey($registeredMethod)) { $unmappedRegistered[$registeredMethod] = 0 }
            $unmappedRegistered[$registeredMethod]++
            continue
        }
        $registeredClassifications += $classified
    }
    $strongestRegistered = Get-HighestMethod -Methods $registeredClassifications
    $usage = if ($signInStatus -eq 'ok' -and -not [string]::IsNullOrWhiteSpace($registrationId)) { $usageByUser[$registrationId.ToString().ToLowerInvariant()] } else { $null }
    $strongestObserved = if ($null -ne $usage) { Get-HighestMethod -Methods @($usage.MethodStats.Values) } else { $null }
    $successfulSignIns = if ($null -ne $usage) { $usage.SuccessfulSignInCount } else { 0 }
    $explicitMethodSignIns = if ($null -ne $usage) { $usage.ExplicitMethodSignInCount } else { 0 }
    $mfaRequiredSignIns = if ($null -ne $usage) { $usage.MfaRequiredSignInCount } else { 0 }
    $coverage = if ($successfulSignIns -gt 0) { '{0} of {1} ({2:P1})' -f $explicitMethodSignIns, $successfulSignIns, ($explicitMethodSignIns / $successfulSignIns) } else { $null }
    $observationStatus = Get-ObservationStatus -SignInStatus $signInStatus -SuccessfulSignIns $successfulSignIns -ExplicitMethodSignIns $explicitMethodSignIns
    $comparison = if ($null -eq $strongestObserved) { 'No explicit method evidence for comparison' }
        elseif ($null -eq $strongestRegistered) { 'No registered method was classified' }
        elseif ($strongestRegistered.Score -gt $strongestObserved.Score) { 'Stronger method registered than explicitly observed' }
        else { 'Explicitly observed method meets or exceeds registered strength' }

    [pscustomobject][ordered]@{
        UserPrincipalName                        = Get-OptionalPropertyValue -Object $registration -Name 'userPrincipalName'
        DisplayName                               = Get-OptionalPropertyValue -Object $registration -Name 'userDisplayName'
        UserId                                    = $registrationId
        UserType                                  = $userType
        IsAdmin                                   = Get-OptionalPropertyValue -Object $registration -Name 'isAdmin'
        AllRegisteredMethods                      = $registeredMethods -join '; '
        StrongestRegisteredMethod                 = if ($null -ne $strongestRegistered) { $strongestRegistered.Name } else { 'None registered or classified' }
        StrongestRegisteredScore                  = if ($null -ne $strongestRegistered) { $strongestRegistered.Score } else { $null }
        StrongestRegisteredTier                   = Get-AuthTier -Score $(if ($null -ne $strongestRegistered) { $strongestRegistered.Score } else { $null })
        IsMfaRegistered                           = Get-OptionalPropertyValue -Object $registration -Name 'isMfaRegistered'
        IsMfaCapable                              = Get-OptionalPropertyValue -Object $registration -Name 'isMfaCapable'
        IsPasswordlessCapable                     = Get-OptionalPropertyValue -Object $registration -Name 'isPasswordlessCapable'
        DefaultMfaMethod                          = Get-OptionalPropertyValue -Object $registration -Name 'defaultMfaMethod'
        UserPreferredSecondaryAuthentication      = Get-OptionalPropertyValue -Object $registration -Name 'userPreferredMethodForSecondaryAuthentication'
        SystemPreferredAuthenticationMethods      = @(Get-OptionalPropertyValue -Object $registration -Name 'systemPreferredAuthenticationMethods') -join '; '
        RegistrationReportLastUpdatedUtc          = Get-OptionalPropertyValue -Object $registration -Name 'lastUpdatedDateTime'
        SuccessfulInteractiveSignInsReviewed      = $successfulSignIns
        SignInsWithExplicitMethod                 = $explicitMethodSignIns
        ExplicitMethodEvidenceCoverage            = $coverage
        ExplicitMethodEvidenceStatus              = $observationStatus
        SuccessfulSignInsReportingMfaRequirement  = $mfaRequiredSignIns
        LastSuccessfulInteractiveSignInUtc        = if ($null -ne $usage) { $usage.LastSuccessfulSignIn.UtcDateTime.ToString('o') } else { $null }
        MethodsExplicitlyObserved                 = if ($null -ne $usage) { @($usage.MethodStats.Keys | Sort-Object) -join '; ' } else { $null }
        StrongestExplicitlyObservedMethod         = if ($null -ne $strongestObserved) { $strongestObserved.Name } else { 'No explicit method observed' }
        StrongestExplicitlyObservedScore          = if ($null -ne $strongestObserved) { $strongestObserved.Score } else { $null }
        StrongestExplicitlyObservedTier           = Get-AuthTier -Score $(if ($null -ne $strongestObserved) { $strongestObserved.Score } else { $null })
        StrongestExplicitlyObservedMethodCount    = if ($null -ne $strongestObserved) { $strongestObserved.Count } else { 0 }
        StrongestExplicitlyObservedLastSeenUtc    = if ($null -ne $strongestObserved) { $strongestObserved.LastObserved.UtcDateTime.ToString('o') } else { $null }
        RegistrationVsObservation                 = $comparison
        StrongerMethodRegisteredThanObserved      = if ($null -eq $strongestObserved -or $null -eq $strongestRegistered) { $null } else { $strongestRegistered.Score -gt $strongestObserved.Score }
        ObservationWindowStartUtc                 = $startText
        ObservationWindowEndUtc                   = $endText
    }
})

$tierOrder = @('Phishing-resistant MFA', 'Passwordless MFA', 'Strong MFA (app, token, or TAP)', 'Phone-based MFA', 'Single-factor / SSPR only', 'None / unclassified')
$summary = New-Object System.Collections.Generic.List[object]
foreach ($tier in $tierOrder) {
    $registeredCount = @($report | Where-Object { $_.StrongestRegisteredTier -eq $tier }).Count
    $observedCount = @($report | Where-Object { $_.StrongestExplicitlyObservedTier -eq $tier -and $_.SignInsWithExplicitMethod -gt 0 }).Count
    $summary.Add([pscustomobject][ordered]@{
        RecordType                        = 'Tier distribution'
        RunUtc                            = $runUtc.ToString('o')
        ObservationWindowStartUtc         = $startText
        ObservationWindowEndUtc           = $endText
        StrengthTier                      = $tier
        RegisteredUserCount               = $registeredCount
        ExplicitlyObservedUserCount       = $observedCount
        TotalUsers                        = $null
        SuccessfulInteractiveSignInCount  = $null
        ExplicitMethodSignInCount         = $null
        ExplicitMethodEvidenceRate        = $null
        Notes                             = $null
    })
}
$totalSuccessfulSignIns = [int](@($report | Measure-Object -Property SuccessfulInteractiveSignInsReviewed -Sum).Sum)
$totalExplicitMethodSignIns = [int](@($report | Measure-Object -Property SignInsWithExplicitMethod -Sum).Sum)
$summary.Add([pscustomobject][ordered]@{
    RecordType                        = 'Evidence coverage'
    RunUtc                            = $runUtc.ToString('o')
    ObservationWindowStartUtc         = $startText
    ObservationWindowEndUtc           = $endText
    StrengthTier                      = 'All users'
    RegisteredUserCount               = $null
    ExplicitlyObservedUserCount       = $null
    TotalUsers                        = $report.Count
    SuccessfulInteractiveSignInCount  = $totalSuccessfulSignIns
    ExplicitMethodSignInCount         = $totalExplicitMethodSignIns
    ExplicitMethodEvidenceRate        = if ($totalSuccessfulSignIns -gt 0) { $totalExplicitMethodSignIns / $totalSuccessfulSignIns } else { $null }
    Notes                             = 'A missing explicit method does not mean that the user did not authenticate or did not use MFA.'
})

Write-ConsoleSummary -Report $report -Summary $summary.ToArray()

$report | Sort-Object @{ Expression = 'IsAdmin'; Descending = $true }, @{ Expression = 'StrongestRegisteredScore'; Descending = $true }, UserPrincipalName |
    Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
$summary | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

if ($unmappedRegistered.Count -gt 0) {
    Write-Warning 'Unmapped registered authentication methods were found. Add them to ConvertTo-AuthMethod before treating them as weak or absent.'
    $unmappedRegistered.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host "  $($_.Key) (x$($_.Value))" }
}
if ($unmappedSignIn.Count -gt 0) {
    Write-Warning 'Unmapped successful sign-in authentication methods were found. Review them before acting on observed-strength results.'
    $unmappedSignIn.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host "  $($_.Key) (x$($_.Value))" }
}

Write-Host "Per-user posture report: $OutputPath"
Write-Host "Summary report:          $summaryPath"
if ($ExportEvidence -and $evidenceCount -gt 0) { Write-Host "Evidence report:         $evidencePath ($evidenceCount rows)" }
elseif ($ExportEvidence) { Write-Host 'Evidence report:         no explicitly observed methods in the selected window' }

if ($GenerateHtmlSummary) {
    $htmlSummaryPath = Join-Path (Join-Path $PSScriptRoot 'support') 'New-EntraAuthPostureHtmlSummary.ps1'
    if (-not (Test-Path -LiteralPath $htmlSummaryPath)) {
        Write-Warning "HTML summary generation was requested, but the helper is missing: $htmlSummaryPath"
    }
    else {
        & $htmlSummaryPath -PosturePath $OutputPath -SummaryPath $summaryPath -OutputDirectory $outputDirectory
    }
}

if ($PackageDeliverables) {
    $packagerPath = Join-Path (Join-Path $PSScriptRoot 'support') 'New-EntraAuthPosturePackage.ps1'
    if (-not (Test-Path -LiteralPath $packagerPath)) {
        Write-Warning "Deliverable packaging was requested, but the packager is missing: $packagerPath"
    }
    else {
        $packageParams = @{
            PosturePath                = $OutputPath
            SummaryPath                = $summaryPath
            OutputDirectory            = $outputDirectory
            MaxEvidenceRowsInWorkbook  = $MaxEvidenceRowsInWorkbook
        }
        if ($ExportEvidence -and $evidenceCount -gt 0) { $packageParams.EvidencePath = $evidencePath }
        & $packagerPath @packageParams
    }
}
