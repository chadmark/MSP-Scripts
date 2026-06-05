<#
.SYNOPSIS
    Removes all BitLocker key protectors from the OS drive to allow a clean re-encryption attempt.

.DESCRIPTION
    Run this manually when a previous BitLocker enablement attempt partially succeeded, leaving
    orphaned key protectors on a FullyDecrypted drive. Clears all protectors so that
    Enable-BitLockerWithNinja.ps1 can start fresh without hitting 0x80310031.

    After running this script, confirm the output shows no remaining key protectors, then
    re-run Enable-BitLockerWithNinja.ps1 via NinjaOne.

.NOTES
    Author      : Chad
    Last Edit   : 03/23/2026
    Environment : Run manually on endpoint (PowerShell as Administrator)
    Requires    : Administrator rights

    WARNING: This script removes ALL key protectors from C:. Only run this when BitLocker
             is confirmed NOT actively encrypting (Conversion Status: Fully Decrypted).
             Running this on an actively encrypted drive will leave it without protectors.
#>

#region Preflight
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must run as Administrator."
}

$mountPoint = "C:"
#endregion

#region Status check
Write-Host "--- Current BitLocker status ---"
& manage-bde -status $mountPoint
Write-Host ""
#endregion

#region Remove all key protectors
Write-Host "Removing all key protectors from $mountPoint..."

$blv = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop

if (-not $blv.KeyProtector -or $blv.KeyProtector.Count -eq 0) {
    Write-Host "No key protectors found on $mountPoint. Nothing to remove."
}
else {
    foreach ($kp in $blv.KeyProtector) {
        Write-Host "  Removing protector: $($kp.KeyProtectorType) ($($kp.KeyProtectorId))"
        Remove-BitLockerKeyProtector -MountPoint $mountPoint -KeyProtectorId $kp.KeyProtectorId -ErrorAction Stop
    }
    Write-Host "All key protectors removed."
}
#endregion

#region Confirm
Write-Host ""
Write-Host "--- Remaining key protectors (should be empty) ---"
$remaining = Get-BitLockerVolume -MountPoint $mountPoint | Select-Object -ExpandProperty KeyProtector
if (-not $remaining -or $remaining.Count -eq 0) {
    Write-Host "Confirmed: no key protectors remain on $mountPoint."
} else {
    Write-Warning "Key protectors still present. Review manually:"
    $remaining | ForEach-Object { Write-Warning "  $($_.KeyProtectorType) - $($_.KeyProtectorId)" }
}
#endregion
