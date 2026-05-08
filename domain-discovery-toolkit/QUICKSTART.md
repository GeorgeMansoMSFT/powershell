# Quick start

## First-time setup

```powershell
# Install required modules (one-time, may take 5-10 minutes)
Install-Module Microsoft.Graph        -Scope CurrentUser -Force
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
Install-Module Az                       -Scope CurrentUser -Force
```

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

1. **Module pinning** — auto-detects your installed Graph version and pins to it.
2. **Graph auth** — opens a Microsoft sign-in dialog. Choose "Work or school account" and sign in with an account that has Global Reader (or higher).
3. **Exchange Online prompt** — asks if you want to include EXO discovery. Default Yes. If yes, prompts for EXO auth.
4. **Azure prompt** — asks if you want to include Azure resource discovery. Default Yes. Auth happens later in the child process.
5. **Modules 01-10** — run sequentially in-process. Each prints findings as it goes.
6. **Module 11 (Azure)** — launches a separate PowerShell process. Auth dialog appears for Azure. Resource Graph + per-subscription deep scan runs.
7. **HTML report** — generated at the end, opens in your default browser if you double-click it.

Total runtime on a small tenant: 1-3 minutes. Larger tenants take longer (mostly the EXO mailbox enumeration).

## Authentication count

You may see up to three authentication dialogs:

- **Graph** at orchestrator start
- **Exchange Online** at the EXO connect step
- **Azure** in the child process

After the first authentication on a workstation, WAM (Windows' broker) caches the token at the OS level. Subsequent runs in the same Windows session usually have zero or one prompts.

WAM dialogs default to showing personal Microsoft accounts. If your work account doesn't appear, click "Work or school account" at the bottom. If asked "Sign in to all apps and websites on this device?", click **"No, this app only"**.

## Outputs

Inside the timestamped output directory:

- `Summary-Report.html` — open this first, it summarizes everything
- `inventory-summary.json` — same data as a JSON blob for tooling
- `errors.log` — anything that went wrong during the run
- `01-users-on-domain.csv` through `11-azure-*.csv` — detailed findings per module

## Running individual modules

If you only need one slice (e.g., just Azure resources):

```powershell
. .\config.ps1
& .\modules\11-AzureResources.ps1 -Domain $DomainToInvestigate -OutputPath $OutputPath
```

Modules 01-10 require Graph (and 06 requires EXO) to be connected first via `Connect-MgGraph` and `Connect-ExchangeOnline`. Module 11 is self-contained.

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
$IncludeAzureResources = $true   # No prompt; child process will call Connect-AzAccount
```

The interactive auth prompts (Connect-MgGraph, Connect-ExchangeOnline, Connect-AzAccount) still fire — they're separate from the toolkit's own scope prompts. For fully unattended auth, you'd need to use service principal authentication, which requires modifications to the orchestrator (out of scope for this toolkit).

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
