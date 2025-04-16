# Configuration
$resourceGroup = ""
$storageAccountName = ""
$sourceContainerName = ""
$destinationContainerName = ""
$targetFolder = ""

# Authenticate
Connect-AzAccount

# Use connected account for context
$context = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

# Get all blobs from source container
$allBlobs = Get-AzStorageBlob -Container $sourceContainerName -Context $context -Blob "*"

foreach ($blob in $allBlobs) {
    # Match folder pattern: y=2025/m=04/d=15/h=05/m=10/PT5M.json
    if ($blob.Name -match "y=(\d{4})/m=(\d{2})/d=(\d{2})/h=(\d{2})/m=(\d{2})/(.+\.json)$") {
        $year   = $matches[1]
        $month  = $matches[2]
        $day    = $matches[3]
        $hour   = $matches[4]
        $minute = $matches[5]
        $filename = $matches[6]

        # Insert timestamp and random digits before extension
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filename)
        $extension = [System.IO.Path]::GetExtension($filename)
        $uniqueSuffix = "-{0}-{1}-{2}-{3}-{4}" -f $month, $day, $hour, $minute, (Get-Random -Maximum 9999)
        $newFileName = "$baseName$uniqueSuffix$extension"

        # Final destination path
        $newBlobName = "$targetFolder/$newFileName"

        # Skip if already exists
        $exists = Get-AzStorageBlob -Container $destinationContainerName -Blob $newBlobName -Context $context -ErrorAction SilentlyContinue
        if (-not $exists) {
            Start-AzStorageBlobCopy -SrcBlob $blob.Name -SrcContainer $sourceContainerName -DestContainer $destinationContainerName -DestBlob $newBlobName -Context $context
            Write-Host "Copying: $($blob.Name) → $destinationContainerName/$newBlobName"

            # Wait for copy to complete
            $copyStatus = "pending"
            while ($copyStatus -eq "pending") {
                Start-Sleep -Seconds 1
                $copyStatus = (Get-AzStorageBlobCopyState -Blob $newBlobName -Container $destinationContainerName -Context $context).Status
            }
            if ($copyStatus -eq "success") {
                Remove-AzStorageBlob -Blob $blob.Name -Container $sourceContainerName -Context $context
                Write-Host "Deleted original blob: $($blob.Name)"

                # Get the folder path (everything up to the filename)
                $folderPrefix = ($blob.Name -split "/")[0..($blob.Name.Split("/").Count - 2)] -join "/"

                # Check for other blobs in the same "folder"
                $remaining = Get-AzStorageBlob -Container $sourceContainerName -Context $context -Prefix "$folderPrefix/" -ErrorAction SilentlyContinue

                if ($remaining.Count -eq 0) {
                    Write-Host "✅ Folder '$folderPrefix/' is now empty."

                    # Try deleting a folder placeholder blob if it exists
                    $folderBlob = Get-AzStorageBlob -Container $sourceContainerName -Context $context -Blob "$folderPrefix/" -ErrorAction SilentlyContinue

                    if ($folderBlob) {
                        Remove-AzStorageBlob -Container $sourceContainerName -Blob "$folderPrefix" -Context $context
                        Write-Host "🗑️ Deleted folder placeholder blob: $folderPrefix/"
                    }
                }
            }
        }
    }
}
