#Requires -Version 5.1

<#
.SYNOPSIS
    Removes a specified domain OR local user from the local Administrators group.

.DESCRIPTION
    Resolves the built-in local Administrators group by well-known SID (S-1-5-32-544, locale/rename
    safe), then removes one specific account if it's a direct member. No other member is touched.
    Each execution only affects the local machine it runs on - Ninja fans the run out across a
    policy/group of endpoints.

    Two modes, controlled by the "Local Account" checkbox:
      - Unchecked (default): targets an AD DOMAIN account - "AD Domain" + "User Account" build DOMAIN\User.
      - Checked: targets a LOCAL account on the machine itself - "AD Domain" is ignored, "User Account"
        is read as the local username (e.g. "Shawn") and qualified as COMPUTERNAME\Shawn.

.NOTES
    Author       : Chad
    Last Edit    : 08-18-2026
    GitHub       : https://github.com/chadmark/MSP-Scripts/blob/main/Ninja/ninja_remove_localadmin_user.ps1
    Environment  : NinjaOne RMM - runs as SYSTEM, Windows 10/11 and Windows Server, domain-joined or standalone
    Requires     : Local Administrator / SYSTEM context
    Ninja Note   : Script variables required:
                   AD Domain     | Env: aDDomain     | Type: Text     | NetBIOS domain name (e.g. "CONTOSO").
                                                                         Required unless Local Account is checked.
                   User Account  | Env: userAccount  | Type: Text     | Domain SamAccountName, or local username
                                                                         if Local Account is checked (e.g. "Shawn").
                   Local Account | Env: localAccount | Type: Checkbox | Target a local account on this machine
                                                                         instead of a domain account.
                   Report Only   | Env: reportOnly   | Type: Checkbox | Dry run - logs only, no changes made.
                                                                         Defaults to $true if unset outside Ninja.
    Version      : 1.1

.CHANGELOG
    0.1 - 08-18-2026 - Initial draft
    1.0 - 08-18-2026 - Confirmed working on test machine, finalized for repo
    1.1 - 08-18-2026 - Added Local Account mode (target a local user instead of a domain user);
                        renamed "AD User" field to "User Account". Confirmed working.

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [String]$ADDomain,

    [Parameter()]
    [String]$UserAccount,

    [Parameter()]
    [Switch]$LocalAccount,

    [Parameter()]
    [Switch]$ReportOnly
)

begin {
    if ($env:aDDomain -and $env:aDDomain -notlike "null") { $ADDomain = $env:aDDomain }
    if ($env:userAccount -and $env:userAccount -notlike "null") { $UserAccount = $env:userAccount }
    if ($env:localAccount -and $env:localAccount -notlike "null") {
        $LocalAccount = [System.Convert]::ToBoolean($env:localAccount)
    }
    if ($env:reportOnly -and $env:reportOnly -notlike "null") {
        $ReportOnly = [System.Convert]::ToBoolean($env:reportOnly)
    }
    elseif (-not $PSBoundParameters.ContainsKey('ReportOnly')) {
        # Safety default for manual/out-of-Ninja runs: report-only unless explicitly turned off
        $ReportOnly = $true
    }

    if ($LocalAccount) {
        # Local mode: AD Domain is ignored entirely - User Account is read as the LOCAL username on
        # this machine (e.g. "Shawn"), qualified with this machine's own name.
        if (-not $UserAccount) {
            Write-Host "ERROR: User Account (the local username, in Local Account mode) must be specified."
            exit 1
        }
        $TargetAuthority = $env:COMPUTERNAME
        $TargetAccount = "$TargetAuthority\$UserAccount"
    }
    else {
        if (-not $ADDomain -or -not $UserAccount) {
            Write-Host "ERROR: Both AD Domain and User Account must be specified."
            exit 1
        }
        $TargetAuthority = $ADDomain
        $TargetAccount = "$TargetAuthority\$UserAccount"
    }

    function Test-IsElevated {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

process {
    if (-not (Test-IsElevated)) {
        Write-Host "ERROR: Access denied. This script must run elevated (SYSTEM/Administrator)."
        exit 1
    }

    # Resolve the built-in Administrators group by well-known SID so this works regardless of
    # locale (e.g. "Administrateurs") or a renamed group.
    try {
        $AdminGroup = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Could not resolve the local Administrators group (SID S-1-5-32-544): $($_.Exception.Message)"
        exit 1
    }

    if ($ReportOnly) {
        # Existence check only - no changes. Get-LocalGroupMember can throw if an unrelated member
        # has an orphaned SID, so fall back to ADSI if needed rather than reporting a false negative.
        $isMember = $false
        try {
            $isMember = [bool](Get-LocalGroupMember -Group $AdminGroup -Member $TargetAccount -ErrorAction Stop)
        }
        catch {
            try {
                $adsiGroup = [ADSI]"WinNT://./Administrators,group"
                $isMember = [bool]($adsiGroup.Invoke('Members') | Where-Object {
                        $adsPath = $_.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $_, $null)
                        $adsPath -match "^WinNT://$([regex]::Escape($TargetAuthority))/$([regex]::Escape($UserAccount))$"
                    })
            }
            catch {
                Write-Host "ERROR: Could not determine membership for $TargetAccount : $($_.Exception.Message)"
                exit 1
            }
        }

        if ($isMember) {
            Write-Host "WOULD REMOVE: $TargetAccount is currently a member of local Administrators (report-only mode - no changes made)"
        }
        else {
            Write-Host "$TargetAccount is not currently a member of local Administrators."
        }
        exit 0
    }

    # Live mode - Remove-LocalGroupMember resolves only the specified account (not a full group
    # enumeration), so it isn't affected by unrelated orphaned SIDs elsewhere in the group.
    if ($PSCmdlet.ShouldProcess($TargetAccount, "Remove from local Administrators")) {
        try {
            Remove-LocalGroupMember -Group $AdminGroup -Member $TargetAccount -Confirm:$false -ErrorAction Stop
            Write-Host "REMOVED: $TargetAccount from local Administrators"
        }
        catch {
            if ($_.Exception.Message -match 'is not a member|does not exist|not found|No mapping between account names') {
                Write-Host "$TargetAccount is not currently a member of local Administrators. Nothing to do."
            }
            else {
                Write-Host "FAILED to remove $TargetAccount : $($_.Exception.Message)"
                exit 1
            }
        }
    }

    exit 0
}

end {
}
