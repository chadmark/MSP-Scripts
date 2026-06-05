<#
.SYNOPSIS
    Grants Editor access to a specified user's calendar for all mailboxes in the tenant.

.DESCRIPTION
    Connects to Exchange Online and grants Editor calendar permissions on a target mailbox
    to every UserMailbox in the organization. Skips the calendar owner to avoid self-permission
    errors. Outputs a results summary table and optionally exports a CSV report.

.NOTES
    Author:       Chad Mark
    Last Edit:    2026-03-24
    GitHub:       https://github.com/chadmark/MSP-Scripts/blob/main/Microsoft365/Grant_Calendar_Editor_Access.ps1
    Original Author: ChatGPT
    Original Link:   N/A (generated 2026-02-12)
    Environment:  Microsoft 365 / Exchange Online
    Requires:     ExchangeOnlineManagement module, appropriate admin permissions
    Version:      1.1

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

# ── Configuration ────────────────────────────────────────────────────────────

do {
    $CalendarOwner = Read-Host "Enter the calendar owner's email address"
} while ($CalendarOwner -notmatch '^[\w\.\-]+@[\w\.\-]+\.\w+$')

$CalendarIdentity = "$CalendarOwner`:\Calendar"
$ExportCsv        = $false   # Set to $true to export results to CSV
$CsvPath          = "C:\Temp\CalendarPermissions_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

# ── Connect to Exchange Online ────────────────────────────────────────────────

if (-not (Get-ConnectionInformation | Where-Object { $_.State -eq "Connected" })) {
    Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
    Connect-ExchangeOnline -ShowBanner:$false
}

# ── Main ─────────────────────────────────────────────────────────────────────

Write-Host "`nGranting Editor access on '$CalendarIdentity' to all mailboxes...`n" -ForegroundColor Yellow

$mailboxes = Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox
$results   = @()

foreach ($mb in $mailboxes) {
    $user = $mb.PrimarySmtpAddress.ToString()

    # Skip the calendar owner — cannot grant permission to yourself
    if ($user -eq $CalendarOwner) {
        Write-Host "  SKIPPED (calendar owner) - $user" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{
            User        = $user
            Status      = "Skipped"
            AccessRight = "N/A"
            Error       = ""
        }
        continue
    }

    Write-Host "Processing $user ..." -ForegroundColor Cyan

    try {
        # Check if permission already exists to decide Add vs Set
        $existing = Get-MailboxFolderPermission -Identity $CalendarIdentity -User $user -ErrorAction SilentlyContinue

        if ($existing) {
            Set-MailboxFolderPermission `
                -Identity     $CalendarIdentity `
                -User         $user `
                -AccessRights Editor `
                -ErrorAction  Stop
            $action = "Updated"
        } else {
            Add-MailboxFolderPermission `
                -Identity     $CalendarIdentity `
                -User         $user `
                -AccessRights Editor `
                -ErrorAction  Stop
            $action = "Added"
        }

        $perm = Get-MailboxFolderPermission -Identity $CalendarIdentity -User $user
        Write-Host "  SUCCESS ($action) - Editor granted" -ForegroundColor Green

        $results += [PSCustomObject]@{
            User        = $user
            Status      = "Success ($action)"
            AccessRight = ($perm.AccessRights -join ",")
            Error       = ""
        }
    }
    catch {
        Write-Host "  FAILED - $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{
            User        = $user
            Status      = "Failed"
            AccessRight = ""
            Error       = $_.Exception.Message
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n==== FINAL RESULTS ====" -ForegroundColor Yellow
$results | Format-Table -AutoSize

$successCount = ($results | Where-Object { $_.Status -like "Success*" }).Count
$failCount    = ($results | Where-Object { $_.Status -eq "Failed" }).Count
$skipCount    = ($results | Where-Object { $_.Status -eq "Skipped" }).Count

Write-Host "Success: $successCount  |  Failed: $failCount  |  Skipped: $skipCount`n" -ForegroundColor Cyan

if ($ExportCsv) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation
    Write-Host "Results exported to: $CsvPath" -ForegroundColor Green
}