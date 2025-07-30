# Requires: Az.Accounts, Az.Security modules

param(
    [Parameter(Mandatory=$false)]
    [string]$InputFile, # Path to CSV or TXT file with SubscriptionId column or single-column list

    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId # Single subscription ID
)

# Validate input parameters
# Ensure that at least one of InputFile or SubscriptionId is provided
if (-not $InputFile -and -not $SubscriptionId) {
    Write-Error "You must provide either -InputFile or -SubscriptionId."
    exit
}

# Load subscription IDs from file or parameter
# Supports both CSV and TXT file formats, or direct parameter input
$subscriptionIds = @()
if ($InputFile) {
    if ($InputFile.ToLower().EndsWith('.csv')) {
        $subscriptionIds = (Import-Csv $InputFile).SubscriptionId
    } else {
        $subscriptionIds = Get-Content $InputFile
    }
} elseif ($SubscriptionId) {
    $subscriptionIds = @($SubscriptionId)
}

# Login to Azure if not already authenticated
if (-not (Get-AzContext)) {
    Connect-AzAccount
}

foreach ($subId in $subscriptionIds) {
    Write-Host "Processing subscription: $subId" -ForegroundColor Cyan
    Select-AzSubscription -SubscriptionId $subId | Out-Null

    # Retrieve CloudPosture pricing settings from Defender for Cloud
    $cloudPosturePricing = Get-AzSecurityPricing -Name "CloudPosture"

    if ($cloudPosturePricing) {
        $extensions = @()

        # Parse Extensions JSON data into a PowerShell object array
        # If parsing fails, initialize as an empty array
        if ($cloudPosturePricing.Extensions) {
            try {
                $extensions = $cloudPosturePricing.Extensions | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $extensions = @()
            }
        }

        # Remove "additionalExtensionProperties" from disabled extensions (except ApiPosture)
        # This prevents update errors when modifying unrelated disabled extensions
        foreach ($ext in $extensions) {
            if ($ext.isEnabled -eq $false -and $ext.name -ne "ApiPosture") {
                $ext.PSObject.Properties.Remove('additionalExtensionProperties')
            }
        }

        # Find the ApiPosture extension in the extensions list
        $apiExtension = $extensions | Where-Object { $_.name -eq "ApiPosture" }

        if (-not $apiExtension) {
            # ApiPosture not present, so we add it as enabled
            Write-Host "Enabling API Security Posture Management..." -ForegroundColor Yellow
            $extensions += [pscustomobject]@{
                name = "ApiPosture"
                isEnabled = $true
                additionalExtensionProperties = $null
                operationStatus = $null
            }
        } elseif ($apiExtension.isEnabled -ne $true) {
            # ApiPosture exists but is disabled, so we enable it
            Write-Host "Turning on API Security Posture Management..." -ForegroundColor Yellow
            $apiExtension.isEnabled = $true
        } else {
            # ApiPosture already enabled, skip changes
            Write-Host "API Security Posture Management already enabled for subscription: $subId" -ForegroundColor Gray
            continue
        }

        # Convert updated extensions list back to JSON for API update
        $jsonExtensions = $extensions | ConvertTo-Json -Depth 5 -Compress

        # Update CloudPosture pricing with new extension settings
        Set-AzSecurityPricing -Name "CloudPosture" -PricingTier $cloudPosturePricing.PricingTier -Extension $jsonExtensions | Out-Null

        Write-Host "Enabled for subscription: $subId" -ForegroundColor Green
    } else {
        # CloudPosture pricing not available for subscription
        Write-Host "CloudPosture pricing option not found in subscription: $subId" -ForegroundColor Red
    }
}
