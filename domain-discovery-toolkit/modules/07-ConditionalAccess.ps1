# 07-ConditionalAccess.ps1
# Finds Conditional Access policies that reference the domain in any condition.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Domain,
    [Parameter(Mandatory)] [string] $OutputPath
)

$ModuleName = "ConditionalAccess"
$OutputFile = Join-Path $OutputPath "07-conditional-access-on-domain.csv"

Write-Host "[$ModuleName] Scanning Conditional Access policies for references to $Domain..." -ForegroundColor Yellow

try {
    $policies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop

    $matches = foreach ($p in $policies) {
        # Serialize the policy to JSON and search the entire blob - CA policies have many places
        # where a domain could be referenced (filter by user attribute, exclude/include domains for guests, etc.).
        $json = $p | ConvertTo-Json -Depth 10 -Compress
        if ($json -like "*$Domain*") {
            # Find the surrounding context for each match
            $contextSnippets = @()
            $startIndex = 0
            while ($startIndex -lt $json.Length) {
                $idx = $json.IndexOf($Domain, $startIndex, [System.StringComparison]::OrdinalIgnoreCase)
                if ($idx -lt 0) { break }
                $start = [Math]::Max(0, $idx - 60)
                $len   = [Math]::Min(140, $json.Length - $start)
                $contextSnippets += $json.Substring($start, $len)
                $startIndex = $idx + $Domain.Length
            }

            [PSCustomObject]@{
                PolicyId    = $p.Id
                DisplayName = $p.DisplayName
                State       = $p.State
                CreatedDateTime = $p.CreatedDateTime
                ModifiedDateTime = $p.ModifiedDateTime
                MatchSnippets = ($contextSnippets | Select-Object -Unique) -join " || "
            }
        }
    }

    if ($matches.Count -gt 0) {
        $matches | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    } else {
        "PolicyId,DisplayName,State,CreatedDateTime,ModifiedDateTime,MatchSnippets" | Out-File -FilePath $OutputFile -Encoding UTF8
    }

    Write-Host "[$ModuleName] Found $($matches.Count) CA policies referencing $Domain." -ForegroundColor Green
    Add-InventorySummary -Module $ModuleName -Count $matches.Count -OutputFile $OutputFile -Notes "Review snippets - domain may appear in named locations, user filters, or external IDs"
}
catch {
    Write-DiscoveryError -Module $ModuleName -Message $_.Exception.Message
    Add-InventorySummary -Module $ModuleName -Count -1 -OutputFile $OutputFile -Notes "ERROR: $($_.Exception.Message)"
}
