# Script: Export Defender XDR Machine Vulnerabilities and Recommendations
# Description: Retrieves devices tagged with 'AttackPath' and exports their vulnerabilities and recommendations to a CSV
# Debug mode available using the -DebugMode switch
# Need Machine.Read.All, SecurityRecommendation.Read.All, and Vulnerability.Read.All in WindowsDefenderATP API

param (
    [switch]$DebugMode
)

# --- App Registration and Token Retrieval ---
$tenantId = "<tenantId>"
$clientId = "<clientId"
$clientSecret = "<clientSecret>"
$scope = "https://api.securitycenter.microsoft.com/.default"
$tokenEndpoint = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

if ($DebugMode) { Write-Host "Requesting token from $tokenEndpoint..." }

# Request access token using client credentials
$body = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = $scope
}
$response = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body -ContentType "application/x-www-form-urlencoded"
$token = $response.access_token

if ($DebugMode) { Write-Host "Access token acquired." }

# --- Helper to call Defender API securely ---
function Invoke-DefenderApi {
    param (
        [string]$Uri
    )
    if ($DebugMode) { Write-Host "Calling API: $Uri" }
    try {
        return Invoke-RestMethod -Method GET -Uri $Uri -Headers @{ Authorization = "Bearer $token" } -ContentType "application/json"
    } catch {
        Write-Warning "API call to $Uri failed: $_"
        return $null
    }
}

# --- Retrieve Devices with 'AttackPath' Tag ---
function Get-AttackPathDevices {
    $uri = "https://api.securitycenter.microsoft.com/api/machines"
    $allDevices = Invoke-DefenderApi -Uri $uri
    if ($null -eq $allDevices) { return @() }
    $filtered = $allDevices.value | Where-Object { $_.machineTags -contains "AttackPath" }
    if ($DebugMode) { Write-Host "Found $($filtered.Count) devices with tag 'AttackPath'." }
    return $filtered
}

# --- Get Vulnerabilities for a Device ---
function Get-DeviceVulnerabilities {
    param ($deviceId)
    $uri = "https://api.securitycenter.microsoft.com/api/machines/$deviceId/vulnerabilities"
    $result = Invoke-DefenderApi -Uri $uri
    if ($DebugMode) { Write-Host "Retrieved $($result.value.Count) vulnerabilities for device $deviceId" }
    return $result.value
}

# --- Get Recommendations for a Device ---
function Get-DeviceRecommendations {
    param ($deviceId)
    $uri = "https://api.securitycenter.microsoft.com/api/machines/$deviceId/recommendations"
    $result = Invoke-DefenderApi -Uri $uri
    if ($DebugMode) { Write-Host "Retrieved $($result.value.Count) recommendations for device $deviceId" }
    return $result.value
}

# --- Main Function to Export CSV Report ---
function Export-AttackPathDeviceReport {
    $devices = Get-AttackPathDevices
    $report = @()

    foreach ($device in $devices) {
        $deviceId = $device.id
        $deviceName = $device.computerDnsName
        $ipAddress = $device.lastIpAddress

        if ($DebugMode) { Write-Host "\nProcessing device: $deviceName ($deviceId) - IP: $ipAddress" }

        # Add each vulnerability as a row with CVE in its own column
        $vulns = Get-DeviceVulnerabilities -deviceId $deviceId
        foreach ($vuln in $vulns) {
            if ($DebugMode) { Write-Host "  Vulnerability: $($vuln.name)" }
            $report += [PSCustomObject]@{
                DeviceName = $deviceName
                IPAddress = $ipAddress
                DeviceID = $deviceId
                Type = "Vulnerability"
                CVE = $vuln.name
                Title = $vuln.description
            }
        }

        # Add each recommendation with its title and description
        $recs = Get-DeviceRecommendations -deviceId $deviceId
        foreach ($rec in $recs) {
            if ($DebugMode) { Write-Host "  Recommendation: $($rec.recommendationName)" }
            $report += [PSCustomObject]@{
                DeviceName = $deviceName
                IPAddress = $ipAddress
                DeviceID = $deviceId
                Type = "Recommendation"
                CVE = $null
                Title = $rec.recommendationName
                Description = $rec.recommendationDescription
            }
        }
    }

    # Export report to CSV
    $report | Export-Csv -Path "AttackPath_Device_Report.csv" -NoTypeInformation -Encoding UTF8
    Write-Host "\nCSV export complete: AttackPath_Device_Report.csv"
}

# Execute the main export function
Export-AttackPathDeviceReport
