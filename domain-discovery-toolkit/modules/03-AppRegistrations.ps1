# 03-AppRegistrations.ps1
# Finds app registrations with the domain in redirect URIs, identifier URIs, or logout URLs.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "AppRegistrations"
$OutputFile = Join-Path $OutputPath "03-app-registrations-on-domain.csv"

Write-Host "[$ModuleName] Scanning app registrations for references to $Domain..." -ForegroundColor Yellow

try {
    $allApps = Get-MgApplication -All -Property `
        Id, AppId, DisplayName, Web, Spa, PublicClient, IdentifierUris, SignInAudience, Notes `
        -ErrorAction Stop

    $matches = foreach ($app in $allApps) {
        $hits = @{}

        $webRedirects = @($app.Web.RedirectUris   | Where-Object { $_ -like "*$Domain*" })
        $spaRedirects = @($app.Spa.RedirectUris   | Where-Object { $_ -like "*$Domain*" })
        $pubRedirects = @($app.PublicClient.RedirectUris | Where-Object { $_ -like "*$Domain*" })
        $idUris       = @($app.IdentifierUris    | Where-Object { $_ -like "*$Domain*" })
        $logoutUrl    = if ($app.Web.LogoutUrl -like "*$Domain*") { $app.Web.LogoutUrl } else { $null }
        $homePageUrl  = if ($app.Web.HomePageUrl -like "*$Domain*") { $app.Web.HomePageUrl } else { $null }

        if ($webRedirects.Count -gt 0) { $hits["WebRedirects"] = $webRedirects -join ";" }
        if ($spaRedirects.Count -gt 0) { $hits["SpaRedirects"] = $spaRedirects -join ";" }
        if ($pubRedirects.Count -gt 0) { $hits["PublicClientRedirects"] = $pubRedirects -join ";" }
        if ($idUris.Count -gt 0)       { $hits["IdentifierUris"] = $idUris -join ";" }
        if ($logoutUrl)                { $hits["LogoutUrl"] = $logoutUrl }
        if ($homePageUrl)              { $hits["HomePageUrl"] = $homePageUrl }

        if ($hits.Count -gt 0) {
            [PSCustomObject]@{
                ObjectId       = $app.Id
                AppId          = $app.AppId
                DisplayName    = $app.DisplayName
                SignInAudience = $app.SignInAudience
                MatchTypes     = ($hits.Keys -join ";")
                WebRedirects           = $hits["WebRedirects"]
                SpaRedirects           = $hits["SpaRedirects"]
                PublicClientRedirects  = $hits["PublicClientRedirects"]
                IdentifierUris         = $hits["IdentifierUris"]
                LogoutUrl              = $hits["LogoutUrl"]
                HomePageUrl            = $hits["HomePageUrl"]
                Notes                  = $app.Notes
            }
        }
    }

    if ($matches.Count -gt 0) {
        $matches | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    } else {
        "ObjectId,AppId,DisplayName,SignInAudience,MatchTypes,WebRedirects,SpaRedirects,PublicClientRedirects,IdentifierUris,LogoutUrl,HomePageUrl,Notes" |
            Out-File -FilePath $OutputFile -Encoding UTF8
    }

    $idUriCount = @($matches | Where-Object { $_.IdentifierUris }).Count
    $notes = "WithIdentifierUris=$idUriCount (these are HARD blockers)"

    Write-Host "[$ModuleName] Found $($matches.Count) app registrations. $notes" -ForegroundColor Green
    Add-InventorySummary -Module $ModuleName -Count $matches.Count -OutputFile $OutputFile -Notes $notes
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
