<#
.SYNOPSIS
    Recursively resizes JPG and PNG images in the current directory using ImageMagick.
.DESCRIPTION
    Walks through the current directory and all subdirectories, finding JPG and PNG files
    and resizing them in place using ImageMagick. Files under 1MB are skipped to
    avoid processing already-optimized images. Outputs are written back to the
    original file path, overwriting the source file.
    ImageMagick settings are tuned for a balance of quality and file size:
      - Resizes to a maximum of 2048x2048 while preserving aspect ratio
      - Skips enlarging images that are already smaller than the target
      - JPG: Uses 4:4:4 chroma sampling to retain full color detail
      - PNG: Uses compression level 9 with adaptive filtering
      - Strips embedded metadata (EXIF, ICC, comments) to reduce file size
      - Suppresses non-fatal warnings with -quiet
.PARAMETER None
    No parameters. Run from the root directory you want to process.
.EXAMPLE
    # Navigate to your target directory first, then run:
    PS C:\Photos> .\Resize-Images.ps1
.EXAMPLE
    # Run against a specific path by changing the -Path value in the script:
    -Path "C:\ClientPhotos"
.NOTES
    Author      : Chad Mark
    Last Edit   : 2026-07-23
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/Magick-Resize-JPG-PNG-Images-Skip1MB.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 5.1+, ImageMagick (magick.exe in system PATH)
    Version     : 1.1
.LINK
    https://github.com/chadmark/MSP-Scripts
#>
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$MinFileSize = 1MB
$TargetResolution = '2048x2048>'
$JpegQuality = 88
$PngCompression = 9
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Get-ChildItem -Path . -Recurse -Include *.jpg, *.jpeg, *.png | ForEach-Object {
    if ($_.Length -lt $MinFileSize) {
        Write-Host "Skipped (too small): $($_.FullName)" -ForegroundColor Yellow
        return
    }

    $ext = $_.Extension.ToLower()

    if ($ext -eq '.png') {
        magick -quiet $_.FullName `
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
          $_.FullName
    } else {
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
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $($_.FullName)" -ForegroundColor Red
    } else {
        Write-Host "Done: $($_.FullName)" -ForegroundColor Green
    }
}
