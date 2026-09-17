<#
.SYNOPSIS
    Analyzes the CSV produced by Find-OversizedJPGs.ps1 — summary stats, breakdown by extension,
    top folders by total size, and the largest individual files.
.DESCRIPTION
    Reads the Oversized-Images-<date>.csv report and produces several views without needing to
    open a 50MB CSV in Excel:
      - Overall summary: file count, total size, average size
      - Breakdown by extension (.jpg/.jpeg/.png): count and total size per type
      - Top folders by total size, rolled up to $FolderDepth path segments, so scattered files
        surface as "this folder has 400MB of oversized images" instead of one row per file
      - The $TopN largest individual files
    Also writes a small per-folder summary CSV next to the source file, so you have a short list
    to hand off or work through instead of the full 50MB report.
.PARAMETER None
    No parameters. Edit $CsvPath, $FolderDepth, and $TopN below, then run.
.EXAMPLE
    PS C:\> .\Analyze-OversizedImagesReport.ps1
.NOTES
    Author      : Chad Mark
    Last Edit   : 09-17-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/Image-and-PDF-Resizing/Analyze-OversizedImagesReport.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 5.1+
    Version     : 1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$CsvPath      = 'C:\Path\To\Oversized-Images-09-17-2026.csv'   # edit to the actual report path
$FolderDepth  = 3                                              # how many path segments to roll folders up to (e.g. C:\Users\Chad = depth 3)
$TopN         = 25                                             # how many largest individual files to show
$SummaryOut   = Join-Path (Split-Path $CsvPath -Parent) "Oversized-Images-FolderSummary.csv"
# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------
Write-Host "Loading $CsvPath ..." -ForegroundColor Cyan
if (-not (Test-Path $CsvPath)) {
    Write-Host "File not found: $CsvPath" -ForegroundColor Red
    return
}

# Import-Csv gives everything as strings, so SizeMB needs to be cast back to a number for math/sorting
$raw = Import-Csv -Path $CsvPath
$data = [System.Collections.Generic.List[object]]::new($raw.Count)
foreach ($row in $raw) {
    $data.Add([PSCustomObject]@{
        FullPath      = $row.FullPath
        Extension     = $row.Extension
        SizeMB        = [double]$row.SizeMB
        LastWriteTime = $row.LastWriteTime
    })
}
Remove-Variable raw

Write-Host "Loaded $($data.Count) rows.`n" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Overall summary
# ---------------------------------------------------------------------------
$totalCount = $data.Count
$totalMB    = [math]::Round(($data | Measure-Object SizeMB -Sum).Sum, 2)
$avgMB      = [math]::Round(($data | Measure-Object SizeMB -Average).Average, 2)
$maxMB      = [math]::Round(($data | Measure-Object SizeMB -Maximum).Maximum, 2)

Write-Host "=== Overall ===" -ForegroundColor Green
Write-Host "Files: $totalCount | Total: $totalMB MB | Average: $avgMB MB | Largest: $maxMB MB`n"

# ---------------------------------------------------------------------------
# Breakdown by extension
# ---------------------------------------------------------------------------
Write-Host "=== By extension ===" -ForegroundColor Green
$data | Group-Object Extension | ForEach-Object {
    [PSCustomObject]@{
        Extension = $_.Name
        Count     = $_.Count
        TotalMB   = [math]::Round(($_.Group | Measure-Object SizeMB -Sum).Sum, 2)
    }
} | Sort-Object TotalMB -Descending | Format-Table -AutoSize

# ---------------------------------------------------------------------------
# Top folders by total size (rolled up to $FolderDepth segments)
# Single pass with a hashtable — Group-Object + Add-Member per-row is far too slow at this scale (300k+ rows)
# ---------------------------------------------------------------------------
Write-Host "Rolling up folders..." -ForegroundColor Cyan
$folderTotals = @{}
foreach ($row in $data) {
    $dirName = [System.IO.Path]::GetDirectoryName($row.FullPath)
    if ([string]::IsNullOrEmpty($dirName)) {
        $key = $dirName
    } else {
        $parts = $dirName.Split('\')
        if ($parts.Length -le $FolderDepth) {
            $key = $dirName
        } else {
            $key = [string]::Join('\', $parts[0..($FolderDepth - 1)])
        }
    }

    if (-not $folderTotals.ContainsKey($key)) {
        $folderTotals[$key] = [PSCustomObject]@{ Folder = $key; FileCount = 0; TotalMB = 0.0 }
    }
    $folderTotals[$key].FileCount++
    $folderTotals[$key].TotalMB += $row.SizeMB
}

$folderSummary = $folderTotals.Values | ForEach-Object {
    $_.TotalMB = [math]::Round($_.TotalMB, 2)
    $_
} | Sort-Object TotalMB -Descending

Write-Host "=== Top folders by total size (rolled up to $FolderDepth path levels) ===" -ForegroundColor Green
$folderSummary | Select-Object -First 20 | Format-Table -AutoSize

$folderSummary | Export-Csv -Path $SummaryOut -NoTypeInformation
Write-Host "Full folder summary saved to: $SummaryOut`n" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Largest individual files
# ---------------------------------------------------------------------------
Write-Host "=== Top $TopN largest files ===" -ForegroundColor Green
$data | Sort-Object SizeMB -Descending | Select-Object -First $TopN FullPath, SizeMB | Format-Table -AutoSize
