<#
.SYNOPSIS
    Disables Google Chrome's background mode via policy registry key.
.DESCRIPTION
    Prevents Chrome from continuing to run in the background after the user closes
    all Chrome windows. Creates the Chrome policy key (if missing) and sets
    BackgroundModeEnabled to "0". Skips execution if the value already exists
    to avoid overwriting an existing configuration.
    Writes to HKLM, so the setting is machine-wide (applies to all users on the
    device, not just the account it's run under). This is a one-time, run-once
    script — intended for onboarding new PCs via Ninja. No recurring schedule
    or repeat runs are needed once it has been applied.
.NOTES
    Author      : Chad
    Last Edit   : 08-21-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_disable_chrome_background_mode.ps1
    Environment : Windows endpoints with Google Chrome installed
    Requires    : Local admin rights (writes to HKLM)
    Version     : 1.2
    Ninja Note  : No script variables required.
.CHANGELOG
    1.0 - 08-21-2026 - Initial version
    1.1 - 08-21-2026 - Check now targets the BackgroundModeEnabled value itself, not just the parent key, so the script no longer skips if the key exists for an unrelated reason
    1.2 - 08-21-2026 - Documented as a one-time, machine-wide onboarding script; no recurring runs needed
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

$regPath = "HKLM:\Software\Policies\Google\Chrome"
$valueName = "BackgroundModeEnabled"

$existingValue = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction SilentlyContinue

if ($existingValue) {
    Write-Host "Value '$valueName' already exists under '$regPath'. Skipping script execution."
    return
}

# Create the necessary registry keys
New-Item -Path "HKLM:\Software\Policies\Google" -Force | Out-Null
New-Item -Path $regPath -Force | Out-Null

# Create the registry property
New-ItemProperty -Path $regPath -Name $valueName -PropertyType String -Value "0" -Force

Write-Host "Registry key and value successfully created."
