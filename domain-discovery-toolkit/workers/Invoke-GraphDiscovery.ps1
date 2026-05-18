# Invoke-GraphDiscovery.ps1
# Runs all Microsoft Graph discovery modules in an isolated PowerShell process.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ToolkitRoot,
    [Parameter(Mandatory)] [string]$ModulesPath,
    [Parameter(Mandatory)] [string]$Domain,
    [Parameter(Mandatory)] [string]$OutputPath,
    [Parameter(Mandatory)] [string]$SummaryPath,
    [int]$IncludeGuests = 1,
    [int]$SignInLookbackDays = 30
)

$ErrorActionPreference = "Continue"

. (Join-Path $ToolkitRoot "tools\ToolkitRuntime.ps1")
Import-ToolkitModuleGroup -ToolkitRoot $ToolkitRoot -Group "Graph"

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

function Write-GraphSummary {
    $script:InventorySummary | ConvertTo-Json -Depth 8 | Out-File -FilePath $SummaryPath -Encoding UTF8
}

try {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
} catch { }

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
Write-Host "Required scopes: Directory.Read.All, Application.Read.All, AuditLog.Read.All, Policy.Read.All, Domain.Read.All" -ForegroundColor DarkGray
Write-Host "A browser window will open for sign-in." -ForegroundColor DarkGray
Write-Host "TIP: If you don't see a sign-in window, check behind other open windows (Alt-Tab)." -ForegroundColor DarkGray

try {
    Connect-MgGraph -Scopes `
        "Directory.Read.All", `
        "Application.Read.All", `
        "AuditLog.Read.All", `
        "Policy.Read.All", `
        "Domain.Read.All" `
        -NoWelcome `
        -ErrorAction Stop
} catch {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host " Connect-MgGraph FAILED" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Common causes:" -ForegroundColor Yellow
    Write-Host "  1. The sign-in dialog was cancelled or dismissed." -ForegroundColor Yellow
    Write-Host "  2. The sign-in dialog appeared behind another window." -ForegroundColor Yellow
    Write-Host "  3. Admin consent is required for Microsoft Graph Command Line Tools." -ForegroundColor Yellow
    Write-Host "  4. Conditional Access policy blocks interactive sign-in for the account." -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Red
    Write-DiscoveryError -Module "GraphAuth" -Message "Connect-MgGraph failed: $($_.Exception.Message)"
    Add-InventorySummary -Module "GraphAuth" -Count -1 -OutputFile "" -Notes "ERROR: Connect-MgGraph failed"
    Write-GraphSummary
    exit 2
}

$graphCtx = Get-MgContext
if (-not $graphCtx) {
    Write-DiscoveryError -Module "GraphAuth" -Message "Connect-MgGraph returned but no context was established."
    Add-InventorySummary -Module "GraphAuth" -Count -1 -OutputFile "" -Notes "ERROR: No Graph context established"
    Write-GraphSummary
    exit 2
}

Write-Host "Connected to Graph as: $($graphCtx.Account) (TenantId: $($graphCtx.TenantId))" -ForegroundColor Green

$modulesToRun = @(
    @{ Script = "01-Users.ps1";              Args = @{ Domain=$Domain; OutputPath=$OutputPath; IncludeGuests=([bool]$IncludeGuests) } }
    @{ Script = "02-Groups.ps1";             Args = @{ Domain=$Domain; OutputPath=$OutputPath } }
    @{ Script = "03-AppRegistrations.ps1";   Args = @{ Domain=$Domain; OutputPath=$OutputPath } }
    @{ Script = "04-ServicePrincipals.ps1";  Args = @{ Domain=$Domain; OutputPath=$OutputPath } }
    @{ Script = "05-ManagedIdentities.ps1";  Args = @{ Domain=$Domain; OutputPath=$OutputPath } }
    @{ Script = "07-ConditionalAccess.ps1";  Args = @{ Domain=$Domain; OutputPath=$OutputPath } }
    @{ Script = "08-Federation.ps1";         Args = @{ Domain=$Domain; OutputPath=$OutputPath } }
    @{ Script = "09-SignInActivity.ps1";     Args = @{ Domain=$Domain; OutputPath=$OutputPath; LookbackDays=$SignInLookbackDays } }
    @{ Script = "10-SoftDeleted.ps1";        Args = @{ Domain=$Domain; OutputPath=$OutputPath } }
)

foreach ($mod in ($modulesToRun | Sort-Object { $_.Script })) {
    $scriptPath = Join-Path $ModulesPath $mod.Script
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-DiscoveryError -Module $mod.Script -Message "Script not found at $scriptPath"
        continue
    }

    Write-Host ""
    Write-Host "----- Running $($mod.Script) -----" -ForegroundColor Cyan
    try {
        $modArgs = $mod.Args
        . $scriptPath @modArgs
    } catch {
        Write-DiscoveryError -Module $mod.Script -Message "Module failed: $($_.Exception.Message)"
    }
}

Write-GraphSummary
exit 0
