# Run-AllDiscovery.ps1
# Orchestrates isolated discovery workers and produces a summary HTML report.
# Run from the toolkit root directory.

[CmdletBinding()]
param(
    [string] $ConfigPath = "$PSScriptRoot\config.ps1",
    [switch] $ForceRuntimeRefresh,
    [switch] $NoDependencyDownload
)

$ErrorActionPreference = "Continue"
$start = Get-Date

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found at $ConfigPath. Copy config.ps1 from the toolkit root and edit it first."
}

. $ConfigPath
. (Join-Path $PSScriptRoot "tools\ToolkitRuntime.ps1")

$ToolkitRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$ModulesPath = Join-Path $ToolkitRoot "modules"
$WorkersPath = Join-Path $ToolkitRoot "workers"

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " Verified Domain Reference Discovery" -ForegroundColor Cyan
Write-Host " Domain: $DomainToInvestigate" -ForegroundColor Cyan
Write-Host " Output: $OutputPath" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

$script:SkippedScopes = @()

function Resolve-OptionalScope {
    param(
        [AllowNull()] [object]$ConfigValue,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string[]]$DescriptionLines,
        [string[]]$Notes = @()
    )

    if ($ConfigValue -eq $false) {
        Write-Host ""
        Write-Host "${Name}: explicitly disabled in config. Skipping." -ForegroundColor DarkYellow
        $script:SkippedScopes += "$Name (disabled in config)"
        return $false
    }

    if ($ConfigValue -eq $true) {
        Write-Host ""
        Write-Host "${Name}: required by config. Including in scan." -ForegroundColor Cyan
        return $true
    }

    Write-Host ""
    foreach ($line in $DescriptionLines) {
        Write-Host $line -ForegroundColor Cyan
    }
    foreach ($note in $Notes) {
        Write-Host $note -ForegroundColor DarkGray
    }

    $response = Read-Host "Include $Name scan? [Y/n]"
    if ($response -eq "" -or $response -match "^[Yy]") {
        return $true
    }

    Write-Host "Skipping $Name discovery (per user)." -ForegroundColor DarkYellow
    $script:SkippedScopes += "$Name (declined by user)"
    return $false
}

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)] $InputObject)

    process {
        if ($null -eq $InputObject) { return $null }

        if ($InputObject -is [hashtable]) { return $InputObject }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
        }

        if ($InputObject.PSObject.Properties.Count -gt 0 -and $InputObject.GetType().Name -eq "PSCustomObject") {
            $hash = @{}
            foreach ($prop in $InputObject.PSObject.Properties) {
                $hash[$prop.Name] = ConvertTo-Hashtable $prop.Value
            }
            return $hash
        }

        return $InputObject
    }
}

function Merge-InventorySummaryFile {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $summaryObject = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $summaryObject) {
        return
    }

    foreach ($prop in $summaryObject.PSObject.Properties) {
        $script:InventorySummary[$prop.Name] = ConvertTo-Hashtable $prop.Value
    }
}

function Invoke-DiscoveryWorker {
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$Name
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Worker '$Name' not found at $ScriptPath"
    }

    $psExe = Get-ToolkitPowerShellExe
    Write-Host ""
    Write-Host "----- Running $Name (isolated process) -----" -ForegroundColor Cyan
    $workerArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments
    & $psExe @workerArgs
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-DiscoveryError -Module $Name -Message "Worker exited with code $exitCode"
    }
}

$runExchange = Resolve-OptionalScope `
    -ConfigValue $IncludeExchangeOnline `
    -Name "Exchange Online" `
    -DescriptionLines @(
        "Exchange Online discovery covers mailboxes, distribution lists, mail-enabled",
        "groups, transport rules, connectors, and accepted domains. This is typically",
        "one of the largest categories of domain references."
    )

$runAzure = Resolve-OptionalScope `
    -ConfigValue $IncludeAzureResources `
    -Name "Azure resources" `
    -DescriptionLines @(
        "Azure resource discovery covers App Service, APIM, Front Door, Application",
        "Gateway custom domain bindings, resource names/tags/app config, Resource Graph,",
        "and managed identity federated credentials containing the domain."
    ) `
    -Notes @(
        "The Azure scan runs in a separate PowerShell process and prompts for Azure auth independently."
    )

$dependencyGroups = @("Graph")
if ($runExchange) { $dependencyGroups += "Exchange" }
if ($runAzure) { $dependencyGroups += "Azure" }

try {
    Initialize-ToolkitRuntime `
        -ToolkitRoot $ToolkitRoot `
        -Groups $dependencyGroups `
        -ForceRefresh:$ForceRuntimeRefresh `
        -NoDownload:$NoDependencyDownload
} catch {
    Write-Host ""
    Write-Host "Toolkit runtime setup failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "No tenant data was collected. Resolve the dependency issue and re-run the toolkit." -ForegroundColor Yellow
    exit 1
}

$graphSummaryPath = Join-Path $OutputPath "00-graph-worker-status.json"
$exoSummaryPath = Join-Path $OutputPath "06-exchange-worker-status.json"
$azStatusFile = Join-Path $OutputPath "11-azure-status.json"

$graphWorker = Join-Path $WorkersPath "Invoke-GraphDiscovery.ps1"
$graphArgs = @(
    "-ToolkitRoot", $ToolkitRoot,
    "-ModulesPath", $ModulesPath,
    "-Domain", $DomainToInvestigate,
    "-OutputPath", $OutputPath,
    "-SummaryPath", $graphSummaryPath,
    "-IncludeGuests", $(if ($IncludeGuests) { "1" } else { "0" }),
    "-SignInLookbackDays", ([string]$SignInLookbackDays)
)
Invoke-DiscoveryWorker -ScriptPath $graphWorker -Arguments $graphArgs -Name "Graph discovery"
Merge-InventorySummaryFile -Path $graphSummaryPath

if ($runExchange) {
    $exoWorker = Join-Path $WorkersPath "Invoke-ExchangeDiscovery.ps1"
    $exoArgs = @(
        "-ToolkitRoot", $ToolkitRoot,
        "-ModulesPath", $ModulesPath,
        "-Domain", $DomainToInvestigate,
        "-OutputPath", $OutputPath,
        "-SummaryPath", $exoSummaryPath
    )
    Invoke-DiscoveryWorker -ScriptPath $exoWorker -Arguments $exoArgs -Name "Exchange Online discovery"
    Merge-InventorySummaryFile -Path $exoSummaryPath
}

if ($runAzure) {
    $azScript = Join-Path $ModulesPath "11-AzureResources.ps1"
    $azArgs = @(
        "-Domain", $DomainToInvestigate,
        "-OutputPath", $OutputPath,
        "-ToolkitRoot", $ToolkitRoot
    )
    Invoke-DiscoveryWorker -ScriptPath $azScript -Arguments $azArgs -Name "Azure resource discovery"

    if (Test-Path -LiteralPath $azStatusFile) {
        $azStatus = Get-Content -LiteralPath $azStatusFile -Raw | ConvertFrom-Json
        $script:InventorySummary["AzureResources"] = @{
            Count = [int]$azStatus.Count
            OutputFile = "11-azure-*.csv (multiple files)"
            Notes = $azStatus.Notes
            Timestamp = $azStatus.Timestamp
        }
    } else {
        Write-DiscoveryError -Module "11-AzureResources.ps1" -Message "Az scan completed but no status file was written."
    }
}

if ($WriteJsonSummary) {
    $script:InventorySummary | ConvertTo-Json -Depth 8 | Out-File -FilePath $SummaryJson -Encoding UTF8
    Write-Host ""
    Write-Host "Summary JSON written to: $SummaryJson" -ForegroundColor Green
}

$htmlReportPath = Join-Path $OutputPath "Summary-Report.html"
$reportScript = Join-Path $ToolkitRoot "Generate-Report.ps1"

if (Test-Path -LiteralPath $reportScript) {
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
