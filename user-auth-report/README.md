# Entra authentication methods report (scalable alternative)

`Get-EntraAuthMethodReport.ps1` builds a per-user list of registered authentication methods for a whole Entra ID tenant. It is a stand-in for the Entra **User registration details** report while that report is missing some users.

It reads each user's methods directly from `/users/{id}/authentication/methods`, the same data shown on the user's **Security info** page and the user blade in the Entra admin center. It does not read the report.

> **See it first:** [open the example report](https://georgemansomsft.github.io/powershell/user-auth-report/Example/AuthMethodReport_example.html). It shows 500 made-up `contoso.test` users. The example files are also in [`Example/`](Example/).

## Contents

- [Requirements](#requirements)
- [Usage](#usage)
- [Parameters](#parameters)
- [Output](#output)
- [Recommended rollout](#recommended-rollout)
- [Known limitations](#known-limitations)
- [Appendix A: How it works](#appendix-a-how-it-works)
- [Appendix B: Security review](#appendix-b-security-review)
- [Appendix C: Testing](#appendix-c-testing)

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- `Microsoft.Graph.Authentication` 2.x. This is the only Graph module needed; the full SDK isn't required.

  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```

- A tenant in the Global, US Government L4 (GCC High) or US Government L5 (DoD) cloud. The China (21Vianet) cloud isn't supported, because the authentication methods API isn't available there.
- Permissions:

| Run as | Graph permissions | Entra role (delegated only) |
|---|---|---|
| Signed-in admin (interactive) | `User.Read.All`, `UserAuthenticationMethod.Read.All` (+ `AuditLog.Read.All` for `-CompareWithReport`) | **Global Reader** covers everything. Authentication Administrator can read methods but only sees masked phone numbers. For `-CompareWithReport`, the account also needs Reports Reader, Security Reader, Security Administrator or Global Reader. |
| Managed identity / app + certificate | Application: `User.Read.All`, `UserAuthenticationMethod.Read.All` (+ `AuditLog.Read.All` for `-CompareWithReport`) | n/a |

`-GroupId` also needs `GroupMember.Read.All`. In interactive mode the script asks for it automatically. For an app or managed identity, add it to the permissions you grant.

## Usage

### Interactive (first test)

```powershell
.\Get-EntraAuthMethodReport.ps1 -TenantId contoso.onmicrosoft.com -CompareWithReport -MaxUsers 500
```

Remove `-MaxUsers` to run against the whole tenant.

### App registration with a certificate

```powershell
.\Get-EntraAuthMethodReport.ps1 -TenantId <tenantId> -ClientId <appId> -CertificateThumbprint <thumbprint> -CompareWithReport
```

For a US Government tenant, add `-GraphEndpoint https://graph.microsoft.us` (GCC High) or `-GraphEndpoint https://dod-graph.microsoft.us` (DoD).

### Scheduled nightly run in Azure Automation (managed identity)

1. Create an Automation account with a **PowerShell 7.2+** runtime and enable its system-assigned managed identity.
2. Import the `Microsoft.Graph.Authentication` module into the account.
3. Grant the identity Graph application permissions. A Global Administrator or Privileged Role Administrator must run this once:

   ```powershell
   Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
   $miObjectId = '<managed identity object (principal) id>'
   $graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
   foreach ($perm in 'User.Read.All','UserAuthenticationMethod.Read.All','AuditLog.Read.All') {
       $role = $graph.AppRoles | Where-Object { $_.Value -eq $perm -and $_.AllowedMemberTypes -contains 'Application' }
       New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miObjectId -PrincipalId $miObjectId -ResourceId $graph.Id -AppRoleId $role.Id
   }
   ```

   `New-MgServicePrincipalAppRoleAssignment` is in the `Microsoft.Graph.Applications` module.
4. Import the script as a runbook and run it with:

   ```powershell
   -ManagedIdentity -CompareWithReport -OutputPath $env:TEMP
   ```

5. Copy the output files to durable storage, such as a storage account or SharePoint. Automation sandboxes are temporary, so that step needs to be added at the end of the runbook.

### Report on a subset of users

Graph applies the scope when it lists users, before the per-user method reads. Only users in scope are read, so the run time scales with the number of users in scope. For example, at the measured rate, 20,000 users would take about 50–60 minutes instead of 2–2.5 hours for 50,000.

```powershell
# By attribute (any property /users supports in an advanced query)
.\Get-EntraAuthMethodReport.ps1 -UserFilter "employeeType eq 'Employee' and accountEnabled eq true"
.\Get-EntraAuthMethodReport.ps1 -UserFilter "employeeType in ('10','11')"
.\Get-EntraAuthMethodReport.ps1 -UserFilter "companyName in ('Contoso EMEA','Contoso APAC')"
.\Get-EntraAuthMethodReport.ps1 -UserFilter "onPremisesExtensionAttributes/extensionAttribute5 eq 'PasskeyWave1'"

# By group membership (nested groups included; users in several groups are read once)
.\Get-EntraAuthMethodReport.ps1 -GroupId <passkeyPilotGroupId>, <wave2GroupId>

# Both: members of the group who also match the filter
.\Get-EntraAuthMethodReport.ps1 -GroupId <passkeyPilotGroupId> -UserFilter "userType eq 'Member'"
```

- To scope by role, department or similar, the simplest option is often an existing pilot group or a dynamic group with that rule. Dynamic groups can use rules that `$filter` can't express.
- Put values in single quotes, even numbers. `employeeType` and most other user properties are text, so `employeeType eq '10'` works but `employeeType eq 10` fails with HTTP 400 (`incompatible types`).
- An invalid filter, or one that matches nobody, stops the run before any authentication methods are read.
- Filters are sent as Graph *advanced queries* (`ConsistencyLevel: eventual`). Users created or changed in the last few minutes may not match yet.
- The scope is recorded in `RunSummary_*.json` (`Scope`) and shown in the HTML header, so a partial report isn't mistaken for the whole tenant.
- `-CompareWithReport` still downloads the whole native report, which is cheap and not throttled like the method reads. It compares only in-scope users. `NativeReportUsersInScope` in the summary is the in-scope count.

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-TenantId` | none | Tenant ID or domain. Required with `-ClientId`. |
| `-ClientId`, `-CertificateThumbprint` | none | App-only sign-in with a certificate from the local certificate store. |
| `-ManagedIdentity`, `-ManagedIdentityClientId` | off | Managed identity sign-in. Add the client ID for a user-assigned identity. |
| `-AccessToken` | none | A Graph token (`SecureString`) you already have. It is never refreshed, so it must last for the whole run. |
| `-OutputPath` | `.\AuthMethodReport` | Folder for the output files. |
| `-UserFilter` | none | OData filter on user properties, sent as an advanced query, e.g. `"employeeType eq 'Employee'"`. |
| `-GroupId` | none | Only read members (including nested) of these group object IDs. Needs `GroupMember.Read.All`. |
| `-CompareWithReport` | off | Also download the native registration details report and flag differences. Needs `AuditLog.Read.All`. |
| `-MaxConcurrency` | 8 | Maximum `$batch` requests in flight (1–32). |
| `-BatchSize` | 20 | Users per `$batch` request (1–20). |
| `-MaxUsersPerSecond` | 0 (off) | Ceiling on read rate. |
| `-MaxRetries` | 12 | Retries for non-throttling errors (1–50). |
| `-MaxUsers` | 0 (all) | Limit the run for testing. The report is then marked incomplete if more users matched. |
| `-IncludeContactDetails` | off | Include phone numbers and email addresses in the detail CSV. |
| `-NoHtml` | off | Skip the HTML viewer. |
| `-ProgressIntervalSeconds` | 15 | How often progress is logged (5–600). |
| `-ApiVersion` | v1.0 | Use `beta` only if a method type is missing from v1.0. |
| `-GraphEndpoint` | `https://graph.microsoft.com` | One of `https://graph.microsoft.com`, `https://graph.microsoft.us` (GCC High) or `https://dod-graph.microsoft.us` (DoD). No other value is accepted. |
| `-TestGraphEndpoint` | none | **Testing only.** Sends requests to a local mock Graph server instead of Microsoft Graph. See [Appendix B](#appendix-b-security-review). |

## Output

All output goes to `-OutputPath`, which defaults to `.\AuthMethodReport`.

| File | Contents |
|---|---|
| `AuthMethodReport_<timestamp>.html` | A self-contained viewer. Open it in any browser to search, filter by "has / lacks method", sort, page, and export the filtered view to CSV. It does not need a server or internet access. |
| `AuthMethods_<timestamp>.csv` | One row per user, with a column per method family. See [CSV columns](#csv-columns). |
| `AuthMethodDetails_<timestamp>.csv` | One row per registered method (passwords excluded): model, AAGUID, created and last-used dates. |
| `AuthMethodErrors_<timestamp>.csv` | Only written if some users couldn't be read. |
| `RunSummary_<timestamp>.json` | Run statistics and the completeness result. See [Report completeness](#report-completeness). |

The [`Example/`](Example/) folder has sample output for 500 made-up `contoso.test` users, created with the mock Graph server in `Tests\`. [Open the example viewer](https://georgemansomsft.github.io/powershell/user-auth-report/Example/AuthMethodReport_example.html) in your browser. GitHub shows `.html` files as source code, so the link goes to a GitHub Pages copy.

### CSV columns

`AuthMethods_*.csv` has these columns:

- **User:** `UserPrincipalName`, `DisplayName`, `UserId`, `AccountEnabled`, `UserType`, `OnPremisesSyncEnabled`, `UserCreatedDateTime`.
- **Read result:** `ReadStatus` is `OK` or `Error`. `ErrorDetail` gives the reason for `Error`.
- **Methods:** `MethodsRegistered`, `MethodCount`, `HasPasskey`, `HasPasskeyInAuthenticator`, `HasPasskeyOther`, `PasskeyCount`, `PasskeyModels`, `PasskeyNewestCreated`, `HasMicrosoftAuthenticator`, `AuthenticatorDevices`, `HasWindowsHelloForBusiness`, `HasPlatformCredential`, `HasPhone`, `HasSoftwareOath`, `HasHardwareOath`, `HasTemporaryAccessPass`, `HasEmail`.
- **Derived from registered methods:**
  - `HasMfaMethodRegistered` is true if the user has registered at least one of: Microsoft Authenticator, passkey (FIDO2), Windows Hello for Business, Platform Credential (macOS), mobile, alternate or office phone, software OATH or hardware OATH.
  - `HasPhishingResistantMethodRegistered` is true if the user has registered a passkey, Windows Hello for Business or Platform Credential.
  - Both columns only say which methods are *registered*. They don't evaluate authentication methods policy or Conditional Access, so a registered method may still be disabled by policy for that user.
- **With `-CompareWithReport`:** `InNativeReport`, `NativeMethodsRegistered`, `NativeIsMfaCapable` (copied unchanged from the native report's `isMfaCapable`) and `Discrepancy`.

Other things to know about the columns:

- **Failed reads are unknown, not "no".** If a user's methods couldn't be read (`ReadStatus` = `Error`), every method column is left empty rather than `False` or `0`. The HTML export does the same.
- **`MethodCount`** is the number of distinct method types the user has registered, not counting the password. All passkeys count as one type. Method types the script doesn't recognise yet are counted too. The HTML viewer shows the same number.
- **Spreadsheet formula guard.** Text values that start with `=`, `+`, `-`, `@`, a tab or a line break get a leading `'`, so Excel and similar apps show them as text instead of running them as formulas. This applies to all three CSV files and to the HTML viewer's CSV export.

### Report completeness

Each run checks whether every user in scope was listed and read. The result is in `RunSummary_*.json` and shown as a banner at the top of the HTML viewer.

| Field | Meaning |
|---|---|
| `ReportComplete` | `true` only if none of the issues below happened. |
| `CompletenessIssues` | A list of reasons the report is incomplete: <ul><li>the run stopped at `-MaxUsers` while more users matched;</li><li>Graph's `@odata.count` for a filter or group didn't match the number of users it returned;</li><li>some users' methods couldn't be read (they are in the errors CSV);</li><li>some users have neither a result nor a recorded failure.</li></ul> |
| `NativeComparisonStatus` | `NotRequested`, `Completed` or `Failed`. If the native report download fails (for example because `AuditLog.Read.All` is missing), the run continues without the comparison. This doesn't make the method report incomplete. |
| `NativeComparisonError` | The error, when the status is `Failed`. |

HTML banners:

- **Green, "Complete"**: every user in scope was enumerated and read.
- **Red, "Incomplete report"**: lists the issues. Don't treat users missing from this report as having no methods.
- **Amber, "Native report comparison failed"**: shown in addition when the comparison failed. The discrepancy columns are hidden.

`RunSummary_*.json` also records:

- **Run:** `TenantId`, `AuthMode`, `GraphEndpoint`, `Scope`, `StartedUtc`, `DurationSeconds`, `MethodReadSeconds`.
- **Counts:** `UsersEnumerated`, `UsersRead`, `UsersFailed`.
- **Throttling and errors:** `BatchesSent`, `ThrottledItems`, `ThrottledBatches`, `ServerErrors`, `TransportErrors`, `Retries`, `PeakBatchesInFlight`, `TokenRefreshes`.
- **Results:** `UsersWithMfaMethodRegistered`, `UsersWithPhishingResistantMethodRegistered`, `PasskeyUsers`, `NativeReportUsers`, `NativeReportUsersInScope`, `Discrepancies`.
- **Files:** `CsvPath`, `DetailCsvPath`, `HtmlPath`, `ErrorCsvPath`.

### Comparing with the native report

With `-CompareWithReport`, every user that was read successfully is also checked against the native report and may be marked with a **Discrepancy**:

- `Missing from native report`: only for **enabled** users. Microsoft documents that the native report API doesn't work for disabled users, so disabled users are never flagged as missing.
- `Passkey not shown in native report`
- `Native report shows passkey that is no longer registered`
- `Native report shows no methods`

If the user or passkey was created in the last 48 hours, the note says the report may simply be lagging. This mode gives evidence for the open support case.

### Handling the output

The files list every user's sign-in methods, including device names and passkey models. Treat them as sensitive: store them with restricted access and don't email them around. Phone numbers and email addresses are left out unless `-IncludeContactDetails` is used.

## Recommended rollout

1. Run interactively against a test tenant with `-CompareWithReport`, and check a handful of users against their Security info page.
2. Run in the production tenant with `-MaxUsers 2000 -CompareWithReport`, using a Global Reader account. Review `RunSummary_*.json` for throttling counts. `ReportComplete` will be `false` here only because of `-MaxUsers`.
3. Do a full run. Confirm that `ReportComplete` is `true`, and that the enabled users known to be missing from the native report appear with the right methods and are flagged `Missing from native report`.
4. Optionally, schedule it nightly in Azure Automation with a managed identity.

## Known limitations

- The Graph documentation advises against looping over every user with the authentication methods API for tenant-wide auditing. This script exists because the recommended report is currently incomplete. Once the report is fixed, switch back to it or keep this as a periodic cross-check.
- **Disabled users.** The native report API [doesn't include disabled users](https://learn.microsoft.com/en-us/graph/api/authenticationmethodsroot-list-userregistrationdetails?view=graph-rest-1.0): Microsoft's documentation says "This method doesn't work for disabled users." This script reads disabled users' methods and includes them in its output, but never flags them as missing from the native report.
- Guests are included too. Use `-UserFilter` to exclude guests or disabled users, e.g. `"accountEnabled eq true and userType eq 'Member'"`.
- `HasMfaMethodRegistered` and `HasPhishingResistantMethodRegistered` describe registered methods only. They don't evaluate policy. Use the native report's `isMfaCapable` (`NativeIsMfaCapable`) for Microsoft's own evaluation.
- A user changed during the run may show the state from when they were read.
- The run can't be paused and resumed. If it stops, run it again.
- The China (21Vianet) cloud isn't supported.

## Appendix A: How it works

### Why it is much faster than a per-user loop

A typical `foreach ($u in $users) { Get-MgUserAuthenticationMethod -UserId $u.Id }` makes one HTTP call per user, one after another. This script is faster for three reasons:

- **20 users per HTTP call.** It uses Graph JSON `$batch`.
- **Several batches at once.** It runs up to 8 by default, so up to 160 users are in flight.
- **Throttling is handled per user, not per run.** Only the throttled users in a batch are retried after `Retry-After`. Concurrency is halved when Graph throttles and raised again when it stops.

### Throttling design (for tenants with tens of thousands of users)

- Graph throttles each request inside a `$batch` separately. The script reads the per-item `429` and `Retry-After`, and retries only those items.
- **Adaptive concurrency.**
  - It starts at `min(4, MaxConcurrency)` batches in flight.
  - On throttling it halves concurrency, at most once per `max(5 s, Retry-After)`.
  - After 10 clean batches it adds 1.
- **Separate retry budgets.**
  - Throttling (`429`) is expected at scale and is retried up to `max(100, MaxRetries)` times per user.
  - Server and transport errors are retried up to `MaxRetries` times (default 12), with backoff.
  - Users that still fail are listed in the errors CSV, and the report is marked incomplete, rather than stopping the run.
- **Optional rate ceiling.** `-MaxUsersPerSecond` leaves Graph capacity for other apps and automations in the tenant. Use it if a nightly run competes with other workloads. The default is `0`, meaning no ceiling.
- **Paging.** `/users` paging and the native report download use the same `429` and `5xx` handling.

### Access token refresh

- With interactive, certificate or managed identity sign-in, the Graph SDK owns the token. The script copies the SDK's current token at the start, every 40 minutes, and whenever Graph returns `401`.
- A `401` can come back for a whole `$batch` request or for single users inside a batch. Either way, the token is refreshed **once**: other requests that fail with the same expired token at the same time just retry with the new one. The affected users are retried using the normal `-MaxRetries` budget.
- If the token can't be refreshed:
  - a `401` for a whole request stops the run with an error;
  - a `401` for single users inside a batch marks those users as failed ("HTTP 401: the access token expired and could not be refreshed"), and the report is marked incomplete.
- With `-AccessToken`, the token is never refreshed. Use a token that lasts longer than the run.
- `TokenRefreshes` in the run summary counts the refreshes after the first token.

## Appendix B: Security review

This section is for a security team that needs to confirm the script only reads data and only talks to Microsoft Graph.

Line numbers refer to `Get-EntraAuthMethodReport.ps1` with SHA256 `97FC7688DB3D3CDFDB4F4A81153FFDDCF218C2FC11A91BA18D990D5B41AA6697`, which has 1,330 lines. If the hash differs, the line numbers may have moved. Check the hash with:

```powershell
Get-FileHash .\Get-EntraAuthMethodReport.ps1 -Algorithm SHA256
```

### Every Graph request

`{root}` is `-GraphEndpoint`, which defaults to `https://graph.microsoft.com` (lines 168–169). `{base}` is `{root}/{ApiVersion}`, which defaults to `https://graph.microsoft.com/v1.0` (lines 165–166 and 232).

| Line | HTTP method | URI | When it runs | Permission used |
|---|---|---|---|---|
| 303 | GET | `{root}/v1.0/users?$top=1&$select=id` | At sign-in, every 40 minutes, and after a `401` response. Skipped with `-AccessToken`. | `User.Read.All` |
| 731 | GET | `{base}/groups/{groupId}?$select=id,displayName` | Once per `-GroupId`, to show the group name | `GroupMember.Read.All` |
| 734 | GET | `{base}/groups/{groupId}/transitiveMembers/microsoft.graph.user?$select=…&$top=999[&$filter=…]&$count=true` | Lists users when `-GroupId` is used | `GroupMember.Read.All`, `User.Read.All` |
| 738 | GET | `{base}/users?$select=…&$top=999[&$filter=…&$count=true]` | Lists users when `-GroupId` isn't used | `User.Read.All` |
| 765 | GET | `@odata.nextLink` returned by Graph | Fetches the next page of the user list | Same as the first page |
| 802, 870 | POST | `{base}/$batch` | Reads methods for up to 20 users per call | See the next row |
| 867 | GET, inside the batch | `/users/{id}/authentication/methods` | Once per user, plus retries | `UserAuthenticationMethod.Read.All` |
| 982 | GET | `{base}/reports/authenticationMethods/userRegistrationDetails` | Only with `-CompareWithReport` | `AuditLog.Read.All` |
| 988 | GET | `@odata.nextLink` returned by Graph | Fetches the next page of the native report | `AuditLog.Read.All` |

The `$select` list (line 719) is `id,userPrincipalName,displayName,accountEnabled,userType,onPremisesSyncEnabled,createdDateTime`.

### Why this is read-only

- **The permissions requested.** Every permission the script requests is `*.Read.All`. Interactive mode requests the scopes at lines 264–266.
- **What actually limits the token.**
  - **App or managed identity:** the token carries only the application permissions you grant. If you grant only the permissions above, the token itself can't change anything, whatever the code does.
  - **Interactive (delegated):** sign-in uses the Microsoft Graph Command Line Tools app. Its token can also carry scopes the user or tenant consented to earlier, including write scopes. What the token can actually do is limited to those scopes *and* the signed-in user's role. With Global Reader, it can't change other users or tenant settings, but it could make changes the user is allowed to make to their own account. The script doesn't use any of that. If the token itself must be read-only, run with a dedicated app registration (certificate) or a managed identity that has only the read permissions above.
- **The only POST.** The only POST is to Graph's `$batch` endpoint (lines 802 and 870). `$batch` just carries other requests. Line 867 builds its body and hard-codes `"method":"GET"` for every item.
- **Two places send requests.** Apart from line 303, every request is built in `New-GraphRequest` (line 332) and sent with `SendAsync` (lines 368 and 871). `New-GraphRequest` is called only with GET (line 363) or POST to `$batch` (line 870).
- **Line 303.** This call goes through the Graph SDK's `Invoke-MgGraphRequest`. It exists only so the script can reuse the SDK's current access token for its own HTTP client.
- **Sign-in.** Sign-in (lines 269, 274 and 277) is handled by Microsoft's `Connect-MgGraph`. It contacts Entra ID's sign-in endpoints, or the managed identity endpoint in Azure.
- **No other network calls.** There is no `Invoke-RestMethod`, `Invoke-WebRequest` or `WebClient`. The HTML viewer's JavaScript is embedded in the file (line 447). It loads nothing from the internet and makes no network requests. Its CSV export is generated in the browser and saved locally.
- **Local writes.** The only things written locally are the output files in `-OutputPath`.

### Where the token can be sent

- **Fixed list of endpoints.** `-GraphEndpoint` accepts only the three official HTTPS Microsoft Graph endpoints (line 168). Anything else, including `http://`, is rejected before sign-in. The matching `Connect-MgGraph -Environment` (`Global`, `USGov` or `USGovDoD`, line 214) is used, so sign-in happens in the same cloud. China (21Vianet) isn't offered because the authentication methods API isn't available there.
- **Origin check on every request.** `Assert-GraphUri` (line 244) rejects any URL whose scheme, host and port don't exactly match the chosen endpoint, or that contains user info. It runs on every request before the token is attached (line 334) and on every `@odata.nextLink` before it is followed (line 326).
- **Redirects are never followed.** Automatic redirects are turned off (line 318). A `3xx` response stops the run (lines 380 and 908) instead of sending the token to another host.
- **Test endpoint.** `-TestGraphEndpoint` (lines 171–180) exists only to run the regression tests against the local mock server. It:
  - accepts only a loopback URL (`localhost`, `127.0.0.1` or `::1`) with no path, query or user info;
  - only works together with `-AccessToken`, so no real sign-in happens;
  - can't be combined with `-GraphEndpoint` (line 221);
  - logs a warning on every run.

### Check it yourself

- List every line that builds or sends a request, signs in or controls redirects:

  ```powershell
  Select-String .\Get-EntraAuthMethodReport.ps1 -Pattern 'BaseUri/|GraphRoot/|batchUri|SendAsync|Invoke-MgGraphRequest|HttpMethod\(|"method"|nextLink|Connect-MgGraph|AllowAutoRedirect|Invoke-RestMethod|Invoke-WebRequest|WebClient'
  ```

- If the tenant sends Microsoft Graph activity logs to Log Analytics (`MicrosoftGraphActivityLogs`), filter by the app ID and confirm that every request is a `GET` or a `POST` to `$batch`.

## Appendix C: Testing

This section separates what was tested against a mock, what was tested in a real tenant, and what hasn't been verified.

### Mocked tests (repeatable, no tenant needed)

The `Tests\` folder has a local mock Graph server (`Start-MockGraph.ps1`). It runs on `localhost` and never contacts Microsoft Graph. To run the tests:

```powershell
# Regression suite: each scenario starts its own mock with one fault injected
powershell -NoProfile -File .\Tests\Invoke-RegressionTests.ps1

# End-to-end check of every user's result
powershell -NoProfile -File .\Tests\Invoke-MockTest.ps1 -UserCount 5000
```

**The regression suite** checks:

- **Parameters.** `-GraphEndpoint` rejects `http://`, other hosts and the China endpoint. `-TestGraphEndpoint` rejects non-loopback URLs and URLs with a path, requires `-AccessToken`, and can't be combined with `-GraphEndpoint`.
- **Origin.** A next-page link pointing at another origin is refused for both the user list and the native report. A second "canary" origin on the mock checks that no request ever reaches it.
- **Redirects.** Redirects on the user list and on `$batch` aren't followed.
- **Token refresh.** Expired tokens on single batch items and on whole requests are refreshed once and every user is read. If the refreshed token is also rejected, the affected users fail and the report is marked incomplete.
- **Completeness.** A clean run with throttling is marked complete. An `@odata.count` mismatch and `-MaxUsers` truncation are marked incomplete.
- **Native comparison status.** `Completed`, `Failed` (when the native report returns `403`) and `NotRequested`. A failed comparison doesn't mark the report incomplete.
- **End to end**, via `Invoke-MockTest.ps1`:
  - the renamed columns;
  - empty (unknown) values for users that couldn't be read;
  - the CSV formula guard;
  - identical `MethodCount` values in the CSV and HTML.

**`Invoke-MockTest.ps1`** runs 5,000 users against a mock that deliberately injects:

- per-item `429` throttling on 5% of items;
- `503` errors;
- `403` users;
- every method type, an unknown future method type, and HTML/script-injection and formula-injection display names;
- a native report with missing users, missing passkeys and stale passkeys.

Every user's result matched the expected values in each scope mode: all users, `-UserFilter`, `-GroupId` with two overlapping groups (overlapping users read once), and both together. The mock rejects filters and group-member queries that aren't sent as advanced queries. Run time with the hardening changes matched the earlier version (about 10 seconds for 5,000 mocked users).

The HTML banners (complete, incomplete, native comparison failed) were also checked by opening the generated reports in a headless browser.

### Real-tenant tests (dev tenant, about 1,026 users)

Earlier full runs, in both interactive (delegated) and app-only certificate modes:

| Mode | Users | Total time | Method reads | Throttled items (all retried) | Failed |
|---|---|---|---|---|---|
| Delegated (interactive) | 1,026 | 177 s | 148 s | 84 | 0 |
| App-only (certificate) | 1,026 | 189 s | 166 s | 93 | 0 |

The method results were correct: phone users had an MFA method registered and email-only users didn't.

`-UserFilter`, using app-only sign-in:

- `"department ne 'AuthMethodReportTest'"` returned exactly the 26 non-test users, which confirms Graph accepts the advanced query.
- `"department eq 'AuthMethodReportTest' and accountEnabled eq false"` with `-MaxUsers 150` returned 150 users.

`-GroupId`, using app-only sign-in. Group A has 100 direct members and nested Group B; Group B has 61 members, 11 of whom are also in A.

- `-GroupId A` returned exactly the 150 expected users, so nested members are included and overlap is removed.
- `-GroupId A,B` also returned 150; overlapping users were read once.
- `-GroupId A -UserFilter "startswith(userPrincipalName,'amrtest01')"` returned exactly the 51 expected users.

`-CompareWithReport` across the whole tenant (app-only): the native report returned only the 26 enabled users, and all 26 matched the script's results. The 1,000 disabled test users were absent from the native report, which matches Microsoft's documentation. That run was before the script stopped flagging disabled users as missing; with the current version they aren't flagged.

After the hardening changes, an app-only certificate run of 50 users with `-CompareWithReport` confirmed:

- sign-in with `-Environment Global`;
- the client with redirects turned off;
- origin checks on real Graph pages;
- the `-MaxUsers` completeness flag;
- `NativeComparisonStatus` `Completed`.

All 50 users were read, with 0 failures, 0 discrepancies and 0 token refreshes.

**Measured throttling** on `/users/{id}/authentication/methods`:

- A burst of about 200–235 reads is allowed.
- After that, Graph sustains about **6–7 reads per second**. Throttled items return `429` with `Retry-After: 10`.
- Delegated and app-only behaved the same, so the limit appears to apply to the tenant or this resource, not per user or per app.
- This is far lower than the published per-app limits suggest. The script already runs at this ceiling, so it's limited by the server, not the client.

**Expected timing:** about **2.5–3 minutes per 1,000 users** if the production tenant gets the same ceiling. That is about 70–85 minutes for 28,000 users and 2–2.5 hours for 50,000. Graph's limits scale with tenant size, so a large tenant may be faster, but this hasn't been confirmed. Measure it with the `-MaxUsers 2000` pilot in [Recommended rollout](#recommended-rollout) and extrapolate from `RunSummary_*.json`. Run the full collection unattended, using Azure Automation or a scheduled task.

### Not yet verified

- Passkey detection on real passkey registrations (the dev tenant test users had no passkeys; only the mock covered passkeys).
- The AAGUIDs used to classify "passkey in Microsoft Authenticator".
- A real token expiring during a long run. The refresh logic is only tested against the mock, and it isn't known whether Graph returns `401` for single items inside a `$batch`.
- The `-AccessToken` mode against real Graph (it never refreshes).
- Throughput in a large (28–50k user) tenant.
- Managed identity sign-in and Azure Automation sandbox behaviour.
- A `-UserFilter` on `employeeType` that matches real users. The dev tenant has no `employeeType` values; the syntax was accepted.
- The US Government endpoints and their `-Environment` sign-in. These were reviewed in the code but not run.
