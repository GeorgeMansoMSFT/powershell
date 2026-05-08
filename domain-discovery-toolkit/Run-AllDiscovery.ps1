# Run-AllDiscovery.ps1
# Orchestrates all discovery modules and produces a summary HTML report.
# Run from the toolkit root directory.

[CmdletBinding()]
param(
    [string] $ConfigPath = "$PSScriptRoot\config.ps1"
)

$ErrorActionPreference = "Continue"
$start = Get-Date

# ---------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at $ConfigPath. Copy config.ps1 from the toolkit root and edit it first."
}
. $ConfigPath

$ModulesPath = Join-Path $PSScriptRoot "modules"

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " Verified Domain Reference Discovery" -ForegroundColor Cyan
Write-Host " Domain: $DomainToInvestigate" -ForegroundColor Cyan
Write-Host " Output: $OutputPath" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# Pin Graph SDK to a single version to avoid assembly conflicts
# ---------------------------------------------------------------
# When multiple versions of Microsoft.Graph.* modules are installed, PowerShell can fail
# to resolve assemblies across versions. We pick the highest version that has a *complete*
# set of the modules we need, and force-import them all from that version.
$requiredGraphModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Applications',
    'Microsoft.Graph.Identity.SignIns',
    'Microsoft.Graph.Identity.DirectoryManagement'
)

# Find versions where ALL required modules exist
$versionMap = @{}
foreach ($modName in $requiredGraphModules) {
    $found = Get-Module -ListAvailable -Name $modName -ErrorAction SilentlyContinue
    foreach ($f in $found) {
        $v = $f.Version.ToString()
        if (-not $versionMap.ContainsKey($v)) { $versionMap[$v] = @() }
        $versionMap[$v] += $modName
    }
}

$completeVersions = $versionMap.GetEnumerator() |
    Where-Object { $_.Value.Count -eq $requiredGraphModules.Count } |
    ForEach-Object { [version]$_.Key } |
    Sort-Object -Descending

if ($completeVersions.Count -eq 0) {
    throw "No single version of Microsoft.Graph.* has all required modules installed. Run: Install-Module Microsoft.Graph -Scope CurrentUser -Force"
}

$targetVersion = $completeVersions[0].ToString()

# Graph 2.24 and earlier have known assembly conflicts with Az PowerShell 5.x (Azure.Identity mismatch).
# If we'd be pinning to an old version AND Az is installed, warn the user.
$minAzCompatibleGraph = [version]'2.25.0'
$azInstalled = $null -ne (Get-Module -ListAvailable -Name Az.Accounts -ErrorAction SilentlyContinue)
if ($azInstalled -and ($completeVersions[0] -lt $minAzCompatibleGraph)) {
    Write-Host ""
    Write-Host "WARNING: Microsoft.Graph $targetVersion has known assembly conflicts with Az PowerShell 5.x." -ForegroundColor Red
    Write-Host "         Graph-using modules will likely fail with 'Could not load file or assembly' errors." -ForegroundColor Red
    Write-Host "         Recommended fix: Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber" -ForegroundColor Yellow
    Write-Host "         Then close PowerShell, reopen, and re-run this orchestrator." -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-Host "Continue anyway? [y/N]"
    if ($continue -notmatch '^[Yy]') {
        throw "Aborted by user. Update Microsoft.Graph and try again."
    }
}

Write-Host "Pinning Microsoft.Graph modules to version $targetVersion (avoids assembly conflicts)..." -ForegroundColor Yellow

# Remove any already-loaded Graph modules so they reload at the pinned version
Get-Module Microsoft.Graph* | Remove-Module -Force -ErrorAction SilentlyContinue

# Import each at the pinned version
foreach ($modName in $requiredGraphModules) {
    try {
        Import-Module $modName -RequiredVersion $targetVersion -Force -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        Write-Warning "Could not load $modName $targetVersion`: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------
# Verify Graph connection
# ---------------------------------------------------------------
# Disconnect any stale Graph context first. If a previous run left a half-broken WAM
# broker session, child modules will fail with "InteractiveBrowserCredential authentication
# failed: User canceled authentication" because they can't reuse the broker token from
# the parent scope. A clean disconnect + reconnect at orchestrator start avoids this.
try {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
} catch { }

# NOTE on WAM (Web Account Manager): As of Microsoft.Graph 2.34+, WAM is enabled by
# default on Windows and CANNOT be disabled (per Microsoft's Set-MgGraphOption docs).
# This means the first sign-in will use the Windows-native WAM dialog, which:
#   - Defaults to showing personal Microsoft accounts (click "Work or school account")
#   - Asks "Sign in to all apps and websites on this device?" (click "No, this app only")
# Once authenticated, the token is cached and reused for the rest of the session.
# If a customer's environment blocks WAM entirely, the only fallback is -UseDeviceCode,
# but device code is blocked by Conditional Access in many customer tenants.

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
Write-Host "Required scopes: Directory.Read.All, Application.Read.All, AuditLog.Read.All, Policy.Read.All, Domain.Read.All" -ForegroundColor DarkGray
Write-Host "A browser window will open for sign-in." -ForegroundColor DarkGray

Connect-MgGraph -Scopes `
    "Directory.Read.All", `
    "Application.Read.All", `
    "AuditLog.Read.All", `
    "Policy.Read.All", `
    "Domain.Read.All" `
    -NoWelcome
$graphCtx = Get-MgContext

if (-not $graphCtx) {
    throw "Failed to establish Graph connection. Aborting."
}
Write-Host "Connected to Graph as: $($graphCtx.Account) (TenantId: $($graphCtx.TenantId))" -ForegroundColor Green

# ---------------------------------------------------------------
# Run modules
# ---------------------------------------------------------------
$modulesToRun = @(
    @{ Script = "01-Users.ps1";              Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath; IncludeGuests=$IncludeGuests } }
    @{ Script = "02-Groups.ps1";             Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
    @{ Script = "03-AppRegistrations.ps1";   Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
    @{ Script = "04-ServicePrincipals.ps1";  Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
    @{ Script = "05-ManagedIdentities.ps1";  Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
    @{ Script = "07-ConditionalAccess.ps1";  Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
    @{ Script = "08-Federation.ps1";         Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
    @{ Script = "09-SignInActivity.ps1";     Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath; LookbackDays=$SignInLookbackDays } }
    @{ Script = "10-SoftDeleted.ps1";        Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
)

# Track scopes that were skipped so we can flag the report as incomplete
$script:SkippedScopes = @()

# ---------------------------------------------------------------
# Exchange Online connection - auto-connect with skip option
# ---------------------------------------------------------------
$exoConnected = $false
try {
    $exoInfo = Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object State -eq "Connected"
    if ($exoInfo) { $exoConnected = $true }
} catch { }

if ($exoConnected) {
    Write-Host ""
    Write-Host "Exchange Online: already connected. Including in scan." -ForegroundColor Green
    $modulesToRun += @{ Script = "06-ExchangeOnline.ps1"; Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
}
elseif ($IncludeExchangeOnline -eq $false) {
    Write-Host ""
    Write-Host "Exchange Online: explicitly disabled in config. Skipping." -ForegroundColor DarkYellow
    $script:SkippedScopes += "Exchange Online (disabled in config)"
}
elseif (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "Exchange Online: ExchangeOnlineManagement module not installed." -ForegroundColor Yellow
    Write-Host "  To include EXO discovery, run: Install-Module ExchangeOnlineManagement -Scope CurrentUser" -ForegroundColor DarkGray
    Write-Host "  Then re-run this orchestrator. Skipping for now." -ForegroundColor Yellow
    $script:SkippedScopes += "Exchange Online (module not installed)"
}
else {
    # Either prompt the user, or auto-connect if config forces it
    $shouldConnect = $false
    if ($IncludeExchangeOnline -eq $true) {
        Write-Host ""
        Write-Host "Exchange Online: required by config. Connecting..." -ForegroundColor Cyan
        $shouldConnect = $true
    } else {
        Write-Host ""
        Write-Host "Exchange Online discovery covers mailboxes, distribution lists, mail-enabled" -ForegroundColor Cyan
        Write-Host "groups, transport rules, connectors, and accepted domains. This is typically the" -ForegroundColor Cyan
        Write-Host "largest category of domain references and skipping leaves the scan incomplete." -ForegroundColor Cyan
        $response = Read-Host "Connect to Exchange Online now? [Y/n]"
        if ($response -eq '' -or $response -match '^[Yy]') {
            $shouldConnect = $true
        }
    }

    if ($shouldConnect) {
        try {
            # Try to reuse the Graph session's identity for silent SSO. WAM caches the
            # token at the OS level, and EXO can often pick it up without re-prompting
            # if the same UPN is specified.
            if ($graphCtx -and $graphCtx.Account) {
                Connect-ExchangeOnline -UserPrincipalName $graphCtx.Account -ShowBanner:$false -ErrorAction Stop
            } else {
                Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
            }
            Write-Host "Connected to Exchange Online." -ForegroundColor Green
            $modulesToRun += @{ Script = "06-ExchangeOnline.ps1"; Args = @{ Domain=$DomainToInvestigate; OutputPath=$OutputPath } }
        } catch {
            Write-Warning "Exchange Online connection failed: $($_.Exception.Message)"
            Write-Host "Continuing without Exchange Online discovery." -ForegroundColor Yellow
            $script:SkippedScopes += "Exchange Online (connection failed: $($_.Exception.Message))"
        }
    } else {
        Write-Host "Skipping Exchange Online discovery (per user)." -ForegroundColor DarkYellow
        $script:SkippedScopes += "Exchange Online (declined by user)"
    }
}

# ---------------------------------------------------------------
# Azure resources connection - auto-connect with skip option
# ---------------------------------------------------------------
# Track whether to run the Az resource scan in a separate process after the main loop.
# Az PowerShell and Microsoft.Graph have known Azure.Identity assembly conflicts when
# loaded in the same process, so module 11 runs in a clean child PowerShell with its
# own independent Connect-AzAccount.
$script:RunAzScan = $false

if ($IncludeAzureResources -eq $false) {
    Write-Host ""
    Write-Host "Azure resources: explicitly disabled in config. Skipping." -ForegroundColor DarkYellow
    $script:SkippedScopes += "Azure resources (disabled in config)"
}
elseif (-not (Get-Module -ListAvailable -Name Az.Accounts -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "Azure resources: Az PowerShell not installed." -ForegroundColor Yellow
    Write-Host "  To include Azure resource discovery, run: Install-Module Az -Scope CurrentUser" -ForegroundColor DarkGray
    Write-Host "  Then re-run this orchestrator. Skipping for now." -ForegroundColor Yellow
    $script:SkippedScopes += "Azure resources (Az module not installed)"
}
elseif ($IncludeAzureResources -eq $true) {
    Write-Host ""
    Write-Host "Azure resources: required by config. Will scan in separate process at end of run." -ForegroundColor Cyan
    $script:RunAzScan = $true
}
else {
    Write-Host ""
    Write-Host "Azure resource discovery covers App Service, APIM, Front Door, Application" -ForegroundColor Cyan
    Write-Host "Gateway custom domain bindings, plus resource names/tags/app config containing the" -ForegroundColor Cyan
    Write-Host "domain. Recommended if any Azure resources reference the domain." -ForegroundColor Cyan
    Write-Host "Note: due to known Az/Graph SDK assembly conflicts, this scan runs in a separate" -ForegroundColor DarkGray
    Write-Host "PowerShell process and will prompt for Azure auth independently." -ForegroundColor DarkGray
    $response = Read-Host "Include Azure resource scan? [Y/n]"
    if ($response -eq '' -or $response -match '^[Yy]') {
        $script:RunAzScan = $true
    } else {
        Write-Host "Skipping Azure resource discovery (per user)." -ForegroundColor DarkYellow
        $script:SkippedScopes += "Azure resources (declined by user)"
    }
}

foreach ($mod in ($modulesToRun | Sort-Object { $_.Script })) {
    $scriptPath = Join-Path $ModulesPath $mod.Script
    if (-not (Test-Path $scriptPath)) {
        Write-DiscoveryError -Module $mod.Script -Message "Script not found at $scriptPath"
        continue
    }

    Write-Host ""
    Write-Host "----- Running $($mod.Script) -----" -ForegroundColor Cyan
    try {
        # Dot-source the module so it runs in this scope and can see helper functions
        # (Add-InventorySummary, Write-DiscoveryError) and $script:InventorySummary
        # defined in config.ps1.
        $modArgs = $mod.Args
        . $scriptPath @modArgs
    } catch {
        Write-DiscoveryError -Module $mod.Script -Message "Module failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------
# Module 11: Azure resources (runs in separate process to avoid Az/Graph
# Azure.Identity assembly conflict)
# ---------------------------------------------------------------
if ($script:RunAzScan) {
    Write-Host ""
    Write-Host "----- Running 11-AzureResources.ps1 (separate process) -----" -ForegroundColor Cyan
    Write-Host "Launching child PowerShell to avoid Az/Graph SDK assembly conflicts..." -ForegroundColor DarkGray
    Write-Host "You will be prompted to authenticate to Azure once more in the child window." -ForegroundColor DarkGray

    $azScript = Join-Path $ModulesPath "11-AzureResources.ps1"
    $azStatusFile = Join-Path $OutputPath "11-azure-status.json"

    # Determine which PowerShell to invoke. Prefer pwsh (PS7+) if available; fallback to powershell.
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        (Get-Command pwsh).Source
    } else {
        (Get-Command powershell).Source
    }

    $azArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $azScript,
        "-Domain", $DomainToInvestigate,
        "-OutputPath", $OutputPath
    )

    try {
        & $psExe @azArgs
        $azExitCode = $LASTEXITCODE

        if (Test-Path $azStatusFile) {
            $azStatus = Get-Content $azStatusFile -Raw | ConvertFrom-Json
            $script:InventorySummary["AzureResources"] = @{
                Count = $azStatus.Count
                OutputFile = "11-azure-*.csv (multiple files)"
                Notes = $azStatus.Notes
                Timestamp = $azStatus.Timestamp
            }
        } else {
            Write-DiscoveryError -Module "11-AzureResources.ps1" -Message "Az scan completed but no status file written. Exit code: $azExitCode"
        }
    } catch {
        Write-DiscoveryError -Module "11-AzureResources.ps1" -Message "Az scan launch failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------
# Write summary JSON
# ---------------------------------------------------------------
if ($WriteJsonSummary) {
    $script:InventorySummary | ConvertTo-Json -Depth 5 | Out-File -FilePath $SummaryJson -Encoding UTF8
    Write-Host ""
    Write-Host "Summary JSON written to: $SummaryJson" -ForegroundColor Green
}

# ---------------------------------------------------------------
# Generate HTML report
# ---------------------------------------------------------------
$htmlReportPath = Join-Path $OutputPath "Summary-Report.html"
$reportScript = Join-Path $PSScriptRoot "Generate-Report.ps1"

if (Test-Path $reportScript) {
    Write-Host ""
    Write-Host "Generating HTML summary report..." -ForegroundColor Yellow
    & $reportScript -InventorySummary $script:InventorySummary -Domain $DomainToInvestigate -OutputPath $htmlReportPath -OutputDir $OutputPath -SkippedScopes $script:SkippedScopes
    Write-Host "HTML report: $htmlReportPath" -ForegroundColor Green
}

$elapsed = (Get-Date) - $start
Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " Discovery complete." -ForegroundColor Cyan
Write-Host " Elapsed: $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
Write-Host " Output:  $OutputPath" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
