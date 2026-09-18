<#
.SYNOPSIS
    Recursively resizes JPG and PNG images using ImageMagick, with verified-success overwrite,
    resumable skip-if-already-processed tracking, and an errors-only CSV log.
.DESCRIPTION
    General-purpose, ad-hoc tool -- point $SearchPath at whatever folder needs cleaning up and run
    it manually. For the automated, single-client scheduled version, see MSP-Configs\NinjaRMM\
    ninja_ocpm_ocfs02_image_resize.ps1 (hardcoded path, NinjaOne custom field alerting wired in).

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

    Resumability (same pattern as Convert-HEIC-to-JPG-Bulk.ps1):
      - Every successfully processed file's full path is appended to $ManifestPath (plain text,
        one path per line). On each run, the manifest is loaded first and any file already in it
        is skipped instantly — no re-resize, no magick call. This means re-running against the
        whole tree only spends real work on files that are new since the last run, without needing
        any timestamp comparison (which is unreliable across copies -- CreationTime changes when a
        file is copied to a new location, LastWriteTime does not).
      - Caveat: if a file at an already-processed path is later replaced with different content,
        the manifest won't know to reprocess it (matched by path only, not by hash).

    Logging:
      - $ErrorLogPath only ever contains Failed rows (path, size, magick exit code, timestamp).
        Successes and skips are NOT written there — keeps the file small enough to actually
        read/share, even across a full run over hundreds of thousands of images.
      - Per-run counts (Succeeded / Failed / Skipped-too-small / Skipped-already-processed /
        space saved) are still printed to the console at the end.
      - $LogDirectory defaults to a Logs folder next to the script. If you're running this via a
        scheduled task rather than launching it by hand, point $LogDirectory at a fixed path instead
        of relying on the script's own location -- depending on how it's deployed, the working
        directory at execution time may not be where you expect.
.PARAMETER None
    No parameters. Edit $SearchPath and $MinFileSize below, then run.
.EXAMPLE
    PS C:\Photos> .\Magick-Resize-JPG-PNG-Images-SafeOverwrite.ps1
.EXAMPLE
    # Run against a specific path by changing $SearchPath below:
    $SearchPath = "C:\ClientPhotos"
.NOTES
    Author      : Chad Mark
    Last Edit   : 09-18-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/Image-and-PDF-Resizing/Magick-Resize-JPG-PNG-Images-SafeOverwrite.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 5.1+, ImageMagick (magick.exe in system PATH)
    Version     : 1.2
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
$LogDirectory     = Join-Path $PSScriptRoot 'Logs'   # next to the script by default
if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$ManifestPath     = Join-Path $LogDirectory 'Resize-Processed-Manifest.txt'
$ErrorLogPath     = Join-Path $LogDirectory "Resize-Errors-$(Get-Date -Format 'MM-dd-yyyy_HHmmss').csv"
# ---------------------------------------------------------------------------
# Load manifest of already-processed files so re-runs skip them instantly
# ---------------------------------------------------------------------------
$processed = [System.Collections.Generic.HashSet[string]]::new()
if (Test-Path $ManifestPath) {
    Get-Content -Path $ManifestPath | ForEach-Object { [void]$processed.Add($_) }
    Write-Host "Loaded manifest: $($processed.Count) file(s) already processed in prior runs.`n" -ForegroundColor Cyan
}

$errors = [System.Collections.Generic.List[object]]::new()
$succeeded = 0
$failed = 0
$skippedSmall = 0
$skippedDone = 0
$totalSavedMB = 0.0

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Get-ChildItem -Path $SearchPath -Recurse -Include *.jpg, *.jpeg, *.png -File -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_

    if ($processed.Contains($file.FullName)) {
        $skippedDone++
        return
    }

    $originalSizeMB = [math]::Round($file.Length / 1MB, 3)

    if ($file.Length -lt $MinFileSize) {
        $skippedSmall++
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

        # Append to manifest immediately (not batched) so a crash mid-run doesn't lose progress
        Add-Content -Path $ManifestPath -Value $file.FullName
        $succeeded++
        $script:totalSavedMB += ($originalSizeMB - $newSizeMB)
    } else {
        if (Test-Path $tempPath) { Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue }
        Write-Host "FAILED (original untouched): $($file.FullName)" -ForegroundColor Red
        $errors.Add([PSCustomObject]@{
            Timestamp    = Get-Date -Format 'MM-dd-yyyy HH:mm:ss'
            FullPath     = $file.FullName
            SizeMB       = $originalSizeMB
            Detail       = "magick exit code $magickExitCode"
        })
        $failed++
    }
}

if ($errors.Count -gt 0) {
    $errors | Export-Csv -Path $ErrorLogPath -NoTypeInformation
}

$summaryLine = "SUMMARY: Succeeded=$succeeded Failed=$failed SkippedSmall=$skippedSmall SkippedAlreadyProcessed=$skippedDone SpaceSavedMB=$([math]::Round($totalSavedMB, 2)) RunTime=$(Get-Date -Format 'MM-dd-yyyy HH:mm:ss')"

Write-Host ""
Write-Host "=== $summaryLine ===" -ForegroundColor Cyan
if ($errors.Count -gt 0) {
    Write-Host "Errors logged to: $ErrorLogPath" -ForegroundColor Red
} else {
    Write-Host "No errors this run." -ForegroundColor Green
}

# Non-zero exit code on any failure -- lets Task Scheduler's "Last Run Result" (or anything else
# checking the exit code) distinguish a clean run from one with errors.
if ($failed -gt 0) { exit 1 } else { exit 0 }