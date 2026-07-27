<#
.SYNOPSIS
Creates an XLSX workbook from Entra posture CSV files.

.DESCRIPTION
Uses the Microsoft Excel desktop COM server already installed on Windows. No
PowerShell modules are required. The source CSVs are not changed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $PosturePath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $SummaryPath,

    [ValidateScript({ [string]::IsNullOrWhiteSpace($_) -or (Test-Path -LiteralPath $_ -PathType Leaf) })]
    [string] $EvidencePath,

    [string] $OutputDirectory = (Split-Path -Parent $PosturePath),

    [ValidateRange(0, 1000000)]
    [int] $MaxEvidenceRowsInWorkbook = 100000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ExcelColor {
    param([Parameter(Mandatory)][int] $Red, [Parameter(Mandatory)][int] $Green, [Parameter(Mandatory)][int] $Blue)
    return $Red + (256 * $Green) + (65536 * $Blue)
}

function Release-ComObject {
    param([AllowNull()][object] $Object)
    if ($null -eq $Object) { return }
    try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object) } catch { }
}

function Test-ExcelDesktop {
    $excel = $null
    try {
        $excel = New-Object -ComObject Excel.Application 4>$null
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $excel) {
            try { $excel.Quit() } catch { }
            Release-ComObject -Object $excel
        }
    }
}

function Set-ExcelCell {
    param(
        [Parameter(Mandatory)][object] $Worksheet,
        [Parameter(Mandatory)][int] $Row,
        [Parameter(Mandatory)][int] $Column,
        [AllowNull()][object] $Value
    )

    $cell = $Worksheet.Cells.Item($Row, $Column)
    try {
        if ($null -eq $Value) { $cell.Value2 = '' }
        else { $cell.Value2 = $Value }
    }
    finally { Release-ComObject -Object $cell }
}

function Set-ExcelNumberCell {
    param(
        [Parameter(Mandatory)][object] $Worksheet,
        [Parameter(Mandatory)][int] $Row,
        [Parameter(Mandatory)][int] $Column,
        [Parameter(Mandatory)][double] $Value
    )

    # Keep numeric writes at a dedicated COM call site. Windows PowerShell's COM
    # binder caches the first setter type it sees, which is normally text headers.
    $cell = $Worksheet.Cells.Item($Row, $Column)
    try { $cell.Value2 = $Value }
    finally { Release-ComObject -Object $cell }
}

function ConvertTo-ExcelValue {
    param([AllowNull()][object] $Value, [Parameter(Mandatory)][string] $ColumnName)

    if ($null -eq $Value) { return '' }
    $text = $Value.ToString()
    if ($text -eq 'True') { return 'Yes' }
    if ($text -eq 'False') { return 'No' }
    if ($ColumnName -match 'Score|Count|Reviewed|SignIns') {
        $number = 0.0
        if ([double]::TryParse($text, [ref]$number)) { return $number }
    }
    return $text
}

function Add-ExcelTable {
    param(
        [Parameter(Mandatory)][object] $Worksheet,
        [Parameter(Mandatory)][object[]] $Rows,
        [Parameter(Mandatory)][string[]] $Columns,
        [Parameter(Mandatory)][int] $StartRow,
        [Parameter(Mandatory)][int] $StartColumn,
        [Parameter(Mandatory)][string] $TableName
    )

    $dataRowCount = [Math]::Max(1, $Rows.Count)
    $dimensions = [int[]]@([int]($dataRowCount + 1), [int]$Columns.Count)
    $values = [System.Array]::CreateInstance([object], $dimensions)
    for ($columnIndex = 0; $columnIndex -lt $Columns.Count; $columnIndex++) {
        $values.SetValue($Columns[$columnIndex], 0, $columnIndex)
    }
    for ($rowIndex = 0; $rowIndex -lt $Rows.Count; $rowIndex++) {
        $row = $Rows[$rowIndex]
        for ($columnIndex = 0; $columnIndex -lt $Columns.Count; $columnIndex++) {
            $columnName = $Columns[$columnIndex]
            $property = $row.PSObject.Properties[$columnName]
            $value = if ($null -eq $property) { '' } else { ConvertTo-ExcelValue -Value $property.Value -ColumnName $columnName }
            $values.SetValue($value, $rowIndex + 1, $columnIndex)
        }
    }

    $lastRow = $StartRow + $dataRowCount
    $tableRange = $Worksheet.Range(
        $Worksheet.Cells.Item($StartRow, $StartColumn),
        $Worksheet.Cells.Item($lastRow, $StartColumn + $Columns.Count - 1)
    )
    # One bulk assignment avoids a COM call per cell and is the main scalability
    # safeguard for large posture reports.
    $tableRange.Value = $values
    $headerRange = $Worksheet.Range($Worksheet.Cells.Item($StartRow, $StartColumn), $Worksheet.Cells.Item($StartRow, $StartColumn + $Columns.Count - 1))
    $headerRange.Font.Bold = $true
    $headerRange.Font.Color = Get-ExcelColor 255 255 255
    $headerRange.Interior.Color = Get-ExcelColor 31 78 121
    $table = $Worksheet.ListObjects.Add(1, $tableRange, $null, 1)
    $table.Name = $TableName
    $table.TableStyle = 'TableStyleMedium2'
    if ($dataRowCount -le 5000) {
        $tableRange.EntireColumn.AutoFit()
        foreach ($columnIndex in 0..($Columns.Count - 1)) {
            $column = $Worksheet.Columns.Item($StartColumn + $columnIndex)
            if ($column.ColumnWidth -gt 42) { $column.ColumnWidth = 42 }
            Release-ComObject -Object $column
        }
    }
    else {
        Write-Verbose "Skipped AutoFit for large Excel table '$TableName' ($dataRowCount rows)."
        foreach ($columnIndex in 0..($Columns.Count - 1)) {
            $column = $Worksheet.Columns.Item($StartColumn + $columnIndex)
            $column.ColumnWidth = 18
            Release-ComObject -Object $column
        }
    }
    Release-ComObject -Object $table
    Release-ComObject -Object $tableRange
    Release-ComObject -Object $headerRange
    return [pscustomobject]@{ LastRow = $lastRow; LastColumn = $StartColumn + $Columns.Count - 1 }
}

function Set-WorksheetTitle {
    param([Parameter(Mandatory)][object] $Worksheet, [Parameter(Mandatory)][string] $Title, [int] $LastColumn = 8)

    $titleRange = $Worksheet.Range($Worksheet.Cells.Item(1, 1), $Worksheet.Cells.Item(1, $LastColumn))
    $titleRange.Merge()
    $titleRange.Value2 = $Title
    $titleRange.Font.Name = 'Aptos Display'
    $titleRange.Font.Size = 18
    $titleRange.Font.Bold = $true
    $titleRange.Font.Color = Get-ExcelColor 255 255 255
    $titleRange.Interior.Color = Get-ExcelColor 31 78 121
    $titleRange.RowHeight = 30
    Release-ComObject -Object $titleRange
}

function Add-ReviewRow {
    param(
        [System.Collections.Generic.List[object]] $Rows,
        [object] $User,
        [string] $Priority,
        [string] $Finding,
        [string] $RecommendedAction
    )
    $Rows.Add([pscustomobject][ordered]@{
        Priority                    = $Priority
        Finding                     = $Finding
        UserPrincipalName           = $User.UserPrincipalName
        IsAdmin                     = $User.IsAdmin
        StrongestRegisteredMethod   = $User.StrongestRegisteredMethod
        StrongestRegisteredTier     = $User.StrongestRegisteredTier
        ExplicitMethodEvidence      = $User.ExplicitMethodEvidenceCoverage
        RecommendedAction           = $RecommendedAction
    })
}

function Get-AvailableWorkbookPath {
    param([Parameter(Mandatory)][string] $Directory, [Parameter(Mandatory)][string] $BaseName)

    $index = 0
    do {
        $suffix = if ($index -eq 0) { '' } else { "-$index" }
        $workbook = Join-Path $Directory "$BaseName$suffix.xlsx"
        $index++
    } while (Test-Path -LiteralPath $workbook)
    return $workbook
}

if (-not (Test-ExcelDesktop)) {
    Write-Verbose 'Desktop Microsoft Excel is not installed or its COM server cannot be started. CSV and HTML reports were preserved; no XLSX was created.'
    return
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$posture = @(Import-Csv -LiteralPath $PosturePath)
$summary = @(Import-Csv -LiteralPath $SummaryPath)
$evidenceRowCount = 0
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $evidenceLineCount = ([System.IO.File]::ReadLines($EvidencePath) | Measure-Object).Count
    $evidenceRowCount = [Math]::Max(0, $evidenceLineCount - 1)
}
$includeEvidenceWorksheet = $evidenceRowCount -gt 0 -and $evidenceRowCount -le $MaxEvidenceRowsInWorkbook
$evidence = if ($includeEvidenceWorksheet) { @(Import-Csv -LiteralPath $EvidencePath) } else { @() }
if ($evidenceRowCount -gt $MaxEvidenceRowsInWorkbook) {
    Write-Warning "The evidence CSV contains $evidenceRowCount rows, exceeding the workbook limit of $MaxEvidenceRowsInWorkbook. The XLSX will omit the Evidence - Restricted worksheet; the CSV remains the complete restricted deliverable."
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($PosturePath)
$workbookPath = Get-AvailableWorkbookPath -Directory $OutputDirectory -BaseName $baseName

$reviewRows = New-Object System.Collections.Generic.List[object]
foreach ($user in $posture) {
    $registeredScore = 0
    [void][int]::TryParse($user.StrongestRegisteredScore, [ref]$registeredScore)
    if ($user.IsAdmin -eq 'True' -and $registeredScore -eq 0) {
        Add-ReviewRow -Rows $reviewRows -User $user -Priority 'High' -Finding 'Privileged account has no classified registration' -RecommendedAction 'Confirm break-glass, service, test, or active privileged-account status; document the approved control.'
    }
    elseif ($user.IsAdmin -eq 'True' -and $registeredScore -lt 90) {
        Add-ReviewRow -Rows $reviewRows -User $user -Priority 'Medium' -Finding 'Privileged account is below phishing-resistant registration target' -RecommendedAction 'Validate the required authentication strength and migrate where appropriate.'
    }
    elseif ($user.StrongerMethodRegisteredThanObserved -eq 'True') {
        Add-ReviewRow -Rows $reviewRows -User $user -Priority 'Review' -Finding 'Stronger method is registered than explicitly observed' -RecommendedAction 'Review only with evidence coverage and relevant app access; token reuse is not a control failure.'
    }
    elseif ($registeredScore -eq 0) {
        Add-ReviewRow -Rows $reviewRows -User $user -Priority 'Review' -Finding 'No classified registration' -RecommendedAction 'Classify the identity (human, service, test, or break-glass) before treating this as a remediation item.'
    }
}

$tierRows = if ($null -ne $summary[0].PSObject.Properties['RecordType']) {
    @($summary | Where-Object { $_.RecordType -eq 'Tier distribution' })
}
else {
    # Supports packaging reports generated by the first hybrid script version.
    @($summary | Where-Object { $_.StrengthTier -ne 'Evidence coverage (all users)' })
}
$totalSuccessfulSignIns = [int](@($posture | Measure-Object -Property SuccessfulInteractiveSignInsReviewed -Sum).Sum)
$totalExplicitSignIns = [int](@($posture | Measure-Object -Property SignInsWithExplicitMethod -Sum).Sum)
$mfaRequiredSignIns = [int](@($posture | Measure-Object -Property SuccessfulSignInsReportingMfaRequirement -Sum).Sum)
$coverageText = if ($totalSuccessfulSignIns -gt 0) { '{0} of {1} ({2:P1})' -f $totalExplicitSignIns, $totalSuccessfulSignIns, ($totalExplicitSignIns / $totalSuccessfulSignIns) } else { 'No successful interactive sign-ins' }
$phishRegistered = @($posture | Where-Object { $_.StrongestRegisteredTier -eq 'Phishing-resistant MFA' }).Count
$noClassifiedRegistration = @($posture | Where-Object { $_.StrongestRegisteredTier -eq 'None / unclassified' }).Count
$privilegedNoMethod = @($posture | Where-Object { $_.IsAdmin -eq 'True' -and $_.StrongestRegisteredTier -eq 'None / unclassified' }).Count

$excel = $null
$workbook = $null
try {
    $excel = New-Object -ComObject Excel.Application 4>$null
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.ScreenUpdating = $false
    $workbook = $excel.Workbooks.Add()

    $overview = $workbook.Worksheets.Item(1)
    $overview.Name = 'Overview'
    Set-WorksheetTitle -Worksheet $overview -Title 'Microsoft Entra Authentication Posture' -LastColumn 8
    Set-ExcelCell -Worksheet $overview -Row 3 -Column 1 -Value 'Report scope'
    Set-ExcelCell -Worksheet $overview -Row 3 -Column 2 -Value "$($posture[0].ObservationWindowStartUtc) through $($posture[0].ObservationWindowEndUtc)"
    Set-ExcelCell -Worksheet $overview -Row 4 -Column 1 -Value 'Generated (UTC)'
    Set-ExcelCell -Worksheet $overview -Row 4 -Column 2 -Value (Get-Date).ToUniversalTime().ToString('o')
    $overview.Range('A3:A4').Font.Bold = $true

    $metrics = @(
        [pscustomobject]@{ Metric = 'Users in scope'; Value = $posture.Count; Note = 'Users returned by Entra registration reporting' },
        [pscustomobject]@{ Metric = 'Privileged accounts'; Value = @($posture | Where-Object { $_.IsAdmin -eq 'True' }).Count; Note = 'IsAdmin flag from Entra registration report' },
        [pscustomobject]@{ Metric = 'Phishing-resistant registrations'; Value = $phishRegistered; Note = 'FIDO2/passkey, Windows Hello for Business, or certificate' },
        [pscustomobject]@{ Metric = 'No classified registration'; Value = $noClassifiedRegistration; Note = 'Classify before treating as a remediation item' },
        [pscustomobject]@{ Metric = 'Privileged accounts with no classified registration'; Value = $privilegedNoMethod; Note = 'Highest-priority account review' },
        [pscustomobject]@{ Metric = 'Explicit authentication-method evidence'; Value = $coverageText; Note = 'Evidence coverage; missing detail does not mean no MFA' },
        [pscustomobject]@{ Metric = 'Successful sign-ins reporting MFA requirement'; Value = "$mfaRequiredSignIns of $totalSuccessfulSignIns"; Note = 'MFA requirement on successful interactive sign-ins' },
        [pscustomobject]@{ Metric = 'Restricted evidence worksheet'; Value = if ($evidenceRowCount -eq 0) { 'No evidence rows' } elseif ($includeEvidenceWorksheet) { "Included ($evidenceRowCount rows)" } else { "Omitted ($evidenceRowCount rows)" }; Note = if ($includeEvidenceWorksheet) { 'Restricted evidence is included in this workbook.' } else { 'Use the restricted evidence CSV; the workbook row guardrail was reached.' } }
    )
    [void](Add-ExcelTable -Worksheet $overview -Rows $metrics -Columns @('Metric','Value','Note') -StartRow 6 -StartColumn 1 -TableName 'OverviewMetrics')
    Set-ExcelCell -Worksheet $overview -Row 16 -Column 1 -Value 'Strength distribution'
    $overview.Cells.Item(16,1).Font.Bold = $true
    $tierColumns = if ($null -ne $summary[0].PSObject.Properties['RecordType']) {
        @('StrengthTier','RegisteredUserCount','ExplicitlyObservedUserCount')
    }
    else {
        @('StrengthTier','UsersByRegisteredStrength','UsersByExplicitlyObservedStrength')
    }
    [void](Add-ExcelTable -Worksheet $overview -Rows $tierRows -Columns $tierColumns -StartRow 17 -StartColumn 1 -TableName 'StrengthDistribution')
    Set-ExcelCell -Worksheet $overview -Row 26 -Column 1 -Value 'Interpretation note'
    Set-ExcelCell -Worksheet $overview -Row 27 -Column 1 -Value 'Explicitly observed methods come only from successful interactive sign-ins with classifiable authentication details. Existing sessions and token claims often satisfy MFA without a fresh factor in the current event.'
    $overview.Range('A26').Font.Bold = $true
    $overview.Range('A27:H29').Merge()
    $overview.Range('A27:H29').WrapText = $true
    $overview.Range('A27:H29').Interior.Color = Get-ExcelColor 221 235 247
    $overview.Range('A27:H29').VerticalAlignment = -4160
    $overview.Columns.Item(1).ColumnWidth = 38
    $overview.Columns.Item(2).ColumnWidth = 22
    $overview.Columns.Item(3).ColumnWidth = 54
    $overview.PageSetup.Orientation = 2
    $overview.PageSetup.Zoom = $false
    $overview.PageSetup.FitToPagesWide = 1
    $overview.PageSetup.FitToPagesTall = 1
    $overview.PageSetup.PrintArea = '$A$1:$H$29'

    $reviewSheet = $workbook.Worksheets.Add($overview)
    $reviewSheet.Name = 'Review Queue'
    Set-WorksheetTitle -Worksheet $reviewSheet -Title 'Authentication Posture Review Queue' -LastColumn 8
    Set-ExcelCell -Worksheet $reviewSheet -Row 3 -Column 1 -Value 'This is a review queue, not an automatic remediation list. Confirm the account purpose and applicable control before acting.'
    $reviewSheet.Range('A3:H3').Merge()
    $reviewSheet.Range('A3:H3').WrapText = $true
    $reviewSheet.Range('A3:H3').Interior.Color = Get-ExcelColor 255 242 204
    [void](Add-ExcelTable -Worksheet $reviewSheet -Rows $reviewRows.ToArray() -Columns @('Priority','Finding','UserPrincipalName','IsAdmin','StrongestRegisteredMethod','StrongestRegisteredTier','ExplicitMethodEvidence','RecommendedAction') -StartRow 5 -StartColumn 1 -TableName 'ReviewQueue')
    $reviewSheet.Application.ActiveWindow.SplitRow = 5
    $reviewSheet.Application.ActiveWindow.FreezePanes = $true

    $postureSheet = $workbook.Worksheets.Add($reviewSheet)
    $postureSheet.Name = 'User Posture'
    Set-WorksheetTitle -Worksheet $postureSheet -Title 'Per-User Authentication Posture' -LastColumn 12
    $postureColumns = @($posture[0].PSObject.Properties.Name)
    [void](Add-ExcelTable -Worksheet $postureSheet -Rows $posture -Columns $postureColumns -StartRow 3 -StartColumn 1 -TableName 'UserPosture')
    $postureSheet.Application.ActiveWindow.SplitRow = 3
    $postureSheet.Application.ActiveWindow.FreezePanes = $true

    if ($includeEvidenceWorksheet) {
        $evidenceSheet = $workbook.Worksheets.Add($postureSheet)
        $evidenceSheet.Name = 'Evidence - Restricted'
        Set-WorksheetTitle -Worksheet $evidenceSheet -Title 'Authentication Evidence - Restricted Data' -LastColumn 10
        Set-ExcelCell -Worksheet $evidenceSheet -Row 3 -Column 1 -Value 'Contains sign-in identifiers, IP addresses, and device metadata. Limit distribution to authorized technical and audit audiences.'
        $evidenceSheet.Range('A3:J3').Merge()
        $evidenceSheet.Range('A3:J3').WrapText = $true
        $evidenceSheet.Range('A3:J3').Interior.Color = Get-ExcelColor 244 204 204
        $evidenceColumns = @($evidence[0].PSObject.Properties.Name)
        [void](Add-ExcelTable -Worksheet $evidenceSheet -Rows @($evidence) -Columns $evidenceColumns -StartRow 5 -StartColumn 1 -TableName 'SignInEvidence')
        $evidenceSheet.Application.ActiveWindow.SplitRow = 5
        $evidenceSheet.Application.ActiveWindow.FreezePanes = $true
    }

    $guideSheet = $workbook.Worksheets.Add()
    $guideSheet.Name = 'Scoring Guide'
    Set-WorksheetTitle -Worksheet $guideSheet -Title 'Scoring Policy and Reporting Notes' -LastColumn 5
    $scoreGuide = @(
        [pscustomobject]@{ Score = 100; Method = 'FIDO2 security key / passkey'; Tier = 'Phishing-resistant MFA' },
        [pscustomobject]@{ Score = 95; Method = 'Windows Hello for Business'; Tier = 'Phishing-resistant MFA' },
        [pscustomobject]@{ Score = 90; Method = 'Certificate-based authentication'; Tier = 'Phishing-resistant MFA' },
        [pscustomobject]@{ Score = 85; Method = 'Microsoft Authenticator passwordless'; Tier = 'Passwordless MFA' },
        [pscustomobject]@{ Score = 70; Method = 'Microsoft Authenticator push'; Tier = 'Strong MFA (app, token, or TAP)' },
        [pscustomobject]@{ Score = 60; Method = 'Temporary Access Pass'; Tier = 'Strong MFA (app, token, or TAP)' },
        [pscustomobject]@{ Score = 55; Method = 'Hardware OATH token'; Tier = 'Strong MFA (app, token, or TAP)' },
        [pscustomobject]@{ Score = 50; Method = 'Software OATH token'; Tier = 'Strong MFA (app, token, or TAP)' },
        [pscustomobject]@{ Score = 30; Method = 'Phone (SMS or voice)'; Tier = 'Phone-based MFA' },
        [pscustomobject]@{ Score = 20; Method = 'Email one-time passcode'; Tier = 'Single-factor / SSPR only' },
        [pscustomobject]@{ Score = 10; Method = 'Password or security question'; Tier = 'Single-factor / SSPR only' }
    )
    [void](Add-ExcelTable -Worksheet $guideSheet -Rows $scoreGuide -Columns @('Score','Method','Tier') -StartRow 3 -StartColumn 1 -TableName 'ScoringGuide')
    Set-ExcelCell -Worksheet $guideSheet -Row 17 -Column 1 -Value 'Notes'
    $guideSheet.Cells.Item(17,1).Font.Bold = $true
    $notes = @(
        'Scores are a transparent customer reporting policy, not official Microsoft assurance levels.',
        'Registered-method data is from Microsoft Graph v1.0 userRegistrationDetails.',
        'Explicit-method evidence is from Microsoft Graph beta sign-in authentication details and is limited by retention and session/token reuse.',
        'No explicit observed method does not mean that the user did not authenticate or did not use MFA.'
    )
    $noteRow = 18
    foreach ($note in $notes) {
        Set-ExcelCell -Worksheet $guideSheet -Row $noteRow -Column 1 -Value $note
        $guideSheet.Range("A$noteRow:E$noteRow").Merge()
        $guideSheet.Range("A$noteRow:E$noteRow").WrapText = $true
        $noteRow++
    }
    $guideSheet.Columns.Item(1).ColumnWidth = 44
    $guideSheet.Columns.Item(2).ColumnWidth = 38
    $guideSheet.Columns.Item(3).ColumnWidth = 34

    $workbook.SaveAs($workbookPath, 51)
    Write-Host "Workbook created: $workbookPath"
}
finally {
    if ($null -ne $workbook) {
        try { $workbook.Close($false) } catch { }
        Release-ComObject -Object $workbook
    }
    if ($null -ne $excel) {
        try { $excel.Quit() } catch { }
        Release-ComObject -Object $excel
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
