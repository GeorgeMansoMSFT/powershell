# 10-SoftDeleted.ps1
# Finds soft-deleted users (in the recycle bin) referencing the domain.
# These count toward UPN uniqueness for 30 days after deletion and can block re-provisioning.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "SoftDeleted"
$OutputFile = Join-Path $OutputPath "10-soft-deleted-on-domain.csv"

Write-Host "[$ModuleName] Scanning soft-deleted users for references to @$Domain..." -ForegroundColor Yellow

try {
    # Soft-deleted users are queryable via /directory/deletedItems/microsoft.graph.user
    $uri = "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?`$top=999&`$select=id,userPrincipalName,displayName,mail,deletedDateTime"

    $deletedUsers = @()
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        $deletedUsers += $response.value
        $uri = $response.'@odata.nextLink'
    } while ($uri)

    $matches = $deletedUsers | Where-Object {
        $_.userPrincipalName -like "*@$Domain" -or
        $_.userPrincipalName -like "*$($Domain.Replace('.','_'))#EXT#*" -or
        $_.mail -like "*@$Domain"
    } | ForEach-Object {
        [PSCustomObject]@{
            ObjectId          = $_.id
            UserPrincipalName = $_.userPrincipalName
            DisplayName       = $_.displayName
            Mail              = $_.mail
            DeletedDateTime   = $_.deletedDateTime
            DaysUntilPurge    = if ($_.deletedDateTime) {
                $deleted = [DateTime]$_.deletedDateTime
                30 - ((Get-Date) - $deleted).Days
            } else { "Unknown" }
        }
    }

    if ($matches.Count -gt 0) {
        $matches | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
        $notes = "Soft-deleted users still hold UPN/email references for up to 30 days. Hard-delete via Remove-MgDirectoryDeletedItem if needed."
        Write-Host "[$ModuleName] Found $($matches.Count) soft-deleted users. $notes" -ForegroundColor DarkYellow
    } else {
        "ObjectId,UserPrincipalName,DisplayName,Mail,DeletedDateTime,DaysUntilPurge" | Out-File $OutputFile -Encoding UTF8
        $notes = "No soft-deleted users referencing the domain."
        Write-Host "[$ModuleName] $notes" -ForegroundColor Green
    }

    Add-InventorySummary -Module $ModuleName -Count $matches.Count -OutputFile $OutputFile -Notes $notes
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
