# New-OfflineDependencyPack.ps1
# Builds a redistributable dependency pack from dependencies.lock.json.

[CmdletBinding()]
param(
    [string]$ToolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$OutputZip = (Join-Path $ToolkitRoot "domain-migration-toolkit-dependencies.zip"),
    [switch]$ForceRefresh
)

$ErrorActionPreference = "Stop"

. (Join-Path $ToolkitRoot "tools\ToolkitRuntime.ps1")

Initialize-ToolkitRuntime `
    -ToolkitRoot $ToolkitRoot `
    -Groups @("Graph", "Exchange", "Azure") `
    -ForceRefresh:$ForceRefresh

$runtimeRoot = Join-Path $ToolkitRoot ".runtime"
if (-not (Test-Path -LiteralPath $runtimeRoot)) {
    throw "Runtime folder not found at $runtimeRoot"
}

if (Test-Path -LiteralPath $OutputZip) {
    Remove-Item -LiteralPath $OutputZip -Force
}

Compress-Archive -Path $runtimeRoot -DestinationPath $OutputZip -Force

Write-Host ""
Write-Host "Offline dependency pack created:" -ForegroundColor Green
Write-Host "  $OutputZip" -ForegroundColor White
Write-Host ""
Write-Host "Customers should extract this zip beside Run-AllDiscovery.ps1 so .runtime\modules exists." -ForegroundColor Cyan
