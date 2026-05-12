#Requires -Version 5.1

<#
.SYNOPSIS
    Removes Dell SupportAssist and Dell SupportAssist Remediation from the system.
.DESCRIPTION
    Detects and silently removes Dell SupportAssist and Dell SupportAssist Remediation
    using each app's registered uninstall method (msiexec GUID or SupportAssistUninstaller.exe).
    Each app is handled independently — a failure on one does not block removal of the other.
    Terminates any running SupportAssistClientUI process after removal attempts complete.
.NOTES
    Author       Chad Mark
    Last Edit    05-12-2025
    GitHub       chadmark/MSP-Scripts/Ninja/ninja_remove_dell_supportassist.ps1
    Environment  NinjaOne — runs as SYSTEM on domain-joined Windows endpoints
    Requires     PowerShell 5.1+, Administrator privileges
    Version      1.1

.CHANGELOG
    1.0 - 05-12-2025 - Initial release; fixed not-found exit code, fixed UninstallString path splitting
    1.1 - 05-12-2025 - Added independent removal of Dell SupportAssist Remediation; extracted Invoke-AppUninstall helper
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding()]
param ()

begin {
    function Test-IsElevated {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # Returns $true on success, $false on failure — caller decides whether to set error flag
    function Invoke-AppUninstall {
        param (
            [string]$DisplayName,
            [string]$UninstallString
        )

        if ($UninstallString -match 'msiexec.exe') {
            $null = $UninstallString -match '{[A-F0-9-]+}'
            $guid = $matches[0]

            Write-Host "[Info] Removing $DisplayName using msiexec..."
            try {
                $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -PassThru
                if ($Process.ExitCode -ne 0) { throw "Exit code: $($Process.ExitCode)" }
                return $true
            }
            catch {
                Write-Host "[Error] msiexec removal of $DisplayName failed. $_"
                return $false
            }
        }
        elseif ($UninstallString -match 'SupportAssistUninstaller.exe') {
            # UninstallString may contain embedded arguments — split path from args
            $parts = $UninstallString -split '"'
            if ($parts.Count -ge 2) {
                $exePath = $parts[1]
                $exeArgs = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
            }
            else {
                $exePath = $UninstallString.Split(" ")[0]
                $exeArgs = $UninstallString.Substring($exePath.Length).Trim()
            }

            if ($exeArgs -notmatch '/S') {
                $exeArgs = "/arp /S /norestart $exeArgs".Trim()
            }

            Write-Host "[Info] Removing $DisplayName using SupportAssistUninstaller.exe..."
            try {
                $Process = Start-Process -FilePath $exePath -ArgumentList $exeArgs -Wait -PassThru
                if ($Process.ExitCode -ne 0) { throw "Exit code: $($Process.ExitCode)" }
                return $true
            }
            catch {
                Write-Host "[Error] SupportAssistUninstaller.exe removal of $DisplayName failed. $_"
                return $false
            }
        }
        else {
            Write-Host "[Error] Unsupported uninstall method for $DisplayName. UninstallString: $UninstallString"
            return $false
        }
    }
}

process {
    if (-not (Test-IsElevated)) {
        Write-Error "[Error] Access Denied. Please run with Administrator privileges."
        exit 1
    }

    $RegPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $ErrorOccurred = $false

    # --- Dell SupportAssist ---
    $DellSA = Get-ItemProperty -Path $RegPaths |
        Where-Object { $_.DisplayName -eq 'Dell SupportAssist' } |
        Select-Object -Property DisplayName, UninstallString

    if (-not $DellSA) {
        Write-Host "[Info] Dell SupportAssist not found. Skipping."
    }
    else {
        Write-Host "[Info] Dell SupportAssist found."
        $DellSA | ForEach-Object {
            if (-not (Invoke-AppUninstall -DisplayName $_.DisplayName -UninstallString $_.UninstallString)) {
                $ErrorOccurred = $true
            }
        }
    }

    # --- Dell SupportAssist Remediation ---
    $DellSAR = Get-ItemProperty -Path $RegPaths |
        Where-Object { $_.DisplayName -eq 'Dell SupportAssist Remediation' } |
        Select-Object -Property DisplayName, UninstallString

    if (-not $DellSAR) {
        Write-Host "[Info] Dell SupportAssist Remediation not found. Skipping."
    }
    else {
        Write-Host "[Info] Dell SupportAssist Remediation found."
        $DellSAR | ForEach-Object {
            if (-not (Invoke-AppUninstall -DisplayName $_.DisplayName -UninstallString $_.UninstallString)) {
                $ErrorOccurred = $true
            }
        }
    }

    # --- Kill lingering UI process ---
    $SupportAssistClientUI = Get-Process -Name "SupportAssistClientUI" -ErrorAction SilentlyContinue
    if ($SupportAssistClientUI) {
        Write-Host "[Info] SupportAssistClientUI still running — stopping process..."
        try {
            $SupportAssistClientUI | Stop-Process -Force -Confirm:$false -ErrorAction Stop
        }
        catch {
            Write-Host "[Warn] Failed to stop SupportAssistClientUI. A reboot may be required."
        }
    }

    if ($ErrorOccurred) {
        Write-Host "[Error] One or more removals failed. Review output above."
        exit 1
    }

    Write-Host "[Info] Dell SupportAssist removal complete."
    exit 0
}

end {}
