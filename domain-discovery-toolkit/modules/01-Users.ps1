# 01-Users.ps1
# Finds active users with the verified domain in UPN, mail, proxyAddresses, or otherMails.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath,
    [bool] $IncludeGuests = $true
)

$ModuleName = "Users"
$OutputFile = Join-Path $OutputPath "01-users-on-domain.csv"

Write-Host "[$ModuleName] Scanning users for references to @$Domain..." -ForegroundColor Yellow

try {
    $filter = if ($IncludeGuests) { $null } else { "userType eq 'Member'" }

    # Pull all users with the relevant attributes. -All paginates automatically.
    $allUsers = Get-MgUser -All -Filter $filter -Property `
        Id, UserPrincipalName, DisplayName, Mail, OtherMails, ProxyAddresses, UserType, AccountEnabled, OnPremisesSyncEnabled `
        -ErrorAction Stop

    $matches = foreach ($user in $allUsers) {
        $reasons = @()

        if ($user.UserPrincipalName -like "*@$Domain") { $reasons += "UPN" }
        if ($user.Mail -like "*@$Domain")              { $reasons += "Mail" }

        $proxyHits = @($user.ProxyAddresses | Where-Object { $_ -like "*@$Domain*" })
        if ($proxyHits.Count -gt 0) { $reasons += "ProxyAddresses($($proxyHits.Count))" }

        $otherHits = @($user.OtherMails | Where-Object { $_ -like "*@$Domain" })
        if ($otherHits.Count -gt 0) { $reasons += "OtherMails($($otherHits.Count))" }

        # For guests, the UPN is mangled (george_contoso.com#EXT#@tenant.onmicrosoft.com)
        # so we also check for that pattern.
        if ($user.UserType -eq "Guest" -and $user.UserPrincipalName -like "*_$($Domain.Replace('.', '_'))#EXT#*") {
            $reasons += "GuestUPN(mangled)"
        }

        if ($reasons.Count -gt 0) {
            [PSCustomObject]@{
                ObjectId           = $user.Id
                UserPrincipalName  = $user.UserPrincipalName
                DisplayName        = $user.DisplayName
                Mail               = $user.Mail
                UserType           = $user.UserType
                AccountEnabled     = $user.AccountEnabled
                IsSyncedFromOnPrem = $user.OnPremisesSyncEnabled -eq $true
                MatchReasons       = ($reasons -join ";")
                ProxyAddressesOnDomain = ($proxyHits -join ";")
                OtherMailsOnDomain     = ($otherHits -join ";")
            }
        }
    }

    if ($matches.Count -gt 0) {
        $matches | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    } else {
        # Still create the file so it's clear we ran
        "ObjectId,UserPrincipalName,DisplayName,Mail,UserType,AccountEnabled,IsSyncedFromOnPrem,MatchReasons,ProxyAddressesOnDomain,OtherMailsOnDomain" |
            Out-File -FilePath $OutputFile -Encoding UTF8
    }

    $syncedCount = @($matches | Where-Object { $_.IsSyncedFromOnPrem }).Count
    $cloudCount = @($matches | Where-Object { -not $_.IsSyncedFromOnPrem }).Count
    $guestCount = @($matches | Where-Object { $_.UserType -eq "Guest" }).Count

    $notes = "Synced=$syncedCount; Cloud-only=$cloudCount; Guests=$guestCount"
    Write-Host "[$ModuleName] Found $($matches.Count) users referencing @$Domain. $notes" -ForegroundColor Green

    Add-InventorySummary -Module $ModuleName -Count $matches.Count -OutputFile $OutputFile -Notes $notes
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
