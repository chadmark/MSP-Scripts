<#
.SYNOPSIS
    Disables stale Active Directory computer accounts and moves them to a
    designated OU based on how many days have passed since the machine last
    rotated its machine account password.

.DESCRIPTION
    Queries AD for all enabled computer objects whose PasswordLastSet attribute
    is older than the configured threshold. For each matching computer the
    script will:
      1. Disable the computer account
      2. Stamp a description noting the date and reason for disablement
      3. Move the object to the target disabled-computers OU

    A WhatIf mode (default ON) previews every action without making changes.
    Set $WhatIf = $false to execute for real. All actions and skips are written
    to a dated log file.

    Why PasswordLastSet and not LastLogonDate?
    PasswordLastSet is updated only when the Netlogon service on the machine
    successfully authenticates with a DC and rotates its machine account password
    (every ~30 days while the machine is online). It replicates immediately to all
    DCs, has no built-in lag, and cannot be spoofed by a cached logon — making it
    the most reliable "last seen on domain" signal available without querying every
    DC individually.

.NOTES
    Author:         Chad
    Last Edit:      06-29-2026
    GitHub:         chadmark/MSP-Scripts/ActiveDirectory/Disable-StaleComputers.ps1
    Environment:    On-premises AD or hybrid — run from a domain-joined machine
                    with RSAT (AD DS Tools) installed.
    Requires:       ActiveDirectory module, rights to disable and move computer
                    objects in AD, and write access to the target OU.
    Version:        1.3

.CHANGELOG
    1.3 - 06-29-2026 - Pre-check: already-disabled accounts in target OU logged as SKIP not FAIL
    1.2 - 06-29-2026 - Split try/catch per step; errors now log which step failed (Disable/Set-Description/Move) with full exception message
    1.1 - 06-29-2026 - Log filename now includes HH-mm to prevent WhatIf and live runs from appending to the same file
    1.0 - 06-29-2026 - Initial release

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# ─── CONFIGURATION ────────────────────────────────────────────────────────────

# Days since PasswordLastSet before a computer is considered stale.
$StaleThresholdDays = 90

# Target OU for disabled computer objects.
$TargetOU = "OU=DisabledComputers,DC=corp,DC=domain,DC=com"

# Set to $false to actually disable and move objects. Default $true = preview only.
$WhatIf = $true

# Filter by computer type. Options: "All", "Servers", "Workstations"
$Filter = "All"

# Log file path. Defaults to script directory, dated.
$LogPath = Join-Path $PSScriptRoot "Disable-StaleComputers_$(Get-Date -Format 'yyyy-MM-dd_HH-mm').log"

# ─── INIT ─────────────────────────────────────────────────────────────────────

#Requires -Modules ActiveDirectory

$ErrorActionPreference = "Stop"
$today     = Get-Date
$threshold = $today.AddDays(-$StaleThresholdDays)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line
    switch ($Level) {
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        "WHATIF"  { Write-Host $line -ForegroundColor Cyan }
        default   { Write-Host $line }
    }
}

# ─── PREFLIGHT ────────────────────────────────────────────────────────────────

# Verify target OU exists before touching anything
try {
    $null = Get-ADOrganizationalUnit -Identity $TargetOU
} catch {
    Write-Log "Target OU not found: $TargetOU — aborting." "ERROR"
    exit 1
}

Write-Log "=== Disable-StaleComputers START ==="
Write-Log "Threshold : $StaleThresholdDays days (cutoff: $($threshold.ToString('MM/dd/yyyy')))"
Write-Log "Target OU : $TargetOU"
Write-Log "Filter    : $Filter"
Write-Log "WhatIf    : $WhatIf"

# ─── QUERY ────────────────────────────────────────────────────────────────────

Write-Log "Querying Active Directory for stale enabled computer objects..."

$computers = Get-ADComputer -Filter { Enabled -eq $true } -Properties `
    Name, OperatingSystem, PasswordLastSet, DistinguishedName, Description |
    Where-Object { $_.PasswordLastSet -lt $threshold -or $_.PasswordLastSet -eq $null }

# Apply type filter
$computers = switch ($Filter) {
    "Servers"      { $computers | Where-Object { $_.OperatingSystem -like "*Server*" } }
    "Workstations" { $computers | Where-Object { $_.OperatingSystem -notlike "*Server*" } }
    default        { $computers }
}

$total = ($computers | Measure-Object).Count
Write-Log "Found $total computer(s) matching stale criteria."

if ($total -eq 0) {
    Write-Log "Nothing to do — exiting."
    exit 0
}

# ─── CONFIRM ──────────────────────────────────────────────────────────────────

if (-not $WhatIf) {
    Write-Host "`n  !! LIVE MODE — changes will be made to Active Directory !!" -ForegroundColor Red
    Write-Host "  $total computer account(s) will be DISABLED and MOVED to:" -ForegroundColor Red
    Write-Host "  $TargetOU`n" -ForegroundColor Red
    $confirm = Read-Host "  Type YES to proceed"
    if ($confirm -ne "YES") {
        Write-Log "Aborted by user at confirmation prompt." "WARN"
        exit 0
    }
}

# ─── PROCESS ──────────────────────────────────────────────────────────────────

$succeeded = 0
$skipped   = 0
$failed    = 0

foreach ($computer in $computers) {
    $name       = $computer.Name
    $dn         = $computer.DistinguishedName
    $pwdLastSet = if ($computer.PasswordLastSet) {
                      $computer.PasswordLastSet.ToString("MM/dd/yyyy")
                  } else { "Never" }
    $daysSince  = if ($computer.PasswordLastSet) {
                      [math]::Round(($today - $computer.PasswordLastSet).TotalDays)
                  } else { "N/A" }
    $os         = $computer.OperatingSystem

    # Skip if already disabled and already in the target OU — end state is correct, nothing to do.
    # Also catches accounts that were pre-disabled before the script ran (e.g. manually disabled
    # but not yet moved), which would cause Disable-ADAccount to throw even though the intent is met.
    $alreadyInTargetOU = $dn -like "*$TargetOU*"
    $alreadyDisabled   = -not $computer.Enabled

    if ($alreadyDisabled -and $alreadyInTargetOU) {
        Write-Log "SKIP  | $name — already disabled and in target OU" "WARN"
        $skipped++
        continue
    }

    $newDescription = "Disabled by Disable-StaleComputers.ps1 on $($today.ToString('MM/dd/yyyy')) — PasswordLastSet: $pwdLastSet ($daysSince days)"

    if ($WhatIf) {
        Write-Log "WHATIF| $name | OS: $os | PasswordLastSet: $pwdLastSet ($daysSince days) | Would disable + move to $TargetOU" "WHATIF"
        $succeeded++
        continue
    }

    try {
        # 1. Disable
        Disable-ADAccount -Identity $dn
    } catch {
        Write-Log "FAIL  | $name | OS: $os | PasswordLastSet: $pwdLastSet ($daysSince days) | Step: Disable | $($_.Exception.Message)" "ERROR"
        $failed++
        continue
    }

    try {
        # 2. Stamp description
        Set-ADComputer -Identity $dn -Description $newDescription
    } catch {
        Write-Log "FAIL  | $name | OS: $os | PasswordLastSet: $pwdLastSet ($daysSince days) | Step: Set-Description | $($_.Exception.Message)" "ERROR"
        $failed++
        continue
    }

    try {
        # 3. Move
        Move-ADObject -Identity $dn -TargetPath $TargetOU
    } catch {
        Write-Log "FAIL  | $name | OS: $os | PasswordLastSet: $pwdLastSet ($daysSince days) | Step: Move | $($_.Exception.Message)" "ERROR"
        $failed++
        continue
    }

    Write-Log "OK    | $name | OS: $os | PasswordLastSet: $pwdLastSet ($daysSince days) | Disabled + moved" "SUCCESS"
    $succeeded++
}

# ─── SUMMARY ──────────────────────────────────────────────────────────────────

Write-Log "=== SUMMARY ==="
if ($WhatIf) {
    Write-Log "WhatIf mode — no changes made. Re-run with `$WhatIf = `$false to execute."
    Write-Log "Would have processed : $succeeded"
} else {
    Write-Log "Succeeded : $succeeded"
    Write-Log "Skipped   : $skipped"
    Write-Log "Failed    : $failed"
}
Write-Log "Log written to: $LogPath"
Write-Log "=== Disable-StaleComputers END ==="