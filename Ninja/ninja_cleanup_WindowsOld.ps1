
<#
.SYNOPSIS
    Removes previous Windows installation files (Windows.old) using Windows Disk Cleanup
    after a configurable minimum age.

.DESCRIPTION
    Detects Windows.old on the system drive and determines cleanup eligibility based on
    the minimum age specified through the NinjaOne variable DefaultMinimumAgeDays.

    This script:
      - Reads the required DefaultMinimumAgeDays variable from NinjaOne
      - Validates the minimum age (1-365 days); exits safely if missing or invalid
      - Detects Windows.old on the system drive
      - Determines folder age using its creation timestamp
      - Skips cleanup when the folder is younger than the configured minimum age
      - Uses Microsoft's cleanmgr.exe with the Previous Installations cleanup category
      - Checks for conflicting selections in the Disk Cleanup SAGERUN profile
      - Preserves and restores existing Disk Cleanup registry settings
      - Measures available disk space before and after cleanup
      - Reports cleanup status and recovered free space
      - Provides timestamped output through NinjaOne script activity results
      - Returns exit code 0 for success or skipped cleanup; exit code 1 for errors

    Removing Windows.old eliminates the ability to roll back to the previous Windows
    installation using those files. A minimum age of 14 days is recommended for routine
    deployments, although NinjaOne controls the actual configured value.

    The age calculation uses the Windows.old creation timestamp as an estimate of
    upgrade age. It does not independently verify the configured Windows rollback
    period or whether a Windows upgrade is currently in progress.

    This script does not remove C:\$GetCurrent or other Windows Setup directories.

.NOTES
    Author      : Chad Markley, Markley Technologies
    Last Edit   : 11-10-2026
    GitHub      : MSP-Scripts/ninja/ninja_Cleanup_WindowsOld.ps1
    Environment : NinjaOne (run as SYSTEM) or elevated interactive PowerShell
    Requires    : Windows 10/11 or Windows Server, PowerShell 5.1+,
                  Administrator/SYSTEM, Windows Disk Cleanup (cleanmgr.exe)
    Version     : 1.0

    Ninja Note  : Script variable (required):
                    Name            : Default Minimum Age Days
                    Calculated Name : DefaultMinimumAgeDays
                    Type            : Integer/Text
                    Default Value   : 14

                  The minimum age can be overridden when executing the script.
                  If the variable is blank, missing, or invalid, no cleanup occurs.

                  Run As: SYSTEM.
                  Exit 0 = cleanup completed / skipped / not required.
                  Exit 1 = failure or invalid configuration.

                  Cleanup results, disk-space measurements, and errors are
                  written to the NinjaOne script activity output.

.CHANGELOG
    1.0 - 11-10-2026 - Initial release of Windows.old cleanup automation.
          Added NinjaOne DefaultMinimumAgeDays variable, folder age validation,
          cleanmgr.exe SAGERUN:1221 execution, registry configuration preservation,
          conflict detection, timestamped logging, disk-space reporting,
          and explicit exit codes.

          Tested successfully on 11-10-2026 through NinjaOne:
            Configured minimum age : 4 days
            Windows.old age        : 4 days
            Free space before      : 46.81 GB
            Free space after       : 86.65 GB
            Net space recovered    : 39.84 GB
            Execution time         : 56 minutes 19 seconds
            Windows.old removed    : Yes
            Registry restored      : Yes
            NinjaOne result        : SUCCESS

.LINK
    https://github.com/chadmark/MSP-Scripts
    https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cleanmgr
#>

#region Helpers

function Write-Log {
    param(
        [string]$Message
    )

    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Get-FreeSpaceGB {
    $Disk = Get-CimInstance Win32_LogicalDisk `
        -Filter "DeviceID='$env:SystemDrive'" `
        -ErrorAction Stop

    if (-not $Disk) {
        throw "Unable to retrieve system drive information."
    }

    return [math]::Round($Disk.FreeSpace / 1GB, 2)
}

#endregion

#region Main

$ExitCode = 0
$RegistryModified = $false
$PreviousFlagExists = $false
$PreviousFlagValue = $null

$WindowsOld = Join-Path $env:SystemDrive 'Windows.old'

$RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Previous Installations'
$StateFlag = 'StateFlags1221'

try {
    Write-Log "Starting Windows.old cleanup assessment."

    # Read required NinjaOne variable
    $RawMinimumAge = $env:DefaultMinimumAgeDays

    if ([string]::IsNullOrWhiteSpace($RawMinimumAge)) {
        throw "Required NinjaOne variable DefaultMinimumAgeDays was not supplied."
    }

    $MinimumAgeDays = 0

    if (-not [int]::TryParse(
        $RawMinimumAge.Trim(),
        [ref]$MinimumAgeDays
    )) {
        throw "DefaultMinimumAgeDays must be a valid integer."
    }

    if ($MinimumAgeDays -lt 1 -or $MinimumAgeDays -gt 365) {
        throw "DefaultMinimumAgeDays must be between 1 and 365."
    }

    Write-Log "Minimum age configured: $MinimumAgeDays days."

    if (-not (Test-Path -LiteralPath $WindowsOld -PathType Container)) {
        Write-Log "Windows.old not found. No cleanup required."
    }
    else {
        $Folder = Get-Item -LiteralPath $WindowsOld `
            -Force -ErrorAction Stop

        $FolderAgeDays = [math]::Floor(
            ((Get-Date) - $Folder.CreationTime).TotalDays
        )

        Write-Log "Windows.old detected."
        Write-Log "Creation date: $($Folder.CreationTime)"
        Write-Log "Estimated age: $FolderAgeDays days."

        if ($FolderAgeDays -lt 0) {
            throw "Windows.old creation date is in the future."
        }

        if ($FolderAgeDays -lt $MinimumAgeDays) {
            Write-Log "SKIPPED: Folder is newer than $MinimumAgeDays days."
        }
        else {
            Write-Log "Windows.old meets the minimum age requirement."

            $CleanMgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'

            if (-not (Test-Path -LiteralPath $CleanMgr)) {
                throw "Disk Cleanup executable not found: $CleanMgr"
            }

            if (-not (Test-Path -LiteralPath $RegPath)) {
                throw "Disk Cleanup Previous Installations registry category not found."
            }

            # Prevent execution of additional categories previously
            # selected under the same SAGERUN profile.
            $VolumeCachesPath = Split-Path $RegPath -Parent
            $TargetKey = Get-Item -LiteralPath $RegPath -ErrorAction Stop

            $OtherSelections = @(
                Get-ChildItem -LiteralPath $VolumeCachesPath `
                    -ErrorAction Stop |
                Where-Object {
                    $_.PSPath -ne $TargetKey.PSPath
                } |
                ForEach-Object {
                    $Flag = Get-ItemProperty `
                        -LiteralPath $_.PSPath `
                        -Name $StateFlag `
                        -ErrorAction SilentlyContinue

                    if ($Flag -and $Flag.$StateFlag -eq 2) {
                        $_.PSChildName
                    }
                }
            )

            if ($OtherSelections.Count -gt 0) {
                throw "Disk Cleanup profile 1221 already selects other categories: $($OtherSelections -join ', ')"
            }

            # Save existing registry selection for restoration.
            $ExistingProperties = Get-ItemProperty `
                -LiteralPath $RegPath -ErrorAction Stop

            $ExistingFlag = $ExistingProperties.PSObject.Properties[$StateFlag]

            if ($null -ne $ExistingFlag) {
                $PreviousFlagExists = $true
                $PreviousFlagValue = [int]$ExistingFlag.Value
            }

            $FreeBeforeGB = Get-FreeSpaceGB

            Write-Log "Free space before cleanup: $FreeBeforeGB GB."
            Write-Log "Starting Windows Disk Cleanup."

            New-ItemProperty `
                -Path $RegPath `
                -Name $StateFlag `
                -PropertyType DWord `
                -Value 2 `
                -Force `
                -ErrorAction Stop | Out-Null

            $RegistryModified = $true

            $Process = Start-Process `
                -FilePath $CleanMgr `
                -ArgumentList '/SAGERUN:1221' `
                -Wait `
                -PassThru `
                -WindowStyle Hidden `
                -ErrorAction Stop

            if ($Process.ExitCode -ne 0) {
                throw "Disk Cleanup exited with code $($Process.ExitCode)."
            }

            $FreeAfterGB = Get-FreeSpaceGB

            $RecoveredGB = [math]::Round(
                ($FreeAfterGB - $FreeBeforeGB), 2
            )

            Write-Log "Disk Cleanup completed."
            Write-Log "Free space before: $FreeBeforeGB GB."
            Write-Log "Free space after: $FreeAfterGB GB."
            Write-Log "Net free-space change: $RecoveredGB GB."

            if (Test-Path -LiteralPath $WindowsOld) {
                Write-Log "NOTICE: Windows.old still exists. Some files may remain."
            }
            else {
                Write-Log "SUCCESS: Windows.old directory removed."
            }
        }
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    $ExitCode = 1
}
finally {
    if ($RegistryModified) {
        try {
            if ($PreviousFlagExists) {
                Set-ItemProperty `
                    -LiteralPath $RegPath `
                    -Name $StateFlag `
                    -Value $PreviousFlagValue `
                    -ErrorAction Stop
            }
            else {
                Remove-ItemProperty `
                    -LiteralPath $RegPath `
                    -Name $StateFlag `
                    -ErrorAction Stop
            }

            Write-Log "Disk Cleanup registry configuration restored."
        }
        catch {
            Write-Log "WARNING: Failed to restore registry configuration: $_"
            $ExitCode = 1
        }
    }
}

#endregion

exit $ExitCode
