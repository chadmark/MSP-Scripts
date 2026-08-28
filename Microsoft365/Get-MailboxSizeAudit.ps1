<#
.SYNOPSIS
    Audits an Exchange Online mailbox's size to identify the largest folders,
    checks Recoverable Items bloat, and reports Online Archive status.

.DESCRIPTION
    Reports overall primary mailbox size vs. send/receive quotas, breaks
    down every primary mailbox folder by size (largest first), and checks
    Recoverable Items separately (its own quota, not counted against
    primary mailbox size).

    If an Online Archive is enabled, also reports archive size vs. the
    1.5 TB auto-expanding cap, whether auto-expanding archiving is turned
    on, and a largest-folders breakdown of the archive itself.

    Use this as the first diagnostic step any time a user reports a full
    mailbox or is near/at their send quota. It answers three questions:
      1. Is the primary mailbox actually full, or is it Recoverable Items?
      2. Which folder(s) are driving the size?
      3. Is an Online Archive in place and actually absorbing old mail,
         or is retention misconfigured/not catching this mailbox?

    HOW TO RUN:
      1. Dot-source an authenticated EXO session first - this script does
         not connect on its own:
           . C:\scripts\Connect-Client.ps1
      2. Run against the affected mailbox:
           .\Get-MailboxSizeAudit.ps1 -Identity user@domain.com
      3. Read the console output top to bottom - Overview, then
         Recoverable Items, then Archive (if present), then primary
         mailbox folders.
      4. If a folder is the clear offender, follow up with a targeted
         compliance search (New-ComplianceSearch) scoped to that mailbox
         with a size filter (e.g. size>26214400 for 25MB+) to find the
         individual large items driving it.
      5. If the Online Archive section shows AutoExpandingArchive: False,
         that's very likely your root cause for archive fullness - enable
         with: Enable-Mailbox -Identity user@domain.com -AutoExpandingArchive
      6. If mail isn't reaching the archive at all despite a retention
         policy being assigned, check the policy's tags and age limits
         (Get-Mailbox user@domain.com | Select RetentionPolicy) - an age
         limit longer than the mailbox's actual mail history means nothing
         has qualified to move yet.

    Does not modify anything - read-only reporting.

.PARAMETER Identity
    UPN or email address of the mailbox to audit.

.PARAMETER TopFolders
    Number of largest folders to display, for both primary and archive
    breakdowns. Default 25.

.PARAMETER ExportPath
    Optional path to export the full primary mailbox folder breakdown as
    CSV (all folders, not just the Top N shown on screen).

.EXAMPLE
    .\Get-MailboxSizeAudit.ps1 -Identity user@domain.com

.EXAMPLE
    .\Get-MailboxSizeAudit.ps1 -Identity user@domain.com -ExportPath C:\temp\user-mailbox-audit.csv

.NOTES
    Author      : Chad
    Last Edit   : 08-28-2026
    GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Microsoft365/Get-MailboxSizeAudit.ps1
    Environment : Exchange Online (EXO V3 module)
    Requires    : ExchangeOnlineManagement module; active session via Connect-Client.ps1
    Version     : 1.0

.CHANGELOG
    1.0 - 08-28-2026 - Initial version. Validated against a live client
                       mailbox that surfaced an untouched 4-year retention
                       tag as the root cause of primary mailbox fullness.

.LINK
    https://github.com/chadmark/MSP-Scripts/tree/main/Microsoft365
#>

param(
    [Parameter(Mandatory)]
    [string]$Identity,

    [int]$TopFolders = 25,

    [string]$ExportPath
)

function Convert-EWSSizeToBytes {
    param([string]$SizeString)
    # EXO returns strings like "1.2 GB (1,234,567 bytes)"
    if ($SizeString -match '\(([\d,]+)\s*bytes\)') {
        return [int64]($matches[1] -replace ',', '')
    }
    return 0
}

Write-Host "`n=== Mailbox Overview: $Identity ===" -ForegroundColor Cyan
try {
    $stats = Get-MailboxStatistics -Identity $Identity
    $mbx   = Get-Mailbox -Identity $Identity

    [PSCustomObject]@{
        DisplayName           = $mbx.DisplayName
        TotalItemSize         = $stats.TotalItemSize
        ItemCount             = $stats.ItemCount
        ProhibitSendQuota     = $mbx.ProhibitSendQuota
        ProhibitSendRecvQuota = $mbx.ProhibitSendReceiveQuota
        ArchiveStatus         = $mbx.ArchiveStatus
        AutoExpandingArchive  = $mbx.AutoExpandingArchiveEnabled
        LitigationHold        = $mbx.LitigationHoldEnabled
        InPlaceHolds          = if ($mbx.InPlaceHolds) { $mbx.InPlaceHolds -join '; ' } else { 'None' }
    } | Format-List
}
catch {
    Write-Host "Failed to pull mailbox stats: $_" -ForegroundColor Red
    return
}

Write-Host "=== Recoverable Items (separate quota - dumpster/hold storage) ===" -ForegroundColor Cyan
try {
    $recoverable = Get-MailboxFolderStatistics -Identity $Identity -FolderScope RecoverableItems -IncludeOldestAndNewestItems
    $recoverable | ForEach-Object {
        [PSCustomObject]@{
            Folder    = $_.FolderPath
            ItemCount = $_.ItemsInFolder
            SizeBytes = Convert-EWSSizeToBytes $_.FolderSize
            SizeHR    = $_.FolderSize
        }
    } | Sort-Object SizeBytes -Descending | Format-Table -AutoSize
}
catch {
    Write-Host "Could not pull Recoverable Items stats: $_" -ForegroundColor Yellow
}

if ($mbx.ArchiveStatus -ne 'None') {
    Write-Host "`n=== Online Archive: Quota & Usage ===" -ForegroundColor Cyan
    try {
        $archiveStats = Get-MailboxStatistics -Identity $Identity -Archive

        [PSCustomObject]@{
            ArchiveTotalItemSize = $archiveStats.TotalItemSize
            ArchiveItemCount     = $archiveStats.ItemCount
            ArchiveQuota         = $mbx.ArchiveQuota
            ArchiveWarningQuota  = $mbx.ArchiveWarningQuota
            AutoExpandingArchive = $mbx.AutoExpandingArchiveEnabled
        } | Format-List

        if (-not $mbx.AutoExpandingArchiveEnabled) {
            Write-Host "AutoExpandingArchive is DISABLED. This is the likely cause of the archive filling up." -ForegroundColor Yellow
            Write-Host "Fix: Enable-Mailbox -Identity $Identity -AutoExpandingArchive" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Could not pull archive mailbox stats: $_" -ForegroundColor Yellow
    }

    Write-Host "`n=== Top $TopFolders Archive Folders by Size ===" -ForegroundColor Cyan
    try {
        $archiveFolderStats = Get-MailboxFolderStatistics -Identity $Identity -Archive -IncludeOldestAndNewestItems -FolderScope All

        $archiveFolderStats | ForEach-Object {
            [PSCustomObject]@{
                FolderPath      = $_.FolderPath
                ItemsInFolder   = $_.ItemsInFolder
                FolderSizeBytes = Convert-EWSSizeToBytes $_.FolderSize
                FolderSizeHR    = $_.FolderSize
                OldestItemDate  = $_.OldestItemReceivedDate
                NewestItemDate  = $_.NewestItemReceivedDate
            }
        } | Sort-Object FolderSizeBytes -Descending | Select-Object -First $TopFolders |
            Format-Table FolderPath, ItemsInFolder, FolderSizeHR, OldestItemDate, NewestItemDate -AutoSize
    }
    catch {
        Write-Host "Failed to pull archive folder statistics: $_" -ForegroundColor Red
    }
}
else {
    Write-Host "`nNo Online Archive is enabled for this mailbox." -ForegroundColor Yellow
}

Write-Host "`n=== Top $TopFolders Primary Mailbox Folders by Size ===" -ForegroundColor Cyan
try {
    $folderStats = Get-MailboxFolderStatistics -Identity $Identity -IncludeOldestAndNewestItems -FolderScope All

    $parsed = $folderStats | ForEach-Object {
        [PSCustomObject]@{
            FolderPath        = $_.FolderPath
            ItemsInFolder     = $_.ItemsInFolder
            FolderSizeBytes   = Convert-EWSSizeToBytes $_.FolderSize
            FolderSizeHR      = $_.FolderSize
            OldestItemDate    = $_.OldestItemReceivedDate
            NewestItemDate    = $_.NewestItemReceivedDate
        }
    } | Sort-Object FolderSizeBytes -Descending

    $parsed | Select-Object -First $TopFolders | Format-Table FolderPath, ItemsInFolder, FolderSizeHR, OldestItemDate, NewestItemDate -AutoSize

    if ($ExportPath) {
        $parsed | Export-Csv -Path $ExportPath -NoTypeInformation
        Write-Host "Full folder breakdown exported to $ExportPath" -ForegroundColor Green
    }
}
catch {
    Write-Host "Failed to pull folder statistics: $_" -ForegroundColor Red
}

Write-Host "`nNext step: for the top offending folder(s), run a targeted compliance search" -ForegroundColor Cyan
Write-Host "(e.g. New-ComplianceSearch) scoped to this mailbox with a size filter like" -ForegroundColor Cyan
Write-Host "'size>26214400' (25MB) to pinpoint individual large items for cleanup." -ForegroundColor Cyan
