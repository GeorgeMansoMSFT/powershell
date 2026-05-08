# Generate-Report.ps1
# Produces a human-readable HTML summary of discovery findings.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [hashtable] $InventorySummary,
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath,
    [Parameter(Mandatory)] [string] $OutputDir,
    [string[]] $SkippedScopes = @()
)

# Categorize blockers
$hardBlockers = @("Users", "Groups", "AppRegistrations", "ManagedIdentities", "ExchangeOnline", "Federation")
$softBlockers = @("ServicePrincipals", "ConditionalAccess", "AzureResources")
$informational = @("SignInActivity", "SoftDeleted")

# Map module names to their numeric order so the report can sort the same way the
# CSVs and run sequence do (01-Users, 02-Groups, ..., 11-AzureResources).
$moduleOrder = @{
    "Users"             = 1
    "Groups"            = 2
    "AppRegistrations"  = 3
    "ServicePrincipals" = 4
    "ManagedIdentities" = 5
    "ExchangeOnline"    = 6
    "ConditionalAccess" = 7
    "Federation"        = 8
    "SignInActivity"    = 9
    "SoftDeleted"       = 10
    "AzureResources"    = 11
}

function Get-Severity($module, $count) {
    if ($count -lt 0) { return "error" }
    if ($count -eq 0) { return "ok" }
    if ($module -in $hardBlockers)    { return "blocker" }
    if ($module -in $softBlockers)    { return "warn" }
    return "info"
}

function Get-Category($module, $count, $notes) {
    # Federation is a special case: it's a hard blocker only when the domain is
    # actually federated. When Managed (the common case), it's not a blocker.
    if ($module -eq "Federation") {
        if ($notes -like "*FEDERATED*") {
            return "Hard blocker (must fix before removal)"
        } else {
            return "Domain auth status"
        }
    }
    if ($module -in $hardBlockers)    { return "Hard blocker (must fix before removal)" }
    if ($module -in $softBlockers)    { return "Soft blocker (recommend fixing)" }
    return "Informational"
}

$rows = foreach ($key in $InventorySummary.Keys) {
    $entry = $InventorySummary[$key]
    $sev   = Get-Severity $key $entry.Count
    $cat   = Get-Category $key $entry.Count $entry.Notes
    $order = if ($moduleOrder.ContainsKey($key)) { $moduleOrder[$key] } else { 999 }

    [PSCustomObject]@{
        Module     = $key
        ModuleOrder = $order
        Category   = $cat
        Count     = $entry.Count
        Severity  = $sev
        Output    = if ($entry.OutputFile) { Split-Path -Leaf $entry.OutputFile } else { "" }
        Notes     = $entry.Notes
        Timestamp = $entry.Timestamp
    }
}

$totalBlockers = ($rows | Where-Object { $_.Severity -eq "blocker" -and $_.Count -gt 0 } | Measure-Object Count -Sum).Sum
$totalWarnings = ($rows | Where-Object { $_.Severity -eq "warn"    -and $_.Count -gt 0 } | Measure-Object Count -Sum).Sum

# Count actual error/warning entries in errors.log rather than just InventorySummary
# entries with Count = -1. errors.log captures any module-level issue, including
# things that didn't cause the module to fail outright but are worth flagging.
$errorLogPath = Join-Path $OutputDir "errors.log"
$totalErrors = 0
if (Test-Path $errorLogPath) {
    $totalErrors = @(Get-Content $errorLogPath -ErrorAction SilentlyContinue).Count
}

$readinessStatus = if ($totalBlockers -eq 0 -and $totalErrors -eq 0) {
    @{ Text = "READY"; Color = "#2e7d32"; Description = "No hard blockers found. Domain removal should succeed once any soft blockers are addressed." }
} elseif ($totalBlockers -gt 0) {
    @{ Text = "NOT READY"; Color = "#c62828"; Description = "$totalBlockers references found that will block domain removal. Address all hard blockers before attempting removal." }
} else {
    @{ Text = "REVIEW"; Color = "#ef6c00"; Description = "Soft blockers or errors detected. Review findings before proceeding." }
}

# Split rows into "has findings" (count > 0) and "no findings" (count = 0 or error).
# Sort each group by the module's numeric order so the report mirrors run sequence.
$rowsWithFindings = $rows | Where-Object { $_.Count -gt 0 } | Sort-Object ModuleOrder
$rowsNoFindings   = $rows | Where-Object { $_.Count -le 0 } | Sort-Object ModuleOrder

function Build-TableRow($row) {
    $color = switch ($row.Severity) {
        "blocker" { "#ffebee" }
        "warn"    { "#fff8e1" }
        "info"    { "#e3f2fd" }
        "ok"      { "#e8f5e9" }
        "error"   { "#fce4ec" }
    }
    $countDisplay = if ($row.Count -lt 0) { "ERROR" } else { $row.Count }
    @"
        <tr style="background-color: $color;">
            <td><strong>$($row.Module)</strong></td>
            <td>$($row.Category)</td>
            <td style="text-align: right; font-family: monospace;">$countDisplay</td>
            <td>$($row.Output)</td>
            <td>$($row.Notes)</td>
        </tr>
"@
}

$findingsTableRows = ($rowsWithFindings | ForEach-Object { Build-TableRow $_ }) -join "`n"
$noFindingsTableRows = ($rowsNoFindings | ForEach-Object { Build-TableRow $_ }) -join "`n"

$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Build the skipped-scopes warning block (empty if nothing was skipped)
$skippedBlock = ""
if ($SkippedScopes -and $SkippedScopes.Count -gt 0) {
    $skippedItems = ($SkippedScopes | ForEach-Object { "<li>$_</li>" }) -join "`n"
    $skippedBlock = @"
<div class="skipped-banner">
  <h3>&#9888;&#65039; Scan incomplete - some scopes were not included</h3>
  <p>The following discovery scopes were skipped. Domain references in these areas
     were NOT inventoried, so this report may not reflect all blockers. Re-run with
     these scopes enabled before treating the report as authoritative.</p>
  <ul>
$skippedItems
  </ul>
</div>
"@
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Domain Discovery Report &mdash; $Domain</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; max-width: 1100px; margin: 2em auto; padding: 0 1em; color: #222; }
  h1 { border-bottom: 2px solid #0078d4; padding-bottom: 0.3em; }
  h2 { color: #0078d4; margin-top: 2em; }
  .status-banner { padding: 1.5em; border-radius: 8px; color: white; margin: 1.5em 0; }
  .status-banner h2 { color: white; margin: 0 0 0.5em 0; border: none; }
  .meta { color: #666; font-size: 0.9em; }
  table { width: 100%; border-collapse: collapse; margin: 1em 0; }
  th { background-color: #0078d4; color: white; text-align: left; padding: 0.6em; font-weight: 600; }
  td { padding: 0.6em; border-bottom: 1px solid #eee; vertical-align: top; }
  .summary-cards { display: flex; gap: 1em; margin: 1em 0; flex-wrap: wrap; }
  .card { flex: 1; min-width: 200px; padding: 1em; border-radius: 6px; border: 1px solid #ddd; }
  .card .num { font-size: 2em; font-weight: bold; }
  .card.blocker { border-color: #c62828; }
  .card.blocker .num { color: #c62828; }
  .card.warn { border-color: #ef6c00; }
  .card.warn .num { color: #ef6c00; }
  .card.info { border-color: #1976d2; }
  .card.info .num { color: #1976d2; }
  .legend { font-size: 0.85em; color: #666; }
  .next-steps { background: #f5f5f5; padding: 1em; border-left: 4px solid #0078d4; margin: 1em 0; }
  .skipped-banner { background: #fff8e1; padding: 1em 1.5em; border-left: 4px solid #ef6c00; margin: 1.5em 0; border-radius: 4px; }
  .skipped-banner h3 { margin: 0 0 0.5em 0; color: #ef6c00; }
  .skipped-banner ul { margin: 0.5em 0 0 0; }
  code { background: #f0f0f0; padding: 0.1em 0.3em; border-radius: 3px; font-size: 0.9em; }
</style>
</head>
<body>

<h1>Verified Domain Discovery Report</h1>
<p class="meta">
  <strong>Domain:</strong> $Domain<br/>
  <strong>Generated:</strong> $reportDate<br/>
  <strong>Output directory:</strong> <code>$OutputDir</code>
</p>

<div class="status-banner" style="background-color: $($readinessStatus.Color);">
  <h2>$($readinessStatus.Text)</h2>
  <p>$($readinessStatus.Description)</p>
</div>

$skippedBlock

<div class="summary-cards">
  <div class="card blocker">
    <div>Hard blocker references</div>
    <div class="num">$totalBlockers</div>
    <div class="legend">Must be cleared before domain removal succeeds</div>
  </div>
  <div class="card warn">
    <div>Soft blocker references</div>
    <div class="num">$totalWarnings</div>
    <div class="legend">Recommended to fix to avoid post-cutover issues</div>
  </div>
  <div class="card info">
    <div>Errors / warnings logged</div>
    <div class="num">$totalErrors</div>
    <div class="legend">See <code>errors.log</code> in the output directory for details</div>
  </div>
</div>

<h2>Findings by module</h2>
<table>
  <thead>
    <tr>
      <th>Module</th>
      <th>Category</th>
      <th style="text-align: right;">Findings</th>
      <th>Output file</th>
      <th>Notes</th>
    </tr>
  </thead>
  <tbody>
$findingsTableRows
  </tbody>
</table>

<details style="margin-top: 1.5em;">
  <summary style="cursor: pointer; color: #0078d4; font-weight: 600; padding: 0.5em 0;">
    Show categories with no findings
  </summary>
  <table>
    <thead>
      <tr>
        <th>Module</th>
        <th>Category</th>
        <th style="text-align: right;">Findings</th>
        <th>Output file</th>
        <th>Notes</th>
      </tr>
    </thead>
    <tbody>
$noFindingsTableRows
    </tbody>
  </table>
</details>

<h2>Recommended next steps</h2>

<div class="next-steps">
  <h3>1. Address hard blockers</h3>
  <p>Hard blockers are objects that will prevent domain removal until cleared: users, groups, app registration identifier URIs, managed identities, mailboxes, distribution lists, mail-enabled security groups, and accepted domains. For each finding, decide:</p>
  <ul>
    <li><strong>Migrate</strong> &mdash; preserve in destination tenant</li>
    <li><strong>Recreate</strong> &mdash; rebuild in destination, retire here</li>
    <li><strong>Retire</strong> &mdash; no longer needed</li>
  </ul>
  <p>Build a remediation plan with an owner and due date for each item.</p>
</div>

<div class="next-steps">
  <h3>2. Convert UPNs to .onmicrosoft.com</h3>
  <p>Per Microsoft's UPN change guidance, change all on-prem AD <code>userPrincipalName</code> values from <code>@$Domain</code> to <code>@&lt;tenant&gt;.onmicrosoft.com</code>, then trigger an Entra Connect delta sync. Pilot a small group first &mdash; this is a user-facing change. Sign-in with the old UPN stops working as soon as sync propagates, and Outlook/Teams clients will require reauthentication.</p>
</div>

<div class="next-steps">
  <h3>3. Clear Exchange-mastered objects</h3>
  <p>Mail-enabled security groups, distribution lists, and lingering proxyAddresses must be cleaned up in the Exchange Admin Center &mdash; these don't surface in Entra Connect or Graph queries directly.</p>
</div>

<div class="next-steps">
  <h3>4. Address soft blockers before cutover</h3>
  <p>Soft blockers (service principal reply URLs, Conditional Access policy references, Azure resource custom domain bindings) won't prevent domain removal but will cause downstream breakage if left alone. Update reply URLs and notification emails on service principals, edit CA policies that reference the domain, and reconfigure Azure resource custom domain bindings before cutover.</p>
</div>

<div class="next-steps">
  <h3>5. Address app-level UPN dependencies</h3>
  <p>Review the sign-in activity output (<code>09-signins-by-app.csv</code>) &mdash; the top apps by sign-in volume are your highest-priority validation targets post-UPN-change. Apps with hardcoded <code>@$Domain</code> identifiers will need configuration updates.</p>
</div>

<div class="next-steps">
  <h3>6. Verify federation status</h3>
  <p>If <code>08-federation-config.csv</code> shows <code>AuthenticationType = Federated</code>, you must convert the domain to Managed authentication (or remove the federation configuration) before the domain can be released. Most tenants are already Managed; this step is only relevant for federated configurations.</p>
</div>

<h2>Reference documentation</h2>
<ul>
  <li><a href="https://learn.microsoft.com/en-us/entra/identity/users/domains-manage">Add and verify custom domain names (Microsoft Learn)</a></li>
  <li><a href="https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/howto-troubleshoot-upn-changes">Plan and troubleshoot UPN changes</a></li>
  <li><a href="https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/plan-connect-topologies">Entra Connect: Supported topologies</a></li>
  <li><a href="https://learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-tenant-to-tenant-migrations">M365 tenant-to-tenant migrations (architecture)</a></li>
  <li><a href="https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration">Cross-tenant mailbox migration</a></li>
</ul>

<p class="meta" style="margin-top: 3em; border-top: 1px solid #eee; padding-top: 1em;">
  Generated by Verified Domain Discovery Toolkit. This is a read-only inventory &mdash; no changes were made to the tenant.
</p>

</body>
</html>
"@

# Write with explicit UTF-8 encoding (no BOM) using .NET to avoid PowerShell 5.1's
# inconsistent Out-File encoding behavior. HTML entities (&mdash; etc.) are used
# throughout the heredoc instead of literal Unicode characters to be encoding-safe
# regardless of how PowerShell tokenizes the source file.
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutputPath, $html, $utf8NoBom)
