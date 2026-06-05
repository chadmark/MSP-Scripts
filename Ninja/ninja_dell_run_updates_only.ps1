#Requires -Version 5.1

<#
  .SYNOPSIS
    Runs Dell Command Update to scan and install critical updates
  .DESCRIPTION
    Scans for and installs critical Dell driver, firmware, and other updates using
    the Dell Command Update CLI. Application-type updates (e.g. SupportAssist) are
    excluded. Does not check for or update the DCU application itself.
    Assumes Dell Command Update is already installed on the target system.
  .NOTES
    Author:          Chad
    Last Edit:       05-12-2026
    GitHub:          https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_dell_run_updates_only.ps1
    Environment:     Windows 10/11
    Requires:        PowerShell 5.1+, Dell hardware, Dell Command Update already installed
    Version:         1.1
    Ninja Note:      Checkbox variable required — Name: "Reboot if needed", Calculated name: rebootIfNeeded
  .CHANGELOG
    1.1 - 05-12-2026 - Limit updates to critical severity; exclude application type to prevent SupportAssist installation
    1.0 - 05-12-2026 - Initial release
  .LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding()]
param (
  [Switch]$Reboot
)

# Override switch params from NinjaOne script variables
if ($env:rebootIfNeeded -and [System.Convert]::ToBoolean($env:rebootIfNeeded)) { $Reboot = $true }

# Set PowerShell preferences
Set-Location -Path $env:SystemRoot
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
if ([Net.ServicePointManager]::SecurityProtocol -notcontains 'Tls12' -and [Net.ServicePointManager]::SecurityProtocol -notcontains 'Tls13') {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Check device manufacturer
if ((Get-CimInstance -ClassName Win32_BIOS).Manufacturer -notlike '*Dell*') {
  Write-Output 'Not a Dell system. Aborting...'
  exit 0
}

# Check for DCU CLI
$DCU = (Resolve-Path "$env:SystemDrive\Program Files*\Dell\CommandUpdate\dcu-cli.exe" -ErrorAction SilentlyContinue).Path
if ($null -eq $DCU) {
  Write-Warning 'Dell Command Update CLI was not detected. Please install DCU before running this script.'
  exit 1
}

Write-Output "Dell Command Update CLI found: $DCU"

try {
  # Configure DCU automatic updates
  Write-Output 'Configuring Dell Command Update...'
  Start-Process -NoNewWindow -Wait -FilePath $DCU -ArgumentList '/configure -scheduleAction=DownloadInstallAndNotify -updatesNotification=disable -forceRestart=disable -scheduleAuto -silent'

  # Scan and install critical driver, firmware, and other updates - excludes application type (e.g. SupportAssist)
  Write-Output 'Scanning and installing available Dell updates...'
  $DCUProcess = Start-Process -NoNewWindow -Wait -PassThru -FilePath $DCU -ArgumentList '/applyUpdates -updateSeverity=critical -updateType=driver,firmware,others -autoSuspendBitLocker=enable -reboot=disable'
}
catch {
  Write-Warning 'Unable to apply updates using the dcu-cli.'
  Write-Warning $_
  exit 1
}

# Reboot if specified and DCU indicates it is required (exit code 1)
if ($Reboot) {
  if ($DCUProcess.ExitCode -eq 1) {
    Write-Warning 'Reboot required by DCU and reboot checkbox is set - rebooting in 60 seconds...'
    Start-Process -Wait -NoNewWindow -FilePath 'shutdown.exe' -ArgumentList '/r /f /t 60 /c "This system will restart in 60 seconds to complete Dell update installation. Please save and close your work." /d p:4:1'
  }
  else { Write-Output 'Reboot checkbox is set but DCU did not indicate a reboot is required - skipping reboot.' }
}
else { Write-Output 'A reboot may be needed to complete the installation of driver and firmware updates.' }
