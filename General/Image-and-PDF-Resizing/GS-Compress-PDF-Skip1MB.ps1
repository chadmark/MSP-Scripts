<#
.SYNOPSIS
    Recursively compresses PDF files in the current directory using Ghostscript.

.DESCRIPTION
    Features:
      - Recursively scans the current directory and all subdirectories for PDF files
      - Skips files under 1MB (already-optimized, not worth reprocessing)
      - Compresses via Ghostscript to a temp file, then moves it over the original
        only on success — originals are never touched if compression fails
      - Passes --permit-file-read / --permit-file-write scoped to the working
        directory to work around Ghostscript's SAFER sandbox blocking writes to
        mapped network drives
      - Optional -ShowCommand switch prints the exact gswin64c invocation for
        each file, useful for troubleshooting without cluttering normal runs

    Output quality is controlled by the -dPDFSETTINGS preset:
      /screen   -  72 DPI, smallest file size, screen viewing only
      /ebook    - 150 DPI, good balance of size and quality (default)
      /printer  - 300 DPI, suitable for printing
      /prepress - 300 DPI, high quality with color preservation

.PARAMETER ShowCommand
    Switch. When specified, prints the full gswin64c command line (including
    the permit-file flags, quality preset, and file paths) to the console
    before running it, for each PDF processed. Off by default so normal runs
    stay quiet. Useful when diagnosing a failure — compare the printed command
    against whatever error Ghostscript reports back.

    Named ShowCommand rather than using PowerShell's built-in -Debug common
    parameter, because -Debug pauses with a Continue/Halt/Suspend prompt on
    every Write-Debug call — impractical when looping over many files.

.EXAMPLE
    # Normal run — quiet, no diagnostic output:
    PS C:\Documents> .\GS-Compress-PDF-Skip1MB.ps1

.EXAMPLE
    # Run with diagnostics — prints each gswin64c command as it executes:
    PS C:\Documents> .\GS-Compress-PDF-Skip1MB.ps1 -ShowCommand

.EXAMPLE
    # Run against a specific network path, with diagnostics on:
    cd "M:\Yearly-STMTS\2020\Maribel"
    & "C:\scripts\GS-Compress-PDF-Skip1MB.ps1" -ShowCommand

.EXAMPLE
    # Verify Ghostscript is installed and accessible:
    gswin64c --version

.NOTES
    Author        : Chad Mark
    Last Edit     : 08-07-2026
    GitHub        : https://github.com/chadmark/MSP-Scripts/blob/main/General/GS-Compress-PDF-Skip1MB.ps1
    Environment   : Windows 10/11
    Requires      : PowerShell 5.1+, Ghostscript (gswin64c.exe in system PATH)
    Version       : 1.3

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

param(
    [switch]$ShowCommand
)

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

    if ($ShowCommand) {
        Write-Host "CMD: gswin64c $($gsArgs -join ' ')" -ForegroundColor DarkGray
    }

    & gswin64c $gsArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $InputFile" -ForegroundColor Red
        Remove-Item $TempFile -ErrorAction SilentlyContinue
    } else {
        Move-Item -Force $TempFile $InputFile
        Write-Host "Done: $InputFile" -ForegroundColor Green
    }
}
