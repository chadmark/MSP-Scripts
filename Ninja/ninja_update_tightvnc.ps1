<#
    .SYNOPSIS
    Updates TightVNC via Chocolatey, stopping and restarting the TightVNC service around the upgrade.

    .DESCRIPTION
    Checks if Chocolatey is installed and installs/upgrades it if needed, then stops the
    TightVNC Server service, upgrades TightVNC via Chocolatey, and restarts the service.

    .NOTES
    Author      : Chad Mark
    Last Edit   : 04-10-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_update_tightvnc.ps1
    Environment : Windows 10/11, Domain-joined
    Requires    : PowerShell 5.1+, NinjaRMM, Internet access or internal Chocolatey source
    Version     : 1.0

    .LINK
    https://github.com/chadmark/MSP-Scripts
#>

$ServiceName = "tvnserver"
$DisplayName = "TightVNC Server"

# --- Chocolatey check / install ---
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Chocolatey not found. Installing..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
} else {
    Write-Host "Chocolatey found. Upgrading to latest..."
    choco upgrade chocolatey -y
}

# --- Stop service ---
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Host "Stopping '$DisplayName'..."
    Stop-Service -Name $ServiceName -Force
    $svc.WaitForStatus('Stopped', '00:00:30')
}

# --- Upgrade TightVNC ---
Write-Host "Upgrading TightVNC via Chocolatey..."
choco upgrade tightvnc -y
$exitCode = $LASTEXITCODE

# --- Restart service ---
Write-Host "Starting '$DisplayName'..."
Start-Service -Name $ServiceName
$svc = Get-Service -Name $ServiceName
$svc.WaitForStatus('Running', '00:00:30')
Write-Host "Service status: $($svc.Status)"

# --- Exit with Choco's exit code ---
exit $exitCode
