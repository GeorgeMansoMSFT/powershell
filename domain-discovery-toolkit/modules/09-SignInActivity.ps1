# 09-SignInActivity.ps1
# Pulls sign-in logs to identify which UPNs on the domain are actively being used,
# and which apps they're signing into. This tells you where to focus migration effort.
# Requires AuditLog.Read.All permission.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath,
    [int] $LookbackDays = 30
)

$ModuleName = "SignInActivity"
$ByUserFile  = Join-Path $OutputPath "09-signins-by-user.csv"
$ByAppFile   = Join-Path $OutputPath "09-signins-by-app.csv"

Write-Host "[$ModuleName] Pulling $LookbackDays days of sign-in activity for *@$Domain..." -ForegroundColor Yellow
Write-Host "[$ModuleName] Note: Graph API caps at 30 days. For longer history, use Sentinel/Log Analytics." -ForegroundColor DarkYellow

try {
    $startDate = (Get-Date).AddDays(-$LookbackDays).ToString("yyyy-MM-ddTHH:mm:ssZ")

    # Interactive sign-ins
    $filter = "userPrincipalName eq '*@$Domain' or endsWith(userPrincipalName,'@$Domain')"
    # Graph filter syntax for endsWith on UPN requires ConsistencyLevel:eventual
    $filter = "createdDateTime ge $startDate"

    Write-Host "[$ModuleName]   Querying interactive sign-ins (this can take a while)..." -ForegroundColor Cyan

    $signIns = Get-MgAuditLogSignIn -All -Filter $filter -ErrorAction Stop |
        Where-Object { $_.UserPrincipalName -like "*@$Domain" }

    Write-Host "[$ModuleName]   Got $($signIns.Count) interactive sign-in events. Aggregating..." -ForegroundColor Cyan

    if ($signIns.Count -gt 0) {
        # By user
        $byUser = $signIns |
            Group-Object UserPrincipalName, UserId |
            ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                [PSCustomObject]@{
                    UserPrincipalName = $first.UserPrincipalName
                    UserId            = $first.UserId
                    UserDisplayName   = $first.UserDisplayName
                    SignInCount       = $_.Count
                    LastSignIn        = ($_.Group | Sort-Object CreatedDateTime -Descending | Select-Object -First 1).CreatedDateTime
                    DistinctApps      = ($_.Group | Select-Object -ExpandProperty AppDisplayName -Unique).Count
                    DistinctIPs       = ($_.Group | Select-Object -ExpandProperty IPAddress -Unique).Count
                    Apps              = (($_.Group | Select-Object -ExpandProperty AppDisplayName -Unique) -join ";")
                }
            } |
            Sort-Object SignInCount -Descending

        $byUser | Export-Csv -Path $ByUserFile -NoTypeInformation -Encoding UTF8

        # By app
        $byApp = $signIns |
            Group-Object AppDisplayName, AppId |
            ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                [PSCustomObject]@{
                    AppDisplayName = $first.AppDisplayName
                    AppId          = $first.AppId
                    SignInCount    = $_.Count
                    DistinctUsers  = ($_.Group | Select-Object -ExpandProperty UserId -Unique).Count
                    LastSignIn     = ($_.Group | Sort-Object CreatedDateTime -Descending | Select-Object -First 1).CreatedDateTime
                }
            } |
            Sort-Object SignInCount -Descending

        $byApp | Export-Csv -Path $ByAppFile -NoTypeInformation -Encoding UTF8

        $notes = "Users with activity=$(@($byUser).Count); Apps with activity=$(@($byApp).Count); Total events=$($signIns.Count)"
        Write-Host "[$ModuleName] $notes" -ForegroundColor Green
        Add-InventorySummary -Module $ModuleName -Count $signIns.Count -OutputFile $ByUserFile -Notes $notes
    } else {
        "UserPrincipalName,UserId,UserDisplayName,SignInCount,LastSignIn,DistinctApps,DistinctIPs,Apps" | Out-File $ByUserFile -Encoding UTF8
        "AppDisplayName,AppId,SignInCount,DistinctUsers,LastSignIn" | Out-File $ByAppFile -Encoding UTF8
        Write-Host "[$ModuleName] No sign-in events found for *@$Domain in the last $LookbackDays days." -ForegroundColor Green
        Add-InventorySummary -Module $ModuleName -Count 0 -OutputFile $ByUserFile -Notes "No activity in lookback window"
    }
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $ByUserFile -Notes "ERROR: $($_.Exception.Message)"
}
