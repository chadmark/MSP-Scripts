#Requires -Version 5.1

<#
.SYNOPSIS
    Removes Dell SupportAssist from the system.
.DESCRIPTION
    Detects and silently removes Dell SupportAssist using the registered uninstall method
    (msiexec GUID or SupportAssistUninstaller.exe). Terminates any running SupportAssistClientUI
    process after removal. Other Dell SupportAssist-related applications are not removed by default;
    see the registry query comment block for a list of related app display names.
.NOTES
    Author       Chad Mark
    Last Edit    05-12-2025
    GitHub       chadmark/MSP-Scripts/Ninja/ninja_remove_dell_supportassist.ps1
    Environment  NinjaOne — runs as SYSTEM on domain-joined Windows endpoints
    Requires     PowerShell 5.1+, Administrator privileges
    Version      1.0

.CHANGELOG
    1.0 - 05-12-2025 - Initial release; fixed not-found exit code, fixed UninstallString path splitting
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
}

process {
    if (-not (Test-IsElevated)) {
        Write-Error "[Error] Access Denied. Please run with Administrator privileges."
        exit 1
    }

    # Get UninstallString for Dell SupportAssist from the registry.
    # To target additional related apps, add display names to the -or chain below.
    # Related app display names:
    #   'Dell SupportAssist OS Recovery'
    #   'Dell SupportAssist Remediation'
    #   'SupportAssist Recovery Assistant'
    #   'Dell SupportAssist OS Recovery Plugin for Dell Update'
    #   'Dell SupportAssistAgent'
    #   'Dell Update - SupportAssist Update Plugin'
    #   'DellInc.DellSupportAssistforPCs'
    $DellSA = Get-ItemProperty -Path `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -eq 'Dell SupportAssist' } |
        Select-Object -Property DisplayName, UninstallString

    if (-not $DellSA) {
        Write-Host "[Info] Dell SupportAssist not found. Nothing to remove."
        exit 0
    }

    Write-Host "[Info] Dell SupportAssist found."

    $DellSA | ForEach-Object {
        $App = $_

        if ($App.UninstallString -match 'msiexec.exe') {
            $null = $App.UninstallString -match '{[A-F0-9-]+}'
            $guid = $matches[0]

            Write-Host "[Info] Removing Dell SupportAssist using msiexec..."
            try {
                $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -PassThru
                if ($Process.ExitCode -ne 0) {
                    throw "Exit code: $($Process.ExitCode)"
                }
            }
            catch {
                Write-Host "[Error] msiexec removal failed. $_"
                exit 1
            }
        }
        elseif ($App.UninstallString -match 'SupportAssistUninstaller.exe') {
            # UninstallString may contain embedded arguments — split path from args
            $parts = $App.UninstallString -split '"'
            if ($parts.Count -ge 2) {
                $exePath = $parts[1]
                $exeArgs = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "" }
            }
            else {
                $exePath = $App.UninstallString.Split(" ")[0]
                $exeArgs = $App.UninstallString.Substring($exePath.Length).Trim()
            }

            # Append silent flags if not already present
            if ($exeArgs -notmatch '/S') {
                $exeArgs = "/arp /S /norestart $exeArgs".Trim()
            }

            Write-Host "[Info] Removing Dell SupportAssist using SupportAssistUninstaller.exe..."
            try {
                $Process = Start-Process -FilePath $exePath -ArgumentList $exeArgs -Wait -PassThru
                if ($Process.ExitCode -ne 0) {
                    throw "Exit code: $($Process.ExitCode)"
                }
            }
            catch {
                Write-Host "[Error] SupportAssistUninstaller.exe removal failed. $_"
                exit 1
            }
        }
        else {
            Write-Host "[Error] Unsupported uninstall method. UninstallString: $($App.UninstallString)"
            exit 1
        }
    }

    # Kill lingering UI process if still running after uninstall
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

    Write-Host "[Info] Dell SupportAssist successfully removed."
    exit 0
}

end {}
