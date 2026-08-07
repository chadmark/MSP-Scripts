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

    Ghostscript 10.x runs with SAFER sandboxing enabled by default, which can
    block reads/writes on mapped network drives even when NTFS permissions are
    fine. --permit-file-read / --permit-file-write are passed for the current
    working directory (and everything under it) to explicitly allow this.

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
    # Run against a specific path by changing directory first:
    cd "M:\Yearly-STMTS\2020\Maribel"
    & "C:\scripts\GS-Compress-PDF-Skip1MB.ps1"

.EXAMPLE
    # Verify Ghostscript is installed and accessible:
    gswin64c --version

.NOTES
    Author        : Chad Mark
    Last Edit     : 08-07-2026
    GitHub        : https://github.com/chadmark/MSP-Scripts/blob/main/General/GS-Compress-PDF-Skip1MB.ps1
    Environment   : Windows 10/11
    Requires      : PowerShell 5.1+, Ghostscript (gswin64c.exe in system PATH)
    Version       : 1.2

    PDFSETTINGSPresets:
      /screen   - 72 DPI  — smallest size, screen only
      /ebook    - 150 DPI — good balance, email/web sharing (default)
      /printer  - 300 DPI — print quality
      /prepress - 300 DPI — highest quality, full color preservation

    Ghostscript Installation:
      Download from https://www.ghostscript.com/releases/gsdnld.html
      Install the 64-bit version and ensure gswin64c.exe is in your system PATH.
      Verify with: gswin64c --version

.CHANGELOG
    1.0 - 03-25-2026 - Initial creation: recursive PDF compression via Ghostscript,
                        in-place with temp file, skip files under 1MB.
    1.1 - 08-07-2026 - Fixed -sOutputFile argument quoting (embedded literal quotes
                        instead of relying on PowerShell auto-quoting).
    1.2 - 08-07-2026 - Added --permit-file-read / --permit-file-write scoped to the
                        current directory. Root cause of "Could not open the file" /
                        "Unable to open the initial device" errors on mapped network
                        drives (M:\) was Ghostscript 10.x's default SAFER sandbox
                        blocking file writes there, not a permissions or quoting
                        issue. Confirmed working against a live network-share
                        folder. Removed temporary CMD debug line used during
                        troubleshooting.

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
# Hardcoded as a constant — change directly in the gswin64c call below if needed.

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Get-ChildItem -Path . -Filter *.pdf -Recurse | ForEach-Object {
    # Skip files under the minimum size threshold
    if ($_.Length -lt $MinFileSize) {
        Write-Host "Skipped (too small): $($_.FullName)" -ForegroundColor Yellow
        return
    }

    $InputFile  = $_.FullName
    $TempFile   = "$($_.DirectoryName)\temp_$($_.Name)"
    $PermitPath = "$((Get-Location).Path)\*"

    $gsArgs = @(
        "--permit-file-read=$PermitPath"
        "--permit-file-write=$PermitPath"
        '-sDEVICE=pdfwrite'
        '-dCompatibilityLevel=1.4'
        "-dPDFSETTINGS=$PDFSettings"
        '-dNOPAUSE'
        '-dQUIET'
        '-dBATCH'
        "-sOutputFile=`"$TempFile`""
        "`"$InputFile`""
    )

    & gswin64c $gsArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $InputFile" -ForegroundColor Red
        Remove-Item $TempFile -ErrorAction SilentlyContinue
    } else {
        Move-Item -Force $TempFile $InputFile
        Write-Host "Done: $InputFile" -ForegroundColor Green
    }
}
