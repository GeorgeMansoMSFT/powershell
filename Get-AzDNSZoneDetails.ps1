# Prompt for Azure DNS Zone details
$dnsZoneName = Read-Host "Please enter the DNS Zone name"

# Initialize an array to hold the DNS records details
$dnsRecordsDetails = @()

# Get all subscriptions
$subscriptions = Get-AzSubscription

# Loop through each subscription
foreach ($subscription in $subscriptions) {
    # Select the subscription context
    Set-AzContext -SubscriptionId $subscription.Id

    # Get all DNS zones that match the specified DNS zone name
    $dnsZones = Get-AzDnsZone | Where-Object { $_.Name -eq $dnsZoneName }

    # Check if DNS zones are found in the current subscription
    if ($dnsZones.Count -eq 0) {
        Write-Host "DNS Zone '$dnsZoneName' not found in subscription '$($subscription.Name)'."
        continue
    }

    # If multiple DNS zones are found, prompt the user to select one
    if ($dnsZones.Count -eq 1) {
        $dnsZone = $dnsZones[0]
    } else {
        Write-Host "Multiple DNS Zones found with the name '$dnsZoneName' in subscription '$($subscription.Name)'. Please select the correct one:"
        for ($i = 0; $i -lt $dnsZones.Count; $i++) {
            Write-Host "[$i] Resource Group: $($dnsZones[$i].ResourceGroupName)"
        }
        $selection = Read-Host "Enter the number of the correct DNS Zone"
        $dnsZone = $dnsZones[$selection]
    }

    $resourceGroupName = $dnsZone.ResourceGroupName

    # Format the CSV filename
    $date = Get-Date -Format "yyyyMMdd"
    $outputCsvPath = "{0}_{1}_{2}_AzureDNSZoneRecords.csv" -f $resourceGroupName, $dnsZoneName, $date

    # Get all DNS records from the specified DNS zone
    $dnsRecords = Get-AzDnsRecordSet -ResourceGroupName $resourceGroupName -ZoneName $dnsZoneName

    # Loop through each DNS record
    foreach ($record in $dnsRecords) {
        # Determine the value based on record type
        switch ($record.RecordType) {
            "A" {
                foreach ($a in $record.Records) {
                    $value = $a.Ipv4Address
                    $dnsRecordsDetails += [PSCustomObject]@{
                        ZoneName   = $dnsZoneName
                        RecordName = $record.Name
                        RecordType = $record.RecordType
                        Value      = $value
                    }
                }
            }
            "AAAA" {
                foreach ($aaaa in $record.Records) {
                    $value = $aaaa.Ipv6Address
                    $dnsRecordsDetails += [PSCustomObject]@{
                        ZoneName   = $dnsZoneName
                        RecordName = $record.Name
                        RecordType = $record.RecordType
                        Value      = $value
                    }
                }
            }
            "CNAME" {
                foreach ($cname in $record.Records) {
                    $value = $cname.Cname
                    $dnsRecordsDetails += [PSCustomObject]@{
                        ZoneName   = $dnsZoneName
                        RecordName = $record.Name
                        RecordType = $record.RecordType
                        Value      = $value
                    }
                }
            }
            "MX" {
                foreach ($mx in $record.Records) {
                    $value = "Preference=$($mx.Preference), Exchange=$($mx.Exchange)"
                    $dnsRecordsDetails += [PSCustomObject]@{
                        ZoneName   = $dnsZoneName
                        RecordName = $record.Name
                        RecordType = $record.RecordType
                        Value      = $value
                    }
                }
            }
            "NS" {
                foreach ($ns in $record.Records) {
                    $value = $ns.Nsdname
                    $dnsRecordsDetails += [PSCustomObject]@{
                        ZoneName   = $dnsZoneName
                        RecordName = $record.Name
                        RecordType = $record.RecordType
                        Value      = $value
                    }
                }
            }
            "PTR" {
                foreach ($ptr in $record.Records) {
                    $value = $ptr.Ptrdname
                    $dnsRecordsDetails += [PSCustomObject]@{
                        ZoneName   = $dnsZoneName
                        RecordName = $record.Name
                        RecordType = $record.RecordType
                        Value      = $value
                    }
                }
            }
            "SOA" {
                $soa = $record.Records[0]
                $value = "Email=$($soa.Email), Host=$($soa.Host), SerialNumber=$($soa.SerialNumber), RefreshTime=$($soa.RefreshTime), RetryTime=$($soa.RetryTime), ExpireTime=$($soa.ExpireTime), MinimumTtl=$($soa.MinimumTtl)"
                $dnsRecordsDetails += [PSCustomObject]@{
                    ZoneName   = $dnsZoneName
                    RecordName = $record.Name
                    RecordType = $record.RecordType
                    Value      = $value
                }
            }
            "SRV" {
                foreach ($srv in $record.Records) {
                    $value = "Priority=$($srv.Priority), Weight=$($srv.Weight), Port=$($srv.Port), Target=$($srv.Target)"
                    $dnsRecordsDetails += [PSCustomObject]@{
                        ZoneName   = $dnsZoneName
                        RecordName = $record.Name
                        RecordType = $record.RecordType
                        Value      = $value
                    }
                }
            }
            "TXT" {
                foreach ($txt in $record.Records) {
                    $value = $txt.Value -join " " # Join multiple TXT values with space
                    $dnsRecordsDetails += [PSCustomObject]@{
                        ZoneName   = $dnsZoneName
                        RecordName = $record.Name
                        RecordType = $record.RecordType
                        Value      = $value
                    }
                }
            }
        }
    }

    # Export the details to a CSV file
    $dnsRecordsDetails | Export-Csv -Path $outputCsvPath -NoTypeInformation

    Write-Host "DNS records have been exported to $outputCsvPath"
}
