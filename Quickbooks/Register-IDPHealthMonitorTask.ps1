<#
.SYNOPSIS
    Registers a scheduled task to run the IDP health monitor script every 4 hours.

.DESCRIPTION
    Creates a Windows Scheduled Task that runs Monitor_IDP_Health_Logs.ps1 every 4 hours
    under the SYSTEM account. Task starts at 6:00 AM on the day it is registered and
    repeats every 4 hours indefinitely. Existing task with the same name is removed and
    recreated to ensure settings are current.

    Run this script once on the target machine after placing the monitor script in the
    correct location. No ongoing maintenance required.

.NOTES
    Author        : Chad
    Last Edit     : 06-04-2026
    GitHub        : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/Register-IDPHealthMonitorTask.ps1
    Environment   : Windows Server, PowerShell 5.1+, must run as Administrator
    Requires      : Monitor_IDP_Health_Logs.ps1 present at $scriptPath before running
    Version       : 1.1
.LINK
    https://github.com/chadmark/MSP-Scripts

#>

#Requires -RunAsAdministrator

# ============================================================
# CONFIGURATION
# ============================================================

# Full path to the monitor script on this machine
$scriptPath = "C:\scripts\Monitor_IDP_Health_Logs.ps1"

# Scheduled task settings
$taskName      = "Markley - IDP Health Monitor"
$taskDesc      = "Monitors Intuit Data Protect backup health every 4 hours and sends email alert on failure. Managed by Markley Technologies."
$intervalHours = 4
$startTime     = "06:00"

# ============================================================
# REGISTER TASK
# ============================================================

# Verify the script exists before registering
if (-not (Test-Path $scriptPath)) {
    Write-Host "ERROR: Monitor script not found at $scriptPath" -ForegroundColor Red
    Write-Host "Place the script at that path and re-run." -ForegroundColor Red
    exit 1
}

# Remove existing task if present
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task: $taskName" -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Build task components
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

$trigger = New-ScheduledTaskTrigger -Daily -At $startTime

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -RestartCount 1 `
    -RestartInterval (New-TimeSpan -Minutes 10) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Register the task
try {
    Register-ScheduledTask `
        -TaskName $taskName `
        -Description $taskDesc `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Force | Out-Null

    # Set repetition via CIM object on the registered task
    # PS 5.1 does not support repetition params on New-ScheduledTaskTrigger;
    # mutating the registered task object is the only reliable method
    $registered = Get-ScheduledTask -TaskName $taskName
    $registered.Triggers[0].Repetition.Interval = "PT${intervalHours}H"
    $registered.Triggers[0].Repetition.Duration = "P1D"
    $registered | Set-ScheduledTask | Out-Null

    Write-Host "Task registered successfully: $taskName" -ForegroundColor Green
    Write-Host "  Script  : $scriptPath" -ForegroundColor Cyan
    Write-Host "  Schedule: Every $intervalHours hours starting at $startTime" -ForegroundColor Cyan
    Write-Host "  Account : SYSTEM" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To verify:" -ForegroundColor Yellow
    Write-Host "  Get-ScheduledTask -TaskName '$taskName' | Get-ScheduledTaskInfo" -ForegroundColor Gray
} catch {
    Write-Host "ERROR: Failed to register task: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
