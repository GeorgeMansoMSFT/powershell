# 08-Federation.ps1
# Checks if the domain is federated and reports the federation configuration.
# Federation must be unconfigured before the domain can be removed.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "Federation"
$OutputFile = Join-Path $OutputPath "08-federation-config.csv"

Write-Host "[$ModuleName] Checking federation configuration for $Domain..." -ForegroundColor Yellow

try {
    # Domain auth type
    $dom = Get-MgDomain -DomainId $Domain -ErrorAction Stop

    $authType = $dom.AuthenticationType  # "Managed" or "Federated"

    $fedConfig = $null
    if ($authType -eq "Federated") {
        try {
            $fedConfig = Get-MgDomainFederationConfiguration -DomainId $Domain -ErrorAction Stop
        } catch {
            Write-DiscoveryError -Module $ModuleName -Message "Domain marked Federated but federation config retrieval failed: $($_.Exception.Message)"
        }
    }

    $row = [PSCustomObject]@{
        Domain               = $Domain
        IsVerified           = $dom.IsVerified
        IsDefault            = $dom.IsDefault
        IsInitial            = $dom.IsInitial
        AuthenticationType   = $authType
        SupportedServices    = ($dom.SupportedServices -join ";")
        FederationIssuerUri  = if ($fedConfig) { $fedConfig.IssuerUri } else { "" }
        PassiveSignInUri     = if ($fedConfig) { $fedConfig.PassiveSignInUri } else { "" }
        ActiveSignInUri      = if ($fedConfig) { $fedConfig.ActiveSignInUri } else { "" }
        FederationDisplayName = if ($fedConfig) { $fedConfig.DisplayName } else { "" }
    }

    $row | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

    # Count semantics: only "Federated" is a blocker. "Managed" is the safe state.
    if ($authType -eq "Federated") {
        $notes = "FEDERATED - must be converted to Managed before domain removal"
        Write-Host "[$ModuleName] WARNING: $Domain is FEDERATED." -ForegroundColor Red
        $blockerCount = 1
    } else {
        $notes = "Managed (cloud auth) - no federation to unconfigure"
        Write-Host "[$ModuleName] $Domain uses Managed authentication." -ForegroundColor Green
        $blockerCount = 0
    }

    Add-InventorySummary -Module $ModuleName -Count $blockerCount -OutputFile $OutputFile -Notes $notes
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
