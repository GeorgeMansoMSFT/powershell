# Verified Domain Reference Discovery Toolkit

> **Disclaimer**
>
> This is an independent, community-built tool. It is **not** affiliated with, endorsed by, or supported by Microsoft Corporation. While the author may be employed by Microsoft, this toolkit is a personal project and is not an official Microsoft product. It is not covered by any Microsoft support agreement, SLA, or warranty.
>
> The toolkit is provided **as-is**, without warranty of any kind, express or implied. Use at your own risk. Always validate findings against your own environment before taking action based on the output.
>
> For official Microsoft guidance on tenant migrations and domain management, refer to [Microsoft Learn](https://learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-tenant-to-tenant-migrations) or engage Microsoft Consulting Services / a Microsoft partner.

Pre-flight discovery for releasing a verified custom domain from an Entra ID tenant. Identifies every object, configuration, and Azure resource that references the domain, so you can clear references before attempting domain removal.

## What problem this solves

Microsoft's domain removal logic blocks deletion if any object still references the domain — but the portal only tells you the *category* of blocker, not the specific offending objects. ForceDelete exists as an emergency option but auto-rewrites references to `.onmicrosoft.com` with no rollback, no pilot, and no user comms window. Neither path is suitable for a planned tenant migration.

This toolkit gives you a complete inventory of what references the domain, so you can plan a controlled cleanup before the actual removal.

## Discovery scope

The toolkit scans 11 categories across three Microsoft cloud surfaces:

**Microsoft Graph (identity)**
- Users — UPN, mail, proxyAddresses, otherMails (including guests with mangled UPNs)
- Groups — M365 groups, distribution lists, mail-enabled security groups
- App registrations — redirect URIs, identifier URIs, logout URLs, home page URLs
- Service principals — reply URLs, login/logout URLs, notification emails
- Managed identities — display names (federated credentials covered by Azure module)
- Conditional Access policies — any reference to the domain in policy JSON
- Federation configuration — federated vs. managed authentication
- Sign-in activity — last 30 days of UPNs and apps actively using the domain
- Soft-deleted users — recycle bin objects that block UPN reuse for up to 30 days

**Exchange Online**
- Accepted domains, mailboxes, distribution groups, mail contacts, mail users
- Transport rules and inbound/outbound connectors that reference the domain

**Azure Resource Manager**
- Custom domain bindings on App Service, APIM, Front Door, Application Gateway
- Resource display names containing the domain
- Resource tags containing the domain
- App Service settings and connection strings containing the domain
- Azure Resource Graph broad search across all resource types

## Architecture notes

**Isolated worker processes.** The toolkit runs Microsoft Graph, Exchange Online, and Azure discovery in separate PowerShell worker processes. This keeps the Microsoft.Graph, ExchangeOnlineManagement, and Az module stacks from sharing loaded assemblies in one session.

**Toolkit-local dependency cache.** The orchestrator uses `dependencies.lock.json` to download exact tested module versions into `.\.runtime\modules` on first run. It prepends that local cache to `PSModulePath` only for the current process and worker children. It does not install modules globally, update customer modules, or modify the user's PowerShell profile.

**Read-only.** The toolkit makes no modifications. It only enumerates and reports.

**Output formats.** Each module writes its own CSV. The orchestrator generates a consolidated HTML readiness report and a machine-readable JSON inventory summary.

## Prerequisites

- **Windows PowerShell 5.1** or **PowerShell 7+**. PowerShell 7+ is preferred when available.
- **PowerShell Gallery access** for first-run dependency hydration, or the offline dependency pack from the release page.
- **Roles**: Global Reader is sufficient for read-only discovery across Graph + Exchange Online. Reader on Azure subscriptions is sufficient for Azure resource discovery.

No global `Install-Module` step is required. On first run, the toolkit downloads the exact module versions listed in `dependencies.lock.json` into `.\.runtime\modules`, validates their manifest hashes, then launches the discovery workers. If PowerShell Gallery is blocked, extract `domain-migration-toolkit-dependencies.zip` beside `Run-AllDiscovery.ps1` so `.\.runtime\modules` exists, then re-run.

## Authentication behavior

You will be prompted to authenticate up to three times in a fresh session:

1. **Microsoft Graph** — when the isolated Graph worker starts
2. **Exchange Online** — when the isolated EXO worker starts, if selected
3. **Azure** — when the isolated Azure worker starts, if selected

Windows uses the Web Account Manager (WAM) broker for these prompts. WAM is enabled by default in current Microsoft.Graph versions and cannot be disabled. The WAM dialog has two quirks worth knowing:

- It defaults to showing personal Microsoft accounts. Click **"Work or school account"** if you don't see the right account listed.
- After signing in, it asks **"Sign in to all apps and websites on this device?"** — click **"No, this app only"** unless you specifically want to register the admin account to the device.

After the first sign-in, WAM caches the broker token at the OS level. Subsequent runs in the same Windows session typically auth silently with no prompts.

## Quick start

```powershell
# 1. Edit configuration
notepad config.ps1
# Set $DomainToInvestigate to the domain you're investigating
# (Output path defaults to ./output/<timestamp> next to the orchestrator)

# 2. Run the orchestrator
.\Run-AllDiscovery.ps1
```

The first run may spend 5-10 minutes downloading the local dependency cache, especially if Azure discovery is enabled. Later runs reuse the cache. The orchestrator handles connection prompts and module sequencing automatically. Total discovery time on a small tenant after dependencies are ready: ~1-3 minutes. Larger tenants take proportionally longer (mostly the EXO mailbox scan).

## Configuration options

Edit `config.ps1`:

```powershell
$DomainToInvestigate = "contoso.com"        # The domain to investigate
$OutputPath          = "<auto>"             # Defaults to ./output/<timestamp>
$SignInLookbackDays  = 30                   # Max 30 via Graph (use Sentinel for more)
$IncludeExchangeOnline = $null              # $null = prompt, $true = force, $false = skip
$IncludeAzureResources = $null              # Same semantics
$IncludeGuests       = $true                # Include guest users
$WriteJsonSummary    = $true                # Machine-readable summary alongside CSVs
```

For unattended runs, set `$IncludeExchangeOnline = $true` and `$IncludeAzureResources = $true` to skip the interactive prompts (Connect-ExchangeOnline and Connect-AzAccount will still prompt for auth interactively).

## Runtime controls

```powershell
# Re-download and re-validate locked dependencies
.\Run-AllDiscovery.ps1 -ForceRuntimeRefresh

# Require an already-present local/offline runtime; do not download anything
.\Run-AllDiscovery.ps1 -NoDependencyDownload

# Build the optional offline dependency pack for release distribution
.\tools\New-OfflineDependencyPack.ps1
```

## Output files

Each run creates a timestamped directory containing:

| File | Contents |
|---|---|
| `Summary-Report.html` | Human-readable readiness report with severity-coded findings |
| `inventory-summary.json` | Machine-readable rollup of counts and metadata |
| `errors.log` | Any module errors encountered during the run |
| `00-graph-worker-status.json` | Status summary from the isolated Graph worker |
| `06-exchange-worker-status.json` | Status summary from the isolated Exchange worker |
| `01-users-on-domain.csv` | Users with UPN/mail/proxy on the domain |
| `02-groups-on-domain.csv` | Groups with mail/proxy on the domain |
| `03-app-registrations-on-domain.csv` | App regs with redirect URIs, identifier URIs, etc. |
| `04-service-principals-on-domain.csv` | SPs with reply URLs, notification emails |
| `05-managed-identities-on-domain.csv` | UAMI display name matches |
| `06-exchange-*.csv` | Mailboxes, DLs, contacts, transport rules, connectors, accepted domains |
| `07-conditional-access-on-domain.csv` | CA policies referencing the domain |
| `08-federation-config.csv` | Federation status (Managed vs. Federated) |
| `09-signins-by-user.csv` / `09-signins-by-app.csv` | Sign-in activity aggregations |
| `10-soft-deleted-on-domain.csv` | Recycle bin objects still holding the UPN |
| `11-azure-custom-domains.csv` | Azure resource custom domain bindings |
| `11-azure-resource-names.csv` | Azure resources with the domain in their name |
| `11-azure-resource-tags.csv` | Azure resources with the domain in their tags |
| `11-azure-app-config.csv` | App Service settings/connection strings with the domain |
| `11-azure-resource-graph.csv` | Broad Resource Graph search hits |
| `11-azure-managed-identity-fedcreds.csv` | User-assigned managed identity federated credentials referencing the domain |
| `11-azure-status.json` | Status file from the child Az process |

## Severity model

The HTML report categorizes findings:

- **Hard blockers** — Will prevent domain removal until cleared. Includes users, groups, app reg identifier URIs, mailboxes, accepted domains, federated configuration. Must be remediated before standard domain removal succeeds.
- **Soft blockers** — Will not prevent domain removal but will cause downstream breakage. Includes service principal reply URLs, notification emails, Azure resource custom domain bindings, Conditional Access policy references.
- **Informational** — Sign-in activity (helps prioritize app validation), soft-deleted users (UPN reuse blockers for up to 30 days).

The status banner reads READY, REVIEW, or NOT READY based on hard-blocker count.

## Limitations

The toolkit does not currently cover:

- **SharePoint Online** site URLs and sharing settings (requires SPO Management Shell)
- **Power Platform** environments and connectors (requires Power Platform PowerShell)
- **Intune** customization with the domain in notification templates
- **Third-party SaaS apps** with the domain hardcoded as user identifier (sign-in activity report helps identify these but is not comprehensive)
- **Sign-in activity beyond 30 days** (Graph API limit; use Sentinel `SigninLogs` + `AADNonInteractiveUserSignInLogs` for longer history)
- **Non-interactive sign-ins** (only interactive sign-ins; non-interactive requires Sentinel access)

For a tenant with significant SharePoint/Power Platform/Intune surface, plan supplementary discovery in those areas.

## Troubleshooting

**First run appears to pause while downloading dependencies**
The toolkit is hydrating `.\.runtime\modules` with the exact module versions in `dependencies.lock.json`. This can take 5-10 minutes on slower networks, especially with Azure discovery enabled. The bootstrapper prints per-module progress; let it finish unless it reports a failure.

**"PowerShell Gallery is not reachable"**
The customer network may block `www.powershellgallery.com` or TLS/provider setup may be broken on the workstation. Use the offline dependency pack: download `domain-migration-toolkit-dependencies.zip` from the release page, extract it beside `Run-AllDiscovery.ps1`, and re-run.

**"Toolkit runtime cache is incomplete and -NoDownload was specified"**
`.\.runtime\modules` is missing one or more locked dependencies. Either allow the toolkit to download dependencies, or extract the offline dependency pack before running with `-NoDependencyDownload`.

**"Import validation failed for dependency group ..."**
The local runtime cache exists but at least one module cannot be imported in a clean worker process. Re-run with `-ForceRuntimeRefresh`, or delete `.\.runtime` and run again. If PowerShell Gallery is blocked, refresh the offline dependency pack.

**"InteractiveBrowserCredential authentication failed: User canceled authentication"**
A WAM dialog was dismissed or timed out. Re-run the orchestrator. If the issue persists, close all PowerShell windows (to clear in-process auth state) and try again from a fresh session.

**"SharedTokenCacheCredential authentication unavailable. No accounts were found in the cache."**
Stale Az context detected. The Azure worker catches this and re-prompts interactively. If it persists, run `Clear-AzContext -Force` and try again.

**Az scan returns 0 subscriptions despite having access**
The account may not have Reader on any subscriptions, or the local Az runtime failed to authenticate. Check `errors.log` and `11-azure-status.json`. The toolkit does not rely on globally installed Az modules.

**Exchange Online scan times out on large tenants**
The mailbox enumeration (`Get-Mailbox -ResultSize Unlimited`) can take 10+ minutes on tenants with thousands of mailboxes. This is normal. The orchestrator does not have a built-in timeout, so let it run.

**Sign-in activity returns 0 events but the domain is in active use**
The Graph sign-in API only returns interactive sign-ins. Non-interactive activity (refresh token use, background app auth) is in `AADNonInteractiveUserSignInLogs` and requires Sentinel/Log Analytics access.

## Security notes

- The toolkit acquires interactive auth tokens via standard Microsoft authentication flows.
- Tokens are held in memory for the duration of the run and are not persisted to disk by the toolkit.
- The toolkit does not call `Enable-AzContextAutosave` or any other persistence mechanism. WAM's broker cache is OS-level and outside the toolkit's control.
- Graph, Exchange Online, and Azure discovery run in separate PowerShell worker processes with independent authentication. No tokens are passed between processes.
- The local dependency cache contains Microsoft PowerShell modules from PowerShell Gallery. It is stored under `.\.runtime\modules` and can be deleted at any time; the toolkit will recreate it on the next run.
- All output files are written to the local filesystem only. Nothing is uploaded or transmitted off-machine.
