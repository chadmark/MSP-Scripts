<#
.SYNOPSIS
    Installs the ScreenConnect client for OCPM if not already present.
.DESCRIPTION
    Checks both 64-bit and 32-bit registry uninstall keys for the ScreenConnect
    client. If not found, downloads the installer EXE from the ScreenConnect
    relay and runs it silently. Cleans up the installer on completion.
.NOTES
    Author      : Chad
    Last Edit   : 04-20-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_install_screenconnect_HUTTON.ps1
    Environment : Windows 10/11 endpoints, NinjaOne SYSTEM context
    Requires    : PowerShell 5.1+, internet access to markleytech.screenconnect.com
    Version     : 1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SoftwareName = "ScreenConnect Client (dacc29afbbddfd3c)"

$IsInstalled = (Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -eq $SoftwareName }) +
    (Get-ItemProperty HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -eq $SoftwareName })

if (-Not $IsInstalled) {
    Write-Host "$SoftwareName is not installed and will be installed."

    $DestFolder    = "C:\Temp"
    $InstallerFile = "$DestFolder\ScreenConnect.ClientSetup.exe"
    $URL           = "https://markleytech.screenconnect.com/Bin/ScreenConnect.ClientSetup.exe?e=Access&y=Guest&c=HUTTON&c=&c=&c=&c=&c=&c=&c="

    if (Test-Path $DestFolder) {
        Write-Host "Temp folder exists."
    } else {
        New-Item $DestFolder -ItemType Directory | Out-Null
        Write-Host "Temp folder created."
    }

    Write-Host "Downloading installer..."
    Invoke-WebRequest -Uri $URL -OutFile $InstallerFile

    Write-Host "Running installer..."
    $Arguments = "/qn /norestart REBOOT=REALLYSUPPRESS"
    $Process   = Start-Process -Wait $InstallerFile -ArgumentList $Arguments -PassThru

    Remove-Item $InstallerFile -ErrorAction SilentlyContinue

    Write-Host "Exit Code: $($Process.ExitCode)"
    switch ($Process.ExitCode) {
        0    { Write-Host "Success." }
        3010 { Write-Host "Success. Reboot required to complete installation." }
        1641 { Write-Host "Success. Installer initiated a reboot." }
        default {
            Write-Host "Exit code does not indicate success."
        }
    }
} else {
    Write-Host "$SoftwareName is already installed. Exiting."
}