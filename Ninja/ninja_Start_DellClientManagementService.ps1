<#
.SYNOPSIS
    Ensures the Dell Client Management Service is set to Automatic and running.

.DESCRIPTION
    Sets DellClientManagementService startup type to Automatic, starts the service
    if not already running, and waits up to 75 seconds for it to reach a Running state.
    Exits with code 1 on failure so NinjaOne flags the script as failed.

.NOTES
    Author      : Chad
    Last Edit   : 05-04-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_Start_DellClientManagementService.ps1
    Environment : NinjaOne RMM — SYSTEM context, domain-joined Windows endpoints
    Requires    : Dell Client Management Service installed
    Version     : 1.0
.LINK
    https://github.com/chadmark/MSP-Scripts
#>

$ServiceName = "DellClientManagementService"
$TimeoutSpan = [TimeSpan]::FromSeconds(75)

try {
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
} catch {
    Write-Host "ERROR: Service '$ServiceName' not found on this machine. $_"
    exit 1
}

try {
    Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop
    Write-Host "Startup type set to Automatic."
} catch {
    Write-Host "ERROR: Failed to set startup type. $_"
    exit 1
}

if ($svc.Status -ne 'Running') {
    try {
        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-Host "Start-Service issued. Waiting for Running state..."
    } catch {
        Write-Host "ERROR: Failed to start service. $_"
        exit 1
    }
} else {
    Write-Host "Service is already running."
}

try {
    $svc.WaitForStatus('Running', $TimeoutSpan)
    Write-Host "SUCCESS: '$ServiceName' is Running."
} catch [System.ServiceProcess.TimeoutException] {
    Write-Host "ERROR: Service did not reach Running state within $($TimeoutSpan.TotalSeconds) seconds."
    exit 1
} catch {
    Write-Host "ERROR: Unexpected error while waiting for service. $_"
    exit 1
}
