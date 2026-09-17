<#
.SYNOPSIS
    Recursively resizes JPG and PNG images using ImageMagick, with verified-success overwrite and a CSV audit log.
.DESCRIPTION
    Same core behavior as Magick-Resize-JPG-PNG-Images-Skip1MB.ps1: walks the target directory and all
    subdirectories, finds JPG and PNG files, and resizes them in place using ImageMagick. Files under
    $MinFileSize are skipped to avoid processing already-optimized images. ImageMagick settings are
    unchanged (2048x2048 max, no upscaling, JPG 4:4:4 chroma + quality 88, PNG level 9 + adaptive
    filtering, metadata stripped).

    Safety additions over the original script:
      - ImageMagick writes to a temp file (<name>.tmp<ext>) next to the original, NEVER directly over it.
      - The original is only overwritten (Move-Item) if magick exits 0 AND the temp file exists AND
        is non-zero length. If either check fails, the temp file is deleted and the original is left
        completely untouched.
      - Every file processed — success, failure, or skip — is written to a CSV log with before/after
        size and status, so you have a full audit trail of what changed.
    Outputs are written back to the original file path once verified; the file is never left half-written.
.PARAMETER None
    No parameters. Edit $SearchPath and $MinFileSize below, then run.
.EXAMPLE
    PS C:\Photos> .\Magick-Resize-JPG-PNG-Images-SafeOverwrite.ps1
.EXAMPLE
    # Run against a specific path by changing $SearchPath below:
    $SearchPath = "C:\ClientPhotos"
.NOTES
    Author      : Chad Mark
    Last Edit   : 09-17-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/Image-and-PDF-Resizing/Magick-Resize-JPG-PNG-Images-SafeOverwrite.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 5.1+, ImageMagick (magick.exe in system PATH)
    Version     : 1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$SearchPath       = '.'                          # '.' = current directory; set to a full path to target elsewhere
$MinFileSize      = 2.5MB
$TargetResolution = '2048x2048>'
$JpegQuality      = 88
$PngCompression   = 9
$LogPath          = Join-Path $PSScriptRoot "Resize-Log-$(Get-Date -Format 'MM-dd-yyyy_HHmmss').csv"
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$log = [System.Collections.Generic.List[object]]::new()

Get-ChildItem -Path $SearchPath -Recurse -Include *.jpg, *.jpeg, *.png -File | ForEach-Object {
    $file = $_
    $originalSizeMB = [math]::Round($file.Length / 1MB, 3)

    if ($file.Length -lt $MinFileSize) {
        Write-Host "Skipped (too small): $($file.FullName)" -ForegroundColor Yellow
        $log.Add([PSCustomObject]@{
            Timestamp       = Get-Date -Format 'MM-dd-yyyy HH:mm:ss'
            FullPath        = $file.FullName
            Status          = 'Skipped'
            SizeBeforeMB    = $originalSizeMB
            SizeAfterMB     = $originalSizeMB
            SavedMB         = 0
            Detail          = 'Under MinFileSize threshold'
        })
        return
    }

    $ext       = $file.Extension.ToLower()
    $tempPath  = Join-Path $file.DirectoryName ("$($file.BaseName).tmp$($file.Extension)")

    if ($ext -eq '.png') {
        magick -quiet $file.FullName `
          -filter Triangle `
          -define filter:support=2 `
          -resize "$TargetResolution" `
          -unsharp 0.25x0.25+8+0.065 `
          -dither None `
          -define png:compression-level=$PngCompression `
          -define png:compression-filter=5 `
          -define png:compression-strategy=1 `
          -strip `
          -colorspace sRGB `
          $tempPath
    } else {
        magick -quiet $file.FullName `
          -filter Triangle `
          -define filter:support=2 `
          -resize "$TargetResolution" `
          -unsharp 0.25x0.25+8+0.065 `
          -dither None `
          -quality $JpegQuality `
          -sampling-factor 4:4:4 `
          -define jpeg:fancy-upsampling=off `
          -define jpeg:dct-method=fast `
          -interlace none `
          -strip `
          -colorspace sRGB `
          $tempPath
    }

    $magickExitCode = $LASTEXITCODE
    $tempOk = (Test-Path $tempPath) -and ((Get-Item $tempPath).Length -gt 0)

    if ($magickExitCode -eq 0 -and $tempOk) {
        $newSizeMB = [math]::Round((Get-Item $tempPath).Length / 1MB, 3)
        Move-Item -Path $tempPath -Destination $file.FullName -Force
        Write-Host "Done: $($file.FullName) ($originalSizeMB MB -> $newSizeMB MB)" -ForegroundColor Green
        $log.Add([PSCustomObject]@{
            Timestamp       = Get-Date -Format 'MM-dd-yyyy HH:mm:ss'
            FullPath        = $file.FullName
            Status          = 'Success'
            SizeBeforeMB    = $originalSizeMB
            SizeAfterMB     = $newSizeMB
            SavedMB         = [math]::Round($originalSizeMB - $newSizeMB, 3)
            Detail          = ''
        })
    } else {
        if (Test-Path $tempPath) { Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue }
        Write-Host "FAILED (original untouched): $($file.FullName)" -ForegroundColor Red
        $log.Add([PSCustomObject]@{
            Timestamp       = Get-Date -Format 'MM-dd-yyyy HH:mm:ss'
            FullPath        = $file.FullName
            Status          = 'Failed'
            SizeBeforeMB    = $originalSizeMB
            SizeAfterMB     = $originalSizeMB
            SavedMB         = 0
            Detail          = "magick exit code $magickExitCode"
        })
    }
}

$log | Export-Csv -Path $LogPath -NoTypeInformation

$succeeded = ($log | Where-Object Status -eq 'Success').Count
$failed    = ($log | Where-Object Status -eq 'Failed').Count
$skipped   = ($log | Where-Object Status -eq 'Skipped').Count
$totalSavedMB = [math]::Round(($log | Measure-Object SavedMB -Sum).Sum, 2)

Write-Host ""
Write-Host "Done. Succeeded: $succeeded | Failed: $failed | Skipped: $skipped | Space saved: $totalSavedMB MB" -ForegroundColor Cyan
Write-Host "Log saved to: $LogPath" -ForegroundColor Cyan
