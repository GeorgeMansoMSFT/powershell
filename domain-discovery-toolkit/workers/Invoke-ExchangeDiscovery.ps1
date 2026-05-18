# Invoke-ExchangeDiscovery.ps1
# Runs Exchange Online discovery in an isolated PowerShell process.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ToolkitRoot,
    [Parameter(Mandatory)] [string]$ModulesPath,
    [Parameter(Mandatory)] [string]$Domain,
    [Parameter(Mandatory)] [string]$OutputPath,
    [Parameter(Mandatory)] [string]$SummaryPath
)

$ErrorActionPreference = "Continue"

. (Join-Path $ToolkitRoot "tools\ToolkitRuntime.ps1")
Import-ToolkitModuleGroup -ToolkitRoot $ToolkitRoot -Group "Exchange"

$ErrorLog = Join-Path $OutputPath "errors.log"
$script:InventorySummary = @{}

function Write-DiscoveryError {
    param([string]$Module, [string]$Message)
    $entry = "[$(Get-Date -Format 'o')] [$Module] $Message"
    Add-Content -Path $ErrorLog -Value $entry -ErrorAction SilentlyContinue
    Write-Warning $entry
}

function Add-InventorySummary {
    param([string]$Module, [int]$Count, [string]$OutputFile, [string]$Notes = "")
    $script:InventorySummary[$Module] = @{
        Count = $Count
        OutputFile = $OutputFile
        Notes = $Notes
        Timestamp = (Get-Date -Format 'o')
    }
}

function Write-ExchangeSummary {
    $script:InventorySummary | ConvertTo-Json -Depth 8 | Out-File -FilePath $SummaryPath -Encoding UTF8
}

Write-Host "Connecting to Exchange Online..." -ForegroundColor Yellow
try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    Write-Host "Connected to Exchange Online." -ForegroundColor Green
} catch {
    Write-DiscoveryError -Module "ExchangeOnline" -Message "Exchange Online connection failed: $($_.Exception.Message)"
    Add-InventorySummary -Module "ExchangeOnline" -Count -1 -OutputFile "" -Notes "ERROR: Connection failed: $($_.Exception.Message)"
    Write-ExchangeSummary
    exit 2
}

$scriptPath = Join-Path $ModulesPath "06-ExchangeOnline.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-DiscoveryError -Module "06-ExchangeOnline.ps1" -Message "Script not found at $scriptPath"
    Add-InventorySummary -Module "ExchangeOnline" -Count -1 -OutputFile "" -Notes "ERROR: Script not found"
    Write-ExchangeSummary
    exit 1
}

Write-Host ""
Write-Host "----- Running 06-ExchangeOnline.ps1 -----" -ForegroundColor Cyan
try {
    . $scriptPath -Domain $Domain -OutputPath $OutputPath
} catch {
    Write-DiscoveryError -Module "06-ExchangeOnline.ps1" -Message "Module failed: $($_.Exception.Message)"
    Add-InventorySummary -Module "ExchangeOnline" -Count -1 -OutputFile "" -Notes "ERROR: $($_.Exception.Message)"
}

Write-ExchangeSummary
exit 0
