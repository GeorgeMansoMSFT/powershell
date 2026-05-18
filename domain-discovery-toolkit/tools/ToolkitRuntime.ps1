# ToolkitRuntime.ps1
# Local, pinned dependency cache support for the discovery toolkit.

function Get-ToolkitRoot {
    param([string]$ToolkitRoot)

    if ($ToolkitRoot) {
        return (Resolve-Path -LiteralPath $ToolkitRoot).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
}

function Get-ToolkitDependencyLock {
    param([Parameter(Mandatory)] [string]$ToolkitRoot)

    $lockPath = Join-Path $ToolkitRoot "dependencies.lock.json"
    if (-not (Test-Path -LiteralPath $lockPath)) {
        throw "Dependency lock file not found at $lockPath"
    }

    return Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
}

function Get-ToolkitRuntimeModulePath {
    param([Parameter(Mandatory)] [string]$ToolkitRoot)

    $lock = Get-ToolkitDependencyLock -ToolkitRoot $ToolkitRoot
    return Join-Path $ToolkitRoot $lock.moduleRoot
}

function Get-ToolkitPowerShellExe {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }

    $windowsPowerShell = Get-Command powershell -ErrorAction SilentlyContinue
    if ($windowsPowerShell) { return $windowsPowerShell.Source }

    throw "Could not find pwsh.exe or powershell.exe."
}

function Get-ToolkitDependencyEntries {
    param(
        [Parameter(Mandatory)] [object]$Lock,
        [Parameter(Mandatory)] [string[]]$Groups
    )

    $entries = @()
    foreach ($group in $Groups) {
        $groupProp = $Lock.groups.PSObject.Properties[$group]
        if (-not $groupProp) {
            throw "Dependency group '$group' is not defined in dependencies.lock.json"
        }
        $entries += @($groupProp.Value)
    }

    $deduped = @{}
    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $key = "$($entry.name)|$($entry.version)"
        if (-not $deduped.ContainsKey($key)) {
            $deduped[$key] = $entry
            $ordered.Add($entry)
        }
    }

    return $ordered
}

function Test-ToolkitModuleCached {
    param(
        [Parameter(Mandatory)] [string]$ModuleRoot,
        [Parameter(Mandatory)] [object]$Entry
    )

    $manifest = Join-Path $ModuleRoot "$($Entry.name)\$($Entry.version)\$($Entry.name).psd1"
    if (-not (Test-Path -LiteralPath $manifest)) {
        return $false
    }

    try {
        $moduleInfo = Test-ModuleManifest -Path $manifest -ErrorAction Stop
        if ($moduleInfo.Version.ToString() -ne $Entry.version) {
            return $false
        }

        if ($Entry.manifestSha256) {
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifest).Hash
            if ($actualHash -ne $Entry.manifestSha256) {
                throw "Hash mismatch for $($Entry.name) $($Entry.version). Expected $($Entry.manifestSha256), got $actualHash."
            }
        }

        return $true
    } catch {
        throw "Failed to validate $($Entry.name) $($Entry.version): $($_.Exception.Message)"
    }
}

function Test-ToolkitGalleryAccess {
    param([Parameter(Mandatory)] [object]$Entry)

    try {
        if (-not (Get-Command Find-Module -ErrorAction SilentlyContinue)) {
            throw "Find-Module is not available. Install or repair PowerShellGet."
        }

        if ($PSVersionTable.PSEdition -eq "Desktop") {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }

        $null = Find-Module -Name $Entry.name -RequiredVersion $Entry.version -Repository PSGallery -ErrorAction Stop
        return $true
    } catch {
        Write-Host ""
        Write-Host "PowerShell Gallery is not reachable or did not return the locked dependency." -ForegroundColor Red
        Write-Host "Dependency: $($Entry.name) $($Entry.version)" -ForegroundColor Yellow
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Use the offline dependency pack instead:" -ForegroundColor Cyan
        Write-Host "  1. Download domain-migration-toolkit-dependencies.zip from the release page." -ForegroundColor White
        Write-Host "  2. Extract it beside Run-AllDiscovery.ps1 so .runtime\modules exists." -ForegroundColor White
        Write-Host "  3. Re-run .\Run-AllDiscovery.ps1" -ForegroundColor White
        Write-Host ""
        return $false
    }
}

function Set-ToolkitPrivateModulePath {
    param([Parameter(Mandatory)] [string]$ToolkitRoot)

    $moduleRoot = Get-ToolkitRuntimeModulePath -ToolkitRoot $ToolkitRoot
    $paths = @($moduleRoot)

    if ($env:PSModulePath) {
        $paths += ($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ -and $_ -ne $moduleRoot })
    }

    $env:PSModulePath = ($paths -join [IO.Path]::PathSeparator)
}

function Test-ToolkitModuleGroupImport {
    param(
        [Parameter(Mandatory)] [string]$ToolkitRoot,
        [Parameter(Mandatory)] [string]$Group
    )

    $lock = Get-ToolkitDependencyLock -ToolkitRoot $ToolkitRoot
    $entries = Get-ToolkitDependencyEntries -Lock $lock -Groups @($Group)
    $psExe = Get-ToolkitPowerShellExe
    $moduleRoot = Get-ToolkitRuntimeModulePath -ToolkitRoot $ToolkitRoot

    $lines = @(
        '$ErrorActionPreference = "Stop"',
        "`$env:PSModulePath = '$($moduleRoot.Replace("'", "''"))' + [IO.Path]::PathSeparator + `$env:PSModulePath"
    )
    foreach ($entry in $entries) {
        $lines += "Import-Module '$($entry.name)' -RequiredVersion '$($entry.version)' -Force -ErrorAction Stop -WarningAction SilentlyContinue"
    }
    $lines += "'OK'"

    $script = $lines -join "`r`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $output = & $psExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Import validation failed for dependency group '$Group': $($output -join ' ')"
    }
}

function Initialize-ToolkitRuntime {
    param(
        [Parameter(Mandatory)] [string]$ToolkitRoot,
        [Parameter(Mandatory)] [string[]]$Groups,
        [switch]$ForceRefresh,
        [switch]$NoDownload
    )

    $lock = Get-ToolkitDependencyLock -ToolkitRoot $ToolkitRoot
    $moduleRoot = Get-ToolkitRuntimeModulePath -ToolkitRoot $ToolkitRoot
    $entries = @(Get-ToolkitDependencyEntries -Lock $lock -Groups $Groups)

    if (-not (Test-Path -LiteralPath $moduleRoot)) {
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
    }

    Write-Host ""
    Write-Host "Checking toolkit-local PowerShell runtime..." -ForegroundColor Yellow
    Write-Host "  Module cache: $moduleRoot" -ForegroundColor DarkGray
    Write-Host "  Dependency groups: $($Groups -join ', ')" -ForegroundColor DarkGray
    Write-Host "  This does not install modules globally or modify your PowerShell profile." -ForegroundColor DarkGray

    $missing = @()
    foreach ($entry in $entries) {
        if ($ForceRefresh -or -not (Test-ToolkitModuleCached -ModuleRoot $moduleRoot -Entry $entry)) {
            $missing += $entry
        }
    }

    if ($missing.Count -gt 0) {
        if ($NoDownload) {
            throw "Toolkit runtime cache is incomplete and -NoDownload was specified. Extract the offline dependency pack and re-run."
        }

        if (-not (Get-Command Save-Module -ErrorAction SilentlyContinue)) {
            throw "Save-Module is not available. Install or repair PowerShellGet, or use the offline dependency pack."
        }

        if (-not (Test-ToolkitGalleryAccess -Entry $missing[0])) {
            throw "PowerShell Gallery is unavailable. Use the offline dependency pack."
        }

        Write-Host ""
        Write-Host "One-time dependency download required." -ForegroundColor Cyan
        Write-Host "Estimated time: 5-10 minutes on slower networks. Progress is shown per module." -ForegroundColor DarkGray
        Write-Host ""

        $index = 0
        foreach ($entry in $missing) {
            $index++
            Write-Host ("[{0}/{1}] {2} {3} ..." -f $index, $missing.Count, $entry.name, $entry.version) -NoNewline -ForegroundColor Cyan
            try {
                $saveParams = @{
                    Name = $entry.name
                    RequiredVersion = $entry.version
                    Repository = "PSGallery"
                    Path = $moduleRoot
                    Force = $true
                    ErrorAction = "Stop"
                }
                if ((Get-Command Save-Module).Parameters.ContainsKey("AcceptLicense")) {
                    $saveParams["AcceptLicense"] = $true
                }
                Save-Module @saveParams
                $null = Test-ToolkitModuleCached -ModuleRoot $moduleRoot -Entry $entry
                Write-Host " ready" -ForegroundColor Green
            } catch {
                Write-Host " failed" -ForegroundColor Red
                throw "Failed to download or validate $($entry.name) $($entry.version): $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "Toolkit-local runtime cache is ready." -ForegroundColor Green
    }

    Set-ToolkitPrivateModulePath -ToolkitRoot $ToolkitRoot

    foreach ($group in $Groups) {
        Write-Host "Validating dependency group '$group' in a clean PowerShell process..." -ForegroundColor DarkGray
        Test-ToolkitModuleGroupImport -ToolkitRoot $ToolkitRoot -Group $group
    }

    Write-Host "Runtime validation complete." -ForegroundColor Green
    Write-Host ""
}

function Import-ToolkitModuleGroup {
    param(
        [Parameter(Mandatory)] [string]$ToolkitRoot,
        [Parameter(Mandatory)] [string]$Group
    )

    Set-ToolkitPrivateModulePath -ToolkitRoot $ToolkitRoot
    $lock = Get-ToolkitDependencyLock -ToolkitRoot $ToolkitRoot
    $entries = @(Get-ToolkitDependencyEntries -Lock $lock -Groups @($Group))

    foreach ($entry in $entries) {
        Import-Module $entry.name -RequiredVersion $entry.version -Force -ErrorAction Stop -WarningAction SilentlyContinue
    }
}
