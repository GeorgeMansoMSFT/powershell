# 05-ManagedIdentities.ps1
# Finds managed identities with the domain in display name or federated credentials (issuer/subject).
# Federated credentials require the Az.ManagedServiceIdentity module if available; otherwise we use Graph.

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

    # Federated credentials - these are on user-assigned MIs.
    # We query Graph for federated identity credentials on the *application* objects, but for MIs,
    # federated creds are on the Azure resource side, accessed via Az.ManagedServiceIdentity.
    # If Az is loaded, walk UAMIs; otherwise note the limitation.
    $fedCredMatches = @()

    if (Get-Module -ListAvailable Az.ManagedServiceIdentity) {
        try {
            Import-Module Az.ManagedServiceIdentity -ErrorAction Stop -WarningAction SilentlyContinue

            # Need an Az context - caller should have already run Connect-AzAccount
            $ctx = Get-AzContext -ErrorAction SilentlyContinue
            if ($ctx) {
                $allUAMIs = Get-AzUserAssignedIdentity -ErrorAction SilentlyContinue
                foreach ($uami in $allUAMIs) {
                    try {
                        $feds = Get-AzFederatedIdentityCredential `
                            -ResourceGroupName $uami.ResourceGroupName `
                            -IdentityName     $uami.Name `
                            -ErrorAction SilentlyContinue

                        foreach ($fed in $feds) {
                            $reasons = @()
                            if ($fed.Issuer  -like "*$Domain*") { $reasons += "Issuer" }
                            if ($fed.Subject -like "*$Domain*") { $reasons += "Subject" }
                            if (($fed.Audiences -join ";") -like "*$Domain*") { $reasons += "Audience" }

                            if ($reasons.Count -gt 0) {
                                $fedCredMatches += [PSCustomObject]@{
                                    UAMIName     = $uami.Name
                                    UAMIResourceGroup = $uami.ResourceGroupName
                                    UAMIPrincipalId = $uami.PrincipalId
                                    FedCredName  = $fed.Name
                                    Issuer       = $fed.Issuer
                                    Subject      = $fed.Subject
                                    Audiences    = ($fed.Audiences -join ";")
                                    MatchReasons = ($reasons -join ";")
                                }
                            }
                        }
                    } catch {
                        Write-DiscoveryError -Module $ModuleName -Message "Could not enumerate fed creds for UAMI $($uami.Name): $($_.Exception.Message)"
                    }
                }

                if ($fedCredMatches.Count -gt 0) {
                    $fedCredMatches | Export-Csv -Path $FedCredFile -NoTypeInformation -Encoding UTF8
                }
            } else {
                # Az context not available in this process. This is expected - Az and Graph
                # SDKs cannot share a session due to assembly conflicts, so MI federated
                # credential enumeration is handled by module 11 (Azure resources) which
                # runs in a separate process. Do not warn the user.
                Write-Host "[$ModuleName] Skipping fed cred enumeration in this process (handled by module 11)." -ForegroundColor DarkGray
            }
        }
        catch {
            Write-DiscoveryError -Module $ModuleName -Message "Az.ManagedServiceIdentity available but enumeration failed: $($_.Exception.Message)"
        }
    } else {
        Write-Host "[$ModuleName] Az.ManagedServiceIdentity module not available - skipping federated credential enumeration." -ForegroundColor DarkYellow
    }

    $totalCount = $nameMatches.Count + $fedCredMatches.Count
    $notes = "DisplayNameMatches=$($nameMatches.Count); FedCredMatches=$($fedCredMatches.Count)"

    Write-Host "[$ModuleName] Found $totalCount MI references. $notes" -ForegroundColor Green
    Add-InventorySummary -Module $ModuleName -Count $totalCount -OutputFile $OutputFile -Notes $notes
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
