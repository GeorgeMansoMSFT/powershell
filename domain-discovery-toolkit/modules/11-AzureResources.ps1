# 11-AzureResources.ps1
# Azure resource discovery for verified domain references.
# Designed to run in a SEPARATE PowerShell process from the main orchestrator,
# because Az PowerShell and Microsoft.Graph have known Azure.Identity assembly
# conflicts when loaded in the same process.
#
# Discovery scope:
#   - Custom domain bindings (App Service, APIM, Front Door, App Gateway)
#   - Resource display names containing the domain
#   - Resource tags containing the domain
#   - Connection strings, app settings, and secrets keys (App Service config)
#   - Azure Resource Graph search across all resources
#
# Output: writes findings directly to CSV in the output path.
# Status: writes a status file (11-azure-status.json) the orchestrator reads
#         to update the inventory summary after this script completes.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "AzureResources"
$DomainsFile  = Join-Path $OutputPath "11-azure-custom-domains.csv"
$NamesFile    = Join-Path $OutputPath "11-azure-resource-names.csv"
$TagsFile     = Join-Path $OutputPath "11-azure-resource-tags.csv"
$ConfigFile   = Join-Path $OutputPath "11-azure-app-config.csv"
$GraphFile    = Join-Path $OutputPath "11-azure-resource-graph.csv"
$StatusFile   = Join-Path $OutputPath "11-azure-status.json"
$ErrorLog     = Join-Path $OutputPath "errors.log"

function Write-AzError {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'o')] [$ModuleName] $Message"
    Add-Content -Path $ErrorLog -Value $entry -ErrorAction SilentlyContinue
    Write-Warning $entry
}

function Write-Status {
    param([int]$TotalCount, [string]$Notes)
    @{
        Module    = $ModuleName
        Count     = $TotalCount
        Notes     = $Notes
        OutputFiles = @($DomainsFile, $NamesFile, $TagsFile, $ConfigFile, $GraphFile)
        Timestamp = (Get-Date -Format 'o')
    } | ConvertTo-Json -Depth 5 | Out-File -FilePath $StatusFile -Encoding UTF8
}

Write-Host "[$ModuleName] Starting Azure resource discovery for $Domain..." -ForegroundColor Yellow

# Verify we're in a fresh process (no Microsoft.Graph loaded)
if (Get-Module Microsoft.Graph* -ErrorAction SilentlyContinue) {
    Write-AzError "Microsoft.Graph modules detected in this session. This module should run in a clean process to avoid Azure.Identity assembly conflicts."
}

try {
    Import-Module Az.Accounts -Force -ErrorAction Stop -WarningAction SilentlyContinue
    Import-Module Az.Resources -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Import-Module Az.Websites -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Import-Module Az.ApiManagement -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Import-Module Az.Cdn -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Import-Module Az.FrontDoor -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Import-Module Az.Network -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Import-Module Az.ResourceGraph -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
} catch {
    Write-AzError "Failed to import Az modules: $($_.Exception.Message)"
    Write-Status -TotalCount -1 -Notes "ERROR: Az module import failed"
    exit 1
}

$ctx = Get-AzContext -ErrorAction SilentlyContinue

# Always authenticate fresh in this child process. Az PowerShell can't share a
# session with Microsoft.Graph in the parent due to Azure.Identity assembly conflicts,
# so we connect independently here.
#
# Note: Get-AzContext can return a non-null context even when the underlying token
# cache is empty/expired (stale context). We must validate by actually trying to
# acquire a token, not just by checking whether $ctx exists.
$contextValid = $false
if ($ctx) {
    try {
        # Cheap validation call - list subscriptions. If the token is dead, this fails.
        $null = Get-AzSubscription -ErrorAction Stop -WarningAction SilentlyContinue | Select-Object -First 1
        $contextValid = $true
    } catch {
        Write-Host "[$ModuleName] Stale Az context detected ($($_.Exception.Message)). Re-authenticating..." -ForegroundColor DarkYellow
        $contextValid = $false
    }
}

if (-not $contextValid) {
    Write-Host "[$ModuleName] Connecting to Azure interactively..." -ForegroundColor Yellow
    try {
        # Clear any stale context first so Connect-AzAccount doesn't try to be clever
        Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $ctx = Get-AzContext
        if (-not $ctx) {
            throw "Connect-AzAccount returned but Get-AzContext is null"
        }
    } catch {
        Write-AzError "Connect-AzAccount failed: $($_.Exception.Message)"
        Write-Status -TotalCount -1 -Notes "ERROR: Connect-AzAccount failed"
        exit 1
    }
}

$subscriptions = Get-AzSubscription -ErrorAction SilentlyContinue
if (-not $subscriptions -or $subscriptions.Count -eq 0) {
    Write-AzError "No subscriptions found in current Az context."
    Write-Status -TotalCount 0 -Notes "No subscriptions accessible"
    exit 0
}

Write-Host "[$ModuleName] Scanning $($subscriptions.Count) subscription(s)..." -ForegroundColor Cyan

$customDomainFindings = @()
$nameFindings         = @()
$tagFindings          = @()
$configFindings       = @()
$graphFindings        = @()

# ---------------------------------------------------------------
# Pass 1: Resource Graph (fastest, broadest)
# ---------------------------------------------------------------
Write-Host "[$ModuleName]   Pass 1: Azure Resource Graph search across all subscriptions..." -ForegroundColor Cyan
try {
    if (Get-Command Search-AzGraph -ErrorAction SilentlyContinue) {
        $kqlQuery = @"
Resources
| where (name contains '$Domain') or (tostring(tags) contains '$Domain') or (tostring(properties) contains '$Domain')
| project subscriptionId, resourceGroup, type, name, location, tags, properties
| limit 1000
"@
        $graphResults = Search-AzGraph -Query $kqlQuery -ErrorAction SilentlyContinue
        foreach ($r in $graphResults) {
            $matchType = @()
            if ($r.name -like "*$Domain*") { $matchType += "Name" }
            if (($r.tags | ConvertTo-Json -Depth 5 -Compress) -like "*$Domain*") { $matchType += "Tags" }
            if (($r.properties | ConvertTo-Json -Depth 10 -Compress) -like "*$Domain*") { $matchType += "Properties" }

            $graphFindings += [PSCustomObject]@{
                Subscription   = $r.subscriptionId
                ResourceType   = $r.type
                ResourceName   = $r.name
                ResourceGroup  = $r.resourceGroup
                Location       = $r.location
                MatchType      = ($matchType -join ";")
                Tags           = ($r.tags | ConvertTo-Json -Compress)
            }
        }
        Write-Host "[$ModuleName]     Resource Graph: $($graphFindings.Count) hits" -ForegroundColor Green
    } else {
        Write-AzError "Az.ResourceGraph module not available. Install with: Install-Module Az.ResourceGraph -Scope CurrentUser"
    }
} catch {
    Write-AzError "Resource Graph query failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------
# Pass 2: per-subscription deep scans
# ---------------------------------------------------------------
foreach ($sub in $subscriptions) {
    Write-Host "[$ModuleName]   Pass 2: Deep scan of $($sub.Name)..." -ForegroundColor Cyan
    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    } catch {
        Write-AzError "Could not switch to subscription $($sub.Name): $($_.Exception.Message)"
        continue
    }

    # All resources - check display name and tags
    try {
        $allResources = Get-AzResource -ErrorAction SilentlyContinue
        foreach ($r in $allResources) {
            if ($r.Name -like "*$Domain*") {
                $nameFindings += [PSCustomObject]@{
                    Subscription  = $sub.Name
                    ResourceType  = $r.ResourceType
                    ResourceName  = $r.Name
                    ResourceGroup = $r.ResourceGroupName
                    Location      = $r.Location
                    ResourceId    = $r.ResourceId
                }
            }
            if ($r.Tags) {
                $tagJson = $r.Tags | ConvertTo-Json -Compress
                if ($tagJson -like "*$Domain*") {
                    $tagFindings += [PSCustomObject]@{
                        Subscription  = $sub.Name
                        ResourceType  = $r.ResourceType
                        ResourceName  = $r.Name
                        ResourceGroup = $r.ResourceGroupName
                        Tags          = $tagJson
                        ResourceId    = $r.ResourceId
                    }
                }
            }
        }
    } catch { Write-AzError "Resource enumeration failed in $($sub.Name): $($_.Exception.Message)" }

    # App Services / Function Apps - custom domains and app settings
    try {
        $webApps = Get-AzWebApp -ErrorAction SilentlyContinue
        foreach ($app in $webApps) {
            # Custom domain hostnames
            $hnMatches = @($app.HostNames | Where-Object { $_ -like "*$Domain*" -and $_ -notlike "*.azurewebsites.net" })
            foreach ($hn in $hnMatches) {
                $customDomainFindings += [PSCustomObject]@{
                    Subscription  = $sub.Name
                    ResourceType  = "Microsoft.Web/sites"
                    ResourceName  = $app.Name
                    ResourceGroup = $app.ResourceGroup
                    BindingType   = "HostName"
                    Value         = $hn
                    ResourceId    = $app.Id
                }
            }

            # App settings and connection strings (these often contain hostnames)
            try {
                $appDetails = Get-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name -ErrorAction SilentlyContinue
                if ($appDetails) {
                    foreach ($setting in $appDetails.SiteConfig.AppSettings) {
                        if ($setting.Value -like "*$Domain*") {
                            $configFindings += [PSCustomObject]@{
                                Subscription  = $sub.Name
                                ResourceType  = "Microsoft.Web/sites"
                                ResourceName  = $app.Name
                                ResourceGroup = $app.ResourceGroup
                                ConfigType    = "AppSetting"
                                ConfigName    = $setting.Name
                                ValueSnippet  = if ($setting.Value.Length -gt 200) { $setting.Value.Substring(0, 200) + "..." } else { $setting.Value }
                                ResourceId    = $app.Id
                            }
                        }
                    }
                    foreach ($cs in $appDetails.SiteConfig.ConnectionStrings) {
                        if ($cs.ConnectionString -like "*$Domain*") {
                            $configFindings += [PSCustomObject]@{
                                Subscription  = $sub.Name
                                ResourceType  = "Microsoft.Web/sites"
                                ResourceName  = $app.Name
                                ResourceGroup = $app.ResourceGroup
                                ConfigType    = "ConnectionString"
                                ConfigName    = $cs.Name
                                ValueSnippet  = "[REDACTED - contains $Domain]"
                                ResourceId    = $app.Id
                            }
                        }
                    }
                }
            } catch { } # Some web apps fail config retrieval; skip silently
        }
    } catch { Write-AzError "WebApp scan failed in $($sub.Name): $($_.Exception.Message)" }

    # APIM custom domains
    try {
        $apims = Get-AzApiManagement -ErrorAction SilentlyContinue
        foreach ($apim in $apims) {
            $hostnameConfigs = @(
                $apim.PortalCustomHostnameConfiguration,
                $apim.ProxyCustomHostnameConfiguration,
                $apim.ManagementCustomHostnameConfiguration,
                $apim.ScmCustomHostnameConfiguration,
                $apim.DeveloperPortalHostnameConfiguration
            )
            foreach ($hc in $hostnameConfigs) {
                if ($hc -and $hc.Hostname -like "*$Domain*") {
                    $customDomainFindings += [PSCustomObject]@{
                        Subscription  = $sub.Name
                        ResourceType  = "Microsoft.ApiManagement/service"
                        ResourceName  = $apim.Name
                        ResourceGroup = $apim.ResourceGroupName
                        BindingType   = $hc.HostnameType
                        Value         = $hc.Hostname
                        ResourceId    = $apim.Id
                    }
                }
            }
        }
    } catch { Write-AzError "APIM scan failed in $($sub.Name): $($_.Exception.Message)" }

    # Front Door (Standard/Premium)
    try {
        $afdProfiles = Get-AzFrontDoorCdnProfile -ErrorAction SilentlyContinue
        foreach ($profile in $afdProfiles) {
            $customDomains = Get-AzFrontDoorCdnCustomDomain -ProfileName $profile.Name -ResourceGroupName $profile.ResourceGroupName -ErrorAction SilentlyContinue
            foreach ($cd in $customDomains) {
                if ($cd.HostName -like "*$Domain*") {
                    $customDomainFindings += [PSCustomObject]@{
                        Subscription  = $sub.Name
                        ResourceType  = "Microsoft.Cdn/profiles/customdomains"
                        ResourceName  = "$($profile.Name)/$($cd.Name)"
                        ResourceGroup = $profile.ResourceGroupName
                        BindingType   = "FrontDoorCustomDomain"
                        Value         = $cd.HostName
                        ResourceId    = $cd.Id
                    }
                }
            }
        }
    } catch { Write-AzError "Front Door scan failed in $($sub.Name): $($_.Exception.Message)" }

    # Application Gateway listeners
    try {
        $appGws = Get-AzApplicationGateway -ErrorAction SilentlyContinue
        foreach ($gw in $appGws) {
            foreach ($listener in $gw.HttpListeners) {
                if ($listener.HostName -like "*$Domain*") {
                    $customDomainFindings += [PSCustomObject]@{
                        Subscription  = $sub.Name
                        ResourceType  = "Microsoft.Network/applicationGateways"
                        ResourceName  = "$($gw.Name)/$($listener.Name)"
                        ResourceGroup = $gw.ResourceGroupName
                        BindingType   = "HttpListenerHostName"
                        Value         = $listener.HostName
                        ResourceId    = $gw.Id
                    }
                }
            }
        }
    } catch { Write-AzError "App Gateway scan failed in $($sub.Name): $($_.Exception.Message)" }
}

# ---------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------
function Write-FindingsCsv {
    param([array]$Findings, [string]$Path, [string]$EmptyHeader)
    if ($Findings.Count -gt 0) {
        $Findings | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    } else {
        $EmptyHeader | Out-File -FilePath $Path -Encoding UTF8
    }
}

Write-FindingsCsv -Findings $customDomainFindings -Path $DomainsFile `
    -EmptyHeader "Subscription,ResourceType,ResourceName,ResourceGroup,BindingType,Value,ResourceId"
Write-FindingsCsv -Findings $nameFindings -Path $NamesFile `
    -EmptyHeader "Subscription,ResourceType,ResourceName,ResourceGroup,Location,ResourceId"
Write-FindingsCsv -Findings $tagFindings -Path $TagsFile `
    -EmptyHeader "Subscription,ResourceType,ResourceName,ResourceGroup,Tags,ResourceId"
Write-FindingsCsv -Findings $configFindings -Path $ConfigFile `
    -EmptyHeader "Subscription,ResourceType,ResourceName,ResourceGroup,ConfigType,ConfigName,ValueSnippet,ResourceId"
Write-FindingsCsv -Findings $graphFindings -Path $GraphFile `
    -EmptyHeader "Subscription,ResourceType,ResourceName,ResourceGroup,Location,MatchType,Tags"

$totalCount = $customDomainFindings.Count + $nameFindings.Count + $tagFindings.Count + $configFindings.Count

$notes = "CustomDomains=$($customDomainFindings.Count); Names=$($nameFindings.Count); Tags=$($tagFindings.Count); Config=$($configFindings.Count); ResourceGraph=$($graphFindings.Count)"
Write-Host "[$ModuleName] Total: $totalCount findings. $notes" -ForegroundColor Green

Write-Status -TotalCount $totalCount -Notes $notes
