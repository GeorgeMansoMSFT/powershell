<#
.SYNOPSIS
Creates synthetic CSV fixtures for local Entra posture packaging scale tests.

.DESCRIPTION
Creates no tenant connections and contains no customer data. Use the generated
CSV files with New-EntraAuthPosturePackage.ps1 to validate workbook performance
and the evidence worksheet row guardrail.

.EXAMPLE
.\tests\New-EntraAuthPostureScaleFixture.ps1 -UserCount 10000 -EvidenceRowCount 25000
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1000000)]
    [int] $UserCount = 10000,

    [ValidateRange(0, 1000000)]
    [int] $EvidenceRowCount = 25000,

    [string] $OutputDirectory = (Join-Path (Join-Path $PSScriptRoot '..\output') 'scale-fixture')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$runUtc = (Get-Date).ToUniversalTime()
$windowStart = $runUtc.AddDays(-1)
$runText = $runUtc.ToString('o')
$startText = $windowStart.ToString('yyyy-MM-ddTHH:mm:ssZ')
$endText = $runUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$baseName = "Entra-AuthPosture-scale-$UserCount-users-$EvidenceRowCount-evidence"
$posturePath = Join-Path $OutputDirectory "$baseName.csv"
$summaryPath = Join-Path $OutputDirectory "$baseName-summary.csv"
$evidencePath = Join-Path $OutputDirectory "$baseName-evidence.csv"

$posture = foreach ($index in 1..$UserCount) {
    $isStrong = ($index % 5) -eq 0
    $isAdmin = ($index % 1000) -eq 0
    $observed = $index -le [Math]::Min($EvidenceRowCount, $UserCount)
    $registeredMethod = if ($isStrong) { 'Microsoft Authenticator push' } else { 'None registered or classified' }
    $registeredScore = if ($isStrong) { 70 } else { $null }
    $registeredTier = if ($isStrong) { 'Strong MFA (app, token, or TAP)' } else { 'None / unclassified' }
    [pscustomobject][ordered]@{
        UserPrincipalName                        = "sample.user$index@example.com"
        DisplayName                               = "Sample User $index"
        UserId                                    = ('00000000-0000-4000-8000-{0:D12}' -f $index)
        UserType                                  = 'Member'
        IsAdmin                                   = $isAdmin
        AllRegisteredMethods                      = if ($isStrong) { 'Microsoft Authenticator push' } else { '' }
        StrongestRegisteredMethod                 = $registeredMethod
        StrongestRegisteredScore                  = $registeredScore
        StrongestRegisteredTier                   = $registeredTier
        IsMfaRegistered                           = $isStrong
        IsMfaCapable                              = $isStrong
        IsPasswordlessCapable                     = $false
        DefaultMfaMethod                          = if ($isStrong) { 'Microsoft Authenticator' } else { '' }
        UserPreferredSecondaryAuthentication      = ''
        SystemPreferredAuthenticationMethods      = if ($isStrong) { 'Microsoft Authenticator' } else { '' }
        RegistrationReportLastUpdatedUtc          = $runText
        SuccessfulInteractiveSignInsReviewed      = if ($observed) { 1 } else { 0 }
        SignInsWithExplicitMethod                 = if ($observed) { 1 } else { 0 }
        ExplicitMethodEvidenceCoverage            = if ($observed) { '1 of 1 (100.0%)' } else { '' }
        ExplicitMethodEvidenceStatus              = if ($observed) { 'Explicit method observed in all successful sign-ins' } else { 'No successful interactive sign-in in the window' }
        SuccessfulSignInsReportingMfaRequirement  = if ($observed) { 1 } else { 0 }
        LastSuccessfulInteractiveSignInUtc        = if ($observed) { $runText } else { '' }
        MethodsExplicitlyObserved                 = if ($observed) { 'Microsoft Authenticator push' } else { '' }
        StrongestExplicitlyObservedMethod         = if ($observed) { 'Microsoft Authenticator push' } else { 'No explicit method observed' }
        StrongestExplicitlyObservedScore          = if ($observed) { 70 } else { $null }
        StrongestExplicitlyObservedTier           = if ($observed) { 'Strong MFA (app, token, or TAP)' } else { 'None / unclassified' }
        StrongestExplicitlyObservedMethodCount    = if ($observed) { 1 } else { 0 }
        StrongestExplicitlyObservedLastSeenUtc    = if ($observed) { $runText } else { '' }
        RegistrationVsObservation                 = if ($observed) { 'Registration and observation agree' } else { 'No explicit method evidence for comparison' }
        StrongerMethodRegisteredThanObserved      = $false
        ObservationWindowStartUtc                 = $startText
        ObservationWindowEndUtc                   = $endText
    }
}
$posture | Export-Csv -LiteralPath $posturePath -NoTypeInformation -Encoding UTF8

$strongCount = [int][Math]::Floor($UserCount / 5)
$noneCount = $UserCount - $strongCount
$summary = @(
    [pscustomobject][ordered]@{ RecordType = 'Tier distribution'; RunUtc = $runText; ObservationWindowStartUtc = $startText; ObservationWindowEndUtc = $endText; StrengthTier = 'Phishing-resistant MFA'; RegisteredUserCount = 0; ExplicitlyObservedUserCount = 0; TotalUsers = $null; SuccessfulInteractiveSignInCount = $null; ExplicitMethodSignInCount = $null; ExplicitMethodEvidenceRate = $null; Notes = $null },
    [pscustomobject][ordered]@{ RecordType = 'Tier distribution'; RunUtc = $runText; ObservationWindowStartUtc = $startText; ObservationWindowEndUtc = $endText; StrengthTier = 'Passwordless MFA'; RegisteredUserCount = 0; ExplicitlyObservedUserCount = 0; TotalUsers = $null; SuccessfulInteractiveSignInCount = $null; ExplicitMethodSignInCount = $null; ExplicitMethodEvidenceRate = $null; Notes = $null },
    [pscustomobject][ordered]@{ RecordType = 'Tier distribution'; RunUtc = $runText; ObservationWindowStartUtc = $startText; ObservationWindowEndUtc = $endText; StrengthTier = 'Strong MFA (app, token, or TAP)'; RegisteredUserCount = $strongCount; ExplicitlyObservedUserCount = [Math]::Min($EvidenceRowCount, $strongCount); TotalUsers = $null; SuccessfulInteractiveSignInCount = $null; ExplicitMethodSignInCount = $null; ExplicitMethodEvidenceRate = $null; Notes = $null },
    [pscustomobject][ordered]@{ RecordType = 'Tier distribution'; RunUtc = $runText; ObservationWindowStartUtc = $startText; ObservationWindowEndUtc = $endText; StrengthTier = 'Phone-based MFA'; RegisteredUserCount = 0; ExplicitlyObservedUserCount = 0; TotalUsers = $null; SuccessfulInteractiveSignInCount = $null; ExplicitMethodSignInCount = $null; ExplicitMethodEvidenceRate = $null; Notes = $null },
    [pscustomobject][ordered]@{ RecordType = 'Tier distribution'; RunUtc = $runText; ObservationWindowStartUtc = $startText; ObservationWindowEndUtc = $endText; StrengthTier = 'Single-factor / SSPR only'; RegisteredUserCount = 0; ExplicitlyObservedUserCount = 0; TotalUsers = $null; SuccessfulInteractiveSignInCount = $null; ExplicitMethodSignInCount = $null; ExplicitMethodEvidenceRate = $null; Notes = $null },
    [pscustomobject][ordered]@{ RecordType = 'Tier distribution'; RunUtc = $runText; ObservationWindowStartUtc = $startText; ObservationWindowEndUtc = $endText; StrengthTier = 'None / unclassified'; RegisteredUserCount = $noneCount; ExplicitlyObservedUserCount = 0; TotalUsers = $null; SuccessfulInteractiveSignInCount = $null; ExplicitMethodSignInCount = $null; ExplicitMethodEvidenceRate = $null; Notes = $null },
    [pscustomobject][ordered]@{ RecordType = 'Evidence coverage'; RunUtc = $runText; ObservationWindowStartUtc = $startText; ObservationWindowEndUtc = $endText; StrengthTier = 'All users'; RegisteredUserCount = $null; ExplicitlyObservedUserCount = $null; TotalUsers = $UserCount; SuccessfulInteractiveSignInCount = $EvidenceRowCount; ExplicitMethodSignInCount = $EvidenceRowCount; ExplicitMethodEvidenceRate = if ($EvidenceRowCount -gt 0) { 1 } else { $null }; Notes = 'Synthetic scale fixture only.' }
)
$summary | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

if ($EvidenceRowCount -gt 0) {
    $evidence = foreach ($index in 1..$EvidenceRowCount) {
        $userIndex = (($index - 1) % $UserCount) + 1
        [pscustomobject][ordered]@{
            UserPrincipalName         = "sample.user$userIndex@example.com"
            UserId                    = ('00000000-0000-4000-8000-{0:D12}' -f $userIndex)
            SignInId                  = ('10000000-0000-4000-8000-{0:D12}' -f $index)
            CreatedDateTimeUtc        = $runText
            AppDisplayName            = 'Synthetic workload'
            ClientAppUsed             = 'Browser'
            AuthenticationRequirement = 'multiFactorAuthentication'
            ConditionalAccessStatus   = 'success'
            ExplicitMethodForSignIn   = 'Microsoft Authenticator push'
            ExplicitMethodScore       = 70
            RawAuthenticationSteps    = 'Synthetic successful MFA event'
            IpAddress                 = '203.0.113.10'
            DeviceName                = 'SYNTHETIC-DEVICE'
            OperatingSystem           = 'Windows 11'
            Browser                   = 'Edge'
            IsManaged                 = $true
            IsCompliant               = $true
        }
    }
    $evidence | Export-Csv -LiteralPath $evidencePath -NoTypeInformation -Encoding UTF8
}

Write-Host "Synthetic posture fixture:  $posturePath"
Write-Host "Synthetic summary fixture:  $summaryPath"
if ($EvidenceRowCount -gt 0) { Write-Host "Synthetic evidence fixture: $evidencePath" }
