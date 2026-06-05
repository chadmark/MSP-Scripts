<#
.SYNOPSIS
    Removes the ConnectSecure (CyberCNS) Vulnerability Scan Agent and all remnants.

.DESCRIPTION
    Attempts to run the official uninstaller (-r flag) if the binary is still present,
    then scrubs leftover registry keys from both 32- and 64-bit Uninstall hives,
    and removes the installation directory if it remains. Resolves the agent still
    appearing in Installed Apps after service removal.

.NOTES
    Author      : Chad
    Last Edit   : 04-20-2025
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_remove_connectsecure_agent.ps1
    Environment : Windows 10/11 endpoints, SYSTEM context via NinjaOne
    Requires    : PowerShell 5.1+, local admin / SYSTEM privileges
    Version     : 1.0

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

$agentPath = "C:\Program Files (x86)\CyberCNSAgent\cybercnsagent.exe"

if (Test-Path $agentPath) {
    Write-Host "Agent binary found. Running official uninstaller..."
    Start-Process -FilePath $agentPath -ArgumentList "-r" -Wait
} else {
    Write-Host "Agent binary not found. Proceeding with registry and directory cleanup only."
}

# Remove registry uninstall keys (covers both 32- and 64-bit hives)
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

foreach ($path in $regPaths) {
    Get-ChildItem $path | Where-Object {
        $_.GetValue("DisplayName") -like "*ConnectSecure*" -or
        $_.GetValue("DisplayName") -like "*CyberCNS*"
    } | ForEach-Object {
        Write-Host "Removing registry key: $($_.Name)"
        Remove-Item $_.PSPath -Recurse -Force
    }
}

# Remove leftover installation directory if still present
$installDir = "C:\Program Files (x86)\CyberCNSAgent"
if (Test-Path $installDir) {
    Write-Host "Removing leftover directory: $installDir"
    Remove-Item $installDir -Recurse -Force
}

Write-Host "ConnectSecure agent cleanup complete."
