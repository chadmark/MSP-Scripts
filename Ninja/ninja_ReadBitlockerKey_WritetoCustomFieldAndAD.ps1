<#
.SYNOPSIS
    Reads the existing BitLocker recovery key from the OS drive, backs it up to AD DS
    if a domain controller is reachable, and writes it to the NinjaOne custom field.

.DESCRIPTION
    Does NOT enable, disable, or modify BitLocker in any way.
    Intended for machines that are already encrypted but whose recovery key is missing
    from AD DS or the Ninja custom field (e.g. imaged machines, field enrollments, etc.)

    - If BitLocker is not enabled, the script exits cleanly with no error.
    - If no RecoveryPassword protector exists, the script exits cleanly with no error.
    - If the machine is domain-connected, the key is written to both AD DS and the Ninja field.
    - If the DC is unreachable (off-network, VPN not connected, etc.), the AD backup is skipped
      and a warning is logged. The Ninja field is still written successfully.
    - Script does not fail on AD backup failure — Ninja write always completes if a key exists.

    Requires:
    - Ninja-Property-Set cmdlet available (NinjaOne agent)
    - Administrator or SYSTEM elevation

.NOTES
    Author      : Chad
    Last Edit   : 08-12-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts
    Environment : NinjaOne RMM, domain-joined Windows endpoints
    Ninja Note  : Custom field name: bitlockerKey (must exist before running)
    Version     : 1.1
#>

#region Force 64-bit PowerShell
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    Write-Warning "Re-launching in 64-bit PowerShell..."
    if ($myInvocation.Line) {
        & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NonInteractive -NoProfile $myInvocation.Line
    } else {
        & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NonInteractive -NoProfile -File "$($myInvocation.InvocationName)" @args
    }
    exit $LASTEXITCODE
}
#endregion

#region Helpers

function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LatestRecoveryPassword {
    param(
        [Parameter(Mandatory)]
        [string]$MountPoint
    )
    $blv = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
    $rp  = $blv.KeyProtector |
           Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' -and $_.RecoveryPassword } |
           Select-Object -Last 1 -ExpandProperty RecoveryPassword
    return $rp
}

function Backup-RecoveryPasswordToAD {
    param(
        [Parameter(Mandatory)]
        [string]$MountPoint
    )
    $blv         = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
    $rpProtector = $blv.KeyProtector |
                   Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
                   Select-Object -Last 1

    if ($rpProtector) {
        try {
            Backup-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $rpProtector.KeyProtectorId -ErrorAction Stop
            Write-Host "Recovery key successfully backed up to AD DS."
        } catch {
            Write-Warning "AD DS backup call failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "No Recovery Password protector found to back up to AD DS."
    }
}

function Test-DomainControllerReachable {
    try {
        $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
        $dc     = $domain.FindDomainController()
        Write-Host "Domain controller reachable: $($dc.Name)"
        return $true
    } catch {
        Write-Warning "Domain controller not reachable: $($_.Exception.Message)"
        return $false
    }
}

#endregion

try {

    if (-not (Test-IsAdmin)) {
        throw "This script must run as Administrator or SYSTEM."
    }

    $mountPoint = $env:SystemDrive
    if (-not $mountPoint) { $mountPoint = "C:" }

    Write-Host "Checking BitLocker status on $mountPoint..."
    $blv = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop

    # If BitLocker isn't on, exit cleanly — nothing to do
    if ($blv.ProtectionStatus -ne 'On') {
        Write-Host "BitLocker is not enabled on $mountPoint (ProtectionStatus: $($blv.ProtectionStatus)). Nothing to do — skipping."
        exit 0
    }

    # If there's no recovery password protector, exit cleanly — nothing to retrieve
    $hasRecoveryPassword = $null -ne (
        $blv.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' -and $_.RecoveryPassword }
    )

    if (-not $hasRecoveryPassword) {
        Write-Host "BitLocker is active on $mountPoint but no RecoveryPassword protector exists. Nothing to retrieve — skipping."
        exit 0
    }

    Write-Host "BitLocker is active on $mountPoint (VolumeStatus: $($blv.VolumeStatus))."

    # AD DS backup — only if DC is reachable
    Write-Host "Checking domain controller connectivity..."
    $dcReachable = Test-DomainControllerReachable

    if ($dcReachable) {
        Backup-RecoveryPasswordToAD -MountPoint $mountPoint
    } else {
        Write-Warning "Skipping AD DS backup — machine is not connected to the domain network. Key will be written to Ninja only. Re-run when on-network to complete AD backup."
    }

    # Retrieve the key
    Write-Host "Retrieving BitLocker recovery key..."
    $RecoveryKey = Get-LatestRecoveryPassword -MountPoint $mountPoint

    if (-not $RecoveryKey) {
        throw "Retrieved a null recovery key despite protector being present. Check BitLocker volume state."
    }

    Write-Host "BitLocker recovery key retrieved for: $env:COMPUTERNAME"

    # Write to Ninja custom field
    Ninja-Property-Set bitlockerKey $RecoveryKey
    Write-Host "Successfully wrote recovery key to Ninja custom field: bitlockerKey"

    # Summary
    Write-Host ""
    Write-Host "--- Summary ---"
    Write-Host "Computer  : $env:COMPUTERNAME"
    Write-Host "Drive     : $mountPoint"
    Write-Host "AD Backup : $(if ($dcReachable) { 'Completed' } else { 'SKIPPED - not on domain network' })"
    Write-Host "Ninja     : Written"

    exit 0

} catch {
    Write-Error $_
    exit 1
}
