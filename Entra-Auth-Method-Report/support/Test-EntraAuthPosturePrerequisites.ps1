<#
.SYNOPSIS
Checks whether a workstation and Entra tenant are ready to run the posture report.

.DESCRIPTION
Performs local checks by default and does not change the tenant. Use
-TestGraphAccess to sign in and issue two read-only Graph requests that validate
the registration and sign-in data sources used by the report.

.EXAMPLE
.\support\Test-EntraAuthPosturePrerequisites.ps1

.EXAMPLE
.\support\Test-EntraAuthPosturePrerequisites.ps1 -TestGraphAccess
#>
[CmdletBinding()]
param(
    [string] $TenantId,

    [switch] $TestGraphAccess,

    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'output'),

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-CheckResult {
    param(
        [System.Collections.Generic.List[object]] $Results,
        [ValidateSet('Pass','Warning','Fail','Skipped')][string] $Status,
        [string] $Component,
        [string] $Detail,
        [string] $RecommendedAction
    )

    $Results.Add([pscustomobject][ordered]@{
        Status            = $Status
        Component         = $Component
        Detail            = $Detail
        RecommendedAction = $RecommendedAction
    })
}

function Test-ExcelDesktop {
    if ($env:OS -ne 'Windows_NT') { return $false }
    $excel = $null
    try {
        $excel = New-Object -ComObject Excel.Application 4>$null
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $excel) {
            try { $excel.Quit() } catch { }
            try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) } catch { }
        }
    }
}

function Get-GraphPage {
    param([Parameter(Mandatory)][string] $Uri)
    return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
}

$results = New-Object System.Collections.Generic.List[object]
$scriptVersion = '1.0.0'

if ($PSVersionTable.PSVersion -ge [version]'5.1') {
    Add-CheckResult -Results $results -Status Pass -Component 'PowerShell' -Detail "PowerShell $($PSVersionTable.PSVersion) detected." -RecommendedAction 'None.'
}
else {
    Add-CheckResult -Results $results -Status Fail -Component 'PowerShell' -Detail "PowerShell $($PSVersionTable.PSVersion) is below the supported minimum of 5.1." -RecommendedAction 'Install Windows PowerShell 5.1 or PowerShell 7.'
}

$moduleVersions = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication | Sort-Object Version -Descending)
if ($moduleVersions.Count -eq 0) {
    Add-CheckResult -Results $results -Status Fail -Component 'Microsoft.Graph.Authentication' -Detail 'Module is not installed.' -RecommendedAction 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
else {
    $moduleVersion = $moduleVersions[0].Version
    if ($moduleVersion.Major -ge 2) {
        Add-CheckResult -Results $results -Status Pass -Component 'Microsoft.Graph.Authentication' -Detail "Version $moduleVersion is installed." -RecommendedAction 'None.'
    }
    else {
        Add-CheckResult -Results $results -Status Warning -Component 'Microsoft.Graph.Authentication' -Detail "Version $moduleVersion is installed; version 2.x is recommended." -RecommendedAction 'Update-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    try {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    catch {
        Add-CheckResult -Results $results -Status Fail -Component 'Output directory' -Detail "Cannot create $OutputDirectory. $($_.Exception.Message)" -RecommendedAction 'Choose a writable local directory with -OutputDirectory.'
    }
}

if (Test-Path -LiteralPath $OutputDirectory -PathType Container) {
    $writeTestPath = Join-Path $OutputDirectory (".entra-auth-posture-write-test-{0}.tmp" -f [guid]::NewGuid())
    try {
        [System.IO.File]::WriteAllText($writeTestPath, 'test')
        [System.IO.File]::Delete($writeTestPath)
        Add-CheckResult -Results $results -Status Pass -Component 'Output directory' -Detail "Writable: $OutputDirectory" -RecommendedAction 'None.'
    }
    catch {
        Add-CheckResult -Results $results -Status Fail -Component 'Output directory' -Detail "Cannot write to $OutputDirectory. $($_.Exception.Message)" -RecommendedAction 'Choose a writable local directory with -OutputDirectory.'
    }
}
else {
    Add-CheckResult -Results $results -Status Fail -Component 'Output directory' -Detail "Directory does not exist: $OutputDirectory" -RecommendedAction 'Create the directory or specify an existing directory with -OutputDirectory.'
}

if ($env:OS -eq 'Windows_NT') {
    if (Test-ExcelDesktop) {
        Add-CheckResult -Results $results -Status Pass -Component 'Excel packaging (optional)' -Detail 'Desktop Excel and its COM automation interface are available.' -RecommendedAction 'The report will automatically create an XLSX workbook unless -PackageDeliverables $false is specified.'
    }
    else {
        Add-CheckResult -Results $results -Status Warning -Component 'Excel packaging (optional)' -Detail 'Desktop Excel could not be started through COM.' -RecommendedAction 'CSV and HTML outputs remain supported. Install/repair desktop Excel to create the XLSX workbook.'
    }
}
else {
    Add-CheckResult -Results $results -Status Warning -Component 'Excel packaging (optional)' -Detail 'Excel COM packaging is supported only on Windows with desktop Excel.' -RecommendedAction 'Run the core CSV report on this platform, or package the CSVs from a supported Windows workstation.'
}

if ($TestGraphAccess) {
    if ($moduleVersions.Count -eq 0) {
        Add-CheckResult -Results $results -Status Skipped -Component 'Microsoft Graph access' -Detail 'Graph module is not installed.' -RecommendedAction 'Install the module, then run this test again with -TestGraphAccess.'
    }
    else {
        try {
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop -Verbose:$false 4>$null
            $context = Get-MgContext
            $needsConnection = $null -eq $context -or $context.Scopes -notcontains 'AuditLog.Read.All'
            if ($TenantId -and ($null -eq $context -or $context.TenantId -ne $TenantId)) { $needsConnection = $true }
            if ($needsConnection) {
                $connectParams = @{ Scopes = 'AuditLog.Read.All'; NoWelcome = $true; ContextScope = 'Process' }
                if ($TenantId) { $connectParams.TenantId = $TenantId }
                Connect-MgGraph @connectParams
            }
            $context = Get-MgContext
            Add-CheckResult -Results $results -Status Pass -Component 'Microsoft Graph sign-in' -Detail "Connected to tenant $($context.TenantId) as $($context.Account)." -RecommendedAction 'None.'

            try {
                [void](Get-GraphPage -Uri 'https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails?$top=1')
                Add-CheckResult -Results $results -Status Pass -Component 'Registration report access' -Detail 'Read-only userRegistrationDetails request succeeded.' -RecommendedAction 'None.'
            }
            catch {
                Add-CheckResult -Results $results -Status Fail -Component 'Registration report access' -Detail $_.Exception.Message -RecommendedAction 'Confirm AuditLog.Read.All consent and an appropriate Entra role such as Reports Reader or Security Reader.'
            }

            try {
                $since = (Get-Date).ToUniversalTime().AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
                $uri = 'https://graph.microsoft.com/beta/auditLogs/signIns?$top=1&$filter={0}' -f [uri]::EscapeDataString("createdDateTime ge $since")
                [void](Get-GraphPage -Uri $uri)
                Add-CheckResult -Results $results -Status Pass -Component 'Sign-in detail access (beta)' -Detail 'Read-only beta sign-ins request succeeded.' -RecommendedAction 'None.'
            }
            catch {
                Add-CheckResult -Results $results -Status Fail -Component 'Sign-in detail access (beta)' -Detail $_.Exception.Message -RecommendedAction 'Confirm AuditLog.Read.All, an eligible Entra license, and sign-in-log availability. The core registration report can still run with -IncludeSignInActivity $false.'
            }
        }
        catch {
            Add-CheckResult -Results $results -Status Fail -Component 'Microsoft Graph sign-in' -Detail $_.Exception.Message -RecommendedAction 'Run from a supported interactive desktop session and confirm the tenant permits Microsoft Graph PowerShell sign-in.'
        }
    }
}
else {
    Add-CheckResult -Results $results -Status Skipped -Component 'Microsoft Graph access' -Detail 'Skipped because -TestGraphAccess was not supplied.' -RecommendedAction 'Run again with -TestGraphAccess before a customer engagement.'
}

Write-Host "Entra Authentication Posture preflight v$scriptVersion"
$results | Format-Table -AutoSize -Wrap

if ($OutputPath) {
    $resultDirectory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($resultDirectory) -and -not (Test-Path -LiteralPath $resultDirectory)) {
        New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
    }
    $results | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Preflight results: $OutputPath"
}

if (@($results | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) { exit 1 }
