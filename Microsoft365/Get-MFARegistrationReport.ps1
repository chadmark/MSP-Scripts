<#
.SYNOPSIS
    Generates an MFA registration status report for all M365 users.

.DESCRIPTION
    Uses the Microsoft Graph API to pull per-user MFA registration details via
    the /reports/authenticationMethods/userRegistrationDetails endpoint. Produces
    two filtered lists: users with MFA configured and capable, and users with no
    MFA methods registered at all. Exports both to CSV.

.NOTES
    Author          Chad Mark
    Last Edit       05-11-2025
    GitHub          chadmark/MSP-Scripts/Microsoft365/Get-MFARegistrationReport.ps1
    Environment     PowerShell 5.1+ or PowerShell 7+, run interactively or as admin
    Requires        Microsoft.Graph module (Reports, Users scopes)
                    Permissions: Reports.Read.All, UserAuthenticationMethod.Read.All,
                    AuditLog.Read.All (delegated or application)
    Version         1.0

.CHANGELOG
    1.0 - 05-11-2025 - Initial release

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

#Requires -Modules Microsoft.Graph.Reports, Microsoft.Graph.Users

[CmdletBinding()]
param (
    # Output folder for CSV exports. Defaults to script directory.
    [string]$OutputPath = $PSScriptRoot,

    # If set, also exports a full report of all users with all fields.
    [switch]$ExportFull
)

#region --- Connect ---
Write-Host "[*] Connecting to Microsoft Graph..." -ForegroundColor Cyan

Connect-MgGraph -Scopes "Reports.Read.All", "UserAuthenticationMethod.Read.All", "AuditLog.Read.All" -NoWelcome

Write-Host "[+] Connected." -ForegroundColor Green
#endregion

#region --- Pull Registration Details ---
Write-Host "[*] Pulling authentication registration details (this may take a moment)..." -ForegroundColor Cyan

# This endpoint returns one record per user with MFA/SSPR registration state.
# isMfaCapable = has at least one method usable for MFA challenges
# isMfaRegistered = completed the registration flow (may not have a usable method)
# methodsRegistered = list of registered method types (e.g., microsoftAuthenticatorPush, softwareOneTimePasscode)
$RegistrationDetails = Get-MgReportAuthenticationMethodUserRegistrationDetail -All

Write-Host "[+] Retrieved $($RegistrationDetails.Count) user records." -ForegroundColor Green
#endregion

#region --- Build Report Objects ---
$Report = foreach ($User in $RegistrationDetails) {

    $Methods = if ($User.MethodsRegistered) {
        $User.MethodsRegistered -join ", "
    } else {
        "None"
    }

    [PSCustomObject]@{
        DisplayName      = $User.UserDisplayName
        UPN              = $User.UserPrincipalName
        IsMfaCapable     = $User.IsMfaCapable
        IsMfaRegistered  = $User.IsMfaRegistered
        DefaultMfaMethod = $User.DefaultMfaMethod
        MethodsRegistered = $Methods
        IsSsprRegistered = $User.IsSsprRegistered
        IsSsprCapable    = $User.IsSsprCapable
    }
}
#endregion

#region --- Split into Target Groups ---

# Group 1: MFA configured and capable of being challenged
$MfaConfigured = $Report | Where-Object { $_.IsMfaCapable -eq $true }

# Group 2: No MFA registered at all — no methods, no registration
$NoMfaNoDevices = $Report | Where-Object {
    $_.IsMfaRegistered -eq $false -and $_.MethodsRegistered -eq "None"
}
#endregion

#region --- Console Summary ---
Write-Host ""
Write-Host "===== MFA REPORT SUMMARY =====" -ForegroundColor Yellow
Write-Host "  Total users evaluated : $($Report.Count)"
Write-Host "  MFA capable (configured) : $($MfaConfigured.Count)" -ForegroundColor Green
Write-Host "  No MFA, no devices registered : $($NoMfaNoDevices.Count)" -ForegroundColor Red
Write-Host ""

Write-Host "--- Users with NO MFA and NO registered devices ---" -ForegroundColor Red
$NoMfaNoDevices | Select-Object DisplayName, UPN | Format-Table -AutoSize

Write-Host "--- Users with MFA Configured ---" -ForegroundColor Green
$MfaConfigured | Select-Object DisplayName, UPN, DefaultMfaMethod, MethodsRegistered | Format-Table -AutoSize
#endregion

#region --- CSV Export ---
$Timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"

$MfaConfiguredPath  = Join-Path $OutputPath "MFA_Configured_$Timestamp.csv"
$NoMfaPath          = Join-Path $OutputPath "MFA_NotConfigured_NoDevices_$Timestamp.csv"

$MfaConfigured  | Export-Csv -Path $MfaConfiguredPath  -NoTypeInformation -Encoding UTF8
$NoMfaNoDevices | Export-Csv -Path $NoMfaPath          -NoTypeInformation -Encoding UTF8

if ($ExportFull) {
    $FullPath = Join-Path $OutputPath "MFA_FullReport_$Timestamp.csv"
    $Report | Export-Csv -Path $FullPath -NoTypeInformation -Encoding UTF8
    Write-Host "[+] Full report exported: $FullPath" -ForegroundColor Cyan
}

Write-Host "[+] MFA Configured export  : $MfaConfiguredPath" -ForegroundColor Green
Write-Host "[+] No MFA/No Devices export: $NoMfaPath" -ForegroundColor Red
#endregion

Disconnect-MgGraph | Out-Null
Write-Host "[*] Disconnected from Graph." -ForegroundColor Cyan
