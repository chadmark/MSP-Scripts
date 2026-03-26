<#
.SYNOPSIS
    Recursively compresses PDF files in the current directory using Ghostscript.

.DESCRIPTION
    Walks through the current directory and all subdirectories, finding PDF files
    and compressing them in place using Ghostscript. Files under 1MB are skipped
    to avoid processing already-optimized documents.

    Because Ghostscript cannot overwrite a file in place, each file is written
    to a temporary file first, then moved over the original on success. If
    Ghostscript fails, the temp file is removed and the original is preserved.

    Output quality is controlled by the -dPDFSETTINGS preset:
      /screen   -  72 DPI, smallest file size, screen viewing only
      /ebook    - 150 DPI, good balance of size and quality (default)
      /printer  - 300 DPI, suitable for printing
      /prepress - 300 DPI, high quality with color preservation

.PARAMETER None
    No parameters. Run from the root directory you want to process.

.EXAMPLE
    # Navigate to your target directory first, then run:
    PS C:\Documents> .\GS-Compress-PDF-Skip1MB.ps1

.EXAMPLE
    # Run against a specific path by changing the -Path value in the script:
    -Path "C:\ClientDocuments"

.EXAMPLE
    # Verify Ghostscript is installed and accessible:
    gswin64c --version

.NOTES
    Author      : Chad Mark
    Last Edit   : 2026-03-25
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/GS-Compress-PDF-Skip1MB.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 5.1+, Ghostscript (gswin64c.exe in system PATH)
    Version     : 1.0

    PDFSETTINGSPresets:
      /screen   - 72 DPI  — smallest size, screen only
      /ebook    - 150 DPI — good balance, email/web sharing (default)
      /printer  - 300 DPI — print quality
      /prepress - 300 DPI — highest quality, full color preservation

    Ghostscript Installation:
      Download from https://www.ghostscript.com/releases/gsdnld.html
      Install the 64-bit version and ensure gswin64c.exe is in your system PATH.
      Verify with: gswin64c --version

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Minimum file size to process. Files smaller than this will be skipped.
# Supports PowerShell size literals: KB, MB, GB
$MinFileSize = 1MB

# Ghostscript quality preset. See PDFSETTINGSPresets in .NOTES above.
$PDFSettings = '/ebook'

# PDF compatibility level. 1.4 is broadly compatible with all modern viewers.
$CompatibilityLevel = '1.4'

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Get-ChildItem -Path . -Filter *.pdf -Recurse | ForEach-Object {

    # Skip files under the minimum size threshold
    if ($_.Length -lt $MinFileSize) {
        Write-Host "Skipped (too small): $($_.FullName)" -ForegroundColor Yellow
        return
    }

    $InputFile = $_.FullName
    $TempFile  = "$($_.DirectoryName)\temp_$($_.Name)"

    gswin64c `
      -sDEVICE=pdfwrite `
      -dCompatibilityLevel=$CompatibilityLevel `
      -dPDFSETTINGS=$PDFSettings `
      -dNOPAUSE `
      -dQUIET `
      -dBATCH `
      -sOutputFile="$TempFile" `
      "$InputFile"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $InputFile" -ForegroundColor Red
        Remove-Item $TempFile -ErrorAction SilentlyContinue
    } else {
        Move-Item -Force $TempFile $InputFile
        Write-Host "Done: $InputFile" -ForegroundColor Green
    }
}
