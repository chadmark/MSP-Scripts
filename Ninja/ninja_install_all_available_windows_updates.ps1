<#
    .SYNOPSIS
    Installs all available Windows updates silently without reboot.

    .DESCRIPTION
    Ensures PSWindowsUpdate 2.2.0.3 is installed (pinned for stability), registers
    the Microsoft Update service, then installs all available updates. Uses -ServiceID
    instead of the -MicrosoftUpdate switch on Get-WindowsUpdate to avoid a known
    ArgumentException in newer PSWindowsUpdate builds.

    .NOTES
    Original Author : Aaron Stevenson
    Author          : Chad Mark
    Last Edit       : 05-08-2026
    GitHub          : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_install_all_available_windows_updates.ps1
    Environment     : Windows 10/11, NinjaOne RMM (runs as SYSTEM)
    Requires        : PowerShell 5.1+, Internet access
    Version         : 1.3

    .CHANGELOG
    1.0 - 05-05-2026 - Initial release
    1.1 - 05-05-2026 - Added Add-WUServiceManager to register Microsoft Update service before Get-WindowsUpdate
    1.2 - 05-05-2026 - Pinned PSWindowsUpdate to 2.2.0.3; switched Get-WindowsUpdate to use -ServiceID instead of -MicrosoftUpdate
    1.3 - 05-08-2026 - Added Set-ExecutionPolicy Bypass (Process scope) for interactive use on restricted machines

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

        # Pin to 2.2.0.3 — last widely-tested stable version.
        # Newer builds have a known ArgumentException when calling Get-WindowsUpdate
        # against the Microsoft Update service on some Windows builds.
        $pinnedVersion = '2.2.0.3'
        $installed = Get-Module -ListAvailable -Name 'PSWindowsUpdate' |
                     Where-Object { $_.Version -eq $pinnedVersion }

        if (-not $installed) {
            Write-Output "Installing PSWindowsUpdate $pinnedVersion..."
            Install-Module -Name 'PSWindowsUpdate' -RequiredVersion $pinnedVersion -Force
        }

        Import-Module 'PSWindowsUpdate' -RequiredVersion $pinnedVersion -Force
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

# Install all available updates.
# -ServiceID targets Microsoft Update directly instead of using the -MicrosoftUpdate
# switch, which throws "Value does not fall within the expected range" on affected builds.
Write-Output "`nChecking for available updates..."
if ($ForceReboot -eq "true") {
    Get-WindowsUpdate -ServiceID $MicrosoftUpdateServiceID -AcceptAll -Install -AutoReboot
} else {
    Get-WindowsUpdate -ServiceID $MicrosoftUpdateServiceID -AcceptAll -Install -IgnoreReboot
}
