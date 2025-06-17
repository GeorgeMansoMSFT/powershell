# Parameters for the app registration - need Group.Create and User.Read.All in Graph
$tenantId = "<tenantId>"
$clientId = "<clientId>"
$clientSecret = "<clientSecret>"  # Consider using a secure method for production

# Define the UPN of the owner
$ownerUPN = "<example@example.com>"

$secureClientSecret = ConvertTo-SecureSTring -String $clientSecret -AsPlainText -Force
$clientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $clientId, $secureClientSecret

# Connect using app registration (client credentials)
Connect-MgGraph -TenantId $tenantId -ClientSecretCredential $clientSecretCredential -NoWelcome

# Confirm connection
$context = Get-MgContext
if ($context -eq $null) {
    Write-Error "Failed to authenticate with Microsoft Graph."
    break
}

# Define group properties
$groupParams = @{
    DisplayName     = "Contoso Test Group3"
    MailEnabled     = $true
    MailNickname    = "contosoTestGroup3"
    SecurityEnabled = $true
    GroupTypes      = @('Unified')
	"owners@odata.bind" = @(
	    "https://graph.microsoft.com/v1.0/users/$ownerUPN"
    )
}

# Create the group
try {
    $newGroup = New-MgGroup -BodyParameter $groupParams
    Write-Host "Group created successfully with ID: $($newGroup.Id)"
} catch {
    Write-Error "Failed to create group: $_"
}