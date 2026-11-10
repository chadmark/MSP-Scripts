<#
.SYNOPSIS
    Creates or rotates a hardcoded local administrator account
    using a manually typeable cryptographic passphrase.

.DESCRIPTION
    Generic version. Set $NewAdminUsername in the CONFIGURATION
    section before deploying; the script aborts if the placeholder
    value is left in place.

    Creates or updates the managed local administrator, verifies
    Administrators membership, and stores the password in the
    NinjaOne Secure custom field (with readback verification).

    If anything fails mid-rotation, a newly created account is
    disabled, or an existing account's previous password is
    restored locally and in NinjaOne.

    Optionally disables Admin and Administrator, only after the
    managed account is fully verified.

.NOTES
    Author      : Chad Mark
    Last Edit   : 11-10-2026
    Version     : 2.0
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_disable_AdminAdministrator_CreateLocalAdmin_SetRandomPassword.ps1
    Environment : NinjaOne RMM - runs as SYSTEM
    Requires    : 64-bit Windows PowerShell 5.1
    Ninja Note  : Script Variables:
                      disableAdminAccount         (Disable Admin Account)         Checkbox
                      disableAdministratorAccount (Disable Administrator Account) Checkbox
                  Secure Custom Field:
                      localAdminPassword (Secure, script read/write enabled)

.CHANGELOG
    2.0 - 11-10-2026 - Rebuilt from client v2.2: unbiased crypto RNG, larger word list, no duplicate words, Secure field readback, admin membership and enabled-state verification, rollback on failure, structured logging, legacy accounts disabled last, placeholder username guard. Removed $ChangeAdminUsername toggle.
    1.1 - 10-19-2026 - Header and Ninja Note updates.
    1.0 - 04-09-2026 - Initial version.

.LINK
    https://github.com/chadmark/MSP-Scripts/tree/main/Ninja
#>

$ErrorActionPreference = 'Stop'

# ============================================================
# CONFIGURATION
# ============================================================

$PasswordField = 'localAdminPassword'

# Hardcoded managed administrator username.
# Change this before deploying.
$NewAdminUsername = 'LocalAdminAccountName'

if ($NewAdminUsername -eq 'LocalAdminAccountName' -or
    [string]::IsNullOrWhiteSpace($NewAdminUsername)) {
    Write-Error "Set `$NewAdminUsername in the CONFIGURATION section before running. Aborting."
    exit 1
}

# ============================================================
# LOGGING
# ============================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','PASS','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-NinjaCheckbox {
    param(
        [string]$VarName,
        [bool]$Default = $true
    )

    $value = [Environment]::GetEnvironmentVariable($VarName)

    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Log "$VarName not supplied; defaulting to $Default"
        return $Default
    }

    switch ($value.Trim().ToLowerInvariant()) {
        'true'  { return $true }
        'false' { return $false }
        '1'     { return $true }
        '0'     { return $false }
        default {
            throw "Invalid checkbox value for $VarName"
        }
    }
}

# ============================================================
# CRYPTOGRAPHIC PASSWORD GENERATION
# ============================================================

$rng = $null

function Get-CryptoRandom {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1,2147483647)]
        [int]$Max
    )

    # Unbiased rejection sampling for Windows PowerShell 5.1
    $range = [uint64]4294967296
    $limit = $range - ($range % [uint64]$Max)

    $bytes = New-Object byte[] 4

    do {
        $script:rng.GetBytes($bytes)
        $number = [uint64][BitConverter]::ToUInt32($bytes, 0)
    } while ($number -ge $limit)

    return [int]($number % [uint64]$Max)
}

function New-TypeablePassword {

    # Readable words suitable for manual entry.
    $wordList = @(
        'Anchor','Apple','Arrow','Atlas','Autumn','Badger',
        'Baker','Bamboo','Banner','Barrel','Basin','Beacon',
        'Berry','Bison','Blaze','Blossom','Border','Bottle',
        'Breeze','Bridge','Bronze','Brook','Bubble','Cactus',
        'Candle','Canvas','Castle','Cedar','Cherry','Circle',
        'Citrus','Clover','Cobalt','Comet','Copper','Coral',
        'Cotton','Coyote','Crater','Crimson','Crystal','Daisy',
        'Dancer','Daring','Delta','Desert','Dolphin','Dragon',
        'Dream','Drifter','Eagle','Echo','Ember','Emerald',
        'Falcon','Famous','Feather','Fender','Fern','Ferry',
        'Fiddle','Flame','Flint','Flower','Forest','Fossil',
        'Frost','Garden','Garlic','Garnet','Glacier','Golden',
        'Granite','Grape','Gravel','Guitar','Hammer','Harbor',
        'Harvest','Hazel','Helmet','Heron','Hickory','Hollow',
        'Honey','Horizon','Hunter','Island','Ivory','Jacket',
        'Jasper','Jelly','Jewel','Jungle','Kettle','Kindle',
        'Kitten','Ladder','Lagoon','Lantern','Laurel','Ledger',
        'Lemon','Leopard','Lilac','Linen','Lizard','Locket',
        'Lumber','Magnet','Maple','Marble','Marigold','Market',
        'Meadow','Melody','Meteor','Miller','Mirror','Mosaic',
        'Mountain','Mustard','Nectar','Needle','Nickel','Noble',
        'North','Ocean','Olive','Onion','Orange','Orbit',
        'Orchid','Otter','Owl','Oyster','Paddle','Palace',
        'Panther','Paper','Parcel','Parrot','Pastel','Pebble',
        'Pepper','Petal','Phoenix','Piano','Picnic','Pillow',
        'Pineapple','Planet','Plaza','Pocket','Prairie','Prism',
        'Puddle','Pumpkin','Quartz','Rabbit','Radar','Rainbow',
        'Ranger','Raven','Razor','Reef','Ribbon','Ridge',
        'River','Robin','Rocket','Rose','Ruby','Rustle',
        'Saddle','Saffron','Sailor','Salmon','Sandal','Satin',
        'Scarlet','Shadow','Shelter','Silver','Sparrow','Spider',
        'Spirit','Spruce','Square','Stable','Starfish','Stone',
        'Storm','Summer','Sunset','Summit','Tangerine','Temple',
        'Thunder','Tiger','Timber','Tinsel','Topaz','Torch',
        'Tower','Travel','Tulip','Tunnel','Turtle','Twilight',
        'Valley','Velvet','Venus','Violet','Vortex','Walnut',
        'Warden','Water','Willow','Window','Winter','Wizard',
        'Wonder','Woodland','Yellow','Zephyr'
    )

    $selected = @()

    while ($selected.Count -lt 3) {
        $candidate = $wordList[
            (Get-CryptoRandom -Max $wordList.Count)
        ]

        if ($selected -cnotcontains $candidate) {
            $selected += $candidate
        }
    }

    $leadingNum = (Get-CryptoRandom -Max 900) + 100
    $middleNum  = (Get-CryptoRandom -Max 900) + 100

    $symbols = @('!','#','@','*')
    $symbol = $symbols[(Get-CryptoRandom -Max $symbols.Count)]

    $password = "{0} {1} {2}{3}{4}{5}" -f `
        $leadingNum,
        $selected[0],
        $selected[1],
        $middleNum,
        $selected[2],
        $symbol

    if ($password.Length -lt 21 -or $password.Length -ge 200) {
        throw 'Generated password failed length validation.'
    }

    return $password
}

# ============================================================
# NINJAONE SECURE FIELD FUNCTIONS
# ============================================================

function Get-StoredPassword {
    return (Get-NinjaProperty `
        -Name $PasswordField `
        -Type Secure `
        -ErrorAction Stop)
}

function Set-StoredPassword {
    param([string]$Password)

    $null = Set-NinjaProperty `
        -Name $PasswordField `
        -Value $Password `
        -Type Secure `
        -ErrorAction Stop
}

# ============================================================
# LOCAL ADMINISTRATORS GROUP
# ============================================================

function Get-AdministratorsGroup {
    return Get-LocalGroup `
        -SID 'S-1-5-32-544' `
        -ErrorAction Stop
}

function Test-AdminMembership {
    param(
        [string]$Username,
        [string]$GroupName
    )

    $user = Get-LocalUser `
        -Name $Username `
        -ErrorAction Stop

    $members = @(Get-LocalGroupMember `
        -Group $GroupName `
        -ErrorAction Stop)

    foreach ($member in $members) {
        if ($member.SID -and
            $member.SID.Value -eq $user.SID.Value) {
            return $true
        }
    }

    return $false
}

# ============================================================
# MAIN EXECUTION
# ============================================================

$createdAccount = $false
$passwordChanged = $false
$credentialWriteAttempted = $false
$rotationComplete = $false

$previousPassword = $null
$newPassword = $null

try {
    Write-Log "Starting rotation for $NewAdminUsername"

    # --------------------------------------------------------
    # PREREQUISITES
    # --------------------------------------------------------

    if ($PSVersionTable.PSVersion.Major -ne 5) {
        throw 'Windows PowerShell 5.1 is required.'
    }

    if (-not [Environment]::Is64BitProcess) {
        throw '64-bit PowerShell required.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    if ($identity.User.Value -ne 'S-1-5-18') {
        throw 'Script must run as Local SYSTEM.'
    }

    Import-Module Microsoft.PowerShell.LocalAccounts `
        -ErrorAction Stop

    foreach ($cmd in @('Get-NinjaProperty','Set-NinjaProperty')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "NinjaOne command unavailable: $cmd"
        }
    }

    Write-Log 'Execution prerequisites verified.' 'PASS'

    # --------------------------------------------------------
    # CHECKBOX OPTIONS
    # --------------------------------------------------------

    $DisableAdminAccount = Get-NinjaCheckbox `
        -VarName 'disableAdminAccount' `
        -Default $true

    $DisableAdministratorAccount = Get-NinjaCheckbox `
        -VarName 'disableAdministratorAccount' `
        -Default $true

    $adminGroup = Get-AdministratorsGroup

    # --------------------------------------------------------
    # CHECK MANAGED ACCOUNT
    # --------------------------------------------------------

    $existingAccount = Get-LocalUser `
        -Name $NewAdminUsername `
        -ErrorAction SilentlyContinue

    if ($existingAccount) {
        Write-Log "Existing account found: $NewAdminUsername"

        $previousPassword = Get-StoredPassword

        if ([string]::IsNullOrWhiteSpace($previousPassword)) {
            throw 'Previous Secure field credential unavailable.'
        }

        Write-Log 'Previous credential available for recovery.' 'PASS'
    }
    else {
        Write-Log "Creating new account: $NewAdminUsername"
    }

    # --------------------------------------------------------
    # GENERATE PASSPHRASE
    # --------------------------------------------------------

    $script:rng = [Security.Cryptography.RandomNumberGenerator]::Create()

    $newPassword = New-TypeablePassword

    $securePassword = ConvertTo-SecureString `
        -String $newPassword `
        -AsPlainText `
        -Force

    Write-Log 'Cryptographic passphrase generated.' 'PASS'

    # --------------------------------------------------------
    # CREATE OR ROTATE MANAGED ACCOUNT
    # --------------------------------------------------------

    if (-not $existingAccount) {

        New-LocalUser `
            -Name $NewAdminUsername `
            -Password $securePassword `
            -PasswordNeverExpires `
            -AccountNeverExpires `
            -Disabled `
            -Description 'Managed Local Administrator' `
            -ErrorAction Stop | Out-Null

        $createdAccount = $true
        $passwordChanged = $true

        Write-Log 'New account created in disabled state.' 'PASS'
    }
    else {

        Set-LocalUser `
            -Name $NewAdminUsername `
            -Password $securePassword `
            -PasswordNeverExpires $true `
            -AccountNeverExpires `
            -ErrorAction Stop

        $passwordChanged = $true

        Write-Log 'Existing account password updated.' 'PASS'
    }

    # --------------------------------------------------------
    # STORE PASSWORD IN NINJAONE
    # --------------------------------------------------------

    $credentialWriteAttempted = $true

    Set-StoredPassword -Password $newPassword

    Write-Log 'Secure field write accepted.' 'PASS'

    # Verify readback before disabling legacy accounts.
    $readback = Get-StoredPassword

    if ($readback -cne $newPassword) {
        throw 'Secure field readback did not match updated password.'
    }

    $readback = $null

    Write-Log 'Secure field readback verified.' 'PASS'

    # --------------------------------------------------------
    # VERIFY ADMINISTRATOR MEMBERSHIP
    # --------------------------------------------------------

    if (-not (Test-AdminMembership `
        -Username $NewAdminUsername `
        -GroupName $adminGroup.Name)) {

        Add-LocalGroupMember `
            -Group $adminGroup.Name `
            -Member "$env:COMPUTERNAME\$NewAdminUsername" `
            -ErrorAction Stop

        Write-Log 'Added account to local Administrators.' 'PASS'
    }

    $account = Get-LocalUser `
        -Name $NewAdminUsername `
        -ErrorAction Stop

    if (-not $account.Enabled) {
        Enable-LocalUser `
            -Name $NewAdminUsername `
            -ErrorAction Stop
    }

    $account = Get-LocalUser `
        -Name $NewAdminUsername `
        -ErrorAction Stop

    if (-not $account.Enabled) {
        throw 'Managed administrator is not enabled.'
    }

    if (-not (Test-AdminMembership `
        -Username $NewAdminUsername `
        -GroupName $adminGroup.Name)) {
        throw 'Managed administrator group membership missing.'
    }

    $rotationComplete = $true

    Write-Log "Verified administrator: $NewAdminUsername" 'PASS'

    # --------------------------------------------------------
    # DISABLE LEGACY ACCOUNTS
    # --------------------------------------------------------

    $legacyAccounts = @(
        @{ Name = 'Admin'; Disable = $DisableAdminAccount },
        @{ Name = 'Administrator'; Disable = $DisableAdministratorAccount }
    )

    foreach ($entry in $legacyAccounts) {

        if (-not $entry.Disable) {
            Write-Log "Skipping $($entry.Name): toggle disabled."
            continue
        }

        if ($entry.Name -eq $NewAdminUsername) {
            Write-Log 'Refusing to disable managed administrator.' 'WARN'
            continue
        }

        $legacy = Get-LocalUser `
            -Name $entry.Name `
            -ErrorAction SilentlyContinue

        if (-not $legacy) {
            Write-Log "Account not present: $($entry.Name)"
            continue
        }

        if (-not $legacy.Enabled) {
            Write-Log "Already disabled: $($entry.Name)"
            continue
        }

        Disable-LocalUser `
            -Name $legacy.Name `
            -ErrorAction Stop

        Write-Log "Disabled legacy account: $($legacy.Name)" 'PASS'
    }

    Write-Log "Rotation completed successfully for $NewAdminUsername" 'PASS'
    exit 0
}
catch {
    Write-Log "Rotation failed for $NewAdminUsername" 'ERROR'
    Write-Log $_.Exception.Message 'ERROR'

    if (-not $rotationComplete -and $passwordChanged) {

        if ($createdAccount) {
            try {
                Disable-LocalUser `
                    -Name $NewAdminUsername `
                    -ErrorAction Stop

                Write-Log 'New account disabled during recovery.' 'WARN'
            }
            catch {
                Write-Log 'Could not disable new account.' 'ERROR'
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($previousPassword)) {

            try {
                $rollbackSecure = ConvertTo-SecureString `
                    -String $previousPassword `
                    -AsPlainText `
                    -Force

                Set-LocalUser `
                    -Name $NewAdminUsername `
                    -Password $rollbackSecure `
                    -ErrorAction Stop

                Write-Log 'Previous local password restored.' 'PASS'

                if ($credentialWriteAttempted) {
                    Set-StoredPassword -Password $previousPassword
                    Write-Log 'Previous credential restoration submitted.' 'PASS'
                }
            }
            catch {
                Write-Log 'CRITICAL: Credential recovery failed.' 'ERROR'
            }
        }
    }

    exit 1
}
finally {
    if ($rng) {
        $rng.Dispose()
    }

    $newPassword = $null
    $previousPassword = $null
    $securePassword = $null
    $rollbackSecure = $null
    $readback = $null
}