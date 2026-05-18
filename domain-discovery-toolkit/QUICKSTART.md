# Quick start

## First-time setup

No global PowerShell module install is required.

On first run, the toolkit downloads exact tested Microsoft module versions into:

```text
.\.runtime\modules
```

This local cache does not modify your PowerShell profile and does not install modules into `CurrentUser` or `AllUsers`. The first dependency download can take 5-10 minutes, especially if Azure discovery is enabled.

The toolkit validates the cached module versions and manifest hashes before launching any discovery worker.

If PowerShell Gallery is blocked in your environment, use the offline dependency pack from the release page. Extract `domain-migration-toolkit-dependencies.zip` beside `Run-AllDiscovery.ps1` so `.\.runtime\modules` exists, then re-run the toolkit.

## Configure

Edit `config.ps1`:

```powershell
$DomainToInvestigate = "contoso.com"   # The domain you intend to release
```

Output goes to `./output/<timestamp>` next to the orchestrator by default.

## Run

```powershell
cd <toolkit folder>
.\Run-AllDiscovery.ps1
```

## What to expect

The orchestrator walks through these phases:

1. **Scope prompts** — asks whether to include Exchange Online and Azure resources. Default Yes.
2. **Runtime check** — validates `.\.runtime\modules` against `dependencies.lock.json`.
3. **First-run download** — downloads missing exact module versions from PowerShell Gallery, with per-module progress.
4. **Graph worker** — launches an isolated process, prompts for Graph auth, and runs identity modules.
5. **Exchange worker** — launches an isolated process if selected, prompts for EXO auth, and runs Exchange discovery.
6. **Azure worker** — launches an isolated process if selected, prompts for Azure auth, and runs Azure resource discovery.
7. **HTML report** — generated at the end, opens in your default browser if you double-click it.

Total runtime on a small tenant: 1-3 minutes. Larger tenants take longer (mostly the EXO mailbox enumeration).

## Authentication count

You may see up to three authentication dialogs:

- **Graph** when the isolated Graph worker starts
- **Exchange Online** when the isolated EXO worker starts, if selected
- **Azure** when the isolated Azure worker starts, if selected

After the first authentication on a workstation, WAM (Windows' broker) caches the token at the OS level. Subsequent runs in the same Windows session usually have zero or one prompts.

WAM dialogs default to showing personal Microsoft accounts. If your work account doesn't appear, click "Work or school account" at the bottom. If asked "Sign in to all apps and websites on this device?", click **"No, this app only"**.

## Outputs

Inside the timestamped output directory:

- `Summary-Report.html` — open this first, it summarizes everything
- `inventory-summary.json` — same data as a JSON blob for tooling
- `errors.log` — anything that went wrong during the run
- `01-users-on-domain.csv` through `11-azure-*.csv` — detailed findings per module
- `00-graph-worker-status.json`, `06-exchange-worker-status.json`, `11-azure-status.json` — worker status files used by the report generator

## Running individual modules

If you only need one slice (e.g., just Azure resources):

```powershell
. .\config.ps1
& .\modules\11-AzureResources.ps1 -Domain $DomainToInvestigate -OutputPath $OutputPath -ToolkitRoot (Get-Location).Path
```

Modules 01-10 are normally run through the Graph and Exchange worker scripts so the locked local runtime is loaded first. Direct module runs are mainly for development and troubleshooting.

## Permissions cheat sheet

| Module | Required role / permissions |
|---|---|
| 01–05, 07, 08, 10 | Global Reader (or Directory.Read.All + Application.Read.All + Policy.Read.All + Domain.Read.All) |
| 06 | View-Only Recipients in Exchange Online |
| 09 | AuditLog.Read.All + Entra ID P1 (sign-in logs require P1) |
| 11 | Reader role on the Azure subscriptions you want scanned |

Global Reader covers everything except Exchange Online and Azure. For the simplest setup: Global Reader in Entra + Reader on subscriptions + a role with Exchange recipient view permissions.

## Unattended runs

For scheduled or pipeline execution, set in `config.ps1`:

```powershell
$IncludeExchangeOnline = $true   # No prompt; will call Connect-ExchangeOnline
$IncludeAzureResources = $true   # No prompt; Azure worker will call Connect-AzAccount
```

The interactive auth prompts (Connect-MgGraph, Connect-ExchangeOnline, Connect-AzAccount) still fire — they're separate from the toolkit's own scope prompts. For fully unattended auth, you'd need to use service principal authentication, which requires modifications to the orchestrator (out of scope for this toolkit).

## Runtime controls

```powershell
# Re-download and re-validate locked dependencies
.\Run-AllDiscovery.ps1 -ForceRuntimeRefresh

# Do not download anything; fail if the local/offline runtime is incomplete
.\Run-AllDiscovery.ps1 -NoDependencyDownload
```

To build the offline dependency pack for a release:

```powershell
.\tools\New-OfflineDependencyPack.ps1
```

## Troubleshooting one-liner

If something goes sideways and you want to start fresh:

```powershell
# Disconnect everything
Disconnect-MgGraph -ErrorAction SilentlyContinue
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Disconnect-AzAccount -ErrorAction SilentlyContinue

# Close PowerShell completely, reopen, then re-run the orchestrator
```

For deeper troubleshooting see `README.md`.
