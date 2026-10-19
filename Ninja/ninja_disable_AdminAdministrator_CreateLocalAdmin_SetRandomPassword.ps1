<#
.SYNOPSIS
    Creates or updates a local admin account with a typeable random passphrase.

.DESCRIPTION
    Optionally disables existing 'Admin' and 'Administrator' local accounts
    (independently toggleable, default: disabled), then creates or updates a
    local admin account (LocalAdminAccountName) with a cryptographically generated
    passphrase. Password is written to a NinjaRMM custom field upon completion.

.NOTES
    Author      : Chad Mark
    Last Edit   : 10-19-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_disable_AdminAdministrator_CreateLocalAdmin_SetRandomPassword.ps1
    Environment : NinjaOne RMM — runs as SYSTEM on domain-joined Windows endpoints
    Requires    : PowerShell 3.0+
    Version     : 1.1
    Ninja Note  : disableAdminAccount          (Disable Admin Account)          - Checkbox
                  disableAdministratorAccount  (Disable Administrator Account)  - Checkbox
                  Create Custom Secure field for password value to write to

.CHANGELOG
    1.0 - 04-09-2026 - Initial version

.LINK
    https://github.com/chadmark/MSP-Scripts/new/main/Ninja
#>

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Error "PowerShell version 3.0 or higher is required to run this script."
    exit
} else {
    Write-Host "PowerShell version 3.0 or higher is installed. You're good to proceed!"
}

$ChangeAdminUsername = $true
$NewAdminUsername    = "LocalAdminAccountName"

#####################################################################
# Ninja checkbox variables — default TRUE (disable) if not set/unavailable
function Get-NinjaCheckbox {
    param([string]$VarName, [bool]$Default = $true)
    $val = [Environment]::GetEnvironmentVariable($VarName)
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return [System.Convert]::ToBoolean($val)
}

$DisableAdminAccount         = Get-NinjaCheckbox -VarName 'disableAdminAccount'         -Default $true
$DisableAdministratorAccount = Get-NinjaCheckbox -VarName 'disableAdministratorAccount' -Default $true

#####################################################################
Add-Type -AssemblyName System.Web

$wordList = @(
    'Anchor','Badger','Blaze','Benton','Brixton','Cinder','Cobalt','Copper','Dagger',
    'Dancer','Drifter','Ember','Falcon','Fable','Fender','Flint','Gravel','Harbor',
    'Hallow','Harlow','Ivory','Jasper','Kindle','Lancer','Langley','Ledger','Marble',
    'Manning','Morgan','Morton','Nether','Norwood','Orbit','Pepper','Preston','Quartz',
    'Ranger','Riven','Rustle','Sable','Saddle','Shelter','Sutton','Timber','Tinder',
    'Vortex','Warden','Willet','Wilt','Zephyr'
)

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

function Get-CryptoRandom {
    param([int]$Max)
    $bytes = New-Object byte[] 4
    $rng.GetBytes($bytes)
    [Math]::Abs([BitConverter]::ToInt32($bytes, 0)) % $Max
}

$leadingNum  = (Get-CryptoRandom 900) + 100
$word1       = $wordList[(Get-CryptoRandom $wordList.Count)]
$word2       = $wordList[(Get-CryptoRandom $wordList.Count)]
$word3       = $wordList[(Get-CryptoRandom $wordList.Count)]
$midNum      = (Get-CryptoRandom 89) + 10
$specialChar = (@('!','@','#','$','%','^','&','*'))[(Get-CryptoRandom 8)]

$LocalAdminPassword = "$leadingNum $word1 $word2$midNum$word3$specialChar"

if ($LocalAdminPassword.Length -le 20) {
    Write-Warning "Insufficient password length, using random characters"
    $LocalAdminPassword = [System.Web.Security.Membership]::GeneratePassword(24, 5)
}
if ($LocalAdminPassword.Length -le 20) {
    Write-Error "Insufficient password length, aborting."
    exit
}

#####################################################################
$accountsToDisable = @{
    'Admin'         = $DisableAdminAccount
    'Administrator' = $DisableAdministratorAccount
}
foreach ($acct in $accountsToDisable.Keys) {
    if (-not $accountsToDisable[$acct]) {
        Write-Host "Skipping disable for '$acct' (toggle off)" -ForegroundColor Yellow
        continue
    }
    $user = Get-LocalUser -Name $acct -ErrorAction SilentlyContinue
    if ($user -and $user.Enabled) {
        Disable-LocalUser -Name $acct
        Write-Host "Disabled local account: $acct" -ForegroundColor Red
    }
}

#####################################################################
if ($ChangeAdminUsername -eq $false) {
    Set-LocalUser -Name "Admin" -Password ($LocalAdminPassword | ConvertTo-SecureString -AsPlainText -Force) -PasswordNeverExpires:$true
} else {
    $ExistingNewAdmin = Get-LocalUser | Where-Object { $_.Name -eq $NewAdminUsername }
    if (!$ExistingNewAdmin) {
        Write-Host "Creating new user" -ForegroundColor Yellow
        New-LocalUser -Name $NewAdminUsername -Password ($LocalAdminPassword | ConvertTo-SecureString -AsPlainText -Force) -PasswordNeverExpires:$true
        Add-LocalGroupMember -Group Administrators -Member $NewAdminUsername
    } else {
        Write-Host "Updating admin password" -ForegroundColor Yellow
        Set-LocalUser -Name $NewAdminUsername -Password ($LocalAdminPassword | ConvertTo-SecureString -AsPlainText -Force)
    }
}

Ninja-Property-Set localAdminPassword $LocalAdminPassword
