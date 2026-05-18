# 05-ManagedIdentities.ps1
# Finds managed identities with the domain in display name or federated credentials (issuer/subject).
# Federated credentials are discovered by the Azure worker. Keeping Az out of
# this Graph worker avoids Azure.Identity assembly conflicts.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "ManagedIdentities"
$OutputFile = Join-Path $OutputPath "05-managed-identities-on-domain.csv"
$FedCredFile = Join-Path $OutputPath "05-managed-identities-fedcreds.csv"

Write-Host "[$ModuleName] Scanning managed identities for references to $Domain..." -ForegroundColor Yellow

try {
    $allMIs = Get-MgServicePrincipal -All `
        -Filter "servicePrincipalType eq 'ManagedIdentity'" `
        -Property Id, AppId, DisplayName, AlternativeNames, ServicePrincipalType `
        -ErrorAction Stop

    # Display name matches
    $nameMatches = foreach ($mi in $allMIs) {
        if ($mi.DisplayName -like "*$Domain*") {
            [PSCustomObject]@{
                ObjectId    = $mi.Id
                AppId       = $mi.AppId
                DisplayName = $mi.DisplayName
                MatchType   = "DisplayName"
                ResourceId  = ($mi.AlternativeNames | Where-Object { $_ -like "/subscriptions/*" }) -join ";"
            }
        }
    }

    if ($nameMatches.Count -gt 0) {
        $nameMatches | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    } else {
        "ObjectId,AppId,DisplayName,MatchType,ResourceId" | Out-File -FilePath $OutputFile -Encoding UTF8
    }

    "Subscription,UAMIName,UAMIResourceGroup,UAMIPrincipalId,FedCredName,Issuer,Subject,Audiences,MatchReasons" |
        Out-File -FilePath $FedCredFile -Encoding UTF8
    Write-Host "[$ModuleName] Federated credential enumeration is handled by 11-AzureResources.ps1." -ForegroundColor DarkGray

    $totalCount = $nameMatches.Count
    $notes = "DisplayNameMatches=$($nameMatches.Count); FedCredMatches=handled by AzureResources"

    Write-Host "[$ModuleName] Found $totalCount MI references. $notes" -ForegroundColor Green
    Add-InventorySummary -Module $ModuleName -Count $totalCount -OutputFile $OutputFile -Notes $notes
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
