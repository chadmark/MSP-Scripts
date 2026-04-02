<#
.SYNOPSIS
    Enables BitLocker on the OS drive, backs up the recovery key to AD DS, and writes it to a NinjaOne custom field.

.DESCRIPTION
    Runs in 64-bit PowerShell (self-relaunches if needed) and requires elevation.
    Checks ProtectionStatus and VolumeStatus to determine the drive state before acting:
      - Fully protected: skips encryption, ensures key protector, backs up to AD DS, writes to Ninja.
      - Partially encrypted / suspended (VolumeStatus != FullyDecrypted + recovery protector exists):
        resumes BitLocker, ensures key protector, backs up to AD DS, writes to Ninja.
      - Not protected: adds RecoveryPassword protector first (required by GPO before Enable-BitLocker),
        enables with TPM if available (else RecoveryPassword only), backs up to AD DS, writes to Ninja.
    Uses XtsAes256 + UsedSpaceOnly for fast rollout with strong encryption.

.NOTES
    Author      : Chad
    Last Edit   : 03/23/2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_Enablebitlocker_WritetoCustomFieldAndAD.ps1
    Environment : NinjaOne RMM (script runner), domain-joined Windows endpoints
    Requires    : Administrator, BitLocker feature, AD DS (for key backup), Ninja-Property-Set cmdlet
    Version     : 1.0

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

#region Force 64-bit PowerShell (important in RMM contexts)
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

    $rp = $blv.KeyProtector |
        Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' -and $_.RecoveryPassword } |
        Select-Object -Last 1 -ExpandProperty RecoveryPassword

    return $rp
}

function Ensure-RecoveryPasswordProtector {
    param(
        [Parameter(Mandatory)]
        [string]$MountPoint
    )

    $existing = Get-LatestRecoveryPassword -MountPoint $MountPoint
    if (-not $existing) {
        Write-Host "No Recovery Password protector found. Adding one..."
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
    }
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
        Backup-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $rpProtector.KeyProtectorId -ErrorAction SilentlyContinue
        Write-Host "Recovery key backed up to AD DS."
    } else {
        Write-Warning "No Recovery Password protector found to back up to AD DS."
    }
}

function Get-TpmUsable {
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        if ($tpm.TpmPresent -and $tpm.TpmReady) { return $true }
        return $false
    } catch {
        return $false
    }
}
#endregion

try {
    if (-not (Test-IsAdmin)) {
        throw "This script must run as Administrator (BitLocker operations require elevation)."
    }

    $mountPoint = $env:SystemDrive
    if (-not $mountPoint) { $mountPoint = "C:" }

    # (Optional) ensure WinRE is enabled; safe to ignore failures
    try { & reagentc /enable | Out-Null } catch { Write-Warning "reagentc /enable failed or not applicable: $($_.Exception.Message)" }

    $blv         = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop
    $isProtected = ($blv.ProtectionStatus -eq 'On')

    # *** CHANGED: inspect VolumeStatus in addition to ProtectionStatus ***
    # VolumeStatus can be FullyEncrypted/EncryptionInProgress/DecryptionInProgress even when
    # ProtectionStatus=Off (e.g. protection suspended, or a prior script run partially succeeded).
    # A Recovery Password protector may already exist in these states; attempting to add another
    # throws 0x80310031 ("only one key protector of this type is allowed").
    $volumeStatus       = $blv.VolumeStatus   # FullyDecrypted | FullyEncrypted | EncryptionInProgress | etc.
    $hasRecoveryPassword = $null -ne (
        $blv.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' -and $_.RecoveryPassword }
    )

    $alreadyEncrypting = ($volumeStatus -ne 'FullyDecrypted') -and $hasRecoveryPassword
    # *** END CHANGED ***

    if ($isProtected) {
        Write-Host "BitLocker is already enabled (ProtectionStatus=On) on $mountPoint."
        Ensure-RecoveryPasswordProtector -MountPoint $mountPoint
        Backup-RecoveryPasswordToAD      -MountPoint $mountPoint
    }
    # *** CHANGED: new elseif catches partially-encrypted / suspended state ***
    elseif ($alreadyEncrypting) {
        Write-Host "BitLocker encryption is already underway or a key protector exists (VolumeStatus=$volumeStatus). Skipping encryption."
        Write-Host "Ensuring Recovery Password protector and backing up to AD DS..."

        # If protection is suspended, resume it
        try { Resume-BitLocker -MountPoint $mountPoint -ErrorAction Stop | Out-Null } catch { }

        # Ensure a Recovery Password protector exists without adding a duplicate
        Ensure-RecoveryPasswordProtector -MountPoint $mountPoint
        Backup-RecoveryPasswordToAD      -MountPoint $mountPoint
    }
    # *** END CHANGED ***
    else {
        Write-Host "BitLocker is NOT enabled (ProtectionStatus=Off) on $mountPoint. Enabling now..."

        # IMPORTANT: GPO enforces "Do not enable BitLocker until recovery information is stored to AD DS".
        # A Recovery Password protector must exist BEFORE Enable-BitLocker is called, or it throws 0x8031002C.
        Write-Host "Adding Recovery Password protector before enabling (required by GPO)..."
        Add-BitLockerKeyProtector -MountPoint $mountPoint -RecoveryPasswordProtector -ErrorAction Stop | Out-Null

        $tpmUsable = Get-TpmUsable

        if ($tpmUsable) {
            Write-Host "TPM is present/ready. Enabling BitLocker using TPM protector..."
            $enableParams = @{
                MountPoint       = $mountPoint
                UsedSpaceOnly    = $true
                EncryptionMethod = 'XtsAes256'
                TpmProtector     = $true
                SkipHardwareTest = $true
                ErrorAction      = 'Stop'
            }
            Enable-BitLocker @enableParams | Out-Null
        }
        else {
            Write-Host "TPM not usable. Enabling BitLocker using Recovery Password protector..."
            # Recovery Password protector already added above; pass it as the enablement protector
            $enableParams = @{
                MountPoint                = $mountPoint
                UsedSpaceOnly             = $true
                EncryptionMethod          = 'XtsAes256'
                RecoveryPasswordProtector = $true
                SkipHardwareTest          = $true
                ErrorAction               = 'Stop'
            }
            Enable-BitLocker @enableParams | Out-Null
        }

        # If protection is suspended/off for any reason, attempt to resume
        try { Resume-BitLocker -MountPoint $mountPoint -ErrorAction Stop | Out-Null } catch { }

        # Ensure a Recovery Password protector exists (defensive; should already be present)
        Ensure-RecoveryPasswordProtector -MountPoint $mountPoint

        # Back up recovery key to AD DS
        Backup-RecoveryPasswordToAD -MountPoint $mountPoint
    }

    # Refresh + capture key
    $RecoveryKey = Get-LatestRecoveryPassword -MountPoint $mountPoint
    if (-not $RecoveryKey) {
        throw "Unable to retrieve a BitLocker Recovery Password for $mountPoint after ensuring key protectors."
    }

    Write-Host "BitLocker Recovery Key retrieved for: $env:COMPUTERNAME"

    # Write to Ninja custom field
    Ninja-Property-Set bitlockerKey $RecoveryKey

    Write-Host "Successfully wrote recovery key to Ninja custom field: bitlockerKey"
    exit 0
}
catch {
    Write-Error $_
    exit 1
}