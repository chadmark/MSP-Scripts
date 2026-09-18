<#
.SYNOPSIS
    Replaces original PDFs with their compressed versions from \compressed --
    the second half of the GS-Compress-PDF-Skip1MB.ps1 workflow.

.DESCRIPTION
    This is Run 2 of a two-script workflow:
      1. GS-Compress-PDF-Skip1MB.ps1        (compress -- non-destructive)
      2. Review the \compressed folder, confirm it looks right
      3. GS-Compress-PDF-Replace-Originals.ps1  (this script -- DESTRUCTIVE)

    This script permanently deletes original PDF files and replaces them
    with their compressed counterpart from \compressed. There is no undo.
    Only run it after you've confirmed the compressed output looks correct.

    Only files that exist in BOTH the root tree and \compressed are touched.
    A PDF that GS-Compress-PDF-Skip1MB.ps1 skipped -- too small, compression
    failed, or the compressed version wasn't smaller -- has no counterpart in
    \compressed and is left completely alone. It is never deleted just
    because other files in the same tree are being replaced. The script
    reports how many files fall into this "left untouched" category before
    asking for confirmation, so you can see at a glance that nothing is being
    silently skipped or silently deleted.

    Before making any changes, the script shows a full preview: how many
    files will be replaced, their total original vs. compressed size, how
    many are being left untouched and why, and the full list of files about
    to be deleted -- then requires you to type YES to proceed.

.PARAMETER RootPath
    Directory containing the original PDFs and the \compressed subfolder.
    Defaults to the current directory. Must match the root you originally
    ran GS-Compress-PDF-Skip1MB.ps1 against.

.PARAMETER Force
    Skip the interactive YES confirmation prompt. Intended for scripted or
    unattended use only, after you've already verified the behavior manually
    at least once. Use with caution -- this removes the last safety check
    before permanent deletion.

.EXAMPLE
    # Normal use -- run from the same root you compressed:
    PS C:\ClientDocs> .\GS-Compress-PDF-Replace-Originals.ps1

.EXAMPLE
    # Point at a specific root instead of the current directory:
    .\GS-Compress-PDF-Replace-Originals.ps1 -RootPath "D:\shared\2024 Statements"

.EXAMPLE
    # Skip the confirmation prompt (unattended use only):
    .\GS-Compress-PDF-Replace-Originals.ps1 -Force

.NOTES
    Author      : Chad Mark
    Last Edit   : 2026-09-18
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/General/GS-Compress-PDF-Replace-Originals.ps1
    Environment : Windows 10/11
    Requires    : PowerShell 5.1+
    Version     : 1.0
    Companion   : GS-Compress-PDF-Skip1MB.ps1 -- run that first; this script
                  only acts on its output.

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding()]
param (
    [string]$RootPath = (Get-Location).Path,

    [switch]$Force
)

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes bytes" }
}

# ---------------------------------------------------------------------------
# Resolve root and confirm there's actually something to do
# ---------------------------------------------------------------------------

try {
    $RootPath = (Resolve-Path -Path $RootPath -ErrorAction Stop).Path
}
catch {
    Write-Host "ERROR: Root path not found: $RootPath" -ForegroundColor Red
    return
}

$CompressedRoot = Join-Path $RootPath "compressed"

if (-not (Test-Path $CompressedRoot)) {
    Write-Host "ERROR: No \compressed folder found under $RootPath" -ForegroundColor Red
    Write-Host "Nothing to replace. Run GS-Compress-PDF-Skip1MB.ps1 first." -ForegroundColor Red
    return
}

$CompressedFiles = Get-ChildItem -Path $CompressedRoot -Filter *.pdf -Recurse -File

if ($CompressedFiles.Count -eq 0) {
    Write-Host "ERROR: \compressed exists but contains no PDF files." -ForegroundColor Red
    Write-Host "Nothing to replace." -ForegroundColor Red
    return
}

# ---------------------------------------------------------------------------
# Build replacement pairs -- only files with BOTH an original and a
# compressed counterpart are touched.
# ---------------------------------------------------------------------------

$Pairs = @()
$MissingOriginal = 0

foreach ($CFile in $CompressedFiles) {
    $RelativePath = $CFile.FullName.Substring($CompressedRoot.Length).TrimStart('\')
    $OriginalPath = Join-Path $RootPath $RelativePath

    if (-not (Test-Path $OriginalPath)) {
        $MissingOriginal++
        Write-Host "NOTE: compressed file has no matching original, skipping: $RelativePath" -ForegroundColor Yellow
        continue
    }

    $Pairs += [PSCustomObject]@{
        Original       = $OriginalPath
        Compressed     = $CFile.FullName
        OriginalSize   = (Get-Item $OriginalPath).Length
        CompressedSize = $CFile.Length
    }
}

if ($Pairs.Count -eq 0) {
    Write-Host "ERROR: No matching original/compressed pairs found. Nothing to do." -ForegroundColor Red
    return
}

# For visibility: originals in the tree with no compressed counterpart.
# These are correctly left untouched (too small / failed / not smaller
# during compression) -- this script never deletes them.
$AllOriginals = Get-ChildItem -Path $RootPath -Filter *.pdf -Recurse -File |
    Where-Object { $_.FullName -notlike "$CompressedRoot\*" }
$UntouchedCount = $AllOriginals.Count - $Pairs.Count

# ---------------------------------------------------------------------------
# Preview -- nothing has been changed yet
# ---------------------------------------------------------------------------

$TotalOriginalBytes   = ($Pairs | Measure-Object -Property OriginalSize -Sum).Sum
$TotalCompressedBytes = ($Pairs | Measure-Object -Property CompressedSize -Sum).Sum

Write-Host ""
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "About to replace originals with compressed versions" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Root path             : $RootPath"
Write-Host "Files to replace      : $($Pairs.Count)"
Write-Host "Left untouched        : $UntouchedCount (no compressed counterpart -- skipped/failed during compression)"
Write-Host "Original size total   : $(Format-FileSize $TotalOriginalBytes)"
Write-Host "Compressed size total : $(Format-FileSize $TotalCompressedBytes)"
Write-Host ""
Write-Host "THIS WILL PERMANENTLY DELETE $($Pairs.Count) ORIGINAL FILE(S). THERE IS NO UNDO." -ForegroundColor Red
Write-Host ""
Write-Host "Files that will be replaced:" -ForegroundColor Cyan
foreach ($Pair in $Pairs) {
    Write-Host "  $($Pair.Original)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------

if (-not $Force) {
    $Response = Read-Host "Type YES to permanently replace these $($Pairs.Count) file(s)"
    if ($Response -cne 'YES') {
        Write-Host "Cancelled. No files were changed." -ForegroundColor Yellow
        return
    }
}

# ---------------------------------------------------------------------------
# Replace
# ---------------------------------------------------------------------------

$SuccessCount = 0
$FailCount    = 0

foreach ($Pair in $Pairs) {
    try {
        Remove-Item -Path $Pair.Original -Force -ErrorAction Stop
        Move-Item -Path $Pair.Compressed -Destination $Pair.Original -Force -ErrorAction Stop
        Write-Host "Replaced: $($Pair.Original)" -ForegroundColor Green
        $SuccessCount++
    }
    catch {
        $FailCount++
        Write-Host "FAILED: $($Pair.Original) -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Done: $SuccessCount replaced, $FailCount failed" -ForegroundColor Cyan
if ($FailCount -gt 0) {
    Write-Host "Some files failed to replace -- check the errors above and the \compressed folder." -ForegroundColor Red
}

$Remaining = Get-ChildItem -Path $CompressedRoot -Recurse -File -ErrorAction SilentlyContinue
if (-not $Remaining) {
    Write-Host "The \compressed folder is now empty and can be deleted." -ForegroundColor Cyan
}
else {
    Write-Host "$($Remaining.Count) file(s) remain in \compressed (from failures or unmatched items noted above)." -ForegroundColor Yellow
}
