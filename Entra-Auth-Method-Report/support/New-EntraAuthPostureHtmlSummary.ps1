<#
.SYNOPSIS
Creates a portable executive HTML summary from Entra posture CSV files.

.DESCRIPTION
Creates one self-contained static HTML file with inline CSS and no external
assets, scripts, modules, or network dependencies. The report intentionally
contains aggregate posture data only; per-user and sign-in evidence remain in
the CSV and optional XLSX deliverables.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $PosturePath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $SummaryPath,

    [string] $OutputDirectory = (Split-Path -Parent $PosturePath),

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalPropertyValue {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Test-TrueLikeValue {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $false }
    return $Value -eq $true -or $Value.ToString().Equals('True', [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-IntegerOrZero {
    param([AllowNull()][object] $Value)

    $number = 0
    if ($null -ne $Value) { [void][int]::TryParse($Value.ToString(), [ref]$number) }
    return $number
}

function ConvertTo-RateOrZero {
    param([AllowNull()][object] $Value)

    if ($null -eq $Value) { return 0.0 }
    $text = $Value.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return 0.0 }
    $isPercentage = $text.EndsWith('%')
    if ($isPercentage) { $text = $text.TrimEnd('%').Trim() }
    $number = 0.0
    $styles = [System.Globalization.NumberStyles]::Float
    $parsed = [double]::TryParse($text, $styles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    if (-not $parsed) { $parsed = [double]::TryParse($text, [ref]$number) }
    if (-not $parsed) { return 0.0 }
    if ($isPercentage) { $number = $number / 100.0 }
    return [Math]::Max(0.0, [Math]::Min(1.0, $number))
}

function ConvertTo-HtmlText {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Value.ToString())
}

function Format-Count {
    param([int] $Value)
    return $Value.ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Rate {
    param([double] $Value)
    return $Value.ToString('P1', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-AvailableHtmlPath {
    param([Parameter(Mandatory)][string] $Directory, [Parameter(Mandatory)][string] $BaseName)

    $index = 0
    do {
        $suffix = if ($index -eq 0) { '' } else { "-$index" }
        $candidate = Join-Path $Directory "$BaseName$suffix-executive-summary.html"
        $index++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Get-AvailableHtmlPath -Directory $OutputDirectory -BaseName ([System.IO.Path]::GetFileNameWithoutExtension($PosturePath))
}
else {
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $specifiedDirectory = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $specifiedDirectory)) { New-Item -ItemType Directory -Path $specifiedDirectory -Force | Out-Null }
}

$posture = @(Import-Csv -LiteralPath $PosturePath)
$summary = @(Import-Csv -LiteralPath $SummaryPath)
$coverageRow = @($summary | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'RecordType') -eq 'Evidence coverage' } | Select-Object -First 1)[0]
$tierRows = @($summary | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'RecordType') -eq 'Tier distribution' })
if ($tierRows.Count -eq 0) {
    # Supports CSVs created by the first hybrid script version.
    $tierRows = @($summary | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'StrengthTier') -ne 'Evidence coverage (all users)' })
}

$totalUsers = $posture.Count
$privilegedUsers = @($posture | Where-Object { Test-TrueLikeValue -Value (Get-OptionalPropertyValue -Object $_ -Name 'IsAdmin') }).Count
$phishingResistant = @($posture | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'StrongestRegisteredTier') -eq 'Phishing-resistant MFA' }).Count
$passwordlessCapable = @($posture | Where-Object { Test-TrueLikeValue -Value (Get-OptionalPropertyValue -Object $_ -Name 'IsPasswordlessCapable') }).Count
$mfaCapable = @($posture | Where-Object { Test-TrueLikeValue -Value (Get-OptionalPropertyValue -Object $_ -Name 'IsMfaCapable') }).Count
$noClassifiedRegistration = @($posture | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'StrongestRegisteredTier') -eq 'None / unclassified' }).Count
$privilegedNoClassifiedRegistration = @($posture | Where-Object {
    (Test-TrueLikeValue -Value (Get-OptionalPropertyValue -Object $_ -Name 'IsAdmin')) -and
    (Get-OptionalPropertyValue -Object $_ -Name 'StrongestRegisteredTier') -eq 'None / unclassified'
}).Count

$successfulSignIns = if ($null -ne $coverageRow) { ConvertTo-IntegerOrZero (Get-OptionalPropertyValue -Object $coverageRow -Name 'SuccessfulInteractiveSignInCount') } else { [int](@($posture | Measure-Object -Property SuccessfulInteractiveSignInsReviewed -Sum).Sum) }
$explicitMethodSignIns = if ($null -ne $coverageRow) { ConvertTo-IntegerOrZero (Get-OptionalPropertyValue -Object $coverageRow -Name 'ExplicitMethodSignInCount') } else { [int](@($posture | Measure-Object -Property SignInsWithExplicitMethod -Sum).Sum) }
$evidenceRate = if ($null -ne $coverageRow) { ConvertTo-RateOrZero (Get-OptionalPropertyValue -Object $coverageRow -Name 'ExplicitMethodEvidenceRate') } elseif ($successfulSignIns -gt 0) { $explicitMethodSignIns / $successfulSignIns } else { 0.0 }
$mfaRequiredSignIns = [int](@($posture | Measure-Object -Property SuccessfulSignInsReportingMfaRequirement -Sum).Sum)
$windowStart = if ($null -ne $coverageRow) { Get-OptionalPropertyValue -Object $coverageRow -Name 'ObservationWindowStartUtc' } elseif ($totalUsers -gt 0) { Get-OptionalPropertyValue -Object $posture[0] -Name 'ObservationWindowStartUtc' } else { $null }
$windowEnd = if ($null -ne $coverageRow) { Get-OptionalPropertyValue -Object $coverageRow -Name 'ObservationWindowEndUtc' } elseif ($totalUsers -gt 0) { Get-OptionalPropertyValue -Object $posture[0] -Name 'ObservationWindowEndUtc' } else { $null }

$tierOrder = @('Phishing-resistant MFA', 'Passwordless MFA', 'Strong MFA (app, token, or TAP)', 'Phone-based MFA', 'Single-factor / SSPR only', 'None / unclassified')
$distribution = foreach ($tier in $tierOrder) {
    $source = @($tierRows | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'StrengthTier') -eq $tier } | Select-Object -First 1)[0]
    $registered = if ($null -ne $source) {
        $value = Get-OptionalPropertyValue -Object $source -Name 'RegisteredUserCount'
        if ($null -eq $value) { $value = Get-OptionalPropertyValue -Object $source -Name 'UsersByRegisteredStrength' }
        ConvertTo-IntegerOrZero $value
    }
    else { 0 }
    $observed = if ($null -ne $source) {
        $value = Get-OptionalPropertyValue -Object $source -Name 'ExplicitlyObservedUserCount'
        if ($null -eq $value) { $value = Get-OptionalPropertyValue -Object $source -Name 'UsersByExplicitlyObservedStrength' }
        ConvertTo-IntegerOrZero $value
    }
    else { 0 }
    [pscustomobject]@{ Tier = $tier; Registered = $registered; Observed = $observed }
}
$distributionMaximum = [Math]::Max(1, [int](($distribution | ForEach-Object { [Math]::Max($_.Registered, $_.Observed) } | Measure-Object -Maximum).Maximum))

$distributionHtml = foreach ($row in $distribution) {
    $registeredWidth = (100.0 * $row.Registered / $distributionMaximum).ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
    $observedWidth = (100.0 * $row.Observed / $distributionMaximum).ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
    $tone = switch ($row.Tier) {
        'Phishing-resistant MFA' { 'good' }
        'Passwordless MFA' { 'good' }
        'Strong MFA (app, token, or TAP)' { 'good' }
        'Phone-based MFA' { 'watch' }
        'Single-factor / SSPR only' { 'watch' }
        default { 'attention' }
    }
    @"
      <div class="distribution-row $tone">
        <div class="tier-name">$(ConvertTo-HtmlText $row.Tier)</div>
        <div class="bar-group"><span class="bar-label">Registered $(Format-Count $row.Registered)</span><div class="bar-track"><div class="bar registered" style="width: $registeredWidth%"></div></div></div>
        <div class="bar-group"><span class="bar-label">Explicitly observed $(Format-Count $row.Observed)</span><div class="bar-track"><div class="bar observed" style="width: $observedWidth%"></div></div></div>
      </div>
"@
}

$totalRate = if ($totalUsers -gt 0) { 1.0 } else { 0.0 }
$generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <title>Microsoft Entra Authentication Posture</title>
  <style>
    :root { --navy:#103b61; --blue:#1769aa; --cyan:#3d9ed1; --ink:#17212b; --muted:#617080; --line:#d7e0e8; --panel:#ffffff; --background:#f3f7fa; --good:#167a48; --watch:#b76e00; --attention:#b42318; }
    * { box-sizing:border-box; } body { margin:0; background:var(--background); color:var(--ink); font-family:"Segoe UI",Arial,sans-serif; font-size:14px; line-height:1.45; }
    .hero { background:linear-gradient(120deg,#0b314f,#1769aa); color:#fff; padding:38px max(5vw,28px) 34px; } .eyebrow { margin:0 0 8px; color:#bfe9ff; font-size:12px; font-weight:700; letter-spacing:.11em; text-transform:uppercase; } h1 { margin:0; font-size:32px; line-height:1.15; letter-spacing:-.03em; } .subtitle { margin:12px 0 0; max-width:760px; color:#e4f4ff; font-size:16px; } .meta { display:flex; flex-wrap:wrap; gap:10px 28px; margin-top:24px; font-size:13px; } .meta span { color:#d8ebf8; } .meta strong { color:#fff; }
    main { max-width:1180px; margin:0 auto; padding:28px; } h2 { margin:0 0 14px; font-size:19px; letter-spacing:-.01em; } h3 { margin:0 0 6px; font-size:15px; } .section { margin-top:28px; } .grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:16px; } .cards { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:16px; } .card, .panel { background:var(--panel); border:1px solid var(--line); border-radius:10px; box-shadow:0 2px 7px rgba(16,59,97,.06); } .card { min-height:135px; padding:18px; border-top:4px solid var(--blue); } .card.good { border-top-color:var(--good); } .card.watch { border-top-color:var(--watch); } .card.attention { border-top-color:var(--attention); } .card-label { color:var(--muted); font-weight:600; } .metric { margin:8px 0 4px; font-size:29px; font-weight:700; letter-spacing:-.035em; } .detail { color:var(--muted); font-size:13px; } .panel { padding:22px; } .distribution-row { display:grid; grid-template-columns:minmax(180px,1.35fr) minmax(190px,2fr) minmax(190px,2fr); gap:14px; align-items:center; padding:13px 0; border-top:1px solid var(--line); } .distribution-row:first-of-type { border-top:0; } .tier-name { font-weight:650; } .bar-group { min-width:0; } .bar-label { display:block; margin-bottom:5px; color:var(--muted); font-size:12px; } .bar-track { height:10px; overflow:hidden; background:#e7eef4; border-radius:99px; } .bar { min-width:2px; height:100%; border-radius:99px; } .registered { background:var(--blue); } .observed { background:var(--cyan); } .attention .registered { background:var(--attention); } .watch .registered { background:var(--watch); } .legend { display:flex; gap:18px; margin:-4px 0 11px; color:var(--muted); font-size:12px; } .legend i { display:inline-block; width:10px; height:10px; margin-right:5px; border-radius:2px; vertical-align:-1px; } .callout { padding:17px 18px; border-radius:8px; } .callout.attention { background:#fff0ef; border:1px solid #f2c3bf; } .callout.watch { background:#fff8e8; border:1px solid #ecd18e; } .callout.good { background:#edf8f1; border:1px solid #bde1c9; } .callout p { margin:0; color:#3d4b57; } .note { color:var(--muted); } footer { max-width:1180px; margin:0 auto; padding:8px 28px 35px; color:var(--muted); font-size:12px; }
    @media (max-width:820px) { .cards,.grid { grid-template-columns:1fr 1fr; } .distribution-row { grid-template-columns:1fr; gap:7px; } } @media (max-width:540px) { main { padding:18px; } .hero { padding:28px 20px; } h1 { font-size:27px; } .cards,.grid { grid-template-columns:1fr; } }
    @media print { @page { size:auto; margin:12mm; } body { background:#fff; font-size:11px; } .hero { padding:22px; } h1 { font-size:25px; } main { max-width:none; padding:16px 0; } .section { margin-top:18px; } .cards { gap:8px; } .card,.panel { box-shadow:none; } .card { min-height:105px; padding:12px; } .metric { font-size:23px; } .distribution-row,.panel,.callout { break-inside:avoid; } footer { padding:8px 0; } * { -webkit-print-color-adjust:exact; print-color-adjust:exact; } }
  </style>
</head>
<body>
  <header class="hero">
    <p class="eyebrow">Executive summary &middot; aggregate data only</p>
    <h1>Microsoft Entra Authentication Posture</h1>
    <p class="subtitle">Registration strength and explicitly observed successful interactive sign-in evidence. This is a reporting view, not an access-control decision.</p>
    <div class="meta"><span><strong>Report scope:</strong> $(ConvertTo-HtmlText $windowStart) through $(ConvertTo-HtmlText $windowEnd)</span><span><strong>Generated:</strong> $generatedUtc</span></div>
  </header>
  <main>
    <section class="section">
      <h2>Posture at a glance</h2>
      <div class="cards">
        <article class="card"><div class="card-label">Users in scope</div><div class="metric">$(Format-Count $totalUsers)</div><div class="detail">$(Format-Count $privilegedUsers) privileged account$(if ($privilegedUsers -eq 1) { '' } else { 's' }) reported by Entra</div></article>
        <article class="card good"><div class="card-label">Phishing-resistant registration</div><div class="metric">$(Format-Rate $(if ($totalUsers -gt 0) { $phishingResistant / $totalUsers } else { 0 }))</div><div class="detail">$(Format-Count $phishingResistant) user$(if ($phishingResistant -eq 1) { '' } else { 's' }) with FIDO2, Windows Hello for Business, or certificate</div></article>
        <article class="card good"><div class="card-label">Passwordless-capable</div><div class="metric">$(Format-Rate $(if ($totalUsers -gt 0) { $passwordlessCapable / $totalUsers } else { 0 }))</div><div class="detail">$(Format-Count $passwordlessCapable) user$(if ($passwordlessCapable -eq 1) { '' } else { 's' }) reported as passwordless-capable</div></article>
        <article class="card good"><div class="card-label">MFA-capable</div><div class="metric">$(Format-Rate $(if ($totalUsers -gt 0) { $mfaCapable / $totalUsers } else { 0 }))</div><div class="detail">$(Format-Count $mfaCapable) user$(if ($mfaCapable -eq 1) { '' } else { 's' }) reported as MFA-capable</div></article>
        <article class="card $(if ($evidenceRate -ge .75) { 'good' } elseif ($evidenceRate -ge .25) { 'watch' } else { 'attention' })"><div class="card-label">Explicit-method evidence coverage</div><div class="metric">$(Format-Rate $evidenceRate)</div><div class="detail">$(Format-Count $explicitMethodSignIns) of $(Format-Count $successfulSignIns) successful interactive sign-ins</div></article>
        <article class="card $(if ($privilegedNoClassifiedRegistration -gt 0) { 'attention' } else { 'good' })"><div class="card-label">Priority account review</div><div class="metric">$(Format-Count $privilegedNoClassifiedRegistration)</div><div class="detail">Privileged account$(if ($privilegedNoClassifiedRegistration -eq 1) { '' } else { 's' }) with no classified registration</div></article>
      </div>
    </section>
    <section class="section">
      <h2>Registration strength distribution</h2>
      <div class="panel">
        <div class="legend"><span><i style="background:#1769aa"></i>Registered strongest method</span><span><i style="background:#3d9ed1"></i>Strongest explicitly observed method</span></div>
        $($distributionHtml -join [Environment]::NewLine)
      </div>
    </section>
    <section class="section">
      <h2>Recommended review focus</h2>
      <div class="grid">
        <article class="callout $(if ($privilegedNoClassifiedRegistration -gt 0) { 'attention' } else { 'good' })"><h3>Privileged accounts</h3><p>$(Format-Count $privilegedNoClassifiedRegistration) privileged account$(if ($privilegedNoClassifiedRegistration -eq 1) { '' } else { 's' }) ha$(if ($privilegedNoClassifiedRegistration -eq 1) { 's' } else { 've' }) no classified registered method. Confirm account purpose and approved controls before remediation.</p></article>
        <article class="callout $(if ($noClassifiedRegistration -gt 0) { 'watch' } else { 'good' })"><h3>Classification queue</h3><p>$(Format-Count $noClassifiedRegistration) user$(if ($noClassifiedRegistration -eq 1) { '' } else { 's' }) ha$(if ($noClassifiedRegistration -eq 1) { 's' } else { 've' }) no classified registration. Classify service, test, break-glass, B2B, and human identities before treating this as a gap.</p></article>
        <article class="callout $(if ($evidenceRate -ge .75) { 'good' } else { 'watch' })"><h3>Sign-in evidence</h3><p>$(Format-Count $mfaRequiredSignIns) of $(Format-Count $successfulSignIns) successful interactive sign-ins reported an MFA requirement. Use the restricted evidence CSV for technical validation.</p></article>
      </div>
    </section>
    <section class="section">
      <h2>How to read this report</h2>
      <div class="grid">
        <article class="panel"><h3>Registered versus observed</h3><p class="note">Registered strength is the highest-scoring method currently reported for a user. Explicit observation is limited to successful interactive sign-ins that returned a classifiable authentication step in this report window.</p></article>
        <article class="panel"><h3>Evidence caveat</h3><p class="note">A missing explicit method does not mean that a user did not authenticate or did not use MFA. Existing sessions and token claims can satisfy a requirement without a fresh factor in that event.</p></article>
        <article class="panel"><h3>Supporting deliverables</h3><p class="note">Use the CSV or optional workbook for user-level review. The restricted evidence CSV may contain sign-in identifiers, IP addresses, and device metadata and should be shared only with authorized audiences.</p></article>
      </div>
    </section>
  </main>
  <footer>Generated locally from Microsoft Graph report exports. No external scripts, fonts, tracking, or network resources are used. Open in a browser and use Print to PDF when a fixed-format copy is required.</footer>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutputPath, $html, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "Executive HTML created: $OutputPath"
