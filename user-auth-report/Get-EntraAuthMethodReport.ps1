#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a per-user authentication methods report for an entire Entra ID tenant,
    using Microsoft Graph JSON batching with adaptive concurrency.

.DESCRIPTION
    Alternative to the Entra "User registration details" report
    (/reports/authenticationMethods/userRegistrationDetails). The data is read
    directly from each user's authentication methods
    (/users/{id}/authentication/methods), the same source of truth that the
    user's "Security info" page and the Entra admin center user blade use.

    Why it is faster than a per-user Get-MgUserAuthenticationMethod loop:
      * 20 users are requested per HTTP call (Graph JSON $batch).
      * Several batches are kept in flight at the same time.
      * Throttling (HTTP 429) is handled per user: only the throttled users are
        retried after the Retry-After interval, and concurrency is reduced
        automatically, then increased again when Graph stops throttling.

    Outputs (written to -OutputPath):
      * AuthMethods_<timestamp>.csv        one row per user
      * AuthMethodDetails_<timestamp>.csv  one row per registered method
      * AuthMethodReport_<timestamp>.html  self-contained, searchable viewer
      * AuthMethodErrors_<timestamp>.csv   only if some users could not be read
      * RunSummary_<timestamp>.json        run statistics

.PARAMETER TenantId
    Tenant ID or domain. Optional for interactive sign-in, required for -ClientId.

.PARAMETER ManagedIdentity
    Sign in with a managed identity (e.g. Azure Automation account).

.PARAMETER ManagedIdentityClientId
    Client ID of a user-assigned managed identity. Omit for system-assigned.

.PARAMETER ClientId
    App registration client ID (app-only sign-in with a certificate).

.PARAMETER CertificateThumbprint
    Thumbprint of the certificate in the CurrentUser\My or LocalMachine\My store.

.PARAMETER AccessToken
    A pre-acquired Graph access token. It cannot be refreshed, so the run must
    finish before it expires.

.PARAMETER UserFilter
    Optional OData $filter that limits which users are read, for example:
      "employeeType eq 'Employee'"
      "department in ('Sales','Finance')"
      "accountEnabled eq true and userType eq 'Member'"
      "onPremisesExtensionAttributes/extensionAttribute1 eq 'PasskeyWave1'"
    It is sent as a Graph advanced query (ConsistencyLevel: eventual), so any
    property and operator that /users supports with advanced queries can be
    used. Users created or changed in the last few minutes may not match yet.
    Can be combined with -GroupId.

.PARAMETER GroupId
    Object ID of one or more groups. Only users who are members of at least one
    of these groups, directly or through nested groups, are read. Use a dynamic
    group to scope by any attribute. Requires GroupMember.Read.All.

.PARAMETER CompareWithReport
    Also downloads the native User registration details report and flags users
    whose data differs (missing from the report, or a passkey that the report
    does not show). Requires AuditLog.Read.All.

.PARAMETER MaxConcurrency
    Maximum number of $batch requests in flight. The script starts lower and
    adjusts automatically. Default 8 (up to 160 users in flight).

.PARAMETER MaxRetries
    Retries per user for errors other than throttling (5xx, transport errors).
    Throttled (HTTP 429) requests are always retried after Retry-After, up to
    max(100, MaxRetries) times, because throttling is expected at large scale.

.PARAMETER MaxUsersPerSecond
    Optional ceiling on the read rate, to leave Graph capacity for other apps in
    the tenant. 0 (default) means no ceiling; the rate is then governed only by
    Graph's throttling responses.

.PARAMETER IncludeContactDetails
    Include phone numbers and email addresses of phone/email methods in the
    detail CSV. Off by default to keep the output free of contact data.

.EXAMPLE
    .\Get-EntraAuthMethodReport.ps1 -TenantId contoso.onmicrosoft.com

.EXAMPLE
    .\Get-EntraAuthMethodReport.ps1 -ManagedIdentity -CompareWithReport -OutputPath $env:TEMP

.EXAMPLE
    .\Get-EntraAuthMethodReport.ps1 -TenantId <tenantId> -ClientId <appId> -CertificateThumbprint <thumbprint> -UserFilter "accountEnabled eq true"

.EXAMPLE
    .\Get-EntraAuthMethodReport.ps1 -GroupId <passkeyPilotGroupId> -UserFilter "employeeType eq 'Employee'" -CompareWithReport
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'AppCertificate', Mandatory = $true)]
    [string]$TenantId,

    [Parameter(ParameterSetName = 'ManagedIdentity', Mandatory = $true)]
    [switch]$ManagedIdentity,

    [Parameter(ParameterSetName = 'ManagedIdentity')]
    [string]$ManagedIdentityClientId,

    [Parameter(ParameterSetName = 'AppCertificate', Mandatory = $true)]
    [string]$ClientId,

    [Parameter(ParameterSetName = 'AppCertificate', Mandatory = $true)]
    [string]$CertificateThumbprint,

    [Parameter(ParameterSetName = 'AccessToken', Mandatory = $true)]
    [securestring]$AccessToken,

    [string]$OutputPath = (Join-Path -Path (Get-Location).Path -ChildPath 'AuthMethodReport'),

    [string]$UserFilter,

    [guid[]]$GroupId,

    [switch]$CompareWithReport,

    [ValidateRange(1, 32)]
    [int]$MaxConcurrency = 8,

    [ValidateRange(1, 20)]
    [int]$BatchSize = 20,

    [ValidateRange(1, 50)]
    [int]$MaxRetries = 12,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxUsers = 0,

    [ValidateRange(0, 10000)]
    [int]$MaxUsersPerSecond = 0,

    [ValidateSet('v1.0', 'beta')]
    [string]$ApiVersion = 'v1.0',

    [string]$GraphEndpoint = 'https://graph.microsoft.com',

    [switch]$IncludeContactDetails,

    [switch]$NoHtml,

    [ValidateRange(5, 600)]
    [int]$ProgressIntervalSeconds = 15
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$IsAutomation = $false
try { $IsAutomation = [bool]$PSPrivateMetadata.JobId } catch { $IsAutomation = $false }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($IsAutomation) { Write-Output $line }
    elseif ($Level -eq 'WARN') { Write-Warning $Message }
    else { Write-Host $line }
}

#region HTTP / auth plumbing ---------------------------------------------------

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web
if ($PSVersionTable.PSEdition -ne 'Core') {
    # .NET Framework defaults: 2 connections per host and possibly no TLS 1.2.
    [System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max(64, [System.Net.ServicePointManager]::DefaultConnectionLimit)
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}

$GraphEndpoint = $GraphEndpoint.TrimEnd('/')
$BaseUri = "$GraphEndpoint/$ApiVersion"
$AuthMode = $PSCmdlet.ParameterSetName
$TokenRefreshMinutes = 40

$state = @{
    Token          = $null
    TokenAcquired  = [datetime]::MinValue
    TenantId       = $TenantId
    Account        = $null
}

function Connect-GraphSdk {
    $module = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
        Where-Object { $_.Version -ge [version]'2.0.0' } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) {
        throw 'Microsoft.Graph.Authentication 2.x is required. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module $module -ErrorAction Stop

    switch ($AuthMode) {
        'Interactive' {
            $scopes = @('User.Read.All', 'UserAuthenticationMethod.Read.All')
            if ($CompareWithReport) { $scopes += 'AuditLog.Read.All' }
            if ($GroupId) { $scopes += 'GroupMember.Read.All' }
            $p = @{ Scopes = $scopes; NoWelcome = $true }
            if ($TenantId) { $p.TenantId = $TenantId }
            Connect-MgGraph @p | Out-Null
        }
        'ManagedIdentity' {
            $p = @{ Identity = $true; NoWelcome = $true }
            if ($ManagedIdentityClientId) { $p.ClientId = $ManagedIdentityClientId }
            Connect-MgGraph @p | Out-Null
        }
        'AppCertificate' {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome | Out-Null
        }
    }
    $ctx = Get-MgContext
    $state.TenantId = $ctx.TenantId
    $state.Account = if ($ctx.Account) { $ctx.Account } else { $ctx.ClientId }
}

function Update-Token {
    if ($AuthMode -eq 'AccessToken') {
        if (-not $state.Token) {
            $state.Token = [System.Net.NetworkCredential]::new('', $AccessToken).Password
            $state.TokenAcquired = [datetime]::UtcNow
            return $true
        }
        return $false
    }
    # The Graph SDK owns token acquisition and refresh; borrow its current token
    # so batches can be sent concurrently with a plain HttpClient.
    $resp = Invoke-MgGraphRequest -Method GET -Uri "$GraphEndpoint/v1.0/users?`$top=1&`$select=id" -OutputType HttpResponseMessage
    try {
        $token = $resp.RequestMessage.Headers.Authorization.Parameter
    }
    finally { $resp.Dispose() }
    if (-not $token) { throw 'Could not obtain an access token from the Microsoft Graph SDK session.' }
    $state.Token = $token
    $state.TokenAcquired = [datetime]::UtcNow
    return $true
}

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(180)

function New-GraphRequest {
    param([string]$Method, [string]$Uri, [string]$JsonBody)
    $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), $Uri)
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $state.Token)
    $req.Headers.Add('client-request-id', [guid]::NewGuid().ToString())
    if ($JsonBody) {
        $req.Content = New-Object System.Net.Http.StringContent($JsonBody, [System.Text.Encoding]::UTF8, 'application/json')
    }
    return $req
}

function Get-RetryAfterSeconds {
    param($Response, [int]$Attempt)
    $ra = $null
    if ($Response -and $Response.Headers.RetryAfter) {
        if ($Response.Headers.RetryAfter.Delta) { $ra = [int][Math]::Ceiling($Response.Headers.RetryAfter.Delta.TotalSeconds) }
        elseif ($Response.Headers.RetryAfter.Date) { $ra = [int][Math]::Ceiling(($Response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
    }
    if (-not $ra -or $ra -lt 1) { $ra = [int][Math]::Min(60, [Math]::Pow(2, [Math]::Min($Attempt, 6))) }
    return $ra
}

function Invoke-GraphGet {
    # Synchronous GET with retry, used for paging /users and the native report.
    # -AdvancedQuery adds the header Graph requires for advanced $filter/$count queries.
    param([string]$Uri, [switch]$AdvancedQuery)
    $throttled = 0
    $maxThrottled = [Math]::Max(100, $MaxRetries)
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if (([datetime]::UtcNow - $state.TokenAcquired).TotalMinutes -gt $TokenRefreshMinutes) { [void](Update-Token) }
        $req = New-GraphRequest -Method GET -Uri $Uri
        if ($AdvancedQuery) { $req.Headers.Add('ConsistencyLevel', 'eventual') }
        $resp = $null
        try {
            try {
                $resp = $client.SendAsync($req).GetAwaiter().GetResult()
                $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            catch {
                if ($attempt -ge $MaxRetries) { throw }
                Write-Log "Transport error: $($_.Exception.GetBaseException().Message). Retrying." 'WARN'
                $script:stats.TransportErrors++
                Start-Sleep -Seconds ([Math]::Min(60, [Math]::Pow(2, $attempt)))
                continue
            }
            $code = [int]$resp.StatusCode
            if ($code -eq 200) { return ($text | ConvertFrom-Json) }
            if ($code -eq 401 -and $attempt -lt $MaxRetries -and (Update-Token)) { continue }
            if ($code -eq 429 -or $code -ge 500) {
                $wait = Get-RetryAfterSeconds -Response $resp -Attempt $attempt
                $script:stats.ThrottledPages++
                Write-Log "GET returned $code, retrying in $wait s ($Uri)"
                Start-Sleep -Seconds $wait
                # Throttling does not use up the error-retry budget.
                if ($code -eq 429 -and ++$throttled -le $maxThrottled) { $attempt-- }
                continue
            }
            throw "GET $Uri failed with HTTP $code. $text"
        }
        finally {
            if ($resp) { $resp.Dispose() }
            $req.Dispose()
        }
    }
    throw "GET $Uri failed after $MaxRetries attempts."
}

#endregion

#region Method classification --------------------------------------------------

# AAGUIDs of passkeys stored in Microsoft Authenticator (iOS, Android).
$AuthenticatorAaGuids = @('90a3ccdf-635c-4729-a248-9b709135078f', 'de1e552d-db1d-4423-a619-566b625cdc84')

$MethodCatalog = [ordered]@{
    password                = 'Password'
    microsoftAuthenticator  = 'Microsoft Authenticator'
    passkey                 = 'Passkey (any FIDO2)'
    passkeyAuthenticator    = 'Passkey in Authenticator'
    passkeyOther            = 'Passkey (security key / other)'
    windowsHelloForBusiness = 'Windows Hello for Business'
    platformCredential      = 'Platform Credential (macOS)'
    mobilePhone             = 'Mobile phone'
    alternateMobilePhone    = 'Alternate mobile phone'
    officePhone             = 'Office phone'
    softwareOath            = 'Software OATH token'
    hardwareOath            = 'Hardware OATH token'
    temporaryAccessPass     = 'Temporary Access Pass'
    email                   = 'Email'
    qrCodePin               = 'QR code PIN'
}
$MfaKeys = @('microsoftAuthenticator', 'passkey', 'windowsHelloForBusiness', 'platformCredential', 'mobilePhone',
             'alternateMobilePhone', 'officePhone', 'softwareOath', 'hardwareOath')
$PhishResistantKeys = @('passkey', 'windowsHelloForBusiness', 'platformCredential')

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Format-Date {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    return [string]$Value
}

#endregion

#region HTML viewer template ---------------------------------------------------
$HtmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Authentication methods report</title>
<style>
  :root { --bg:#f5f6f8; --card:#fff; --text:#1b1f24; --muted:#5f6b7a; --line:#dde1e6; --accent:#0f6cbd; --good:#107c10; --warn:#c25e00; --bad:#c50f1f; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:"Segoe UI", system-ui, -apple-system, sans-serif; background:var(--bg); color:var(--text); font-size:14px; }
  header { background:#1b1f24; color:#fff; padding:16px 24px; }
  header h1 { margin:0; font-size:20px; font-weight:600; }
  header .sub { color:#c8ced6; font-size:12px; margin-top:4px; }
  main { padding:16px 24px 40px; }
  .cards { display:grid; grid-template-columns:repeat(auto-fill,minmax(170px,1fr)); gap:12px; margin-bottom:16px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:12px 14px; }
  .card .label { color:var(--muted); font-size:12px; }
  .card .value { font-size:22px; font-weight:600; margin-top:2px; }
  .card .pct { color:var(--muted); font-size:12px; }
  .panel { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:12px 14px; margin-bottom:16px; }
  .panel h2 { font-size:14px; margin:0 0 10px; }
  .bars { display:grid; grid-template-columns:minmax(180px,240px) 1fr 110px; gap:6px 10px; align-items:center; }
  .bars .name { cursor:pointer; color:var(--accent); }
  .bars .name:hover { text-decoration:underline; }
  .bar { height:14px; background:#e7ecf2; border-radius:3px; overflow:hidden; }
  .bar span { display:block; height:100%; background:var(--accent); }
  .bars .num { text-align:right; color:var(--muted); font-variant-numeric:tabular-nums; }
  .filters { display:flex; flex-wrap:wrap; gap:10px; align-items:flex-end; }
  .filters label { display:flex; flex-direction:column; font-size:12px; color:var(--muted); gap:3px; }
  .filters input[type=search] { width:280px; }
  .filters input, .filters select, button { font:inherit; padding:5px 8px; border:1px solid var(--line); border-radius:4px; background:#fff; }
  .filters .check { flex-direction:row; align-items:center; gap:6px; color:var(--text); font-size:13px; padding-bottom:6px; }
  button { cursor:pointer; }
  button.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
  table { width:100%; border-collapse:collapse; background:var(--card); }
  th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); vertical-align:top; }
  th { position:sticky; top:0; background:#eef1f5; cursor:pointer; user-select:none; white-space:nowrap; font-weight:600; font-size:12px; }
  th.sorted::after { content:" \25B2"; font-size:10px; }
  th.sorted.desc::after { content:" \25BC"; }
  tr:hover td { background:#f8fafc; }
  .chip { display:inline-block; padding:1px 7px; margin:1px 3px 1px 0; border-radius:10px; background:#e8eef6; font-size:11px; white-space:nowrap; }
  .chip.pr { background:#dff6dd; color:#0b5a08; }
  .chip.weak { background:#fdf0e2; color:#7a3b00; }
  .chip.pw { background:#eceff3; color:#5f6b7a; }
  .muted { color:var(--muted); }
  .bad { color:var(--bad); }
  .warn { color:var(--warn); }
  .pager { display:flex; align-items:center; gap:8px; margin:10px 0; color:var(--muted); }
  .tablewrap { max-height:70vh; overflow:auto; border:1px solid var(--line); border-radius:8px; }
  .note { font-size:12px; color:var(--muted); margin-top:8px; }
</style>
</head>
<body>
<header>
  <h1>Authentication methods report</h1>
  <div class="sub" id="subtitle"></div>
</header>
<main>
  <div class="cards" id="cards"></div>
  <div class="panel">
    <h2>Registered methods <span class="muted" style="font-weight:400">(current filter; click a method to filter by it)</span></h2>
    <div class="bars" id="bars"></div>
  </div>
  <div class="panel">
    <div class="filters">
      <label>Search UPN or name<input type="search" id="q" placeholder="e.g. jane or @contoso.com"></label>
      <label>Account<select id="fEnabled"><option value="">All</option><option value="1" selected>Enabled</option><option value="0">Disabled</option></select></label>
      <label>User type<select id="fType"><option value="">All</option><option>Member</option><option>Guest</option></select></label>
      <label>Has<select id="fHas"></select></label>
      <label>Does not have<select id="fLacks"></select></label>
      <label class="check" id="discWrap"><input type="checkbox" id="fDisc"> Discrepancies only</label>
      <label class="check"><input type="checkbox" id="fErr"> Read errors only</label>
      <button id="reset">Reset</button>
      <button class="primary" id="export">Export filtered CSV</button>
    </div>
    <div class="note">Source: Microsoft Graph <code>/users/{id}/authentication/methods</code>, read for every user at the time shown above. "MFA capable" and "phishing-resistant" are derived from registered methods only and don't take policy (for example, disabled methods) into account.</div>
  </div>
  <div class="pager" id="pagerTop"></div>
  <div class="tablewrap"><table id="tbl"><thead><tr id="head"></tr></thead><tbody id="body"></tbody></table></div>
  <div class="pager" id="pagerBottom"></div>
</main>
<script>
const META = /*__META__*/;
const ROWS = [/*__ROWS__*/];
const C = { upn:0, name:1, enabled:2, type:3, keys:4, pkModels:5, pkNewest:6, status:7, disc:8, native:9, err:10, devices:11 };
const LABELS = {}; META.catalog.forEach(c => LABELS[c[0]] = c[1]);
const PR = new Set(META.prKeys), MFA = new Set(META.mfaKeys);
const WEAK = new Set(["mobilePhone","alternateMobilePhone","officePhone","email"]);
const HIDDEN_CHIPS = new Set(["passkey"]);
ROWS.forEach(r => { r.set = new Set(r[C.keys]); r.mfa = r[C.keys].some(k => MFA.has(k)); r.pr = r[C.keys].some(k => PR.has(k)); r.lc = (r[C.upn] + " " + r[C.name]).toLowerCase(); });

const $ = id => document.getElementById(id);
const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const fmt = n => n.toLocaleString();
const pct = (n, d) => d ? (100 * n / d).toFixed(1) + "%" : "-";

$("subtitle").textContent = "Tenant " + META.tenant + " | generated " + META.generated + " | " + fmt(ROWS.length) + " users | collection took " + Math.round(META.durationSeconds / 60) + " min" + (META.scope && META.scope !== "All users" ? " | scope: " + META.scope : "");
if (!META.compare) $("discWrap").style.display = "none";

const special = [["__mfa","MFA capable (any)"],["__pr","Phishing-resistant (any)"],["__nomfa","No MFA method"]];
function fillSelect(sel) {
  let h = '<option value="">(any)</option>';
  special.forEach(s => h += '<option value="' + s[0] + '">' + esc(s[1]) + '</option>');
  META.catalog.forEach(c => h += '<option value="' + c[0] + '">' + esc(c[1]) + '</option>');
  sel.innerHTML = h;
}
fillSelect($("fHas")); fillSelect($("fLacks"));
$("fLacks").querySelector('option[value="__nomfa"]').remove();

function matchKey(r, k) {
  if (k === "__mfa") return r.mfa;
  if (k === "__pr") return r.pr;
  if (k === "__nomfa") return !r.mfa && r[C.status] === "OK";
  return r.set.has(k);
}

const cols = [
  { t:"User principal name", v:r => r[C.upn] },
  { t:"Display name", v:r => r[C.name] },
  { t:"Enabled", v:r => r[C.enabled] },
  { t:"Type", v:r => r[C.type] },
  { t:"Registered methods", v:r => r[C.keys].filter(k => k !== "password").length },
  { t:"Passkeys", v:r => r[C.pkModels] },
  { t:"Newest passkey", v:r => r[C.pkNewest] },
];
if (META.compare) {
  cols.push({ t:"Native report methods", v:r => r[C.native] });
  cols.push({ t:"Discrepancy", v:r => r[C.disc] });
}
let sortCol = 0, sortDesc = false, page = 0, view = ROWS;
const PAGE = 100;

function renderHead() {
  $("head").innerHTML = cols.map((c, i) => '<th data-i="' + i + '" class="' + (i === sortCol ? "sorted" + (sortDesc ? " desc" : "") : "") + '">' + esc(c.t) + '</th>').join("");
  $("head").querySelectorAll("th").forEach(th => th.onclick = () => {
    const i = +th.dataset.i; if (i === sortCol) sortDesc = !sortDesc; else { sortCol = i; sortDesc = false; }
    apply(false);
  });
}

function chips(r) {
  if (r[C.status] !== "OK") return '<span class="bad">Read error: ' + esc(r[C.err]) + '</span>';
  const ks = r[C.keys].filter(k => !HIDDEN_CHIPS.has(k));
  if (!ks.length) return '<span class="muted">none</span>';
  return ks.map(k => '<span class="chip ' + (k === "password" ? "pw" : PR.has(k) || k.startsWith("passkey") ? "pr" : WEAK.has(k) ? "weak" : "") + '">' + esc(LABELS[k] || k) + '</span>').join("");
}

function renderRow(r) {
  let h = '<td>' + esc(r[C.upn]) + '</td><td>' + esc(r[C.name]) + '</td><td>' + (r[C.enabled] ? "Yes" : '<span class="muted">No</span>') + '</td><td>' + esc(r[C.type]) + '</td>';
  h += '<td' + (r[C.devices] ? ' title="Authenticator devices: ' + esc(r[C.devices]) + '"' : "") + '>' + chips(r) + '</td>';
  h += '<td>' + esc(r[C.pkModels]) + '</td><td class="muted">' + esc(r[C.pkNewest]) + '</td>';
  if (META.compare) h += '<td class="muted">' + esc(r[C.native]) + '</td><td class="warn">' + esc(r[C.disc]) + '</td>';
  return '<tr>' + h + '</tr>';
}

function renderCards() {
  const ok = view.filter(r => r[C.status] === "OK");
  const n = ok.length;
  const c = (label, value, sub) => '<div class="card"><div class="label">' + esc(label) + '</div><div class="value">' + value + '</div><div class="pct">' + (sub || "&nbsp;") + '</div></div>';
  let h = c("Users in view", fmt(view.length), fmt(ROWS.length) + " in report");
  const mfa = ok.filter(r => r.mfa).length, pr = ok.filter(r => r.pr).length, pk = ok.filter(r => r.set.has("passkey")).length;
  h += c("MFA capable", fmt(mfa), pct(mfa, n));
  h += c("Phishing-resistant", fmt(pr), pct(pr, n));
  h += c("Passkey registered", fmt(pk), pct(pk, n));
  h += c("No MFA method", fmt(n - mfa), pct(n - mfa, n));
  const errs = view.length - n;
  if (errs) h += c("Read errors", '<span class="bad">' + fmt(errs) + '</span>', "retry or check permissions");
  if (META.compare) { const d = view.filter(r => r[C.disc]).length; h += c("Differs from native report", '<span class="warn">' + fmt(d) + '</span>', pct(d, n)); }
  $("cards").innerHTML = h;

  const counts = {}; META.catalog.forEach(x => counts[x[0]] = 0);
  ok.forEach(r => r[C.keys].forEach(k => { if (k in counts) counts[k]++; }));
  const max = Math.max(1, ...Object.values(counts));
  $("bars").innerHTML = META.catalog.map(x => '<div class="name" data-k="' + x[0] + '">' + esc(x[1]) + '</div><div class="bar"><span style="width:' + (100 * counts[x[0]] / max).toFixed(2) + '%"></span></div><div class="num">' + fmt(counts[x[0]]) + ' (' + pct(counts[x[0]], n) + ')</div>').join("");
  $("bars").querySelectorAll(".name").forEach(el => el.onclick = () => { $("fHas").value = el.dataset.k; apply(true); });
}

function renderPage() {
  const pages = Math.max(1, Math.ceil(view.length / PAGE));
  if (page >= pages) page = pages - 1;
  $("body").innerHTML = view.slice(page * PAGE, (page + 1) * PAGE).map(renderRow).join("") || '<tr><td colspan="' + cols.length + '" class="muted">No users match the current filter.</td></tr>';
  const pager = 'Showing ' + fmt(view.length ? page * PAGE + 1 : 0) + '-' + fmt(Math.min(view.length, (page + 1) * PAGE)) + ' of ' + fmt(view.length) +
    ' <button data-p="first">&laquo;</button><button data-p="prev">&lsaquo;</button> Page ' + (page + 1) + ' / ' + pages + ' <button data-p="next">&rsaquo;</button><button data-p="last">&raquo;</button>';
  ["pagerTop", "pagerBottom"].forEach(id => {
    $(id).innerHTML = pager;
    $(id).querySelectorAll("button").forEach(b => b.onclick = () => {
      const p = b.dataset.p; page = p === "first" ? 0 : p === "prev" ? Math.max(0, page - 1) : p === "next" ? Math.min(pages - 1, page + 1) : pages - 1; renderPage();
    });
  });
}

function apply(resetPage) {
  const q = $("q").value.trim().toLowerCase(), en = $("fEnabled").value, ty = $("fType").value, has = $("fHas").value, lacks = $("fLacks").value;
  const disc = $("fDisc").checked, err = $("fErr").checked;
  view = ROWS.filter(r =>
    (!q || r.lc.includes(q)) &&
    (en === "" || String(r[C.enabled]) === en) &&
    (!ty || r[C.type] === ty) &&
    (!has || matchKey(r, has)) &&
    (!lacks || (r[C.status] === "OK" && !matchKey(r, lacks))) &&
    (!disc || r[C.disc]) &&
    (!err || r[C.status] !== "OK"));
  const f = cols[sortCol].v, dir = sortDesc ? -1 : 1;
  view.sort((a, b) => { const x = f(a), y = f(b); return (x < y ? -1 : x > y ? 1 : 0) * dir; });
  if (resetPage) page = 0;
  renderHead(); renderCards(); renderPage();
}

function exportCsv() {
  const q = s => '"' + String(s == null ? "" : s).replace(/"/g, '""') + '"';
  const head = ["UserPrincipalName","DisplayName","AccountEnabled","UserType","MethodsRegistered","IsMfaCapable","IsPhishingResistantCapable","PasskeyModels","PasskeyNewestCreated","ReadStatus"];
  if (META.compare) head.push("NativeMethodsRegistered", "Discrepancy");
  const lines = [head.join(",")];
  view.forEach(r => {
    const v = [r[C.upn], r[C.name], r[C.enabled] ? "True" : "False", r[C.type], r[C.keys].filter(k => !HIDDEN_CHIPS.has(k)).map(k => LABELS[k] || k).join("; "), r.mfa, r.pr, r[C.pkModels], r[C.pkNewest], r[C.status]];
    if (META.compare) v.push(r[C.native], r[C.disc]);
    lines.push(v.map(q).join(","));
  });
  const blob = new Blob(["\ufeff" + lines.join("\r\n")], { type:"text/csv;charset=utf-8" });
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "AuthMethods_filtered.csv"; document.body.appendChild(a); a.click(); a.remove();
}

let timer;
$("q").oninput = () => { clearTimeout(timer); timer = setTimeout(() => apply(true), 200); };
["fEnabled","fType","fHas","fLacks","fDisc","fErr"].forEach(id => $(id).onchange = () => apply(true));
$("reset").onclick = () => { $("q").value = ""; $("fEnabled").value = "1"; $("fType").value = ""; $("fHas").value = ""; $("fLacks").value = ""; $("fDisc").checked = false; $("fErr").checked = false; apply(true); };
$("export").onclick = exportCsv;
apply(true);
</script>
</body>
</html>
'@
#endregion

$stats = @{
    Users = 0; Batches = 0; ThrottledItems = 0; ThrottledBatches = 0; ThrottledPages = 0
    ServerErrors = 0; TransportErrors = 0; Retries = 0; FailedUsers = 0; MaxConcurrencyReached = 0
}
$runStart = Get-Date
$stamp = $runStart.ToString('yyyyMMdd-HHmmss')

try {
    #region Sign in ------------------------------------------------------------
    if ($AuthMode -ne 'AccessToken') { Connect-GraphSdk }
    [void](Update-Token)
    Write-Log "Signed in ($AuthMode). Tenant: $($state.TenantId) Account: $($state.Account)"

    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
    #endregion

    #region Enumerate users ----------------------------------------------------
    $select = 'id,userPrincipalName,displayName,accountEnabled,userType,onPremisesSyncEnabled,createdDateTime'
    $query = "`$select=$select&`$top=999"
    if ($UserFilter) { $query += '&$filter=' + [uri]::EscapeDataString($UserFilter) }
    # Group member casts and most attribute filters are only supported as advanced queries.
    $advanced = [bool]($UserFilter -or $GroupId)
    if ($advanced) { $query += '&$count=true' }

    $sources = New-Object System.Collections.Generic.List[string]
    $scopeParts = New-Object System.Collections.Generic.List[string]
    if ($GroupId) {
        $groupNames = New-Object System.Collections.Generic.List[string]
        foreach ($g in @($GroupId | ForEach-Object { $_.ToString() } | Select-Object -Unique)) {
            try { $grp = Invoke-GraphGet -Uri "$BaseUri/groups/$g`?`$select=id,displayName" }
            catch { throw "Could not read group $g. Check the object ID and that the account has GroupMember.Read.All. $($_.Exception.Message)" }
            $groupNames.Add(("'{0}' ({1})" -f $grp.displayName, $g))
            $sources.Add("$BaseUri/groups/$g/transitiveMembers/microsoft.graph.user?$query")
        }
        $scopeParts.Add('Members of ' + ($groupNames -join ', '))
    }
    else { $sources.Add("$BaseUri/users?$query") }
    if ($UserFilter) { $scopeParts.Add("Filter: $UserFilter") }
    if ($MaxUsers -gt 0) { $scopeParts.Add("First $MaxUsers users") }
    $scope = if ($scopeParts.Count) { $scopeParts -join '; ' } else { 'All users' }
    Write-Log "Scope: $scope"

    $users = New-Object System.Collections.Generic.List[object]
    $seenUsers = New-Object 'System.Collections.Generic.HashSet[string]'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($uri in $sources) {
        while ($uri) {
            $page = Invoke-GraphGet -Uri $uri -AdvancedQuery:$advanced
            foreach ($u in $page.value) {
                # Users can be in several of the groups; read each user once.
                if ($seenUsers.Add([string]$u.id)) { $users.Add($u) }
                if ($MaxUsers -gt 0 -and $users.Count -ge $MaxUsers) { break }
            }
            if ($MaxUsers -gt 0 -and $users.Count -ge $MaxUsers) { break }
            $uri = Get-Prop $page '@odata.nextLink'
            if ($users.Count % 9990 -lt 999) { Write-Log "Enumerated $($users.Count) users..." }
        }
        if ($MaxUsers -gt 0 -and $users.Count -ge $MaxUsers) { break }
    }
    $stats.Users = $users.Count
    Write-Log ("Enumerated {0} users in {1:n0} s." -f $users.Count, $sw.Elapsed.TotalSeconds)
    if ($users.Count -eq 0) { throw "No users matched the scope ($scope)." }
    #endregion

    #region Read authentication methods with concurrent $batch -----------------
    $results  = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $failures = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $attempts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $throttleAttempts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $MaxThrottleRetries = [Math]::Max(100, $MaxRetries)
    $dispatchedItems = 0
    $pending  = New-Object 'System.Collections.Generic.Queue[string]'
    $delayed  = New-Object System.Collections.Generic.List[object]
    $inFlight = New-Object System.Collections.Generic.List[object]
    foreach ($u in $users) { $pending.Enqueue([string]$u.id) }

    $ctl = @{
        Concurrency   = [Math]::Min(4, $MaxConcurrency)
        PauseUntil    = [datetime]::MinValue
        LastReduction = [datetime]::MinValue
        CleanStreak   = 0
    }
    $ctl.MaxSeen = $ctl.Concurrency
    $batchUri = "$BaseUri/`$batch"

    $addRetry = {
        param([string]$Id, [int]$DelaySeconds, [string]$Reason, [bool]$Throttled = $false)
        # Throttling is expected at this scale and is not a fault of the user
        # being read, so it has a much higher ceiling than real errors.
        $dict = if ($Throttled) { $throttleAttempts } else { $attempts }
        $limit = if ($Throttled) { $MaxThrottleRetries } else { $MaxRetries }
        $n = 1
        if ($dict.ContainsKey($Id)) { $n = $dict[$Id] + 1 }
        $dict[$Id] = $n
        if ($n -gt $limit) {
            $failures[$Id] = "Gave up after $limit retries. Last: $Reason"
            return
        }
        $stats.Retries++
        $delayed.Add([pscustomobject]@{ Id = $Id; NotBefore = [datetime]::UtcNow.AddSeconds($DelaySeconds) })
    }

    $registerThrottle = {
        param([int]$Seconds)
        $now = [datetime]::UtcNow
        $until = $now.AddSeconds($Seconds)
        if ($until -gt $ctl.PauseUntil) { $ctl.PauseUntil = $until }
        # Several in-flight batches usually report the same throttling event;
        # only back off once per event.
        if (($now - $ctl.LastReduction).TotalSeconds -gt [Math]::Max(5, $Seconds)) {
            $ctl.Concurrency = [Math]::Max(1, [int][Math]::Floor($ctl.Concurrency / 2))
            $ctl.LastReduction = $now
        }
        $ctl.CleanStreak = 0
    }

    $total = $users.Count
    $sw.Restart()
    $lastProgress = [datetime]::UtcNow
    Write-Log "Reading authentication methods: batch size $BatchSize, starting concurrency $($ctl.Concurrency), max $MaxConcurrency."

    while ($pending.Count -gt 0 -or $delayed.Count -gt 0 -or $inFlight.Count -gt 0) {
        $now = [datetime]::UtcNow

        for ($i = $delayed.Count - 1; $i -ge 0; $i--) {
            if ($delayed[$i].NotBefore -le $now) { $pending.Enqueue($delayed[$i].Id); $delayed.RemoveAt($i) }
        }

        if (($now - $state.TokenAcquired).TotalMinutes -gt $TokenRefreshMinutes) {
            if (Update-Token) { Write-Log 'Access token refreshed.' }
        }

        while ($inFlight.Count -lt $ctl.Concurrency -and $pending.Count -gt 0 -and $now -ge $ctl.PauseUntil) {
            if ($MaxUsersPerSecond -gt 0 -and $dispatchedItems -ge $MaxUsersPerSecond * [Math]::Max(1, $sw.Elapsed.TotalSeconds)) { break }
            $ids = New-Object System.Collections.Generic.List[string]
            while ($ids.Count -lt $BatchSize -and $pending.Count -gt 0) { $ids.Add($pending.Dequeue()) }
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('{"requests":[')
            for ($k = 0; $k -lt $ids.Count; $k++) {
                if ($k) { [void]$sb.Append(',') }
                [void]$sb.Append('{"id":"').Append($k + 1).Append('","method":"GET","url":"/users/').Append($ids[$k]).Append('/authentication/methods"}')
            }
            [void]$sb.Append(']}')
            $req = New-GraphRequest -Method POST -Uri $batchUri -JsonBody $sb.ToString()
            $inFlight.Add([pscustomobject]@{ Task = $client.SendAsync($req); Ids = $ids; Request = $req })
            $stats.Batches++
            $dispatchedItems += $ids.Count
        }
        if ($inFlight.Count -gt $stats.MaxConcurrencyReached) { $stats.MaxConcurrencyReached = $inFlight.Count }

        if ($inFlight.Count -eq 0) { Start-Sleep -Milliseconds 250; continue }

        $tasks = [System.Threading.Tasks.Task[]]@($inFlight | ForEach-Object { $_.Task })
        [void][System.Threading.Tasks.Task]::WaitAny($tasks, 500)

        for ($i = $inFlight.Count - 1; $i -ge 0; $i--) {
            $f = $inFlight[$i]
            if (-not $f.Task.IsCompleted) { continue }
            $inFlight.RemoveAt($i)

            if ($f.Task.IsFaulted -or $f.Task.IsCanceled) {
                $stats.TransportErrors++
                $msg = if ($f.Task.Exception) { $f.Task.Exception.GetBaseException().Message } else { 'Request timed out' }
                foreach ($id in $f.Ids) { & $addRetry $id 5 "Transport: $msg" }
                $f.Request.Dispose()
                continue
            }

            $resp = $f.Task.Result
            $code = [int]$resp.StatusCode
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $batchRetryAfter = Get-RetryAfterSeconds -Response $resp -Attempt 2
            $resp.Dispose(); $f.Request.Dispose()

            if ($code -eq 401) {
                if (Update-Token) {
                    foreach ($id in $f.Ids) { & $addRetry $id 0 'HTTP 401' }
                    continue
                }
                throw 'Graph returned 401 Unauthorized and the access token cannot be refreshed. The token has probably expired.'
            }
            if ($code -eq 429 -or $code -ge 500) {
                if ($code -eq 429) { $stats.ThrottledBatches++ } else { $stats.ServerErrors++ }
                & $registerThrottle $batchRetryAfter
                foreach ($id in $f.Ids) { & $addRetry $id $batchRetryAfter "Batch HTTP $code" ($code -eq 429) }
                continue
            }
            if ($code -ne 200) { throw "`$batch request failed with HTTP $code. $text" }

            $batch = $text | ConvertFrom-Json
            $throttleSeconds = 0
            foreach ($r in $batch.responses) {
                $id = $f.Ids[[int]$r.id - 1]
                $s = [int]$r.status
                if ($s -eq 200) {
                    $results[$id] = @($r.body.value)
                }
                elseif ($s -eq 429 -or $s -ge 500 -or $s -eq 401) {
                    $ra = 0
                    $h = Get-Prop $r 'headers'
                    if ($h) { [void][int]::TryParse([string](Get-Prop $h 'Retry-After'), [ref]$ra) }
                    if ($ra -lt 1) { $ra = if ($s -eq 429) { 5 } else { 3 } }
                    if ($s -eq 429) { $stats.ThrottledItems++; if ($ra -gt $throttleSeconds) { $throttleSeconds = $ra } }
                    elseif ($s -ge 500) { $stats.ServerErrors++ }
                    & $addRetry $id $ra "HTTP $s" ($s -eq 429)
                }
                else {
                    $err = Get-Prop (Get-Prop $r 'body') 'error'
                    $detail = if ($err) { "$(Get-Prop $err 'code'): $(Get-Prop $err 'message')" } else { '' }
                    $failures[$id] = "HTTP $s $detail".Trim()
                }
            }
            if ($throttleSeconds -gt 0) {
                & $registerThrottle $throttleSeconds
            }
            else {
                $ctl.CleanStreak++
                if ($ctl.CleanStreak -ge 10 -and $ctl.Concurrency -lt $MaxConcurrency -and $now -ge $ctl.PauseUntil) {
                    $ctl.Concurrency++
                    $ctl.CleanStreak = 0
                }
            }
        }

        if (([datetime]::UtcNow - $lastProgress).TotalSeconds -ge $ProgressIntervalSeconds) {
            $lastProgress = [datetime]::UtcNow
            $done = $results.Count + $failures.Count
            $rate = if ($sw.Elapsed.TotalSeconds -gt 0) { $done / $sw.Elapsed.TotalSeconds } else { 0 }
            $eta = if ($rate -gt 0) { [TimeSpan]::FromSeconds(($total - $done) / $rate).ToString('hh\:mm\:ss') } else { '?' }
            Write-Log ("Progress {0}/{1} ({2:p0}) | {3:n1} users/s | ETA {4} | concurrency {5} | throttled items {6} | retries {7}" -f
                $done, $total, ($(if ($total) { $done / $total } else { 1 })), $rate, $eta, $ctl.Concurrency, $stats.ThrottledItems, $stats.Retries)
            if (-not $IsAutomation) {
                Write-Progress -Activity 'Reading authentication methods' -Status "$done of $total users" -PercentComplete ([Math]::Min(100, [int](100 * $done / [Math]::Max(1, $total))))
            }
        }
    }
    if (-not $IsAutomation) { Write-Progress -Activity 'Reading authentication methods' -Completed }
    $collectSeconds = $sw.Elapsed.TotalSeconds
    $stats.FailedUsers = $failures.Count
    Write-Log ("Read methods for {0} users in {1:n0} s ({2:n1} users/s). Failed: {3}. Throttled items: {4}." -f
        $results.Count, $collectSeconds, ($results.Count / [Math]::Max(1, $collectSeconds)), $failures.Count, $stats.ThrottledItems)
    #endregion

    #region Optional: native registration details report ---------------------
    $native = $null
    if ($CompareWithReport) {
        Write-Log 'Downloading the native User registration details report for comparison...'
        $native = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $uri = "$BaseUri/reports/authenticationMethods/userRegistrationDetails"
        $sw.Restart()
        try {
            while ($uri) {
                $page = Invoke-GraphGet -Uri $uri
                foreach ($r in $page.value) { $native[[string]$r.id] = $r }
                $uri = Get-Prop $page '@odata.nextLink'
            }
            Write-Log ("Native report returned {0} users in {1:n0} s." -f $native.Count, $sw.Elapsed.TotalSeconds)
        }
        catch {
            # Don't lose the collected data because the comparison failed (e.g. AuditLog.Read.All missing).
            Write-Log "Could not download the native report; continuing without comparison. $($_.Exception.Message)" 'WARN'
            $native = $null
        }
    }
    #endregion

    #region Build rows --------------------------------------------------------
    Write-Log 'Building output...'
    $rows = New-Object System.Collections.Generic.List[object]
    $detailRows = New-Object System.Collections.Generic.List[object]
    $errorRows = New-Object System.Collections.Generic.List[object]
    $htmlRows = New-Object System.Text.StringBuilder
    $methodCounts = @{}
    foreach ($k in $MethodCatalog.Keys) { $methodCounts[$k] = 0 }
    $summary = @{ Total = 0; Enabled = 0; Mfa = 0; PhishRes = 0; Passkey = 0; NoMfa = 0; Failed = 0; Discrepancies = 0 }
    $Js = [System.Web.HttpUtility]
    # ISO-8601 UTC strings compare correctly as strings.
    $recentCutoff = [datetime]::UtcNow.AddHours(-48).ToString('yyyy-MM-ddTHH:mm:ss')

    # Hot loop (runs once per user): StrictMode is relaxed so optional Graph properties can be read
    # directly (missing -> $null) instead of through Get-Prop/Format-Date, which cost ~0.3 ms per call.
    Set-StrictMode -Off
    $sortedUsers = $users | Sort-Object -Property userPrincipalName
    $first = $true
    foreach ($u in $sortedUsers) {
        $id = [string]$u.id
        $upn = [string]$u.userPrincipalName
        $keys = New-Object 'System.Collections.Generic.List[string]'
        $other = New-Object 'System.Collections.Generic.List[string]'
        $passkeyModels = New-Object 'System.Collections.Generic.List[string]'
        $passkeyNewest = ''
        $authenticatorDevices = New-Object 'System.Collections.Generic.List[string]'
        $status = 'OK'
        $statusDetail = ''

        if ($results.ContainsKey($id)) {
            foreach ($m in $results[$id]) {
                $type = ([string]$m.'@odata.type') -replace '^#microsoft\.graph\.', '' -replace 'AuthenticationMethod$', ''
                $key = $null
                $d = [ordered]@{
                    UserPrincipalName = $upn; UserId = $id; Method = ''; MethodType = $type; DisplayName = ''
                    Detail = ''; AaGuid = ''; CreatedDateTime = ''; LastUsedDateTime = ''; MethodId = [string]$m.id
                }
                $created = $m.createdDateTime
                switch ($type) {
                    'password' { $key = 'password' }
                    'microsoftAuthenticator' {
                        $key = 'microsoftAuthenticator'
                        $d.DisplayName = [string]$m.displayName
                        $d.Detail = ('{0} {1}' -f $m.deviceTag, $m.phoneAppVersion).Trim()
                        if ($d.DisplayName) { $authenticatorDevices.Add($d.DisplayName) }
                    }
                    'fido2' {
                        $key = 'passkey'
                        $created = $m.creationDateTime
                        $aaguid = ([string]$m.aaGuid).ToLowerInvariant()
                        $model = [string]$m.model
                        $d.DisplayName = [string]$m.displayName
                        $d.Detail = $model
                        $d.AaGuid = $aaguid
                        $sub = if ($AuthenticatorAaGuids -contains $aaguid) { 'passkeyAuthenticator' } else { 'passkeyOther' }
                        if (-not $keys.Contains($sub)) { $keys.Add($sub) }
                        $label = if ($model) { $model } elseif ($d.DisplayName) { $d.DisplayName } else { $aaguid }
                        $passkeyModels.Add($label)
                        $cs = if ($created -is [datetime]) { $created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$created }
                        if ($cs -gt $passkeyNewest) { $passkeyNewest = $cs }
                    }
                    'windowsHelloForBusiness' {
                        $key = 'windowsHelloForBusiness'
                        $d.DisplayName = [string]$m.displayName
                        $d.Detail = [string]$m.keyStrength
                    }
                    'platformCredential' {
                        $key = 'platformCredential'
                        $d.DisplayName = [string]$m.displayName
                        $d.Detail = ('{0} {1}' -f $m.platform, $m.keyStrength).Trim()
                    }
                    'phone' {
                        $pt = [string]$m.phoneType
                        $key = switch ($pt) { 'alternateMobile' { 'alternateMobilePhone' } 'office' { 'officePhone' } default { 'mobilePhone' } }
                        $d.Detail = 'SMS sign-in: ' + [string]$m.smsSignInState
                        if ($IncludeContactDetails) { $d.DisplayName = [string]$m.phoneNumber }
                    }
                    'softwareOath' { $key = 'softwareOath' }
                    'hardwareOath' {
                        $key = 'hardwareOath'
                        $d.DisplayName = [string]$m.displayName
                    }
                    'temporaryAccessPass' {
                        $key = 'temporaryAccessPass'
                        $d.Detail = 'Usable: ' + [string]$m.isUsable
                    }
                    'email' {
                        $key = 'email'
                        if ($IncludeContactDetails) { $d.DisplayName = [string]$m.emailAddress }
                    }
                    'qrCodePin' { $key = 'qrCodePin' }
                    default { if ($type) { $other.Add($type) } }
                }
                if ($key -and -not $keys.Contains($key)) { $keys.Add($key) }
                $d.Method = if ($key) { $MethodCatalog[$key] } else { $type }
                $d.CreatedDateTime = if ($created -is [datetime]) { $created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$created }
                $lu = $m.lastUsedDateTime
                $d.LastUsedDateTime = if ($lu -is [datetime]) { $lu.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$lu }
                if ($type -ne 'password') { $detailRows.Add([pscustomobject]$d) }
            }
        }
        else {
            $status = 'Error'
            $statusDetail = if ($failures.ContainsKey($id)) { $failures[$id] } else { 'Not read' }
            $summary.Failed++
            $errorRows.Add([pscustomobject]@{ UserPrincipalName = $upn; UserId = $id; Error = $statusDetail })
        }

        foreach ($k in $keys) { $methodCounts[$k]++ }
        $isMfa = $false; foreach ($k in $MfaKeys) { if ($keys.Contains($k)) { $isMfa = $true; break } }
        $isPr = $false; foreach ($k in $PhishResistantKeys) { if ($keys.Contains($k)) { $isPr = $true; break } }
        $hasPasskey = $keys.Contains('passkey')
        $enabled = [bool]$u.accountEnabled
        $summary.Total++
        if ($enabled) { $summary.Enabled++ }
        if ($status -eq 'OK') {
            if ($isMfa) { $summary.Mfa++ } else { $summary.NoMfa++ }
            if ($isPr) { $summary.PhishRes++ }
            if ($hasPasskey) { $summary.Passkey++ }
        }

        $methodList = New-Object 'System.Collections.Generic.List[string]'
        $methodCount = $other.Count
        foreach ($k in $keys) {
            if ($k -ne 'passkeyAuthenticator' -and $k -ne 'passkeyOther') {
                $methodList.Add($MethodCatalog[$k])
                if ($k -ne 'password') { $methodCount++ }
            }
        }
        foreach ($o in $other) { $methodList.Add($o) }
        $uc = $u.createdDateTime
        $userCreated = if ($uc -is [datetime]) { $uc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$uc }
        $row = [ordered]@{
            UserPrincipalName          = $upn
            DisplayName                = [string]$u.displayName
            UserId                     = $id
            AccountEnabled             = $enabled
            UserType                   = [string]$u.userType
            OnPremisesSyncEnabled      = [bool]$u.onPremisesSyncEnabled
            UserCreatedDateTime        = $userCreated
            ReadStatus                 = $status
            MethodsRegistered          = ($methodList -join '; ')
            MethodCount                = $methodCount
            IsMfaCapable               = $isMfa
            IsPhishingResistantCapable = $isPr
            HasPasskey                 = $hasPasskey
            HasPasskeyInAuthenticator  = $keys.Contains('passkeyAuthenticator')
            HasPasskeyOther            = $keys.Contains('passkeyOther')
            PasskeyCount               = $passkeyModels.Count
            PasskeyModels              = ($passkeyModels -join '; ')
            PasskeyNewestCreated       = $passkeyNewest
            HasMicrosoftAuthenticator  = $keys.Contains('microsoftAuthenticator')
            AuthenticatorDevices       = ($authenticatorDevices -join '; ')
            HasWindowsHelloForBusiness = $keys.Contains('windowsHelloForBusiness')
            HasPlatformCredential      = $keys.Contains('platformCredential')
            HasPhone                   = ($keys.Contains('mobilePhone') -or $keys.Contains('alternateMobilePhone') -or $keys.Contains('officePhone'))
            HasSoftwareOath            = $keys.Contains('softwareOath')
            HasHardwareOath            = $keys.Contains('hardwareOath')
            HasTemporaryAccessPass     = $keys.Contains('temporaryAccessPass')
            HasEmail                   = $keys.Contains('email')
            ErrorDetail                = $statusDetail
        }

        $discrepancy = ''
        $nativeMethods = ''
        if ($native) {
            $inNative = $native.ContainsKey($id)
            if ($inNative) {
                $nr = $native[$id]
                $nm = @($nr.methodsRegistered)
                $nativeMethods = $nm -join '; '
                $nativePasskey = @($nm -match '(?i)passkey|fido2').Count -gt 0
                if ($status -eq 'OK') {
                    if ($hasPasskey -and -not $nativePasskey) {
                        $discrepancy = 'Passkey not shown in native report'
                        if ($passkeyNewest -and $passkeyNewest -gt $recentCutoff) { $discrepancy += ' (registered in last 48h; report may lag)' }
                    }
                    elseif ($nativePasskey -and -not $hasPasskey) { $discrepancy = 'Native report shows passkey that is no longer registered' }
                    elseif ($isMfa -and $nm.Count -eq 0) { $discrepancy = 'Native report shows no methods' }
                }
            }
            elseif ($enabled -and $status -eq 'OK') {
                # The native report does not include disabled users, by design.
                $discrepancy = 'Missing from native report'
                if ($userCreated -and $userCreated -gt $recentCutoff) { $discrepancy += ' (user created in last 48h; report may lag)' }
            }
            $row.InNativeReport = $inNative
            $row.NativeMethodsRegistered = $nativeMethods
            $row.NativeIsMfaCapable = if ($inNative) { [bool]$native[$id].isMfaCapable } else { $null }
            $row.Discrepancy = $discrepancy
            if ($discrepancy) { $summary.Discrepancies++ }
        }
        $rows.Add([pscustomobject]$row)

        if (-not $NoHtml) {
            if (-not $first) { [void]$htmlRows.Append(',') }
            $first = $false
            # Row layout must match the column indexes used in the HTML template.
            $keyParts = New-Object 'System.Collections.Generic.List[string]'
            foreach ($k in $keys) { $keyParts.Add('"' + $Js::JavaScriptStringEncode($k) + '"') }
            foreach ($o in $other) { $keyParts.Add('"' + $Js::JavaScriptStringEncode($o) + '"') }
            $keyJson = $keyParts -join ','
            $fields = @(
                '"' + $Js::JavaScriptStringEncode($upn) + '"'
                '"' + $Js::JavaScriptStringEncode([string]$u.displayName) + '"'
                $(if ($enabled) { '1' } else { '0' })
                '"' + $Js::JavaScriptStringEncode([string]$u.userType) + '"'
                '[' + $keyJson + ']'
                '"' + $Js::JavaScriptStringEncode($row.PasskeyModels) + '"'
                '"' + $Js::JavaScriptStringEncode($passkeyNewest) + '"'
                '"' + $status + '"'
                '"' + $Js::JavaScriptStringEncode($discrepancy) + '"'
                '"' + $Js::JavaScriptStringEncode($nativeMethods) + '"'
                '"' + $Js::JavaScriptStringEncode($statusDetail) + '"'
                '"' + $Js::JavaScriptStringEncode($row.AuthenticatorDevices) + '"'
            )
            [void]$htmlRows.Append('[').Append(($fields -join ',')).Append(']')
        }
    }
    Set-StrictMode -Version 2.0
    #endregion

    #region Write files -------------------------------------------------------
    $csvPath = Join-Path $OutputPath "AuthMethods_$stamp.csv"
    $detailPath = Join-Path $OutputPath "AuthMethodDetails_$stamp.csv"
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $detailRows | Export-Csv -LiteralPath $detailPath -NoTypeInformation -Encoding UTF8
    $errorPath = $null
    if ($errorRows.Count) {
        $errorPath = Join-Path $OutputPath "AuthMethodErrors_$stamp.csv"
        $errorRows | Export-Csv -LiteralPath $errorPath -NoTypeInformation -Encoding UTF8
    }

    $htmlPath = $null
    if (-not $NoHtml) {
        $htmlPath = Join-Path $OutputPath "AuthMethodReport_$stamp.html"
        $catalogJson = ($MethodCatalog.Keys | ForEach-Object { '["{0}","{1}",{2}]' -f $_, $Js::JavaScriptStringEncode($MethodCatalog[$_]), $methodCounts[$_] }) -join ','
        $meta = '{{"generated":"{0}","tenant":"{1}","compare":{2},"mfaKeys":[{3}],"prKeys":[{4}],"catalog":[{5}],"durationSeconds":{6},"scope":"{7}"}}' -f
            ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'),
            $Js::JavaScriptStringEncode([string]$state.TenantId),
            $(if ($native) { 'true' } else { 'false' }),
            (($MfaKeys | ForEach-Object { '"' + $_ + '"' }) -join ','),
            (($PhishResistantKeys | ForEach-Object { '"' + $_ + '"' }) -join ','),
            $catalogJson,
            [int]((Get-Date) - $runStart).TotalSeconds,
            $Js::JavaScriptStringEncode($scope)
        $html = $HtmlTemplate.Replace('/*__META__*/', $meta).Replace('/*__ROWS__*/', $htmlRows.ToString())
        [System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($false)))
    }

    $runSummary = [pscustomobject]@{
        TenantId                = $state.TenantId
        AuthMode                = $AuthMode
        Scope                   = $scope
        StartedUtc              = $runStart.ToUniversalTime().ToString('o')
        DurationSeconds         = [int]((Get-Date) - $runStart).TotalSeconds
        MethodReadSeconds       = [int]$collectSeconds
        UsersEnumerated         = $stats.Users
        UsersRead               = $results.Count
        UsersFailed             = $failures.Count
        BatchesSent             = $stats.Batches
        ThrottledItems          = $stats.ThrottledItems
        ThrottledBatches        = $stats.ThrottledBatches
        ServerErrors            = $stats.ServerErrors
        TransportErrors         = $stats.TransportErrors
        Retries                 = $stats.Retries
        PeakBatchesInFlight     = $stats.MaxConcurrencyReached
        MfaCapableUsers         = $summary.Mfa
        PhishingResistantUsers  = $summary.PhishRes
        PasskeyUsers            = $summary.Passkey
        NativeReportUsers       = $(if ($native) { $native.Count } else { $null })
        NativeReportUsersInScope = $(if ($native) { @($users | Where-Object { $native.ContainsKey([string]$_.id) }).Count } else { $null })
        Discrepancies           = $(if ($native) { $summary.Discrepancies } else { $null })
        CsvPath                 = $csvPath
        DetailCsvPath           = $detailPath
        HtmlPath                = $htmlPath
        ErrorCsvPath            = $errorPath
    }
    $summaryPath = Join-Path $OutputPath "RunSummary_$stamp.json"
    $runSummary | ConvertTo-Json | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Log ("Done in {0:n0} s. Users: {1}, MFA capable: {2}, passkey: {3}, failed: {4}{5}" -f
        $runSummary.DurationSeconds, $summary.Total, $summary.Mfa, $summary.Passkey, $summary.Failed,
        $(if ($native) { ", discrepancies vs native report: $($summary.Discrepancies)" } else { '' }))
    Write-Log "Output folder: $OutputPath"
    if (-not $IsAutomation) { $runSummary }
    #endregion
}
finally {
    if ($client) { $client.Dispose() }
}
