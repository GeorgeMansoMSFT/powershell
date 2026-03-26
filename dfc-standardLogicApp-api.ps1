
# =============================================================================
# TestDFCAutomation.ps1
# Tests the DFC Workflow Automation REST API to link a Standard Logic App
# to a Microsoft Defender for Cloud alert automation rule.
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURATION — your environment values
# -----------------------------------------------------------------------------
$subscriptionId     = ""
$automationRG       = ""
$automationName     = ""
$logicAppName       = ""
$logicAppRG         = ""
$workflowName       = ""
$triggerName        = "When_an_HTTP_request_is_received"
$location           = "eastus"
$alertFilterValue   = "Malicious file uploaded to storage account"

# Declared as a variable so the $ sign is not interpreted by PowerShell
# when it is interpolated inside the here-string body below
$propertyJPath      = '$.AlertDisplayName'

# Derived resource paths
$logicAppResourceId = "/subscriptions/$subscriptionId/resourceGroups/$logicAppRG/providers/Microsoft.Web/sites/$logicAppName"
$automationUri      = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$automationRG/providers/Microsoft.Security/automations/$($automationName)?api-version=2023-12-01-preview"
$callbackUri        = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$logicAppRG/providers/Microsoft.Web/sites/$logicAppName/hostruntime/runtime/webhooks/workflow/api/management/workflows/$workflowName/triggers/$triggerName/listCallbackUrl?api-version=2022-03-01"

# Temp file path for the request body — avoids inline escaping issues with az rest
$bodyFile           = "$env:TEMP\dfc-automation-body.json"

# =============================================================================
# STEP 1 — Retrieve the Standard Logic App trigger URI
# =============================================================================
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " STEP 1: Fetching Logic App trigger URI..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Calling: $callbackUri"

$callbackResponse = az rest --method post --uri $callbackUri 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Failed to retrieve the trigger URI. Details:" -ForegroundColor Red
    Write-Host $callbackResponse -ForegroundColor Red
    Write-Host ""
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  - You are not logged in. Run: az login" -ForegroundColor Yellow
    Write-Host "  - Wrong subscription set. Run: az account set --subscription '$subscriptionId'" -ForegroundColor Yellow
    Write-Host "  - Logic App name, RG, workflow name, or trigger name is incorrect." -ForegroundColor Yellow
    exit 1
}

# Parse the JSON response and extract the trigger URI value
$callbackJson = $callbackResponse | ConvertFrom-Json
$triggerUri   = $callbackJson.value

if (-not $triggerUri) {
    Write-Host ""
    Write-Host "ERROR: Trigger URI was empty in the response. Full response:" -ForegroundColor Red
    Write-Host ($callbackResponse | Out-String) -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "SUCCESS: Trigger URI retrieved." -ForegroundColor Green
Write-Host "URI (truncated for display): $($triggerUri.Substring(0, [Math]::Min(80, $triggerUri.Length)))..."

# =============================================================================
# STEP 2 — Build the request body and write to temp file, then fire the PUT
# =============================================================================
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " STEP 2: Creating/updating DFC Workflow Automation..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Target endpoint: $automationUri"

# Build the JSON body as a here-string with values interpolated directly.
# $propertyJPath is pre-declared above so the $ in "$.AlertDisplayName"
# is safely passed through without PowerShell trying to expand it.
$bodyJson = @"
{
  "location": "$location",
  "properties": {
    "description": "Trigger Standard Logic App $logicAppName when Defender for Cloud raises a $alertFilterValue alert",
    "isEnabled": true,
    "scopes": [
      {
        "description": "Full subscription scope",
        "scopePath": "/subscriptions/$subscriptionId"
      }
    ],
    "sources": [
      {
        "eventSource": "Alerts",
        "ruleSets": [
          {
            "rules": [
              {
                "propertyJPath": "$propertyJPath",
                "propertyType": "String",
                "expectedValue": "$alertFilterValue",
                "operator": "Contains"
              }
            ]
          }
        ]
      }
    ],
    "actions": [
      {
        "actionType": "LogicApp",
        "logicAppResourceId": "$logicAppResourceId",
        "uri": "$triggerUri"
      }
    ]
  }
}
"@

# Write body to temp file — passing @filepath to az rest is more reliable
# than inline JSON for complex payloads
$bodyJson | Out-File -FilePath $bodyFile -Encoding utf8 -NoNewline
Write-Host ""
Write-Host "Request body written to: $bodyFile"
Write-Host ""
Write-Host "Request body (formatted):"
Write-Host $bodyJson

# Execute the PUT call via az rest, passing body from file
$putResponse = az rest `
    --method PUT `
    --uri $automationUri `
    --headers "Content-Type=application/json" `
    --body "@$bodyFile" `
    2>&1

# =============================================================================
# STEP 3 — Output the result and validate
# =============================================================================
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " STEP 3: Verifying result..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: DFC Automation PUT request failed. Details:" -ForegroundColor Red
    Write-Host $putResponse -ForegroundColor Red
    Write-Host ""
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  - Insufficient permissions (requires Security Admin or Owner on the RG)." -ForegroundColor Yellow
    Write-Host "  - The Microsoft.Security provider is not registered on this subscription." -ForegroundColor Yellow
    Write-Host "  - Invalid subscription ID or resource group name." -ForegroundColor Yellow
    exit 1
}

# Parse and display the response
$putJson = $putResponse | ConvertFrom-Json

Write-Host ""
Write-Host "SUCCESS: DFC Automation created/updated." -ForegroundColor Green
Write-Host ""
Write-Host "--- Response Summary ---" -ForegroundColor White
Write-Host "Name      : $($putJson.name)"
Write-Host "Location  : $($putJson.location)"
Write-Host "Enabled   : $($putJson.properties.isEnabled)"
Write-Host "Actions   : $($putJson.properties.actions | ConvertTo-Json -Depth 3)"
Write-Host ""
Write-Host "Next step: Verify in the Azure Portal under:" -ForegroundColor Yellow
Write-Host "  Defender for Cloud -> Workflow Automation -> '$automationName'" -ForegroundColor Yellow
Write-Host ""
Write-Host "IMPORTANT: The trigger URI is write-only and will NOT appear in portal" -ForegroundColor Yellow
Write-Host "or GET responses. Keep a secure record of it." -ForegroundColor Yellow
Write-Host ""

# Clean up temp file
Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
Write-Host "Temp body file cleaned up." -ForegroundColor Gray
