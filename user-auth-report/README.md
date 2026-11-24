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

- Permissions:

| Run as | Graph permissions | Entra role (delegated only) |
|---|---|---|
| Signed-in admin (interactive) | `User.Read.All`, `UserAuthenticationMethod.Read.All` (+ `AuditLog.Read.All` for `-CompareWithReport`) | **Global Reader** is enough. Authentication Administrator also works but only sees masked phone numbers. |
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
| `-UserFilter` | none | OData filter on user properties, sent as an advanced query, e.g. `"employeeType eq 'Employee'"` |
| `-GroupId` | none | Only read members (including nested) of these group object IDs. Needs `GroupMember.Read.All` |
| `-MaxConcurrency` | 8 | Maximum `$batch` requests in flight (1–32) |
| `-MaxUsersPerSecond` | 0 (off) | Ceiling on read rate |
| `-MaxRetries` | 12 | Retries for non-throttling errors |
| `-MaxUsers` | 0 (all) | Limit the run for testing |
| `-IncludeContactDetails` | off | Include phone numbers and email addresses in the detail CSV |
| `-NoHtml` | off | Skip the HTML viewer |
| `-ApiVersion` | v1.0 | Use `beta` only if a method type is missing from v1.0 |

## Output

All output goes to `-OutputPath`, which defaults to `.\AuthMethodReport`.

| File | Contents |
|---|---|
| `AuthMethodReport_<timestamp>.html` | A self-contained viewer. Open it in any browser to search, filter by "has / lacks method", sort, page, and export the filtered view to CSV. It does not need a server or internet access. |
| `AuthMethods_<timestamp>.csv` | One row per user, with a column per method family (`HasPasskey`, `HasPasskeyInAuthenticator`, `IsMfaCapable`, `IsPhishingResistantCapable`, …). |
| `AuthMethodDetails_<timestamp>.csv` | One row per registered method: model, AAGUID, created and last-used dates. |
| `AuthMethodErrors_<timestamp>.csv` | Only written if some users couldn't be read. |
| `RunSummary_<timestamp>.json` | Run statistics: duration, throttling, retries, totals. |

The [`Example/`](Example/) folder has sample output for 500 made-up `contoso.test` users, created with the mock Graph server in `Tests\`. [Open the example viewer](https://georgemansomsft.github.io/powershell/user-auth-report/Example/AuthMethodReport_example.html) in your browser. GitHub shows `.html` files as source code, so the link goes to a GitHub Pages copy.

### Comparing with the native report

With `-CompareWithReport`, every user is also checked against the native report and marked with a **Discrepancy**:

- `Missing from native report`
- `Passkey not shown in native report`
- `Native report shows passkey that is no longer registered`
- `Native report shows no methods`

If the user or passkey was created in the last 48 hours, the note says the report may simply be lagging. This mode gives evidence for the open support case.

### Handling the output

The files list every user's sign-in methods, including device names and passkey models. Treat them as sensitive: store them with restricted access and don't email them around. Phone numbers and email addresses are left out unless `-IncludeContactDetails` is used.

## Recommended rollout

1. Run interactively against a test tenant with `-CompareWithReport`, and check a handful of users against their Security info page.
2. Run in the production tenant with `-MaxUsers 2000 -CompareWithReport`, using a Global Reader account. Review `RunSummary_*.json` for throttling counts.
3. Do a full run. Confirm that the users known to be missing from the native report appear with the right methods and are flagged `Missing from native report`.
4. Optionally, schedule it nightly in Azure Automation with a managed identity.

## Known limitations

- The Graph documentation advises against looping over every user with the authentication methods API for tenant-wide auditing. This script exists because the recommended report is currently incomplete. Once the report is fixed, switch back to it or keep this as a periodic cross-check.
- A user changed during the run may show the state from when they were read.
- Guests and disabled users are included. Use `-UserFilter` to exclude them, e.g. `"accountEnabled eq true and userType eq 'Member'"`.

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
  - Users that still fail are listed in the errors CSV rather than stopping the run.
- **Optional rate ceiling.** `-MaxUsersPerSecond` leaves Graph capacity for other apps and automations in the tenant. Use it if a nightly run competes with other workloads. The default is `0`, meaning no ceiling.
- **Token refresh.** The token is refreshed every 40 minutes during long runs, except in `-AccessToken` mode.
- **Paging.** `/users` paging and the native report download use the same `429` and `5xx` handling.

## Appendix B: Security review

Every Graph request the script makes.

This section is for a security team that needs to confirm the script only reads data.

Line numbers refer to `Get-EntraAuthMethodReport.ps1` with SHA256 `E3992F0EEDF7E15572EA77B630E110194068806803079F8DEAD08D8677A265E5`, which has 1,154 lines. If the hash differs, the line numbers may have moved. Check the hash with:

```powershell
Get-FileHash .\Get-EntraAuthMethodReport.ps1 -Algorithm SHA256
```

`{base}` is `-GraphEndpoint` plus `-ApiVersion`, which defaults to `https://graph.microsoft.com/v1.0` (lines 145, 143 and 180).

| Line | HTTP method | URI | When it runs | Permission used |
|---|---|---|---|---|
| 234 | GET | `{GraphEndpoint}/v1.0/users?$top=1&$select=id` | At sign-in, every 40 minutes, and after a `401` response. Skipped with `-AccessToken`. | `User.Read.All` |
| 628 | GET | `{base}/groups/{groupId}?$select=id,displayName` | Once per `-GroupId`, to show the group name | `GroupMember.Read.All` |
| 631 | GET | `{base}/groups/{groupId}/transitiveMembers/microsoft.graph.user?$select=…&$top=999[&$filter=…]&$count=true` | Lists users when `-GroupId` is used | `GroupMember.Read.All`, `User.Read.All` |
| 635 | GET | `{base}/users?$select=…&$top=999[&$filter=…&$count=true]` | Lists users when `-GroupId` isn't used | `User.Read.All` |
| 653 | GET | `@odata.nextLink` returned by Graph | Fetches the next page of the user list | Same as the first page |
| 682, 742 | POST | `{base}/$batch` | Reads methods for 20 users per call | See the next row |
| 739 | GET, inside the batch | `/users/{id}/authentication/methods` | Once per user, plus retries if throttled | `UserAuthenticationMethod.Read.All` |
| 847 | GET | `{base}/reports/authenticationMethods/userRegistrationDetails` | Only with `-CompareWithReport` | `AuditLog.Read.All` |
| 853 | GET | `@odata.nextLink` returned by Graph | Fetches the next page of the native report | `AuditLog.Read.All` |

The `$select` list (line 616) is `id,userPrincipalName,displayName,accountEnabled,userType,onPremisesSyncEnabled,createdDateTime`.

**Why this is read-only**

- **The permissions.** Every permission the script requests is `*.Read.All`, so the token can't be used to change anything. This holds even if the code were modified. Interactive mode requests the scopes at lines 202–204. For an app or managed identity, the permissions you grant decide what it can do.
- **The only POST.** The only POST is to Graph's `$batch` endpoint (line 742). `$batch` just carries other requests. Line 739 builds its body and hard-codes `"method":"GET"` for every item.
- **One place sends requests.** Apart from line 234, every request is built in `New-GraphRequest` (line 252) and sent with `SendAsync` (lines 285 and 743). `New-GraphRequest` is called only with GET (line 280) or POST to `$batch` (line 742).
- **Line 234.** This call goes through the Graph SDK's `Invoke-MgGraphRequest`. It exists only so the script can reuse the SDK's current access token for its own HTTP client.
- **Sign-in.** Sign-in (lines 207, 212 and 215) is handled by Microsoft's `Connect-MgGraph`. It contacts Entra ID's sign-in endpoints, or the managed-identity endpoint in Azure.
- **No other network calls.** There are no other network calls: no `Invoke-RestMethod`, `Invoke-WebRequest` or `WebClient`. The HTML viewer's JavaScript is embedded in the file (line 445). It loads nothing from the internet.
- **Local writes.** The only things written locally are the output files in `-OutputPath`.

**Things a reviewer should know**

- **`-GraphEndpoint`.** It exists for national clouds. The access token is sent to whatever host it names, so leave it at the default unless you need a national cloud.
- **Delegated tokens.** Interactive sign-in uses the Microsoft Graph Command Line Tools app. A delegated token from that app can also carry scopes the user or tenant consented to earlier, including write scopes. The script doesn't use them, but if you need the token itself to be read-only, run with a dedicated app registration (certificate) or a managed identity that has only the read permissions above.

**Check it yourself:**

- List every line that builds or sends a request:

  ```powershell
  Select-String .\Get-EntraAuthMethodReport.ps1 -Pattern 'BaseUri/|GraphEndpoint/|batchUri|SendAsync|Invoke-MgGraphRequest|HttpMethod\(|"method"|nextLink|Invoke-RestMethod|Invoke-WebRequest|WebClient'
  ```

- If the tenant sends Microsoft Graph activity logs to Log Analytics (`MicrosoftGraphActivityLogs`), filter by the app ID and confirm that every request is a `GET` or a `POST` to `$batch`.

## Appendix C: Testing

What has been tested, and what hasn't.

**Tested** against the local mock Graph server in `Tests\`, with 5,000 users. The mock deliberately injects:

- per-item `429` throttling on 5% of items;
- `503` errors;
- `403` users;
- every method type, an unknown future method type, and an HTML/script-injection display name;
- a native report with missing users, missing passkeys and stale passkeys.

Every user's result matched the expected values.

To repeat the test, run:

```powershell
powershell -NoProfile -File .\Tests\Invoke-MockTest.ps1 -UserCount 5000
```

User scoping was also tested against the mock, with 2,000 users, for each scope mode:

- `-Scope Filter`
- `-Scope Groups`: two overlapping groups; overlapping users are read once
- `-Scope GroupsAndFilter`

The mock rejects filters and group-member queries that aren't sent as advanced queries. In every mode, only in-scope users were read, and every result matched.

**Tested against a real dev tenant** (about 1,026 users, small tenant) in both interactive (delegated) and app-only certificate modes:

| Mode | Users | Total time | Method reads | Throttled items (all retried) | Failed |
|---|---|---|---|---|---|
| Delegated (interactive) | 1,026 | 177 s | 148 s | 84 | 0 |
| App-only (certificate) | 1,026 | 189 s | 166 s | 93 | 0 |

The method results were correct: phone users were MFA capable and email-only users were not.

`-UserFilter` was also run in the dev tenant using app-only sign-in:

- `"department ne 'AuthMethodReportTest'"` returned exactly the 26 non-test users, which confirms Graph accepts the advanced query.
- `"department eq 'AuthMethodReportTest' and accountEnabled eq false"` with `-MaxUsers 150` returned 150 users.

`-GroupId` was run in the dev tenant using app-only sign-in. Group A has 100 direct members and nested Group B; Group B has 61 members, 11 of whom are also in A.

- `-GroupId A` returned exactly the 150 expected users, so nested members are included and overlap is removed.
- `-GroupId A,B` also returned 150; overlapping users were read once.
- `-GroupId A -UserFilter "startswith(userPrincipalName,'amrtest01')"` returned exactly the 51 expected users.

`-CompareWithReport` was run across the whole dev tenant (1,026 users, app-only):

- The native report returned 26 users. All 26 matched the script's results (0 discrepancies).
- The other 1,000 users were flagged `Missing from native report`. All of them were disabled test accounts created about 1.5 hours before the run.
- So this can't show whether the native report leaves out disabled users or just hadn't picked up new accounts yet. Either way, the script found users the native report missed.

**Measured throttling** on `/users/{id}/authentication/methods`:

- A burst of about 200–235 reads is allowed.
- After that, Graph sustains about **6–7 reads per second**. Throttled items return `429` with `Retry-After: 10`.
- Delegated and app-only behaved the same, so the limit appears to apply to the tenant or this resource, not per user or per app.
- This is far lower than the published per-app limits suggest. The script already runs at this ceiling, so it's limited by the server, not the client.

**Expected timing for 50,000 users:** about **2–2.5 hours** if the production tenant gets the same ceiling, which is about 2.5–3 minutes per 1,000 users. Graph's limits scale with tenant size, so a large tenant may be faster, but this hasn't been confirmed. Measure it with the `-MaxUsers 2000` pilot in [Recommended rollout](#recommended-rollout) and extrapolate from `RunSummary_*.json`. Run the full collection unattended, using Azure Automation or a scheduled task.

**Not yet verified:**

- throughput in a large (30–50k user) tenant;
- whether the native report leaves out disabled users (see above);
- managed identity sign-in and Azure Automation sandbox behaviour;
- the AAGUIDs used to classify "passkey in Microsoft Authenticator".
