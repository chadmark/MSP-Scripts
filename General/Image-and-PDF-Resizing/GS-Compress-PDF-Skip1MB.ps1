<#
.SYNOPSIS
    Recursively compresses PDF files using Ghostscript, writing output to a
    \compressed subfolder that mirrors the original directory structure.

.DESCRIPTION
    Walks through the given root directory (current directory by default) and
    all subdirectories, finding PDF files and compressing them using Ghostscript.
    Files smaller than -MinFileSize are skipped, since they're usually already
    optimized.

    Compressed files are written to a \compressed subfolder under the root path,
    mirroring the original folder structure. Originals are never modified,
    moved, or deleted by this script. Once you're satisfied with the output,
    delete/replace the originals manually, or with a separate cleanup step
    such as the one shown in the examples below.

    A compressed file is only kept if it's actually smaller than the original.
    If Ghostscript's output is the same size or larger, it's discarded and the
    file is reported as skipped -- this script never replaces a file with a
    bigger one.

    Output quality is controlled by the -PDFSettings parameter, which maps to
    Ghostscript's -dPDFSETTINGS preset:
      screen   - Low-resolution output optimized for small file size. (default)
      ebook    - Medium-resolution output intended to balance size and quality.
      printer  - Higher-resolution output intended for printing.
      prepress - Higher-quality preset intended for prepress-oriented workflows;
                 still modifies PDF content and is not a lossless/faithful copy.
      default  - Ghostscript's built-in default behavior (no preset applied).

    screen remains the default because this script was originally built for
    scanned documents being archived, where aggressive size reduction matters
    more than print fidelity. ebook is a reasonable alternative if you need a
    better quality/size balance and don't mind larger files -- pass
    -PDFSettings ebook to use it.

    NOTE ON SCOPE: this revision applies the low-risk/low-complexity portion of
    the originally proposed rewrite (preflight check, parameters, smaller-only
    acceptance, safer output-path detection, accurate preset docs, per-file /
    summary stats), plus temp-file-then-promote staging -- confirmed necessary
    after testing showed a Ctrl+C mid-run left a corrupt file at the final
    output path.

    Resumable processing (skip files that already have output, -Overwrite to
    reprocess) and file-based logging were deliberately left OUT, not merely
    deferred: this script is typically run interactively against a handful
    (4-5) of large PDFs at a time with the console open and watched live, so
    there's no batch large enough to need multi-session resume, and nothing
    a log file would capture that the console/summary doesn't already show.
    If usage patterns change (e.g. unattended runs against large trees), both
    are reasonable to revisit. Because resumability is NOT implemented, every
    run reprocesses every qualifying PDF from scratch -- nothing is ever
    trusted based on a file merely existing. A run interrupted mid-file may
    leave a stray "<name>.pdf.tmp.pdf" file in \compressed; it's inert (never
    read as input, easily identified by the double extension) and safe to
    delete manually.

.PARAMETER RootPath
    Directory to search recursively for PDF files. Defaults to the current
    directory.

.PARAMETER PDFSettings
    Ghostscript quality preset to use. One of: screen, ebook, printer,
    prepress, default. Defaults to screen.

.PARAMETER MinFileSize
    Minimum file size (in bytes) a PDF must be to get processed. Supports
    PowerShell size literals such as 1MB, 500KB. Defaults to 1MB.

.EXAMPLE
    # Normal run against the current directory:
    PS C:\Documents> .\GS-Compress-PDF-Skip1MB.ps1

.EXAMPLE
    # Use the ebook preset instead of the screen default:
    .\GS-Compress-PDF-Skip1MB.ps1 -PDFSettings ebook

.EXAMPLE
    # Only process files 5MB or larger:
    .\GS-Compress-PDF-Skip1MB.ps1 -MinFileSize 5MB

.EXAMPLE
    # Point at a different root directory:
    .\GS-Compress-PDF-Skip1MB.ps1 -RootPath "D:\Scanned Documents"

.EXAMPLE
    # After reviewing output, delete originals and promote compressed files
    # up to their original locations. Run only after confirming the
    # compressed output looks correct -- this is a manual step, not something
    # the script does automatically.
    $Root = (Get-Location).Path
    $CompressedRoot = Join-Path $Root "compressed"

    # Delete original PDFs (everything outside \compressed)
    Get-ChildItem -Path $Root -Filter *.pdf -Recurse -File |
        Where-Object { $_.FullName -notlike "$CompressedRoot\*" } |
        Remove-Item

    # Move compressed files back up, preserving relative structure
    Get-ChildItem -Path $CompressedRoot -Filter *.pdf -Recurse -File | ForEach-Object {
        $RelativePath = $_.FullName.Substring($CompressedRoot.Length).TrimStart('\')
        $Dest = Join-Path $Root $RelativePath
        Move-Item -Force $_.FullName $Dest
    }

.EXAMPLE
    # Verify Ghostscript is installed and accessible:
    gswin64c --version

.NOTES
    Author      : Chad Mark
    Last Edit   : 2026-09-18
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/GS-Compress-PDF-Skip1MB.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 5.1+, Ghostscript (gswin64c.exe in system PATH)
    Version     : 2.0

    Ghostscript Installation:
      Download from https://www.ghostscript.com/releases/gsdnld.html
      Install the 64-bit version and ensure gswin64c.exe is in your system PATH.
      Verify with: gswin64c --version

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding()]
param (
    [string]$RootPath = (Get-Location).Path,

    [ValidateSet('screen', 'ebook', 'printer', 'prepress', 'default')]
    [string]$PDFSettings = 'screen',

    [long]$MinFileSize = 10MB
)

# ---------------------------------------------------------------------------
# Preflight: make sure Ghostscript is actually available before doing anything
# ---------------------------------------------------------------------------

$GsCommand = Get-Command gswin64c -ErrorAction SilentlyContinue
if (-not $GsCommand) {
    Write-Host "ERROR: Ghostscript (gswin64c.exe) was not found in your PATH." -ForegroundColor Red
    Write-Host "Download it from: https://www.ghostscript.com/releases/gsdnld.html" -ForegroundColor Red
    Write-Host "Install the 64-bit build, make sure gswin64c.exe is on your PATH, then re-run this script." -ForegroundColor Red
    return
}

# ---------------------------------------------------------------------------
# Resolve root path
# ---------------------------------------------------------------------------

try {
    $RootPath = (Resolve-Path -Path $RootPath -ErrorAction Stop).Path
}
catch {
    Write-Host "ERROR: Root path not found: $RootPath" -ForegroundColor Red
    return
}

$OutputRoot     = Join-Path $RootPath "compressed"
$PDFSettingsArg = "/$PDFSettings"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes bytes" }
}

function Test-IsUnderPath {
    # Path-aware child check -- avoids false positives from prefix string
    # matching (e.g. "C:\Docs\compressed-old" incorrectly matching
    # "C:\Docs\compressed").
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [Parameter(Mandatory)][string]$ParentPath
    )
    $NormalizedParent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\') + '\'
    $NormalizedChild  = [System.IO.Path]::GetFullPath($ChildPath)
    return $NormalizedChild.StartsWith($NormalizedParent, [System.StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------------------
# Console banner
# ---------------------------------------------------------------------------

Write-Host "GS-Compress-PDF-Skip1MB v2.0" -ForegroundColor Cyan
Write-Host "Root path : $RootPath" -ForegroundColor Cyan
Write-Host "Preset    : $PDFSettingsArg" -ForegroundColor Cyan
Write-Host "Min size  : $(Format-FileSize $MinFileSize)" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$Discovered           = 0
$CompressedCount      = 0
$SkippedTooSmall      = 0
$SkippedNotSmaller    = 0
$FailedCount          = 0
$TotalOriginalBytes   = 0
$TotalCompressedBytes = 0

$PdfFiles = Get-ChildItem -Path $RootPath -Filter *.pdf -Recurse -File

foreach ($File in $PdfFiles) {

    # Skip anything already inside the compressed output tree
    if (Test-IsUnderPath -ChildPath $File.FullName -ParentPath $OutputRoot) {
        continue
    }

    $Discovered++
    $InputFile = $File.FullName

    if ($File.Length -lt $MinFileSize) {
        $SkippedTooSmall++
        Write-Host "Skipped (too small): $InputFile" -ForegroundColor Yellow
        continue
    }

    $RelativePath = $File.FullName.Substring($RootPath.Length).TrimStart('\')
    $OutputFile   = Join-Path $OutputRoot $RelativePath
    $OutputDir    = Split-Path $OutputFile

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    }

    # Ghostscript writes to a temp file first. It's only promoted to the real
    # output filename after we've confirmed it succeeded and is actually
    # smaller -- so a Ctrl+C or crash mid-write can never leave a corrupt or
    # partial file sitting at the trusted final path.
    $TempFile = "$OutputFile.tmp.pdf"
    if (Test-Path $TempFile) {
        Remove-Item $TempFile -ErrorAction SilentlyContinue
    }

    $GsOutput = & gswin64c "-sDEVICE=pdfwrite" "-dCompatibilityLevel=1.4" "-dPDFSETTINGS=$PDFSettingsArg" "-dNOPAUSE" "-dQUIET" "-dBATCH" "-sOutputFile=$TempFile" "$InputFile" 2>&1
    $ExitCode = $LASTEXITCODE

    $OutputIsValid = ($ExitCode -eq 0) -and (Test-Path $TempFile) -and ((Get-Item $TempFile).Length -gt 0)

    if (-not $OutputIsValid) {
        $FailedCount++
        Write-Host "FAILED: $InputFile (exit code $ExitCode)" -ForegroundColor Red
        if ($GsOutput) {
            Write-Host "  Ghostscript said: $($GsOutput -join ' | ')" -ForegroundColor Red
        }
        Remove-Item $TempFile -ErrorAction SilentlyContinue
        continue
    }

    $OriginalSize   = $File.Length
    $CompressedSize = (Get-Item $TempFile).Length

    if ($CompressedSize -ge $OriginalSize) {
        $SkippedNotSmaller++
        Write-Host "Skipped (compressed output was not smaller): $InputFile" -ForegroundColor Yellow
        Remove-Item $TempFile -ErrorAction SilentlyContinue
        continue
    }

    Move-Item -Force $TempFile $OutputFile

    $CompressedCount++
    $TotalOriginalBytes   += $OriginalSize
    $TotalCompressedBytes += $CompressedSize
    $PercentSaved = (1 - ($CompressedSize / $OriginalSize)) * 100

    Write-Host "Compressed: $InputFile" -ForegroundColor Green
    Write-Host "  Original   : $(Format-FileSize $OriginalSize)"
    Write-Host "  Compressed : $(Format-FileSize $CompressedSize)"
    Write-Host "  Saved      : $($PercentSaved.ToString('N1'))%"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$TotalSaved     = $TotalOriginalBytes - $TotalCompressedBytes
$OverallPercent = if ($TotalOriginalBytes -gt 0) { ($TotalSaved / $TotalOriginalBytes) * 100 } else { 0 }

Write-Host ""
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Compression Summary" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "PDFs discovered  : $Discovered" -ForegroundColor Cyan
Write-Host "Compressed       : $CompressedCount" -ForegroundColor Cyan
Write-Host "Too small        : $SkippedTooSmall" -ForegroundColor Cyan
Write-Host "Not smaller      : $SkippedNotSmaller" -ForegroundColor Cyan
Write-Host "Failed           : $FailedCount" -ForegroundColor Cyan
Write-Host ""
Write-Host "Original size    : $(Format-FileSize $TotalOriginalBytes)" -ForegroundColor Cyan
Write-Host "Compressed size  : $(Format-FileSize $TotalCompressedBytes)" -ForegroundColor Cyan
Write-Host "Space saved      : $(Format-FileSize $TotalSaved)" -ForegroundColor Cyan
Write-Host "Reduction        : $($OverallPercent.ToString('N1'))%" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "Compressed files written to: $OutputRoot" -ForegroundColor Cyan
Write-Host "Review the output, then delete/replace originals manually when satisfied." -ForegroundColor Cyan
