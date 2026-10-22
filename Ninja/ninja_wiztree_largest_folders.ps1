<#
.SYNOPSIS
    Reports the largest folders on one or more local drives using WizTree's command-line CSV export.

.DESCRIPTION
    Downloads (if needed) the WizTree portable build, runs its command-line CSV export against the
    drive(s) selected via Ninja script variables, filters to folders over 1 GB, and writes the top 25
    largest folders plus total scan time to a custom field.

    Requires a valid WizTree commercial license (Supporter Code / Enterprise) covering this business
    site - see https://diskanalyzer.com/eula.

    Mirrors ninja_du_largest_folders.ps1's variable/output structure so the two are easy to compare.

.NOTES
    Author          : Chad
    Last Edit       : 09-17-2026
    GitHub Path     : MSP-Scripts/NinjaOne/Disk/ninja_wiztree_largest_folders.ps1
    Environment     : NinjaOne (PowerShell script deployment)
    Requires        : Windows PowerShell 5.1+; outbound HTTPS to diskanalyzer.com on first run per device; licensed WizTree install
    Version         : 1.0
    Ninja Note      : Script Variables -
                        ScanDrives (Text)  - Comma-separated drive letters to scan, e.g. "C" or "C,D,E". Blank defaults to "C".
                        ScanDepth  (Text)  - Max folder depth passed to WizTree's /exportmaxdepth. Blank or invalid defaults to 5.
                       Writes results to custom field: Treesize (plain Text/MultiLine field type) -
                       same field as ninja_du_largest_folders.ps1. Since both scripts share this field,
                       don't run them back-to-back on the same device if you want to compare outputs -
                       whichever runs last overwrites the field.

.CHANGELOG
    1.0 - 09-17-2026 - Initial release. WizTree command-line CSV export, folders only, sorted by
                        allocated size, depth-limited via ScanDrives/ScanDepth Ninja variables.
                        Writes top 25 largest folders + scan time to Treesize custom field.


.LINK
    https://www.diskanalyzer.com/download
.LINK
    https://www.diskanalyzer.com/guide#cmdlinecsv
.LINK
    https://www.diskanalyzer.com/eula
#>

# Enforce TLS 1.2 for secure web requests
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- Ninja variables ----------------------------------------------------
$RawDrives = $env:ScanDrives
$RawDepth  = $env:ScanDepth

if ([string]::IsNullOrWhiteSpace($RawDrives)) {
    $DriveLetters = @('C')
} else {
    $DriveLetters = $RawDrives -split ',' | ForEach-Object { $_.Trim().TrimEnd(':','\') } | Where-Object { $_ -match '^[A-Za-z]$' }
    if (-not $DriveLetters) {
        Write-Host "ScanDrives value '$RawDrives' had no valid drive letters - defaulting to C"
        $DriveLetters = @('C')
    }
}

$Depth = 5
if (-not [string]::IsNullOrWhiteSpace($RawDepth)) {
    $parsedDepth = 0
    if ([int]::TryParse($RawDepth, [ref]$parsedDepth) -and $parsedDepth -gt 0) {
        $Depth = $parsedDepth
    } else {
        Write-Host "ScanDepth value '$RawDepth' is not a valid positive integer - defaulting to 5"
    }
}

# ---- Ensure WizTree is present --------------------------------------------
$HBTempFolderName = "$env:TEMP\hbtemp_wiztree\"
$URI              = "https://www.diskanalyzer.com/files/wiztree_4_32_portable.zip"
$OUTFILE          = "$env:TEMP\hbtemp_wiztree\WizTree.zip"
$DestinationPath  = "$env:TEMP\hbtemp_wiztree\WizTree"
$WizExe           = if ([Environment]::Is64BitOperatingSystem) { "$DestinationPath\WizTree64.exe" } else { "$DestinationPath\WizTree.exe" }

if ((Test-Path $WizExe) -and (Get-Item $WizExe).Length -gt 0) {
    Write-Host "WizTree already present"
} else {
    try {
        New-Item $HBTempFolderName -ItemType Directory -Force | Out-Null
        Invoke-WebRequest -Uri $URI -OutFile $OUTFILE -UseBasicParsing -ErrorAction Stop
        Expand-Archive -LiteralPath $OUTFILE -DestinationPath $DestinationPath -Force -ErrorAction Stop

        if (-not (Test-Path $WizExe) -or (Get-Item $WizExe).Length -eq 0) {
            throw "WizTree executable missing or zero-length after extraction."
        }
        Write-Host "WizTree downloaded and extracted successfully"
    } catch {
        Write-Host "ERROR: Failed to obtain WizTree - $($_.Exception.Message)"
        Ninja-Property-Set Treesize "ERROR: Could not download/extract WizTree - $($_.Exception.Message)"
        exit 1
    }
}

# ---- Scan each selected drive ---------------------------------------------
$StartTime  = Get-Date
$AllResults = @()

foreach ($letter in $DriveLetters) {
    $scanTarget = "$letter`:"
    $scanPath   = "$letter`:\"

    if (-not (Test-Path $scanPath)) {
        Write-Host "Skipping $scanPath - drive not present on this device"
        continue
    }

    $csvPath = "$env:TEMP\hbtemp_wiztree\export_$letter.csv"
    if (Test-Path $csvPath) { Remove-Item $csvPath -Force }

    Write-Host "Scanning $scanPath (max depth $Depth)..."
    try {
        # /admin=1        - use fast MFT scanning (device already runs elevated under Ninja/SYSTEM)
        # /exportfolders=1 /exportfiles=0 - folders only, matches the du.exe script's folder-level output
        # /sortby=2       - sort by allocated size (desc) - closest equivalent to du.exe's DirectorySizeOnDisk
        # /exportmaxdepth - equivalent to du.exe's -l level control
        # /exportdrivecapacity=0 - skip the extra drive-capacity summary row so parsing stays simple
        $arguments = "`"$scanTarget`" /export=`"$csvPath`" /admin=1 /exportfolders=1 /exportfiles=0 /sortby=2 /exportmaxdepth=$Depth /exportdrivecapacity=0"
        $proc = Start-Process -FilePath $WizExe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden

        if ($proc.ExitCode -ne 0) {
            Write-Host "WizTree exited with code $($proc.ExitCode) for $scanPath"
        }

        if (-not (Test-Path $csvPath)) {
            Write-Host "No CSV produced for $scanPath - skipping"
            continue
        }

        # CSV format per diskanalyzer.com/guide#csv: File Name, Size, Allocated, Modified, Attributes, Files, Folders
        # Only keep lines that are actual data rows (start with a quoted drive-letter path) - this
        # skips any header/info rows regardless of WizTree version/export options.
        $dataLines = Get-Content -Path $csvPath | Where-Object { $_ -match '^"[A-Za-z]:' }

        $driveResults = $dataLines | ConvertFrom-Csv -Header 'Name', 'Size', 'Allocated', 'Modified', 'Attributes', 'Files', 'Folders' `
            | Select-Object @{Name = 'Path'; Expression = { $_.Name.TrimEnd('\') } }, `
                            @{Name = 'DirectorySizeOnDisk'; Expression = { [Math]::Round([int64]$_.Allocated / 1GB) } } `
            | Where-Object { $_.DirectorySizeOnDisk -gt 1 }

        $AllResults += $driveResults
    } catch {
        Write-Host "ERROR scanning $scanPath - $($_.Exception.Message)"
    } finally {
        if (Test-Path $csvPath) { Remove-Item $csvPath -Force -ErrorAction SilentlyContinue }
    }
}

$Top25 = $AllResults | Sort-Object DirectorySizeOnDisk -Descending | Select-Object -First 25

$TreeLines = $Top25 | ForEach-Object { "$($_.Path) - $($_.DirectorySizeOnDisk) GB" }

$stopwatch = "Total scan time: $((New-Timespan -Start $StartTime -End (Get-Date)).TotalSeconds) seconds"

# ---- Build and write the custom field --------------------------------------
$CustomField = ($TreeLines + $stopwatch) -join "`r`n"

Write-Host $CustomField

Ninja-Property-Set Treesize $CustomField
