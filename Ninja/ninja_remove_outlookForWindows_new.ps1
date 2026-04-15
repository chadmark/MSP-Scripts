<#
.SYNOPSIS
    Removes the new Outlook for Windows app and cleans up taskbar pins and desktop shortcuts for all users.

.DESCRIPTION
    Targets OutlookForWindows and microsoft.windowscommunicationsapps (the rebranded Mail app that
    presents as "Outlook for Windows" in the taskbar). Removes all installed instances including
    Store stubs, with a retry loop to catch cases where clicking the pin triggers a reinstall mid-run.
    Removes provisioned packages so new user profiles never receive the app. Cleans up the Windows 11
    taskbar state database for all user profiles — restarting Explorer for the active session,
    deleting silently for logged-out profiles. Also removes legacy .lnk pins and desktop shortcuts.
    Safe to run once at onboarding; provisioned package removal ensures clean slate for all future profiles.

.NOTES
    Author:         Chad
    Last Edit:      04-15-2026
    GitHub:         https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_remove_outlookForWindows_new.ps1
    Environment:    NinjaOne RMM — runs as SYSTEM
    Requires:       Windows 10/11, PowerShell 5.1+
    Version:        1.2

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# --- Package Removal with Retry ---
# Loops until all OutlookForWindows instances are gone (catches stub reinstall scenario)
$targets = @('*OutlookForWindows*', '*windowscommunicationsapps*')
$maxAttempts = 5

foreach ($target in $targets) {
    $attempt = 0
    do {
        $attempt++
        $packages = Get-AppxPackage -AllUsers | Where-Object { $_.Name -like $target }
        if ($packages) {
            $packages | ForEach-Object {
                Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Continue
            }
            Start-Sleep -Seconds 3
        }
    } while (($packages) -and ($attempt -lt $maxAttempts))

    # Remove provisioned package so new user profiles never receive the app
    Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $target } | ForEach-Object {
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Continue
    }
}

# --- Determine Active User Session ---
$activeUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if ($activeUser -match '\\') { $activeUser = $activeUser.Split('\')[1] }

# --- Taskbar DB Cleanup (Windows 11) ---
# GUID {AFBF9F1A-8EE8-4C77-AF34-C647E37CA0D9} = taskbar pins database
$UserProfiles = Get-ChildItem 'C:\Users' -Directory | Where-Object {
    $_.Name -notin @('Public', 'Default', 'Default User', 'All Users')
}

foreach ($Profile in $UserProfiles) {
    $cachePath = Join-Path $Profile.FullName 'AppData\Local\Microsoft\Windows\Caches'
    $taskbarDb = Get-ChildItem -Path $cachePath -Filter '{AFBF9F1A-8EE8-4C77-AF34-C647E37CA0D9}*.db' -ErrorAction SilentlyContinue

    if ($taskbarDb) {
        if ($Profile.Name -eq $activeUser) {
            # Active user — stop Explorer, delete db, restart Explorer
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $taskbarDb | Remove-Item -Force -ErrorAction Continue
            Start-Process explorer
        } else {
            # Logged-out profile — delete directly, rebuilds clean on next login
            $taskbarDb | Remove-Item -Force -ErrorAction Continue
        }
    }
}

# --- Legacy .lnk Taskbar Pin Cleanup ---
foreach ($Profile in $UserProfiles) {
    $lnkPath = Join-Path $Profile.FullName 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    if (Test-Path $lnkPath) {
        Get-ChildItem -Path $lnkPath -Filter '*Outlook*' | Remove-Item -Force -ErrorAction Continue
    }
}

# --- Desktop Shortcut Cleanup ---
foreach ($Profile in $UserProfiles) {
    $desktopPath = Join-Path $Profile.FullName 'Desktop'
    if (Test-Path $desktopPath) {
        Get-ChildItem -Path $desktopPath -Filter '*Outlook*' | Remove-Item -Force -ErrorAction Continue
    }
}

# Public desktop
Get-ChildItem -Path 'C:\Users\Public\Desktop' -Filter '*Outlook*' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction Continue
