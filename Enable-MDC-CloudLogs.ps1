param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    # Optional – defaults to current context tenant
    [string]$TenantId
)

# Connect & select subscription
Connect-AzAccount -ErrorAction Stop | Out-Null
Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop

# Make sure the SecurityInsights module is available
if (-not (Get-Module -ListAvailable -Name Az.SecurityInsights)) {
    Install-Module -Name Az.SecurityInsights -Scope CurrentUser -Force
}
Import-Module Az.SecurityInsights

if (-not $TenantId) {
    $TenantId = (Get-AzContext).Tenant.Id
}

# Try to find an existing Defender for Cloud Apps (MicrosoftCloudAppSecurity) connector
$existingConnector = Get-AzSentinelDataConnector `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -WorkspaceName $WorkspaceName `
    -ErrorAction SilentlyContinue `
    | Where-Object {$_.Kind -eq "MicrosoftCloudAppSecurity"}

if ($existingConnector) {
    $connectorId = $existingConnector.Name
    Write-Host "Existing MicrosoftCloudAppSecurity connector found: $connectorId – updating it..."
}
else {
    $connectorId = (New-Guid).Guid
    Write-Host "No existing MicrosoftCloudAppSecurity connector found – creating a new one ($connectorId)..."
}

# Create/update the connector with discovery logs enabled
New-AzSentinelDataConnector `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -WorkspaceName $WorkspaceName `
    -Kind MicrosoftCloudAppSecurity `
    -TenantId $TenantId `
    -Alerts "Enabled" `
    -DiscoveryLog "Enabled" `
    -Id $connectorId `
    -Confirm:$false

Write-Host "Defender for Cloud Apps connector is now configured with Cloud Discovery Logs = Enabled."
