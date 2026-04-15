<#
.SYNOPSIS
    Removes the new Outlook for Windows app and cleans up taskbar pins for all users.

.DESCRIPTION
    Uninstalls the OutlookForWindows AppX package for all users and provisioned packages,
    then removes the taskbar shortcut from all existing user profiles.

.NOTES
    Author:         Chad
    Last Edit:      04-15-2026
    GitHub:         https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_remove_outlook_new.ps1
    Environment:    NinjaOne RMM — runs as SYSTEM
    Requires:       Windows 10/11, PowerShell 5.1+
    Version:        1.0
#>

# Remove installed instances for all users
Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*OutlookForWindows*' } | ForEach-Object {
    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Continue
}

# Remove provisioned package so it won't reinstall for new users
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*OutlookForWindows*' } | ForEach-Object {
    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Continue
}

# Remove taskbar pin from all user profiles
$UserProfiles = Get-ChildItem 'C:\Users' -Directory | Where-Object {
    $_.Name -notin @('Public', 'Default', 'Default User', 'All Users')
}

foreach ($Profile in $UserProfiles) {
    $TaskbarPath = Join-Path $Profile.FullName 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    if (Test-Path $TaskbarPath) {
        Get-ChildItem -Path $TaskbarPath -Filter '*Outlook*' | Remove-Item -Force -ErrorAction Continue
    }
}
