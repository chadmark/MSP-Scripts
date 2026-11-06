<#
    .SYNOPSIS
    Installs all available Windows updates silently without reboot.

    .DESCRIPTION
    Ensures PSWindowsUpdate is installed (latest from PSGallery, or a pinned version
    if $pinnedVersion is set), registers the Microsoft Update service, scans and
    reports the number of available updates, then installs them. Exits early if no
    updates are found. Uses -ServiceID instead of the -MicrosoftUpdate switch on
    Get-WindowsUpdate to avoid the "Value does not fall within the expected range"
    ArgumentException.

    .NOTES
    Original Author : Aaron Stevenson
    Author          : Chad Mark
    Last Edit       : 11-06-2026
    GitHub          : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_install_all_available_windows_updates.ps1
    Environment     : Windows 10/11, NinjaOne RMM (runs as SYSTEM)
    Requires        : PowerShell 5.1+, Internet access
    Version         : 1.7
    Ninja Note      : Script variable required:
                      forceReboot | Env: forceReboot | Type: Checkbox
                      Unchecked = suppress reboot (-IgnoreReboot)
                      Checked   = reboot if required (-AutoReboot)

    .CHANGELOG
    1.0 - 05-05-2026 - Initial release
    1.1 - 05-05-2026 - Register Microsoft Update service
    1.2 - 05-05-2026 - Pin PSWindowsUpdate 2.2.0.3; use -ServiceID
    1.3 - 05-08-2026 - Process-scope execution policy bypass
    1.4 - 11-06-2026 - Report update count before install; exit if none
    1.5 - 11-06-2026 - Fix count; compact results table and summary
    1.6 - 11-06-2026 - One result row per update
    1.7 - 11-06-2026 - Unpin by default (blank = latest); show (no KB) for driver updates

    .LINK
    https://github.com/chadmark/MSP-Scripts
#>

# Bypass execution policy for this session only — does not change machine policy.
# Required when running interactively on machines with restricted execution policy.
# NinjaOne bypasses this automatically; this ensures parity when running manually.
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Microsoft Update service GUID — stable, does not change
$MicrosoftUpdateServiceID = '7971f918-a847-4430-9279-4a52d1efe18d'

function Install-PSWindowsUpdate {
    Write-Output "`nChecking for necessary PowerShell modules..."

    try {
        $ProgressPreference = 'SilentlyContinue'

        if ([Net.ServicePointManager]::SecurityProtocol -notcontains 'Tls12' -and
            [Net.ServicePointManager]::SecurityProtocol -notcontains 'Tls13') {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        }

        if (!(Get-PackageProvider -ListAvailable -Name 'NuGet' -ErrorAction Ignore)) {
            Write-Output 'Installing NuGet package provider...'
            Install-PackageProvider -Name 'NuGet' -MinimumVersion 2.8.5.201 -Force
        }

        Register-PSRepository -Default -InstallationPolicy 'Trusted' -ErrorAction Ignore

        if ((Get-PSRepository -Name 'PSGallery' -ErrorAction Ignore).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name 'PSGallery' -InstallationPolicy 'Trusted'
        }

        # Leave blank to use the latest version from PSGallery.
        # Set to a specific version (e.g. '2.2.0.3') to pin it.
        $pinnedVersion = ''

        if ([string]::IsNullOrWhiteSpace($pinnedVersion)) {
            $targetVersion = (Find-Module -Name 'PSWindowsUpdate' -Repository 'PSGallery').Version.ToString()
            Write-Output "Using latest PSWindowsUpdate version: $targetVersion"
        } else {
            $targetVersion = $pinnedVersion
            Write-Output "Using pinned PSWindowsUpdate version: $targetVersion"
        }

        $installed = Get-Module -ListAvailable -Name 'PSWindowsUpdate' |
                     Where-Object { $_.Version -eq [version]$targetVersion }

        if (-not $installed) {
            Write-Output "Installing PSWindowsUpdate $targetVersion..."
            Install-Module -Name 'PSWindowsUpdate' -RequiredVersion $targetVersion -Force
        }

        Import-Module 'PSWindowsUpdate' -RequiredVersion $targetVersion -Force
        Write-Output 'Modules installed successfully.'
    }
    catch {
        Write-Warning 'Unable to install modules.'
        Write-Warning $_
        exit 1
    }
}

# ---- CONFIGURATION ----
# Ninja script variable: forceReboot (Checkbox) — unchecked by default
# Unchecked = suppress reboot (-IgnoreReboot)
# Checked   = reboot if required (-AutoReboot)
$ForceReboot = $env:forceReboot
# -----------------------

# Install pinned PSWindowsUpdate module
Install-PSWindowsUpdate

# Register the Microsoft Update service if not already present
Write-Output "`nRegistering Microsoft Update service..."
try {
    Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction Stop
    Write-Output 'Microsoft Update service registered.'
}
catch {
    Write-Output "Note: Microsoft Update service registration skipped — $_"
}

# Scan first so we can report how many updates will be applied.
# -ServiceID targets Microsoft Update directly instead of using the -MicrosoftUpdate
# switch, which throws "Value does not fall within the expected range" on affected builds.
Write-Output "`nChecking for available updates..."
# Get-WindowsUpdate can return the whole update list as ONE collection object,
# so @() alone yields a count of 1. ForEach-Object { $_ } unrolls it into
# individual updates so .Count is accurate.
$AvailableUpdates = @(Get-WindowsUpdate -ServiceID $MicrosoftUpdateServiceID | ForEach-Object { $_ })
$UpdateCount = $AvailableUpdates.Count

if ($UpdateCount -eq 0) {
    Write-Output 'No updates found. Nothing to install.'
    exit 0
}

Write-Output "Found $UpdateCount update(s) to install:"
$AvailableUpdates | ForEach-Object {
    $kb = if ($_.KB) { $_.KB } else { '(no KB)' }
    Write-Output "  - $kb $($_.Title)"
}

# Install all available updates
Write-Output "`nInstalling $UpdateCount update(s)..."
# Capture install output instead of letting it print every property of every
# update (that verbose dump gets truncated by Ninja's output limit).
if ($ForceReboot -eq "true") {
    $InstallResults = @(Get-WindowsUpdate -ServiceID $MicrosoftUpdateServiceID -AcceptAll -Install -AutoReboot | ForEach-Object { $_ })
} else {
    $InstallResults = @(Get-WindowsUpdate -ServiceID $MicrosoftUpdateServiceID -AcceptAll -Install -IgnoreReboot | ForEach-Object { $_ })
}

# PSWindowsUpdate emits each update once per stage (Accept, Download, Install).
# Collapse to one row per update, keeping the last (final) state. Group on
# KB + Title because one KB can cover two different updates.
$InstallResults = @($InstallResults |
    Group-Object KB, Title |
    ForEach-Object { $_.Group[-1] })

# Compact per-update results
Write-Output "`nInstall results:"
$InstallResults |
    Select-Object @{ Name = 'KB'; Expression = { if ($_.KB) { $_.KB } else { '(no KB)' } } }, Result, Title |
    Format-Table -AutoSize -Wrap |
    Out-String -Width 250 |
    Write-Output

# Summary counts by result (e.g. Installed / Failed)
Write-Output 'Summary:'
$InstallResults | Group-Object Result | ForEach-Object {
    Write-Output "  $($_.Name): $($_.Count)"
}