<#
.SYNOPSIS
    Configures System Restore with weekly automated restore point creation.
.DESCRIPTION
    Sets VSS shadow storage to 20%, enables System Restore, creates an initial
    restore point, registers a weekly scheduled task (Wednesdays at 10AM), and
    writes the most recent restore point date to a NinjaOne custom field.
.NOTES
    Author:      Chad
    Last Edit:   04-15-2026
    GitHub:      https://github.com/chadmark/MSP-Scripts/Ninja/ninja_system_restore_setup.ps1
    Environment: NinjaOne RMM — runs as SYSTEM
    Requires:    Admin privileges; NinjaOne custom field: mostRecentRecoveryPoint
    Version:     1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# ---------------------------------------------------------
# Variables
# ---------------------------------------------------------
[string]$checkpoint_task             = "Weekly-Checkpoint"
[string]$checkpoint_task_description = "Creates a system restore point every Wednesday at 10AM."
[string]$checkpoint_task_path        = "\WCC\"

# ---------------------------------------------------------
# Set VSS shadow storage max size to 20%
# ---------------------------------------------------------
$vssArgs = "resize shadowstorage /for=C: /on=C: /maxsize=20%"
Start-Process -FilePath "vssadmin.exe" -ArgumentList $vssArgs -Wait

# ---------------------------------------------------------
# Enable System Restore and create initial restore point
# ---------------------------------------------------------
Enable-ComputerRestore -Drive $env:SystemDrive -Confirm:$false
Checkpoint-Computer -Description "RESTOREPOINT" -RestorePointType MODIFY_SETTINGS

# ---------------------------------------------------------
# Build scheduled task components
# ---------------------------------------------------------
$checkpoint_task_trigger  = New-ScheduledTaskTrigger -Weekly -At 10am -DaysOfWeek Wednesday
$checkpoint_task_settings = New-ScheduledTaskSettingsSet `
    -DontStopOnIdleEnd `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries
$checkpoint_task_user = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$checkpoint_task_action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -Command `"Checkpoint-Computer -Description 'RESTOREPOINT' -RestorePointType MODIFY_SETTINGS`""

# ---------------------------------------------------------
# Remove existing task if present, then register
# ---------------------------------------------------------
Get-ScheduledTask -TaskName $checkpoint_task -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask `
    -TaskName    $checkpoint_task `
    -TaskPath    $checkpoint_task_path `
    -Action      $checkpoint_task_action `
    -Trigger     $checkpoint_task_trigger `
    -Principal   $checkpoint_task_user `
    -Settings    $checkpoint_task_settings `
    -Description $checkpoint_task_description `
    -Force

# ---------------------------------------------------------
# Confirm task registration
# ---------------------------------------------------------
if (Get-ScheduledTask -TaskName $checkpoint_task -ErrorAction SilentlyContinue) {
    Write-Host "[ SCHEDULED TASK '$checkpoint_task' CREATED SUCCESSFULLY ]" -ForegroundColor Green
} else {
    Write-Host "[ ERROR: SCHEDULED TASK '$checkpoint_task' COULD NOT BE CREATED ]" -ForegroundColor Red
}

# ---------------------------------------------------------
# Write most recent restore point date to NinjaOne
# ---------------------------------------------------------
try {
    $rp = Get-ComputerRestorePoint | Sort-Object CreationTime -Descending | Select-Object -First 1
    if ($rp) {
        $date = [Management.ManagementDateTimeConverter]::ToDateTime($rp.CreationTime)
        Ninja-Property-Set mostRecentRecoveryPoint "$date"
    } else {
        Ninja-Property-Set mostRecentRecoveryPoint "No restore point found"
    }
} catch {
    Write-Host "[ERROR] Failed to write restore point date to NinjaOne: $($_.Exception.Message)"
}
