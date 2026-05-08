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

**Two PowerShell processes.** The toolkit runs Microsoft Graph and Az PowerShell in separate processes. This is required because the two SDKs depend on conflicting versions of the `Azure.Identity` assembly and cannot coexist in a single PowerShell session. The orchestrator handles this transparently — the Azure resource scan launches a child PowerShell at the end of the run.

**Read-only.** The toolkit makes no modifications. It only enumerates and reports.

**Output formats.** Each module writes its own CSV. The orchestrator generates a consolidated HTML readiness report and a machine-readable JSON inventory summary.

## Prerequisites

- **Windows PowerShell 5.1** (or PowerShell 7+; both work)
- **Microsoft Graph PowerShell**: `Install-Module Microsoft.Graph -Scope CurrentUser`
- **Exchange Online Management**: `Install-Module ExchangeOnlineManagement -Scope CurrentUser`
- **Az PowerShell** (for Azure resource discovery): `Install-Module Az -Scope CurrentUser`
- **Roles**: Global Reader is sufficient for read-only discovery across Graph + Exchange Online. Reader on Azure subscriptions is sufficient for Azure resource discovery.

If you have multiple versions of Microsoft.Graph installed, the toolkit auto-detects the highest complete version and pins to it for the run. If no complete version is available, you'll get a clear error directing you to install Microsoft.Graph.

## Authentication behavior

You will be prompted to authenticate up to three times in a fresh session:

1. **Microsoft Graph** — at orchestrator start
2. **Exchange Online** — when the EXO scan begins (skip with `n` to bypass)
3. **Azure** — in the child process when the Az scan begins (skip with `n` to bypass)

Windows uses the Web Account Manager (WAM) broker for these prompts. WAM is enabled by default in current Microsoft.Graph versions and cannot be disabled. The WAM dialog has two quirks worth knowing:

- It defaults to showing personal Microsoft accounts. Click **"Work or school account"** if you don't see the right account listed.
- After signing in, it asks **"Sign in to all apps and websites on this device?"** — click **"No, this app only"** unless you specifically want to register the admin account to the device.

After the first sign-in, WAM caches the broker token at the OS level. Subsequent runs in the same Windows session typically auth silently with no prompts.

## Quick start

```powershell
# 1. Install required modules (one-time)
Install-Module Microsoft.Graph        -Scope CurrentUser -Force
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
Install-Module Az                       -Scope CurrentUser -Force

# 2. Edit configuration
notepad config.ps1
# Set $DomainToInvestigate to the domain you're investigating
# (Output path defaults to ./output/<timestamp> next to the orchestrator)

# 3. Run the orchestrator
.\Run-AllDiscovery.ps1
```

The orchestrator handles connection prompts and module sequencing automatically. Total run time on a small tenant: ~1-3 minutes. Larger tenants take proportionally longer (mostly the EXO mailbox scan).

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

## Output files

Each run creates a timestamped directory containing:

| File | Contents |
|---|---|
| `Summary-Report.html` | Human-readable readiness report with severity-coded findings |
| `inventory-summary.json` | Machine-readable rollup of counts and metadata |
| `errors.log` | Any module errors encountered during the run |
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

**"Could not load file or assembly 'Microsoft.Graph.Authentication, Version=...'"**
Multiple versions of the Graph SDK are installed and conflicting. Run `Get-Module Microsoft.Graph* -ListAvailable | Group-Object Version` — if you see multiple versions, do a clean reinstall (uninstall all, install one). The orchestrator's pinning logic will handle most cases automatically, but truly mixed installs need manual cleanup.

**"InteractiveBrowserCredential authentication failed: User canceled authentication"**
A WAM dialog was dismissed or timed out. Re-run the orchestrator. If the issue persists, close all PowerShell windows (to clear in-process auth state) and try again from a fresh session.

**"SharedTokenCacheCredential authentication unavailable. No accounts were found in the cache."**
Stale Az context detected. The toolkit catches this and re-prompts interactively in the child process. If you see this in the parent's modules, run `Clear-AzContext -Force` and try again.

**Az scan returns 0 subscriptions despite having access**
Likely the Azure.Identity assembly conflict between Az and Graph. The toolkit runs Az in a separate child process specifically to avoid this. If you still hit it, ensure you have an up-to-date Az module set: `Update-Module Az -Force`.

**Exchange Online scan times out on large tenants**
The mailbox enumeration (`Get-Mailbox -ResultSize Unlimited`) can take 10+ minutes on tenants with thousands of mailboxes. This is normal. The orchestrator does not have a built-in timeout, so let it run.

**Sign-in activity returns 0 events but the domain is in active use**
The Graph sign-in API only returns interactive sign-ins. Non-interactive activity (refresh token use, background app auth) is in `AADNonInteractiveUserSignInLogs` and requires Sentinel/Log Analytics access.

## Security notes

- The toolkit acquires interactive auth tokens via standard Microsoft authentication flows.
- Tokens are held in memory for the duration of the run and are not persisted to disk by the toolkit.
- The toolkit does not call `Enable-AzContextAutosave` or any other persistence mechanism. WAM's broker cache is OS-level and outside the toolkit's control.
- The Az resource scan runs in a separate PowerShell process with its own independent authentication. No tokens are passed between processes.
- All output files are written to the local filesystem only. Nothing is uploaded or transmitted off-machine.
