<#
.SYNOPSIS
    Recursively resizes JPG images in the current directory using ImageMagick
    with parallel processing for improved performance on multi-core systems.

.DESCRIPTION
    Walks through the current directory and all subdirectories, finding JPG files
    and resizing them in place using ImageMagick. Files under 1MB are skipped to
    avoid processing already-optimized images. Outputs are written back to the
    original file path, overwriting the source file.

    This script uses ForEach-Object -Parallel to process multiple images
    simultaneously, significantly reducing total run time on multi-core systems.
    Requires PowerShell 7+. For PowerShell 5.1 compatibility, use the
    sequential version: Magick-Resize-JPG-Images-Skip1MB.ps1

    ImageMagick settings are tuned for a balance of quality and file size:
      - Resizes to a maximum of 2048x2048 while preserving aspect ratio
      - Skips enlarging images that are already smaller than the target
      - Uses 4:4:4 chroma sampling to retain full color detail
      - Strips embedded metadata (EXIF, ICC, comments) to reduce file size
      - Suppresses non-fatal JPEG warnings (e.g. extraneous bytes) with -quiet

    Note: Console output will appear out of order since parallel jobs complete
    independently. This is expected behavior and does not indicate errors.

.PARAMETER None
    No parameters. Run from the root directory you want to process.

.EXAMPLE
    # Navigate to your target directory first, then run:
    PS C:\Photos> .\Resize-JPG-Images-Parallel.ps1

.EXAMPLE
    # Run against a specific path by changing the -Path value in the script:
    -Path "C:\ClientPhotos"

.EXAMPLE
    # Check your PowerShell version before running:
    $PSVersionTable.PSVersion

.EXAMPLE
    # Find your physical core count to tune ThrottleLimit:
    (Get-CimInstance Win32_Processor).NumberOfCores

.NOTES
    Author      : Chad Mark
    Last Edit   : 2026-03-25
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/Magick-Resize-JPG-Images-Skip1MB-Parallel.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 7+, ImageMagick (magick.exe in system PATH)
    Version     : 1.0

    ThrottleLimit Guidance:
      ImageMagick is already somewhat multi-threaded internally, so setting
      ThrottleLimit too high will cause diminishing returns. A good starting
      point is half your physical core count. Adjust based on CPU usage in
      Task Manager — target 80-90% utilization.

        4-core  CPU : ThrottleLimit 2-3
        6-core  CPU : ThrottleLimit 3-4
        8-core  CPU : ThrottleLimit 4-5
        12-core CPU : ThrottleLimit 6-8

    Network/NAS Drives:
      If processing files on a NAS or external drive, reduce ThrottleLimit
      to 2 to avoid simultaneous write conflicts.

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Minimum file size to process. Files smaller than this will be skipped.
# Supports PowerShell size literals: KB, MB, GB
$MinFileSize = 1MB

# Target resolution. The ">" suffix means only shrink, never enlarge.
# Aspect ratio is always preserved.
$TargetResolution = '2048x2048>'

# JPEG output quality (1-100). Higher = better quality, larger file.
$JpegQuality = 88

# Number of parallel jobs. See ThrottleLimit guidance in .NOTES above.
$ThrottleLimit = 4

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Get-ChildItem -Path . -Filter *.jpg -Recurse | ForEach-Object -Parallel {

    # Reference parent scope variables inside the parallel block
    $MinFileSize      = $using:MinFileSize
    $TargetResolution = $using:TargetResolution
    $JpegQuality      = $using:JpegQuality

    # Skip files under the minimum size threshold
    if ($_.Length -lt $MinFileSize) {
        Write-Host "Skipped (too small): $($_.FullName)" -ForegroundColor Yellow
        return
    }

    magick -quiet $_.FullName `
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
      $_.FullName

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $($_.FullName)" -ForegroundColor Red
    } else {
        Write-Host "Done: $($_.FullName)" -ForegroundColor Green
    }

} -ThrottleLimit $ThrottleLimit