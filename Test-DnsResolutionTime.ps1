<#
.SYNOPSIS
    Samples DNS resolution time for a record against a specific DNS server over a
    window, optionally TCP-connect-tests a port on the far server each round, then
    reports min / max / avg / median / percentile statistics.

.DESCRIPTION
    Built to diagnose slow or intermittent DNS resolution (e.g. a reported 6-second
    lookup) against a specific server - typically a domain controller that is
    authoritative for the record and first in the client's DNS server list.

    Diagnostic note: a ~6-second lookup for a record the FIRST server is authoritative
    for is almost never the server being "slow." Authoritative answers come back in
    single-digit milliseconds. Multi-second times are the Windows DNS client timeout/
    retry pattern - the first query gets no usable answer, the client waits out its
    timeout, then a retry (to the same or the next server) succeeds. Common causes:
    the DC drops/ignores the first UDP query, answers from an interface the client
    can't route back to, or has to recurse to a dead forwarder for that name.

    Use -CompareDefault to ALSO sample through the normal OS resolver (no -Server) each
    round. If the targeted -DnsServer query is fast but the default path is slow, the
    problem is in the client's resolver behavior / server ordering / a timing-out first
    server - not the DC you're pointing at.

    Use -Port to ALSO run a timed TCP connect against the far server each round. The
    connect test distinguishes three states by how it fails:
      - open      -> handshake completed, connect time recorded
      - refused   -> RST came back fast (service down / not listening)
      - timeout   -> SYN silently dropped after -PortTimeoutMs (firewall/routing)
    By default the port is tested against the IP the record just resolved to (falling
    back to -DnsServer), so a bad/stale DNS answer shows up as a port failure too.
    Override with -PortTarget to always hit a fixed host.

.PARAMETER Name
    The DNS record / FQDN to resolve (e.g. app.contoso.com). Pass the host name, not a
    full URL.

.PARAMETER DnsServer
    The specific DNS server to query (IP or name) - e.g. the DC's IP.

.PARAMETER DurationMinutes
    Total sampling window. Default 5.

.PARAMETER IntervalSeconds
    Delay between samples. Default 3.

.PARAMETER QueryType
    Record type. Default A.

.PARAMETER ClearCache
    Clear the local DNS client cache before each sample to force a fresh query.
    Mainly useful for the -CompareDefault path (an explicit -Server query normally
    goes over the wire anyway). Requires an elevated session.

.PARAMETER CompareDefault
    Also issue each sample through the default OS resolver (no -Server) for comparison.

.PARAMETER Port
    TCP port to connect-test on the far server each round (e.g. 57000). 0 = disabled.

.PARAMETER PortTarget
    Host/IP to run the port test against. If omitted, uses the address the record
    resolved to that round, falling back to -DnsServer.

.PARAMETER PortTimeoutMs
    Max wait for the TCP handshake before calling it a timeout. Default 3000.

.PARAMETER SlowThresholdMs
    DNS samples at or above this elapsed time are flagged as SLOW. Default 1000.

.PARAMETER CsvPath
    Optional path to export every raw sample as CSV.

.EXAMPLE
    .\Test-DnsResolutionTime.ps1 -Name app.contoso.com -DnsServer 10.0.0.10 `
        -Port 57000 -DurationMinutes 5 -IntervalSeconds 3 -CompareDefault `
        -CsvPath .\dns-samples.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$DnsServer,
    [int]$DurationMinutes = 5,
    [int]$IntervalSeconds = 3,
    [string]$QueryType     = 'A',
    [switch]$ClearCache,
    [switch]$CompareDefault,
    [int]$Port            = 0,
    [string]$PortTarget   = '',
    [int]$PortTimeoutMs   = 3000,
    [int]$SlowThresholdMs = 1000,
    [string]$CsvPath
)

function Invoke-TimedResolve {
    param(
        [string]$Name,
        [string]$Type,
        [string]$Server   # empty string = use default OS resolver
    )

    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $ok   = $true
    $err  = $null
    $addr = ''

    try {
        $params = @{
            Name        = $Name
            Type        = $Type
            DnsOnly     = $true   # no LLMNR/NetBIOS fallback muddying the timing
            ErrorAction = 'Stop'
        }
        if ($Server) { $params['Server'] = $Server }

        $result = Resolve-DnsName @params
        $addr = (($result | Where-Object { $_.IPAddress } |
                  Select-Object -ExpandProperty IPAddress) -join ';')
    }
    catch {
        $ok  = $false
        $err = $_.Exception.Message
    }
    finally {
        $sw.Stop()
    }

    [pscustomobject]@{
        ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        Success   = $ok
        Addresses = $addr
        Error     = $err
    }
}

function Test-TcpPort {
    param(
        [string]$Target,
        [int]$Port,
        [int]$TimeoutMs = 3000
    )

    $sw     = [System.Diagnostics.Stopwatch]::StartNew()
    $client = New-Object System.Net.Sockets.TcpClient
    $ok     = $false
    $err    = $null

    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.EndConnect($iar)   # throws on RST / refused
            $ok = $true
        }
        else {
            $err = "timeout after $TimeoutMs ms (SYN dropped / filtered)"
        }
    }
    catch {
        $err = $_.Exception.Message   # e.g. connection refused
    }
    finally {
        $sw.Stop()
        $client.Close()
    }

    [pscustomobject]@{
        ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        Success   = $ok
        Error     = $err
    }
}

function Get-Stats {
    param([double[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) { return $null }

    $sorted = @($Values | Sort-Object)
    $n      = $sorted.Count

    $pct = {
        param($p)
        if ($n -eq 1) { return $sorted[0] }
        $rank = ($p / 100.0) * ($n - 1)
        $low  = [math]::Floor($rank)
        $high = [math]::Ceiling($rank)
        $frac = $rank - $low
        $sorted[$low] + (($sorted[$high] - $sorted[$low]) * $frac)
    }

    $avg = ($sorted | Measure-Object -Average).Average
    $var = (($sorted | ForEach-Object { [math]::Pow($_ - $avg, 2) } |
             Measure-Object -Sum).Sum) / $n

    [pscustomobject]@{
        Count   = $n
        Min     = [math]::Round($sorted[0], 2)
        Max     = [math]::Round($sorted[-1], 2)
        Average = [math]::Round($avg, 2)
        Median  = [math]::Round((& $pct 50), 2)
        P95     = [math]::Round((& $pct 95), 2)
        P99     = [math]::Round((& $pct 99), 2)
        StdDev  = [math]::Round([math]::Sqrt($var), 2)
    }
}

# ---------------------------------------------------------------------------

$endTime = (Get-Date).AddMinutes($DurationMinutes)
$samples = New-Object System.Collections.Generic.List[object]
$i = 0

Write-Host ("Sampling '{0}' ({1}) against {2}" -f $Name, $QueryType, $DnsServer) -ForegroundColor Cyan
Write-Host ("Window: {0} min, every {1} s  (until {2})" -f $DurationMinutes, $IntervalSeconds, $endTime) -ForegroundColor Cyan
if ($CompareDefault) { Write-Host "Also sampling via the default OS resolver for comparison." -ForegroundColor Cyan }
if ($Port -gt 0)     { Write-Host ("Also TCP connect-testing port {0} on the far server." -f $Port) -ForegroundColor Cyan }
Write-Host ""

while ((Get-Date) -lt $endTime) {
    $i++

    if ($ClearCache) { Clear-DnsClientCache }
    $targeted = Invoke-TimedResolve -Name $Name -Type $QueryType -Server $DnsServer

    $default = $null
    if ($CompareDefault) {
        if ($ClearCache) { Clear-DnsClientCache }
        $default = Invoke-TimedResolve -Name $Name -Type $QueryType -Server ''
    }

    $defElapsed = $null; $defSuccess = $null; $defAddr = $null; $defErr = $null
    if ($default) {
        $defElapsed = $default.ElapsedMs
        $defSuccess = $default.Success
        $defAddr    = $default.Addresses
        $defErr     = $default.Error
    }

    # --- decide port target: explicit override, else resolved IP, else DnsServer
    $portRes = $null
    $portTargetResolved = $null
    if ($Port -gt 0) {
        $portTargetResolved = $PortTarget
        if (-not $portTargetResolved) {
            if ($targeted.Success -and $targeted.Addresses) {
                $addrs = $targeted.Addresses -split ';'
                $v4 = $addrs | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1
                $portTargetResolved = if ($v4) { $v4 } else { $addrs[0] }
            }
            if (-not $portTargetResolved) { $portTargetResolved = $DnsServer }
        }
        $portRes = Test-TcpPort -Target $portTargetResolved -Port $Port -TimeoutMs $PortTimeoutMs
    }

    $portTgt = $null; $portElapsed = $null; $portSuccess = $null; $portErr = $null
    if ($portRes) {
        $portTgt     = $portTargetResolved
        $portElapsed = $portRes.ElapsedMs
        $portSuccess = $portRes.Success
        $portErr     = $portRes.Error
    }

    $row = [pscustomobject]@{
        Sample           = $i
        Timestamp        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        TargetServer     = $DnsServer
        TargetElapsedMs  = $targeted.ElapsedMs
        TargetSuccess    = $targeted.Success
        TargetAddresses  = $targeted.Addresses
        TargetError      = $targeted.Error
        DefaultElapsedMs = $defElapsed
        DefaultSuccess   = $defSuccess
        DefaultAddresses = $defAddr
        DefaultError     = $defErr
        PortTarget       = $portTgt
        PortNumber       = $(if ($Port -gt 0) { $Port } else { $null })
        PortElapsedMs    = $portElapsed
        PortSuccess      = $portSuccess
        PortError        = $portErr
    }
    $samples.Add($row)

    # live feedback
    $flag = ''
    if (-not $targeted.Success)                       { $flag = ' [FAILED]' }
    elseif ($targeted.ElapsedMs -ge $SlowThresholdMs) { $flag = ' [SLOW]' }

    $line = "#{0,-4} dns={1,8} ms{2}" -f $i, $targeted.ElapsedMs, $flag
    if ($CompareDefault -and $default) { $line += ("   default={0,8} ms" -f $default.ElapsedMs) }
    if ($portRes) {
        $pflag = if ($portRes.Success) { 'open' } else { 'FAIL' }
        $line += ("   port{0}={1} ({2} ms)" -f $Port, $pflag, $portRes.ElapsedMs)
    }

    $color = 'Gray'
    if (-not $targeted.Success)                       { $color = 'Red' }
    elseif ($portRes -and -not $portRes.Success)      { $color = 'Yellow' }
    elseif ($targeted.ElapsedMs -ge $SlowThresholdMs) { $color = 'Yellow' }
    Write-Host $line -ForegroundColor $color

    Start-Sleep -Seconds $IntervalSeconds
}

# ---------------------------------------------------------------------------
# Report

Write-Host "`n===== DNS Resolution Report =====" -ForegroundColor Green

$targetTimes = @($samples | Where-Object TargetSuccess | Select-Object -ExpandProperty TargetElapsedMs)
$targetStats = Get-Stats -Values ([double[]]$targetTimes)
$targetFail  = @($samples | Where-Object { -not $_.TargetSuccess }).Count

Write-Host ("Record        : {0} ({1})" -f $Name, $QueryType)
Write-Host ("Target server : {0}" -f $DnsServer)
Write-Host ("Samples       : {0}" -f $samples.Count)
Write-Host ("Failures      : {0}" -f $targetFail)

$distinct = @($samples | Where-Object TargetSuccess |
             Select-Object -ExpandProperty TargetAddresses | Sort-Object -Unique)
Write-Host ("Answers seen  : {0}" -f (($distinct | Where-Object { $_ }) -join '  |  '))

if ($targetStats) {
    Write-Host "`n-- Targeted server timings (ms) --" -ForegroundColor Green
    $targetStats | Format-List
}
else {
    Write-Host "`nNo successful targeted samples to summarize." -ForegroundColor Red
}

$problem = @($samples | Where-Object { -not $_.TargetSuccess -or $_.TargetElapsedMs -ge $SlowThresholdMs })
if ($problem.Count -gt 0) {
    Write-Host ("-- Slow / failed DNS samples (>= {0} ms or error) --" -f $SlowThresholdMs) -ForegroundColor Yellow
    $problem | Format-Table Sample, Timestamp, TargetElapsedMs, TargetSuccess, TargetAddresses, TargetError -AutoSize
}

if ($CompareDefault) {
    $defTimes = @($samples | Where-Object DefaultSuccess | Select-Object -ExpandProperty DefaultElapsedMs)
    $defStats = Get-Stats -Values ([double[]]$defTimes)
    $defFail  = @($samples | Where-Object { $_.DefaultSuccess -eq $false }).Count

    Write-Host "-- Default resolver timings (ms) --" -ForegroundColor Green
    Write-Host ("Failures      : {0}" -f $defFail)
    if ($defStats) { $defStats | Format-List }
    else { Write-Host "No successful default-resolver samples to summarize." -ForegroundColor Red }
}

if ($Port -gt 0) {
    $portTimes = @($samples | Where-Object PortSuccess | Select-Object -ExpandProperty PortElapsedMs)
    $portStats = Get-Stats -Values ([double[]]$portTimes)
    $portFail  = @($samples | Where-Object { $_.PortSuccess -eq $false }).Count

    Write-Host ("-- TCP connect to port {0} (ms) --" -f $Port) -ForegroundColor Green
    Write-Host ("Failures      : {0}" -f $portFail)
    if ($portStats) { $portStats | Format-List }
    else { Write-Host "No successful port connects to summarize." -ForegroundColor Red }

    $portProblem = @($samples | Where-Object { $_.PortSuccess -eq $false })
    if ($portProblem.Count -gt 0) {
        Write-Host "-- Port connect failures --" -ForegroundColor Yellow
        $portProblem | Format-Table Sample, Timestamp, PortTarget, PortElapsedMs, PortError -AutoSize
    }
}

if ($CsvPath) {
    $samples | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host ("Raw samples exported to {0}" -f $CsvPath) -ForegroundColor Cyan
}
