# Entra authentication posture report

This package reports each Entra user's strongest registered authentication
method and the strongest authentication method **explicitly observed** in
successful interactive sign-ins. It is designed for customer posture reviews,
not as a real-time access-control engine.

## What it does

The report joins two Microsoft Graph data sources:

| Data source | Purpose |
| --- | --- |
| `v1.0/reports/authenticationMethods/userRegistrationDetails` | Registered methods, MFA/passwordless capability, user type, and admin flag. |
| `beta/auditLogs/signIns` | Successful interactive sign-in authentication steps and MFA requirement evidence within a selected window. |

The script applies a transparent strength-scoring policy and produces
registration posture, explicit sign-in evidence coverage, and review cues. It
does not make changes to Entra, users, methods, policies, or Conditional Access.

## Support model

The package intentionally keeps dependencies small.

| Capability | Supported configuration | Dependency |
| --- | --- | --- |
| Core CSV reporting | Windows PowerShell 5.1 or PowerShell 7 | `Microsoft.Graph.Authentication` 2.x |
| Entra sign-in evidence | Core reporting plus Entra sign-in-log access | `AuditLog.Read.All`, suitable Entra role, and sign-in-log availability |
| XLSX and PDF packaging | Windows with desktop Excel | Native Excel COM automation; no added PowerShell module |

CSV reporting is the core deliverable. Excel/PDF packaging is optional: if
desktop Excel is unavailable, the report still creates the CSV files and emits a
clear warning.

## Preflight before customer use

Run the local-only check first:

```powershell
.\Test-EntraAuthPosturePrerequisites.ps1
```

Run the full read-only tenant check before an engagement:

```powershell
.\Test-EntraAuthPosturePrerequisites.ps1 -TestGraphAccess
```

The preflight checks PowerShell, the Graph authentication module, output-folder
write access, optional Excel availability, and—when requested—signs in and tests
the two Graph endpoints used by the report. It does not modify the tenant. Add
`-OutputPath .\output\preflight-results.csv` to save the results for a support case.

The preflight and report use the standard interactive Microsoft Graph sign-in
experience. Device code flow is intentionally not used or recommended by this
package; many customers block it because it can be abused in phishing attacks.

## Requirements

### Workstation

- Windows PowerShell 5.1 or PowerShell 7 for the supported core workflow.
- Network access to Microsoft Graph.
- Microsoft Graph PowerShell Authentication module 2.x:

  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```

- Desktop Excel is optional and only required by `-PackageDeliverables`.

### Entra access

The operator needs delegated `AuditLog.Read.All` and an appropriate Entra role,
such as Reports Reader, Security Reader, Security Administrator, or Global
Reader. Customer licensing and retention determine whether sign-in evidence is
available. The registration report and sign-in APIs can also be restricted by
customer tenant policy.

## Run the report

Basic 30-day report:

```powershell
.\Export-EntraStrongestAuthMethodReport.ps1 -DaysBack 30 -Verbose
```

By default, all report outputs are written to the package's `output` folder.
The folder is created automatically and is excluded from Git.

Specify a tenant, exclude B2B guests, and use a selected output path:

```powershell
.\Export-EntraStrongestAuthMethodReport.ps1 `
  -TenantId contoso.onmicrosoft.com `
  -IncludeGuests $false `
  -OutputPath C:\Reports\Entra-AuthPosture.csv
```

Create the customer workbook and executive-summary PDF when desktop Excel is
available:

```powershell
.\Export-EntraStrongestAuthMethodReport.ps1 -DaysBack 30 -PackageDeliverables $true
```

Registration-only fallback (skips the beta sign-in query):

```powershell
.\Export-EntraStrongestAuthMethodReport.ps1 -IncludeSignInActivity $false
```

## Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `DaysBack` | `30` | Number of calendar days of interactive sign-ins to evaluate. |
| `OutputPath` | Timestamped CSV in `output` | Per-user posture CSV location. The containing folder is created if needed. |
| `TenantId` | Current tenant | Tenant GUID or domain used when signing in. |
| `IncludeGuests` | `true` | Includes B2B guests; use `$false` for members only. |
| `IncludeSignInActivity` | `true` | Reads beta sign-ins for explicit-method evidence; set `$false` for registration-only reporting. |
| `ExportEvidence` | `true` | Creates the restricted evidence CSV when classifiable methods are observed. |
| `PackageDeliverables` | `false` | Creates the XLSX workbook and executive PDF through optional desktop Excel automation. |
| `SignInQueryChunkHours` | `24` | Retrieves sign-ins in bounded time chunks. Reduce for exceptionally high-volume tenants. |
| `GraphMaxRetryAttempts` | `6` | Retry limit for throttling and transient Graph service failures. |
| `MaxEvidenceRowsInWorkbook` | `100000` | XLSX evidence-sheet ceiling. The complete restricted CSV is retained when this limit is exceeded. Set `0` to always omit that worksheet. |

## Outputs

| Output | Audience | Contents |
| --- | --- | --- |
| `Entra-AuthPosture-*.csv` | Security/operations | One row per reported user; registration, observation, capability, and coverage fields. |
| `*-summary.csv` | Operations/automation | Numeric tier distribution and separate evidence coverage fields. |
| `*-evidence.csv` | Restricted technical/audit audience | Source sign-in IDs, raw authentication steps, app, IP, and device metadata for explicit-method findings. |
| `*.xlsx` | Customer operations | Overview, Review Queue, User Posture, Evidence - Restricted, and Scoring Guide sheets. |
| `*-executive-summary.pdf` | Leadership | One-page posture summary and interpretation notes. |

Existing XLSX and PDF output files are never overwritten; the packaging helper
adds a numeric suffix instead. Source CSVs are always retained.

## Large-tenant behavior

The CSV outputs are the scalable, complete deliverable. Registration results are
paged, and sign-ins are retrieved in 24-hour chunks by default; each Graph page
can contain up to 1,000 sign-in records. Transient Graph throttling and service
errors are retried using `Retry-After` when available, otherwise exponential
backoff is used. Restricted evidence is streamed directly to its CSV as it is
processed, rather than accumulated in PowerShell memory.

For high-volume tenants, start with a 1- or 7-day window, validate timing and
evidence coverage, then expand the window. Use a smaller
`-SignInQueryChunkHours` value if a chunk is slow or repeatedly throttled.

Excel/PDF packaging is intentionally secondary to CSV at scale. The packager
uses bulk Excel writes and skips expensive AutoFit on large tables. If the
restricted evidence CSV exceeds `MaxEvidenceRowsInWorkbook`, the workbook omits
the Evidence - Restricted sheet and identifies that fact in its Overview; the
complete evidence CSV remains available to authorized technical/audit users.


## How to interpret the fields

### Registered strength

`StrongestRegisteredMethod` is the highest-scoring currently registered method.
The scoring policy is visible in the script and workbook:

| Score | Method group |
| ---: | --- |
| 100 | FIDO2 security key / passkey |
| 95 | Windows Hello for Business |
| 90 | Certificate-based authentication |
| 85 | Microsoft Authenticator passwordless |
| 50-70 | Authenticator push, OATH, or Temporary Access Pass |
| 30 | SMS or voice |
| 10-20 | Email, password, or security question |

These are customer-reporting policy scores, not official Microsoft assurance
levels. Adjust `ConvertTo-AuthMethod` if the customer's approved authentication
method policy uses a different ordering.

### Explicitly observed strength

`StrongestExplicitlyObservedMethod` is not called “method used” deliberately. It
is the strongest successful, classifiable authentication step returned in the
selected sign-in window. `ExplicitMethodEvidenceCoverage` gives the number and
percentage of successful interactive sign-ins that contained such a method.

A missing explicit method does **not** mean the user did not authenticate or did
not use MFA. Existing token/session claims can satisfy a sign-in without a fresh
factor in that event. Treat `RegistrationVsObservation` as a review cue, not an
automatic compliance failure.

## Limitations and operating notes

- Registered-method data uses Microsoft Graph v1.0. Authentication-step detail
  uses Microsoft Graph beta, which Microsoft can change without production API
  guarantees.
- The report assesses successful interactive sign-ins only. It does not evaluate
  service-principal, managed-identity, or non-interactive activity.
- Sign-in evidence is bounded by tenant retention. Entra Free commonly provides
  seven days of sign-in retention; P1/P2 commonly provide 30 days. Archive logs
  before expiry for longer trend reporting.
- The registration report does not return disabled users. Classify service,
  break-glass, test, B2B, and privileged/PIM identities before presenting flags
  as remediation findings.
- `IsAdmin` is not a complete privileged-identity inventory. For mature reports,
  enrich the data with PIM eligible/active roles and other privileged-role data.

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Module not found | Graph Authentication module is absent or blocked by customer software policy | Run the preflight; install or pre-stage only `Microsoft.Graph.Authentication`. |
| Browser sign-in is hidden or blocked | WAM/embedded terminal behavior | Run from a supported interactive desktop PowerShell session; do not weaken tenant policy by enabling device code flow for this tool. |
| Sign-in pass fails | Missing Graph consent, Entra role, licensing, retention, or beta restriction | Run `-IncludeSignInActivity $false` for registration-only posture and attach preflight results for support. |
| No explicit method observed | Token/session reuse or no successful interactive sign-in | Review evidence coverage; do not report this as no MFA. |
| No XLSX/PDF | Excel is not installed or cannot start | CSVs are still complete; run the packager from a Windows workstation with desktop Excel. |

## Microsoft references

- [Microsoft Graph user registration details](https://learn.microsoft.com/en-us/graph/api/authenticationmethodsroot-list-userregistrationdetails?view=graph-rest-1.0)
- [Microsoft Graph authentication detail (beta)](https://learn.microsoft.com/en-us/graph/api/resources/authenticationdetail?view=graph-rest-beta)
- [Microsoft Graph PowerShell authentication](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands?view=graph-powershell-1.0)
- [Microsoft Entra data retention](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/reference-reports-data-retention)
