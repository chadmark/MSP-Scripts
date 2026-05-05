<#
    .SYNOPSIS
    Installs all available Windows updates silently without reboot.

    .DESCRIPTION
    Ensures the PSWindowsUpdate module is installed, then installs all available
    Windows and Microsoft updates silently. Does not trigger a reboot.
    Registers the Microsoft Update service via Add-WUServiceManager before
    running Get-WindowsUpdate to prevent "Value does not fall within the expected
    range" errors on machines where the service is not already registered.

    .NOTES
    Original Author : Aaron Stevenson
    Author          : Chad Mark
    Last Edit       : 05-05-2026
    GitHub          : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_install_all_available_windows_updates.ps1
    Environment     : Windows 10/11, NinjaOne RMM (runs as SYSTEM)
    Requires        : PowerShell 5.1+, Internet access
    Version         : 1.1

    .LINK
    https://github.com/chadmark/MSP-Scripts
#>

function Install-PSModule {
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [String[]]$Modules
    )

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

        foreach ($Module in $Modules) {
            if (!(Get-Module -ListAvailable -Name $Module -ErrorAction Ignore)) {
                Write-Output "Installing $Module module..."
                Install-Module -Name $Module -Force
            }
            Import-Module $Module
        }

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

# Install PSWindowsUpdate module
Install-PSModule -Modules @('PSWindowsUpdate')

# Register the Microsoft Update service if not already registered.
# Skipping this on machines where the service GUID is absent causes
# Get-WindowsUpdate to throw "Value does not fall within the expected range."
Write-Output "`nRegistering Microsoft Update service..."
try {
    Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction Stop
    Write-Output 'Microsoft Update service registered.'
}
catch {
    Write-Output "Note: Microsoft Update service registration skipped — $_"
}

# Install all available Windows and Microsoft updates
Write-Output "`nChecking for available updates..."
if ($ForceReboot -eq "true") {
    Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -AutoReboot
} else {
    Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot
}
