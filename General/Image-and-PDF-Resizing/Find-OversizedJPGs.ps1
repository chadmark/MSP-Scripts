<#
.SYNOPSIS
    Recursively scans for JPG/PNG files at or above a size threshold and reports them, without modifying anything.
.DESCRIPTION
    Read-only inventory script — companion to Magick-Resize-JPG-PNG-Images-SafeOverwrite.ps1.
    Walks the target path and all subdirectories, finds .jpg/.jpeg/.png files at or above a
    configurable size threshold, and writes the results to a CSV report (full path, extension,
    size in MB, last write time), sorted largest first. Prints a summary of total files found and total size.
    Folders that throw access-denied errors (e.g. system/protected paths) are skipped silently
    so the scan can run against a whole drive without stopping.
    Run this first, review the CSV, THEN decide on a conversion approach — this script does not
    resize, move, or delete anything.
.PARAMETER None
    No parameters. Edit $SearchPath and $MinFileSize below, then run.
.EXAMPLE
    PS C:\> .\Find-OversizedJPGs.ps1
    # Scans $SearchPath, writes Oversized-JPGs-<date>.csv next to the script
.NOTES
    Author      : Chad Mark
    Last Edit   : 09-17-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/Image-and-PDF-Resizing/Find-OversizedJPGs.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 5.1+
    Version     : 1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$SearchPath  = 'C:\'                                    # root to scan - narrow this to a specific folder to limit scope
$MinFileSize = 2.5MB                                     # files at/above this size are reported
$ReportPath  = Join-Path $PSScriptRoot "Oversized-Images-$(Get-Date -Format 'MM-dd-yyyy').csv"
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host "Scanning $SearchPath for JPG/PNG files >= $([math]::Round($MinFileSize / 1MB, 2)) MB..." -ForegroundColor Cyan

$results = Get-ChildItem -Path $SearchPath -Recurse -Include *.jpg, *.jpeg, *.png -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -ge $MinFileSize } |
    Select-Object @{N = 'FullPath'; E = { $_.FullName } },
                  @{N = 'Extension'; E = { $_.Extension.ToLower() } },
                  @{N = 'SizeMB'; E = { [math]::Round($_.Length / 1MB, 2) } },
                  LastWriteTime

if (-not $results) {
    Write-Host "No JPG/PNG files found at or above the threshold." -ForegroundColor Yellow
    return
}

$results = $results | Sort-Object Extension, SizeMB -Descending
$results | Export-Csv -Path $ReportPath -NoTypeInformation

$totalCount = $results.Count
$totalMB    = [math]::Round(($results | Measure-Object SizeMB -Sum).Sum, 2)

Write-Host ""
Write-Host "Found $totalCount file(s) totaling $totalMB MB." -ForegroundColor Green
Write-Host "Report saved to: $ReportPath" -ForegroundColor Green
