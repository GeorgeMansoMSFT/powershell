# 04-ServicePrincipals.ps1
# Finds service principals (including enterprise apps) with the domain in reply URLs, login/logout URLs, or notification emails.
# Excludes managed identities (handled separately by module 05).

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "ServicePrincipals"
$OutputFile = Join-Path $OutputPath "04-service-principals-on-domain.csv"

Write-Host "[$ModuleName] Scanning service principals for references to $Domain..." -ForegroundColor Yellow

try {
    $allSPs = Get-MgServicePrincipal -All -Property `
        Id, AppId, DisplayName, ServicePrincipalType, ReplyUrls, LoginUrl, LogoutUrl, NotificationEmailAddresses, Homepage, Tags `
        -ErrorAction Stop

    $matches = foreach ($sp in $allSPs) {
        # Skip managed identities - they get their own module
        if ($sp.ServicePrincipalType -eq "ManagedIdentity") { continue }

        $hits = @{}

        $replyUrls = @($sp.ReplyUrls | Where-Object { $_ -like "*$Domain*" })
        $notifMails = @($sp.NotificationEmailAddresses | Where-Object { $_ -like "*@$Domain" })

        if ($replyUrls.Count -gt 0)              { $hits["ReplyUrls"] = $replyUrls -join ";" }
        if ($sp.LoginUrl  -like "*$Domain*")     { $hits["LoginUrl"]  = $sp.LoginUrl }
        if ($sp.LogoutUrl -like "*$Domain*")     { $hits["LogoutUrl"] = $sp.LogoutUrl }
        if ($sp.Homepage  -like "*$Domain*")     { $hits["Homepage"]  = $sp.Homepage }
        if ($notifMails.Count -gt 0)             { $hits["NotificationEmails"] = $notifMails -join ";" }

        if ($hits.Count -gt 0) {
            [PSCustomObject]@{
                ObjectId             = $sp.Id
                AppId                = $sp.AppId
                DisplayName          = $sp.DisplayName
                ServicePrincipalType = $sp.ServicePrincipalType
                MatchTypes           = ($hits.Keys -join ";")
                ReplyUrls            = $hits["ReplyUrls"]
                LoginUrl             = $hits["LoginUrl"]
                LogoutUrl            = $hits["LogoutUrl"]
                Homepage             = $hits["Homepage"]
                NotificationEmails   = $hits["NotificationEmails"]
            }
        }
    }

    if ($matches.Count -gt 0) {
        $matches | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    } else {
        "ObjectId,AppId,DisplayName,ServicePrincipalType,MatchTypes,ReplyUrls,LoginUrl,LogoutUrl,Homepage,NotificationEmails" |
            Out-File -FilePath $OutputFile -Encoding UTF8
    }

    $byType = $matches | Group-Object ServicePrincipalType | ForEach-Object { "$($_.Name)=$($_.Count)" }
    $notes  = ($byType -join "; ")

    Write-Host "[$ModuleName] Found $($matches.Count) service principals. $notes" -ForegroundColor Green
    Add-InventorySummary -Module $ModuleName -Count $matches.Count -OutputFile $OutputFile -Notes $notes
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
