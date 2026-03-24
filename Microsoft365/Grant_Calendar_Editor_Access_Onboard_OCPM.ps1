<#
.SYNOPSIS
    Grants a new user Editor access to a defined set of calendars, and grants those
    users Editor access to the new user's calendar.

.DESCRIPTION
    Prompts for a new user's email address and performs a two-way calendar permission
    grant. First, the new user is granted Editor access to each calendar in the static
    list. Second, each user in the static list is granted Editor access to the new
    user's calendar. Useful for onboarding scenarios where bidirectional calendar
    access is required across a fixed set of accounts.

.NOTES
    Author:       Chad Mark
    Last Edit:    2026-03-24
    GitHub:       https://github.com/chadmark/MSP-Scripts/blob/main/Microsoft365/Grant_Calendar_Editor_Access_Onboard.ps1
    Environment:  Microsoft 365 / Exchange Online
    Requires:     ExchangeOnlineManagement module, appropriate admin permissions
    Version:      2.0

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# ── Configuration ────────────────────────────────────────────────────────────

$CalendarOwners = @(
    "javier@ocmgmt.com",
    "israel@ocmgmt.com",
    "alberto@ocmgmt.com",
    "andrew@ocmgmt.com",
    "padrics@ocmgmt.com"
)

do {
    $NewUser = Read-Host "Enter the new user's email address to grant Editor access"
} while ($NewUser -notmatch '^[\w\.\-]+@[\w\.\-]+\.\w+$')

# ── Connect to Exchange Online ────────────────────────────────────────────────

if (-not (Get-ConnectionInformation | Where-Object { $_.State -eq "Connected" })) {
    Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
    Connect-ExchangeOnline -ShowBanner:$false
}

# ── Helper Function ───────────────────────────────────────────────────────────

function Set-CalendarEditorAccess {
    param (
        [string]$CalendarOwner,
        [string]$GrantedUser,
        [string]$Direction
    )

    $CalendarIdentity = "$CalendarOwner`:\Calendar"

    if ($GrantedUser -eq $CalendarOwner) {
        Write-Host "  SKIPPED (same as calendar owner) - $CalendarOwner" -ForegroundColor DarkGray
        return [PSCustomObject]@{
            Direction   = $Direction
            Calendar    = $CalendarOwner
            Status      = "Skipped"
            AccessRight = "N/A"
            Error       = ""
        }
    }

    Write-Host "Processing $CalendarOwner ..." -ForegroundColor Cyan

    try {
        $existing = Get-MailboxFolderPermission -Identity $CalendarIdentity -User $GrantedUser -ErrorAction SilentlyContinue

        if ($existing) {
            Set-MailboxFolderPermission `
                -Identity     $CalendarIdentity `
                -User         $GrantedUser `
                -AccessRights Editor `
                -ErrorAction  Stop
            $action = "Updated"
        } else {
            Add-MailboxFolderPermission `
                -Identity     $CalendarIdentity `
                -User         $GrantedUser `
                -AccessRights Editor `
                -ErrorAction  Stop
            $action = "Added"
        }

        $perm = Get-MailboxFolderPermission -Identity $CalendarIdentity -User $GrantedUser
        Write-Host "  SUCCESS ($action) - Editor granted" -ForegroundColor Green

        return [PSCustomObject]@{
            Direction   = $Direction
            Calendar    = $CalendarOwner
            Status      = "Success ($action)"
            AccessRight = ($perm.AccessRights -join ",")
            Error       = ""
        }
    }
    catch {
        Write-Host "  FAILED - $($_.Exception.Message)" -ForegroundColor Red
        return [PSCustomObject]@{
            Direction   = $Direction
            Calendar    = $CalendarOwner
            Status      = "Failed"
            AccessRight = ""
            Error       = $_.Exception.Message
        }
    }
}

# ── Pass 1: Grant New User Access to Static Calendars ────────────────────────

Write-Host "`nPass 1: Granting '$NewUser' Editor access to static user calendars...`n" -ForegroundColor Yellow

$results = @()

foreach ($owner in $CalendarOwners) {
    $results += Set-CalendarEditorAccess -CalendarOwner $owner -GrantedUser $NewUser -Direction "New User -> Static"
}

# ── Pass 2: Grant Static Users Access to New User's Calendar ─────────────────

Write-Host "`nPass 2: Granting static users Editor access to '$NewUser' calendar...`n" -ForegroundColor Yellow

foreach ($owner in $CalendarOwners) {
    $results += Set-CalendarEditorAccess -CalendarOwner $NewUser -GrantedUser $owner -Direction "Static -> New User"
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n==== FINAL RESULTS ====" -ForegroundColor Yellow
$results | Format-Table -AutoSize

$successCount = ($results | Where-Object { $_.Status -like "Success*" }).Count
$failCount    = ($results | Where-Object { $_.Status -eq "Failed" }).Count
$skipCount    = ($results | Where-Object { $_.Status -eq "Skipped" }).Count

Write-Host "Success: $successCount  |  Failed: $failCount  |  Skipped: $skipCount`n" -ForegroundColor Cyan