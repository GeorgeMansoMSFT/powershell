# 02-Groups.ps1
# Finds groups (M365, distribution, mail-enabled security) with mail or proxyAddresses on the domain.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "Groups"
$OutputFile = Join-Path $OutputPath "02-groups-on-domain.csv"

Write-Host "[$ModuleName] Scanning groups for references to @$Domain..." -ForegroundColor Yellow

try {
    $allGroups = Get-MgGroup -All -Property `
        Id, DisplayName, Mail, ProxyAddresses, GroupTypes, MailEnabled, SecurityEnabled, OnPremisesSyncEnabled `
        -ErrorAction Stop

    $matches = foreach ($g in $allGroups) {
        $reasons = @()

        if ($g.Mail -like "*@$Domain") { $reasons += "Mail" }

        $proxyHits = @($g.ProxyAddresses | Where-Object { $_ -like "*@$Domain*" })
        if ($proxyHits.Count -gt 0) { $reasons += "ProxyAddresses($($proxyHits.Count))" }

        if ($reasons.Count -gt 0) {
            $groupType = if ($g.GroupTypes -contains "Unified")    { "M365 Group" }
                         elseif ($g.MailEnabled -and $g.SecurityEnabled) { "Mail-Enabled Security" }
                         elseif ($g.MailEnabled)                  { "Distribution List" }
                         elseif ($g.SecurityEnabled)              { "Security Group" }
                         else                                     { "Unknown" }

            [PSCustomObject]@{
                ObjectId             = $g.Id
                DisplayName          = $g.DisplayName
                GroupType            = $groupType
                Mail                 = $g.Mail
                IsSyncedFromOnPrem   = $g.OnPremisesSyncEnabled -eq $true
                MatchReasons         = ($reasons -join ";")
                ProxyAddressesOnDomain = ($proxyHits -join ";")
            }
        }
    }

    if ($matches.Count -gt 0) {
        $matches | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    } else {
        "ObjectId,DisplayName,GroupType,Mail,IsSyncedFromOnPrem,MatchReasons,ProxyAddressesOnDomain" |
            Out-File -FilePath $OutputFile -Encoding UTF8
    }

    $byType = $matches | Group-Object GroupType | ForEach-Object { "$($_.Name)=$($_.Count)" }
    $notes  = ($byType -join "; ")

    Write-Host "[$ModuleName] Found $($matches.Count) groups. $notes" -ForegroundColor Green
    Add-InventorySummary -Module $ModuleName -Count $matches.Count -OutputFile $OutputFile -Notes $notes
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
