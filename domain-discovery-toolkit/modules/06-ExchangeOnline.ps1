# 06-ExchangeOnline.ps1
# Finds Exchange Online objects referencing the domain: mailboxes, DLs, mail contacts, transport rules, connectors, accepted domains.
# Requires Connect-ExchangeOnline before running.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "ExchangeOnline"
$MailboxFile     = Join-Path $OutputPath "06-exchange-mailboxes.csv"
$DLFile          = Join-Path $OutputPath "06-exchange-distribution-groups.csv"
$ContactFile     = Join-Path $OutputPath "06-exchange-mail-contacts.csv"
$MailUserFile    = Join-Path $OutputPath "06-exchange-mail-users.csv"
$TransportFile   = Join-Path $OutputPath "06-exchange-transport-rules.csv"
$ConnectorFile   = Join-Path $OutputPath "06-exchange-connectors.csv"
$AcceptedFile    = Join-Path $OutputPath "06-exchange-accepted-domains.csv"

Write-Host "[$ModuleName] Scanning Exchange Online for references to $Domain..." -ForegroundColor Yellow

# Verify EXO connection
try {
    $null = Get-ConnectionInformation -ErrorAction Stop | Where-Object State -eq "Connected"
} catch {
    Write-DiscoveryError -Module $ModuleName -Message "Not connected to Exchange Online. Run Connect-ExchangeOnline first."
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile "" -Notes "ERROR: Not connected to EXO"
    return
}

$totalCount = 0

# Accepted domains
try {
    $accepted = @(Get-AcceptedDomain | Where-Object DomainName -like "*$Domain*")
    if ($accepted.Count -gt 0) {
        $accepted | Select-Object Name, DomainName, DomainType, Default |
            Export-Csv -Path $AcceptedFile -NoTypeInformation -Encoding UTF8
        $totalCount += $accepted.Count
        Write-Host "[$ModuleName]   Accepted domains: $($accepted.Count)" -ForegroundColor Cyan
    }
} catch {
    Write-DiscoveryError -Module $ModuleName -Message "Accepted domains query failed: $($_.Exception.Message)"
}

# Mailboxes
try {
    Write-Host "[$ModuleName]   Scanning mailboxes (this can be slow on large tenants)..." -ForegroundColor Cyan
    $mailboxes = @(Get-Mailbox -ResultSize Unlimited |
        Where-Object {
            $_.PrimarySmtpAddress -like "*@$Domain" -or
            (($_.EmailAddresses -join ";") -like "*@$Domain*") -or
            $_.UserPrincipalName -like "*@$Domain"
        } |
        Select-Object Name, DisplayName, PrimarySmtpAddress, UserPrincipalName, RecipientTypeDetails,
                      @{n='EmailAddressesOnDomain';e={ ($_.EmailAddresses | Where-Object { $_ -like "*@$Domain*" }) -join ";" }})

    if ($mailboxes.Count -gt 0) {
        $mailboxes | Export-Csv -Path $MailboxFile -NoTypeInformation -Encoding UTF8
        $totalCount += $mailboxes.Count
        Write-Host "[$ModuleName]   Mailboxes: $($mailboxes.Count)" -ForegroundColor Cyan
    }
} catch {
    Write-DiscoveryError -Module $ModuleName -Message "Mailbox enumeration failed: $($_.Exception.Message)"
}

# Distribution groups
try {
    $dls = @(Get-DistributionGroup -ResultSize Unlimited |
        Where-Object {
            $_.PrimarySmtpAddress -like "*@$Domain" -or
            (($_.EmailAddresses -join ";") -like "*@$Domain*")
        } |
        Select-Object Name, DisplayName, PrimarySmtpAddress, RecipientTypeDetails,
                      @{n='EmailAddressesOnDomain';e={ ($_.EmailAddresses | Where-Object { $_ -like "*@$Domain*" }) -join ";" }})

    if ($dls.Count -gt 0) {
        $dls | Export-Csv -Path $DLFile -NoTypeInformation -Encoding UTF8
        $totalCount += $dls.Count
        Write-Host "[$ModuleName]   Distribution groups: $($dls.Count)" -ForegroundColor Cyan
    }
} catch {
    Write-DiscoveryError -Module $ModuleName -Message "DG enumeration failed: $($_.Exception.Message)"
}

# Mail contacts
try {
    $contacts = @(Get-MailContact -ResultSize Unlimited |
        Where-Object {
            $_.PrimarySmtpAddress -like "*@$Domain" -or
            (($_.EmailAddresses -join ";") -like "*@$Domain*")
        } |
        Select-Object Name, DisplayName, PrimarySmtpAddress, ExternalEmailAddress,
                      @{n='EmailAddressesOnDomain';e={ ($_.EmailAddresses | Where-Object { $_ -like "*@$Domain*" }) -join ";" }})

    if ($contacts.Count -gt 0) {
        $contacts | Export-Csv -Path $ContactFile -NoTypeInformation -Encoding UTF8
        $totalCount += $contacts.Count
        Write-Host "[$ModuleName]   Mail contacts: $($contacts.Count)" -ForegroundColor Cyan
    }
} catch {
    Write-DiscoveryError -Module $ModuleName -Message "Mail contact enumeration failed: $($_.Exception.Message)"
}

# Mail users
try {
    $mailUsers = @(Get-MailUser -ResultSize Unlimited |
        Where-Object {
            $_.PrimarySmtpAddress -like "*@$Domain" -or
            (($_.EmailAddresses -join ";") -like "*@$Domain*") -or
            $_.ExternalEmailAddress -like "*@$Domain"
        } |
        Select-Object Name, DisplayName, PrimarySmtpAddress, ExternalEmailAddress,
                      @{n='EmailAddressesOnDomain';e={ ($_.EmailAddresses | Where-Object { $_ -like "*@$Domain*" }) -join ";" }})

    if ($mailUsers.Count -gt 0) {
        $mailUsers | Export-Csv -Path $MailUserFile -NoTypeInformation -Encoding UTF8
        $totalCount += $mailUsers.Count
        Write-Host "[$ModuleName]   Mail users: $($mailUsers.Count)" -ForegroundColor Cyan
    }
} catch {
    Write-DiscoveryError -Module $ModuleName -Message "Mail user enumeration failed: $($_.Exception.Message)"
}

# Transport rules
try {
    $rules = @(Get-TransportRule | Where-Object {
        ($_.SenderDomainIs    -contains $Domain) -or
        ($_.RecipientDomainIs -contains $Domain) -or
        ($_.From              -join ";") -like "*@$Domain*" -or
        ($_.SentTo            -join ";") -like "*@$Domain*"
    })
    if ($rules.Count -gt 0) {
        $rules | Select-Object Name, State, Priority, SenderDomainIs, RecipientDomainIs |
            Export-Csv -Path $TransportFile -NoTypeInformation -Encoding UTF8
        $totalCount += $rules.Count
        Write-Host "[$ModuleName]   Transport rules: $($rules.Count)" -ForegroundColor Cyan
    }
} catch {
    Write-DiscoveryError -Module $ModuleName -Message "Transport rule enumeration failed: $($_.Exception.Message)"
}

# Connectors (inbound + outbound)
try {
    $inbound = Get-InboundConnector | Where-Object { ($_.SenderDomains -join ";") -like "*$Domain*" }
    $outbound = Get-OutboundConnector | Where-Object { ($_.RecipientDomains -join ";") -like "*$Domain*" }

    $connectors = @()
    if ($inbound)  { $connectors += $inbound  | Select-Object Name, @{n='Direction';e={'Inbound'}}, Enabled, SenderDomains }
    if ($outbound) { $connectors += $outbound | Select-Object Name, @{n='Direction';e={'Outbound'}}, Enabled, @{n='SenderDomains';e={$_.RecipientDomains}} }

    if ($connectors.Count -gt 0) {
        $connectors | Export-Csv -Path $ConnectorFile -NoTypeInformation -Encoding UTF8
        $totalCount += $connectors.Count
        Write-Host "[$ModuleName]   Connectors: $($connectors.Count)" -ForegroundColor Cyan
    }
} catch {
    Write-DiscoveryError -Module $ModuleName -Message "Connector enumeration failed: $($_.Exception.Message)"
}

Write-Host "[$ModuleName] Total Exchange Online references: $totalCount" -ForegroundColor Green
Add-InventorySummary -Module $ModuleName -Count $totalCount -OutputFile "06-exchange-*.csv (multiple files)" -Notes "See 06-exchange-*.csv files in the output directory"
