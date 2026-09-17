<#
.SYNOPSIS
    Bulk-converts HEIC/HEIF images to JPG across a file server share, with
    resumable logging so a large run can be safely re-run after an interruption.
.DESCRIPTION
    Designed for scanning a whole file server share rather than a single local
    folder. Splits the job into two phases:

      PHASE 1 - Discovery
        Walks $RootPath once, finds every .heic/.heif file, and writes the
        full list to a CSV checkpoint (HEIC-Inventory.csv). This is a single
        pass over the share -- nothing is converted yet.

      PHASE 2 - Conversion
        Reads the inventory CSV and converts each file, logging a
        Success/Failed/Skipped result per file to a second CSV
        (HEIC-Conversion-Log.csv).

    Re-running the script re-uses the existing inventory (unless -Rescan is
    passed) and skips any file already marked Success in the log -- so if the
    run is interrupted (network drop, reboot, etc.) you can just run it again
    and it picks up where it left off.

    Uses the same conversion logic and decode-method auto-detection
    (heif-dec.exe vs. ImageMagick's HEIC delegate) as Convert-HEIC-to-JPG.ps1.
    See that script's header for the one-time libheif/MSYS2 setup steps.

.PARAMETER RootPath
    UNC path or drive letter to scan, e.g. \\fileserver\shared or Z:\Shared.
    Required.

.PARAMETER LogFolder
    Where the inventory and conversion-log CSVs are written. Defaults to a
    "HEIC-Conversion-Logs" folder next to this script.

.PARAMETER Rescan
    Force a fresh discovery pass even if an inventory CSV already exists.
    Use this if files may have been added/moved since the last run.

.PARAMETER ListOnly
    Run discovery only -- writes the inventory CSV and reports a count, but
    does not convert anything. Useful to see the scope before committing to
    a multi-hour run, or to sanity-check the file count with someone before
    you kick off a conversion against production data.

.PARAMETER ThrottleLimitMinutes
    Safety valve: if set, the script will stop starting new conversions after
    this many minutes have elapsed (in-flight file still finishes). Leave
    unset ($null) to run to completion. Useful for splitting a huge share into
    scheduled maintenance-window chunks -- just re-run later to resume.

.EXAMPLE
    # See how many HEIC files are out there before committing to anything
    .\Convert-HEIC-to-JPG-Bulk.ps1 -RootPath '\\fileserver\shared' -ListOnly

.EXAMPLE
    # Run the real conversion
    .\Convert-HEIC-to-JPG-Bulk.ps1 -RootPath '\\fileserver\shared'

.EXAMPLE
    # Resume an interrupted run (uses existing inventory + log automatically)
    .\Convert-HEIC-to-JPG-Bulk.ps1 -RootPath '\\fileserver\shared'

.EXAMPLE
    # Force a fresh scan (e.g. more files were added since last run)
    .\Convert-HEIC-to-JPG-Bulk.ps1 -RootPath '\\fileserver\shared' -Rescan

.CHANGELOG
    1.0 (09-17-2026)
        - Initial release. Two-phase discovery/conversion workflow for
          bulk, share-wide HEIC-to-JPG conversion.
        - Resumable via per-file CSV logging (HEIC-Conversion-Log.csv);
          re-running the script skips anything already marked Success.
        - -ListOnly mode to preview file count/total size before converting.
        - -ThrottleLimitMinutes safety valve for scheduled maintenance windows.
        - Extension filtering uses Where-Object rather than Get-ChildItem
          -Include, which was found to silently fail to filter (returning
          every file in the tree) when combined with -LiteralPath -Recurse.
.NOTES
    Author      : Chad Mark
    Last Edit   : 09-17-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/Convert-HEIC-to-JPG-Bulk.ps1
    Environment : Windows 10/11 / Windows Server, PowerShell 5.1+
    Requires    : EITHER ImageMagick w/ HEIC delegate OR heif-dec.exe (libheif)
                  in system PATH. See Convert-HEIC-to-JPG.ps1 header for setup.
    Version     : 1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [string]$LogFolder = (Join-Path $PSScriptRoot 'HEIC-Conversion-Logs'),

    [switch]$Rescan,

    [switch]$ListOnly,

    [Nullable[int]]$ThrottleLimitMinutes = $null
)

# ---------------------------------------------------------------------------
# Configuration (same conversion settings as Convert-HEIC-to-JPG.ps1)
# ---------------------------------------------------------------------------
$JpegQuality      = 92
$ResizeEnabled    = $true
$TargetResolution = '2048x2048>'
$DeleteOriginal   = $false   # leave originals in place by default on a shared drive

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
if (-not (Test-Path $RootPath)) {
    Write-Host "ERROR: RootPath not found or not accessible: $RootPath" -ForegroundColor Red
    return
}

if (-not (Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

$inventoryPath = Join-Path $LogFolder 'HEIC-Inventory.csv'
$logPath       = Join-Path $LogFolder 'HEIC-Conversion-Log.csv'

# Detect available conversion tool (same logic as the single-folder script)
$heifDec = Get-Command heif-dec.exe -ErrorAction SilentlyContinue
$magick  = Get-Command magick.exe   -ErrorAction SilentlyContinue

$magickHasHeic = $false
if ($magick) {
    $delegates = & magick.exe -list format 2>$null | Select-String -Pattern 'HEIC'
    if ($delegates) { $magickHasHeic = $true }
}

if (-not $ListOnly) {
    if (-not $heifDec -and -not $magickHasHeic) {
        Write-Host "ERROR: No HEIC decoder found." -ForegroundColor Red
        Write-Host "Install libheif (provides heif-dec.exe) or an ImageMagick build with a HEIC delegate." -ForegroundColor Red
        Write-Host "See Convert-HEIC-to-JPG.ps1's header for the one-time setup steps." -ForegroundColor Red
        return
    }
}
$method = if ($heifDec) { 'heif-dec' } else { 'magick' }

# ---------------------------------------------------------------------------
# PHASE 1: Discovery
# ---------------------------------------------------------------------------
if ((-not (Test-Path $inventoryPath)) -or $Rescan) {
    Write-Host "Scanning $RootPath for HEIC/HEIF files (single pass)..." -ForegroundColor Cyan

    # SilentlyContinue so one inaccessible folder on the share doesn't abort
    # the whole scan -- common on file servers with mixed permissions.
    #
    # NOTE: -Include is NOT used here on purpose. Combined with -LiteralPath
    # and -Recurse, -Include can silently fail to filter (a known PowerShell
    # quirk) and return every file in the tree instead of just HEIC/HEIF.
    # Pulling everything and filtering by extension explicitly is reliable
    # regardless of PowerShell version.
    $files = Get-ChildItem -LiteralPath $RootPath -Recurse -File `
                -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -in '.heic', '.heif' }

    $files |
        Select-Object @{N='SourcePath'; E={$_.FullName}},
                       @{N='SizeMB'; E={[math]::Round($_.Length / 1MB, 2)}} |
        Export-Csv -Path $inventoryPath -NoTypeInformation -Encoding UTF8

    Write-Host "Found $($files.Count) HEIC/HEIF files. Inventory written to:" -ForegroundColor Green
    Write-Host "  $inventoryPath" -ForegroundColor Green
} else {
    Write-Host "Using existing inventory (pass -Rescan to force a fresh scan):" -ForegroundColor Yellow
    Write-Host "  $inventoryPath" -ForegroundColor Yellow
}

$inventory = Import-Csv -Path $inventoryPath

if ($ListOnly) {
    Write-Host "`n-ListOnly specified -- no files converted." -ForegroundColor Cyan
    Write-Host "Total files found: $($inventory.Count)"
    $totalSizeMB = ($inventory | Measure-Object -Property SizeMB -Sum).Sum
    Write-Host "Total size: $([math]::Round($totalSizeMB, 1)) MB"
    return
}

if ($inventory.Count -eq 0) {
    Write-Host "No HEIC/HEIF files found under $RootPath." -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# Load prior results so we can resume (skip anything already Success)
# ---------------------------------------------------------------------------
$alreadyDone = @{}
if (Test-Path $logPath) {
    Import-Csv -Path $logPath | Where-Object { $_.Result -eq 'Success' } | ForEach-Object {
        $alreadyDone[$_.SourcePath] = $true
    }
    Write-Host "Resuming: $($alreadyDone.Count) file(s) already converted successfully in a prior run." -ForegroundColor Cyan
} else {
    # Create the log with a header row
    'SourcePath,DestPath,Result,Detail,Timestamp' | Out-File -FilePath $logPath -Encoding UTF8
}

Write-Host "Using conversion method: $method" -ForegroundColor Cyan
Write-Host "Converting $($inventory.Count - $alreadyDone.Count) remaining file(s)...`n" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# PHASE 2: Conversion
# ---------------------------------------------------------------------------
$startTime   = Get-Date
$total       = $inventory.Count
$current     = 0
$successCount = 0
$skipCount    = 0
$failCount    = 0

foreach ($row in $inventory) {
    $current++
    $src = $row.SourcePath

    if ($alreadyDone.ContainsKey($src)) { continue }

    # Safety valve for scheduled-window runs
    if ($ThrottleLimitMinutes -and ((Get-Date) - $startTime).TotalMinutes -ge $ThrottleLimitMinutes) {
        Write-Host "`nTime limit of $ThrottleLimitMinutes minute(s) reached -- stopping early. Re-run to resume." -ForegroundColor Yellow
        break
    }

    Write-Progress -Activity "Converting HEIC files" `
                    -Status "$current of $total : $src" `
                    -PercentComplete (($current / $total) * 100)

    if (-not (Test-Path -LiteralPath $src)) {
        "`"$src`",,Failed,Source file no longer exists,$(Get-Date -Format o)" |
            Out-File -FilePath $logPath -Append -Encoding UTF8
        $failCount++
        continue
    }

    $dst = [System.IO.Path]::ChangeExtension($src, '.jpg')

    if (Test-Path -LiteralPath $dst) {
        "`"$src`",`"$dst`",Skipped,JPG already exists,$(Get-Date -Format o)" |
            Out-File -FilePath $logPath -Append -Encoding UTF8
        $skipCount++
        continue
    }

    try {
        if ($method -eq 'heif-dec') {
            if ($magick) {
                $tmp = [System.IO.Path]::ChangeExtension($src, '.tmp.png')
                & heif-dec.exe -q 100 $src $tmp 2>$null
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp)) {
                    $resizeArgs = @()
                    if ($ResizeEnabled) { $resizeArgs = @('-resize', $TargetResolution) }
                    magick $tmp `
                        -auto-orient `
                        @resizeArgs `
                        -quality $JpegQuality `
                        -sampling-factor 4:4:4 `
                        -strip `
                        -colorspace sRGB `
                        $dst
                    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                }
            } else {
                & heif-dec.exe -q $JpegQuality $src $dst 2>$null
            }
        } else {
            $resizeArgs = @()
            if ($ResizeEnabled) { $resizeArgs = @('-resize', $TargetResolution) }
            magick -quiet $src `
                -auto-orient `
                @resizeArgs `
                -quality $JpegQuality `
                -sampling-factor 4:4:4 `
                -strip `
                -colorspace sRGB `
                $dst
        }

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dst)) {
            "`"$src`",`"$dst`",Failed,Conversion tool returned an error,$(Get-Date -Format o)" |
                Out-File -FilePath $logPath -Append -Encoding UTF8
            $failCount++
        } else {
            if ($DeleteOriginal) {
                Remove-Item -LiteralPath $src -ErrorAction SilentlyContinue
            }
            "`"$src`",`"$dst`",Success,,$(Get-Date -Format o)" |
                Out-File -FilePath $logPath -Append -Encoding UTF8
            $successCount++
        }
    } catch {
        $errMsg = $_.Exception.Message -replace '"', "'"
        "`"$src`",`"$dst`",Failed,`"$errMsg`",$(Get-Date -Format o)" |
            Out-File -FilePath $logPath -Append -Encoding UTF8
        $failCount++
    }
}

Write-Progress -Activity "Converting HEIC files" -Completed

Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host "Done."
Write-Host "  Converted : $successCount" -ForegroundColor Green
Write-Host "  Skipped   : $skipCount"    -ForegroundColor Yellow
Write-Host "  Failed    : $failCount"    -ForegroundColor Red
Write-Host "Full log: $logPath"
