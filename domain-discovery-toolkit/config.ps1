# config.ps1
# Edit these values before running the toolkit.

# The custom domain you intend to release from this tenant.
# Example: "contoso.com"
$DomainToInvestigate = "contoso.com"

# Where to write the CSVs and final report.
# Will be created if it doesn't exist.
$OutputPath = Join-Path $PSScriptRoot "output\$(Get-Date -Format 'yyyy-MM-dd-HHmm')"

# Days of sign-in history to query (max 30 via Graph, longer if Sentinel module is enabled).
$SignInLookbackDays = 30

# Exchange Online discovery (mailboxes, DLs, transport rules, accepted domains, etc.)
# By default, the orchestrator will prompt to connect interactively.
# Set to $false to suppress the prompt and skip EXO discovery (e.g. for unattended runs).
# Set to $true to also suppress the prompt but require EXO; the orchestrator will still
#   call Connect-ExchangeOnline if not already connected.
# Leave as $null (default) to let the orchestrator prompt.
$IncludeExchangeOnline = $null

# Azure resource discovery (App Service, APIM, Front Door, App Gateway custom domains).
# Same semantics as $IncludeExchangeOnline.
$IncludeAzureResources = $null

# Set to $true to include guest users in the discovery (recommended).
$IncludeGuests = $true

# Set to $true to also write a JSON inventory summary alongside CSVs.
$WriteJsonSummary = $true

# Throttle delay (ms) between large Graph queries - bump up if you hit 429s.
$GraphThrottleMs = 100

# ============================================================
# Don't edit below unless you know what you're doing.
# ============================================================

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$ErrorLog = Join-Path $OutputPath "errors.log"
$SummaryJson = Join-Path $OutputPath "inventory-summary.json"

# Helper: write to error log
function Write-DiscoveryError {
    param([string]$Module, [string]$Message)
    $entry = "[$(Get-Date -Format 'o')] [$Module] $Message"
    Add-Content -Path $ErrorLog -Value $entry
    Write-Warning $entry
}

# Helper: append to running summary
$script:InventorySummary = @{}
function Add-InventorySummary {
    param([string]$Module, [int]$Count, [string]$OutputFile, [string]$Notes = "")
    $script:InventorySummary[$Module] = @{
        Count = $Count
        OutputFile = $OutputFile
        Notes = $Notes
        Timestamp = (Get-Date -Format 'o')
    }
}

Write-Host "Configuration loaded. Domain: $DomainToInvestigate. Output: $OutputPath" -ForegroundColor Cyan
