<#
.SYNOPSIS
    Ensures winget is installed and updates machine-level applications when run as SYSTEM,
    with support for excluding specific packages from upgrade.

.DESCRIPTION
    Intended to run as SYSTEM via NinjaOne RMM. Checks for winget, installs it if missing,
    then upgrades all machine-scope packages from the winget source — excluding any package
    IDs listed in $ExcludedPackages.

    Exclusions are applied by querying upgradable packages first, filtering the list, then
    upgrading each remaining package individually. This works around winget's lack of a
    native --exclude flag.

    Currently excluded:
      - Synology.ActiveBackupForBusinessAgent
      - Synology.DriveClient

.NOTES
    Author          : Chad
    Original Author : Eric Kobelski
    Original Link   : https://github.com/ekobelski/ninja-scripts/tree/main/winget
    Last Edit       : 04/02/2026
    GitHub          : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_Winget_UpdateAll_Exclude.ps1
    Environment     : NinjaOne RMM (SYSTEM context), Windows endpoints
    Requires        : winget (installed automatically if missing), Administrator / SYSTEM
    Version         : 1.0

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Packages to skip during upgrade ---
$ExcludedPackages = @(
    'Synology.ActiveBackupForBusinessAgent'
    'Synology.DriveClient'
)

function Log([string]$m) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "s"), $m)
}

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { "x64" }
        "ARM64" { "arm64" }
        default { throw "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" }
    }
}

function Get-WingetExe {
    $pattern = Join-Path $env:ProgramFiles "WindowsApps\Microsoft.DesktopAppInstaller*_8wekyb3d8bbwe\winget.exe"
    $item = Get-Item $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($item) { return $item.FullName }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    return $null
}

function Download($uri, $out) {
    Log "Downloading: $uri"
    Invoke-WebRequest -Uri $uri -OutFile $out -UseBasicParsing
}

function Install-Appx($path) {
    try {
        Log "Provisioning package: $path"
        Add-AppxProvisionedPackage -Online -PackagePath $path -SkipLicense | Out-Null
    }
    catch {
        Log "Provisioning failed, trying Add-AppxPackage. Error: $($_.Exception.Message)"
        Add-AppxPackage -Path $path | Out-Null
    }
}

function Confirm-WingetInstalled {
    $existing = Get-WingetExe
    if ($existing) {
        Log "winget present: $existing"
        return $existing
    }

    $arch = Get-Arch
    $tmp = Join-Path $env:TEMP ("winget-bootstrap-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Log "Bootstrap dir: $tmp"

    $vclibsUri  = "https://aka.ms/Microsoft.VCLibs.$arch.14.00.Desktop.appx"
    $vclibsPath = Join-Path $tmp "Microsoft.VCLibs.$arch.14.00.Desktop.appx"
    Download $vclibsUri $vclibsPath
    Install-Appx $vclibsPath

    $xamlIndex = "https://api.nuget.org/v3-flatcontainer/microsoft.ui.xaml/index.json"
    Log "Querying NuGet: $xamlIndex"
    $indexJson = Invoke-RestMethod -Uri $xamlIndex -UseBasicParsing
    $latest    = ($indexJson.versions | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
    if (-not $latest) { throw "Could not determine Microsoft.UI.Xaml version." }

    $nupkgUri  = "https://api.nuget.org/v3-flatcontainer/microsoft.ui.xaml/$latest/microsoft.ui.xaml.$latest.nupkg"
    $nupkgPath = Join-Path $tmp "microsoft.ui.xaml.$latest.nupkg"
    Download $nupkgUri $nupkgPath

    $zipPath = Join-Path $tmp "microsoft.ui.xaml.$latest.zip"
    Copy-Item $nupkgPath $zipPath -Force
    $xamlDir = Join-Path $tmp "xaml"
    Expand-Archive -Path $zipPath -DestinationPath $xamlDir -Force

    $xamlAppx = Join-Path $xamlDir ("tools\AppX\{0}\release\Microsoft.UI.Xaml.2.8.appx" -f $arch)
    if (-not (Test-Path $xamlAppx)) {
        $found = Get-ChildItem -Path $xamlDir -Recurse -Filter "Microsoft.UI.Xaml.2.8.appx" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $xamlAppx = $found.FullName }
    }
    if (-not (Test-Path $xamlAppx)) { throw "Microsoft.UI.Xaml.2.8.appx not found after extract." }
    Install-Appx $xamlAppx

    $aiUri  = "https://aka.ms/getwinget"
    $aiPath = Join-Path $tmp "Microsoft.DesktopAppInstaller.msixbundle"
    Download $aiUri $aiPath
    Install-Appx $aiPath

    Start-Sleep -Seconds 3

    $wg = Get-WingetExe
    if (-not $wg) { throw "winget still not found after App Installer install." }
    Log "winget installed: $wg"
    return $wg
}

$wg = Confirm-WingetInstalled

# Query upgradable packages and filter out exclusions
Log "Querying available upgrades (machine scope, source=winget)..."
$rawOutput = & $wg upgrade --scope machine --source winget --accept-source-agreements --include-unknown | Out-String

# Parse package IDs from winget's tabular output.
# Winget outputs a table; lines with upgradable packages contain a version column pattern.
# We extract the ID column (2nd token) from lines that match, then exclude pinned packages.
$upgradeIds = $rawOutput -split "`n" |
    Where-Object { $_ -match '^\S' -and $_ -notmatch '^(Name|--|-)' } |
    ForEach-Object {
        $tokens = $_ -split '\s{2,}'
        if ($tokens.Count -ge 3) { $tokens[1].Trim() }
    } |
    Where-Object { $_ -and $_ -notin $ExcludedPackages }

if (-not $upgradeIds) {
    Log "No upgradable packages found (after exclusions)."
    exit 0
}

Log "Packages to upgrade: $($upgradeIds.Count)"
foreach ($id in $upgradeIds) {
    if ($id -in $ExcludedPackages) {
        Log "SKIPPED (excluded): $id"
        continue
    }
    Log "Upgrading: $id"
    try {
        & $wg upgrade --id $id --scope machine --source winget `
            --accept-source-agreements --accept-package-agreements --silent
    }
    catch {
        Log "WARNING: Upgrade failed for $id — $($_.Exception.Message)"
    }
}

Log "Machine-scope upgrades complete."
