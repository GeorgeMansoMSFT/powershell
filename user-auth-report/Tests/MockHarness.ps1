<#
.SYNOPSIS
    Helpers shared by Invoke-MockTest.ps1 and Invoke-RegressionTests.ps1: start and
    stop the mock Graph server, run the collector against it, and read its output.
    Dot-source this file; it does not run anything by itself.
#>

$HarnessRoot = Split-Path -Parent $PSScriptRoot
$CollectorPath = Join-Path $HarnessRoot 'Get-EntraAuthMethodReport.ps1'

function Start-MockServer {
    param([int]$Port, [string]$OutDir, [string]$ExpectedPath, [hashtable]$MockArgs = @{})
    $mockScript = Join-Path $PSScriptRoot 'Start-MockGraph.ps1'
    $argList = @('-NoProfile', '-File', "`"$mockScript`"", '-Port', $Port, '-ExpectedPath', "`"$ExpectedPath`"")
    foreach ($k in $MockArgs.Keys) {
        $v = $MockArgs[$k]
        if ($v -is [bool] -or $v -is [switch]) { if ($v) { $argList += "-$k" } }
        elseif ("$v" -ne '') { $argList += "-$k"; $argList += "$v" }
    }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $OutDir 'mock.log') -RedirectStandardError (Join-Path $OutDir 'mock.err.log')
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        try { Invoke-RestMethod -Uri "http://localhost:$Port/ready" -TimeoutSec 5 | Out-Null; return $proc }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    throw "Mock did not start. See mock.log and mock.err.log in $OutDir."
}

function Stop-MockServer {
    # Returns the mock's request counters.
    param([int]$Port, $Process)
    $counts = $null
    try { $counts = Invoke-RestMethod -Uri "http://localhost:$Port/shutdown" -TimeoutSec 10 } catch { }
    Start-Sleep -Milliseconds 500
    if ($Process -and -not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
    return $counts
}

function Invoke-Collector {
    <#
        Runs the collector in a separate PowerShell job. -Endpoint is passed as
        -TestGraphEndpoint; -NoAccessToken omits -AccessToken. Returns the job state,
        its output lines and the terminating error message, if any.
    #>
    param([string]$Endpoint, [string]$OutDir, [hashtable]$CollectorArgs = @{}, [switch]$NoAccessToken,
        [int]$TimeoutMinutes = 20, [switch]$ShowOutput)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock {
        param($collector, $endpoint, $outDir, $extra, $noToken)
        $a = @{ OutputPath = $outDir; ProgressIntervalSeconds = 10 }
        if (-not $noToken) { $a.AccessToken = ConvertTo-SecureString 'test' -AsPlainText -Force }
        if ($endpoint) { $a.TestGraphEndpoint = $endpoint }
        foreach ($k in $extra.Keys) {
            $v = $extra[$k]
            if ($k -eq 'GroupId') { $v = [string[]]@($v) }
            $a[$k] = $v
        }
        & $collector @a *>&1 | ForEach-Object { "$_" }
    } -ArgumentList $CollectorPath, $Endpoint, $OutDir, $CollectorArgs, ($NoAccessToken.IsPresent)
    $lines = New-Object System.Collections.Generic.List[string]
    while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
        foreach ($l in @(Receive-Job $job)) { $lines.Add("$l"); if ($ShowOutput) { Write-Host $l } }
        if ($sw.Elapsed.TotalMinutes -gt $TimeoutMinutes) { Stop-Job $job; break }
        Start-Sleep -Milliseconds 500
    }
    $err = $null
    try { foreach ($l in @(Receive-Job $job -ErrorAction Stop)) { $lines.Add("$l"); if ($ShowOutput) { Write-Host $l } } }
    catch { $err = $_.Exception.Message }
    $reason = $job.ChildJobs[0].JobStateInfo.Reason
    if (-not $err -and $reason) { $err = $reason.Message }
    $state = "$($job.State)"
    Remove-Job $job -Force
    [pscustomobject]@{ State = $state; Error = $err; Output = $lines.ToArray(); Seconds = $sw.Elapsed.TotalSeconds }
}

function Get-RunFiles {
    param([string]$OutDir)
    $f = { param($pattern) Get-ChildItem -LiteralPath $OutDir -Filter $pattern | Select-Object -First 1 }
    $summaryFile = & $f 'RunSummary_*.json'
    [pscustomobject]@{
        Csv     = & $f 'AuthMethods_*.csv'
        Details = & $f 'AuthMethodDetails_*.csv'
        Errors  = & $f 'AuthMethodErrors_*.csv'
        Html    = & $f 'AuthMethodReport_*.html'
        Summary = $(if ($summaryFile) { Get-Content -LiteralPath $summaryFile.FullName -Raw | ConvertFrom-Json } else { $null })
    }
}

function Get-HtmlData {
    # Extracts the META object and ROWS array embedded in the HTML report.
    param([string]$Path)
    $html = Get-Content -LiteralPath $Path -Raw
    $meta = [regex]::Match($html, 'const META = (\{.*?\});\r?\n').Groups[1].Value
    $rows = [regex]::Match($html, 'const ROWS = (\[.*?\]);\r?\n', 'Singleline').Groups[1].Value
    # Windows PowerShell's ConvertFrom-Json emits a JSON array as one object; assigning it
    # to a variable (rather than wrapping the pipeline in @()) avoids nesting it.
    $rowList = $null
    if ($rows) { $rowList = $rows | ConvertFrom-Json }
    [pscustomobject]@{
        Meta = $(if ($meta) { $meta | ConvertFrom-Json } else { $null })
        Rows = $rowList
    }
}

function Reset-OutDir {
    param([string]$OutDir)
    if (Test-Path -LiteralPath $OutDir) { Get-ChildItem -LiteralPath $OutDir -File | Remove-Item -Force }
    else { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
}
