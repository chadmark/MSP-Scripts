<#
.SYNOPSIS
    Exports an HTML (or Markdown) documentation file for the "All Staff Mailboxes" DDG
    and its companion transport rule. Intended for paste into a client's Hudu tenant.

.DESCRIPTION
    Pulls the Dynamic Distribution Group configuration, the restricting transport rule,
    and the current resolved recipient list, then writes a formatted documentation file.

    HTML output is designed to paste directly into Hudu's rich-text (TinyMCE) article editor.
    Markdown output is available for source control or other systems that render Markdown.

    Run after New-AllStaffDDG.ps1 has provisioned the group in a client tenant.

.EXAMPLE
    Connect-ExchangeOnline -UserPrincipalName admin@clientdomain.com
    .\Export-AllStaffDDGDocumentation.ps1 -TenantDomain "clientdomain.com"

    Generates AllStaffMailboxes-clientdomain.com.html in the current directory (default).

.EXAMPLE
    .\Export-AllStaffDDGDocumentation.ps1 -TenantDomain "clientdomain.com" -OutputFormat Markdown

    Generates AllStaffMailboxes-clientdomain.com.md instead.

.NOTES
    Author      : Chad
    Last Edit   : 06-12-2025
    GitHub      : MSP-Scripts/ExchangeOnline/Export-AllStaffDDGDocumentation.ps1
    Environment : Exchange Online (PowerShell 5.1 or 7.x)
    Requires    : ExchangeOnlineManagement module; connect before running
    Version     : 2.0

.CHANGELOG
    2.0 - 06-12-2025 - Add HTML output (default) for Hudu paste; keep Markdown via -OutputFormat
    1.1 - 06-12-2025 - Move RecipientFilter to fenced code block; add explanatory note
    1.0 - 06-12-2025 - Initial release

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding()]
param (
    # The tenant's primary domain (e.g. "clientdomain.com").
    [Parameter(Mandatory)]
    [string]$TenantDomain,

    # Group alias. Defaults to "allstaffmailboxes" to match New-AllStaffDDG.ps1.
    [string]$GroupAlias = "allstaffmailboxes",

    # Display name used to locate the matching transport rule.
    [string]$GroupDisplayName = "All Staff Mailboxes",

    # Output directory. Defaults to current directory.
    [string]$OutputPath = (Get-Location).Path,

    # Output format. HTML (default) for Hudu paste; Markdown for source control or other renderers.
    [ValidateSet("HTML","Markdown")]
    [string]$OutputFormat = "HTML"
)

#region --- Pre-flight ---

try {
    $null = Get-OrganizationConfig -ErrorAction Stop
} catch {
    Write-Error "No active Exchange Online session. Run Connect-ExchangeOnline first."
    exit 1
}

$GroupAddress = "$GroupAlias@$TenantDomain"

#endregion

#region --- Gather DDG ---

$ddg = Get-DynamicDistributionGroup -Identity $GroupAddress -ErrorAction SilentlyContinue
if (-not $ddg) {
    Write-Error "DDG '$GroupAddress' not found in this tenant."
    exit 1
}

$members = Get-Recipient -RecipientPreviewFilter $ddg.RecipientFilter -ResultSize Unlimited |
    Sort-Object DisplayName

#endregion

#region --- Gather Transport Rule ---

$rule = Get-TransportRule | Where-Object {
    $_.SentToMemberOf -contains $ddg.DistinguishedName -or
    $_.Name -like "*$GroupDisplayName*"
} | Select-Object -First 1

#endregion

#region --- Helpers ---

# HTML-encode a value safely (handles $null and non-string types).
function ConvertTo-HtmlSafe {
    param($Value)
    if ($null -eq $Value) { return "" }
    return [System.Web.HttpUtility]::HtmlEncode([string]$Value)
}

# Required for HtmlEncode on PowerShell 5.1.
Add-Type -AssemblyName System.Web

$generatedStamp = Get-Date -Format 'MM-dd-yyyy HH:mm'

#endregion

#region --- Build HTML ---

if ($OutputFormat -eq "HTML") {
    $sb = [System.Text.StringBuilder]::new()

    # Inline styles only — Hudu's editor strips <style> blocks and external CSS.
    $cellStyle = 'style="padding:6px 10px;border:1px solid #ccc;"'
    $headStyle = 'style="padding:6px 10px;border:1px solid #ccc;background:#f3f3f3;text-align:left;"'
    $tableStyle = 'style="border-collapse:collapse;width:100%;font-family:Arial,sans-serif;font-size:14px;"'

    [void]$sb.AppendLine("<h1>All Staff Mailboxes - $(ConvertTo-HtmlSafe $TenantDomain)</h1>")
    [void]$sb.AppendLine("<p><em>Documentation generated $generatedStamp by Markley Technologies.</em></p>")

    [void]$sb.AppendLine("<h2>Purpose</h2>")
    [void]$sb.AppendLine("<p>Distribution channel used by Markley Technologies to send security warnings and administrative notifications to all mailbox users at $(ConvertTo-HtmlSafe $TenantDomain). Sender access is restricted to internal users and markleytech.com.</p>")

    # --- DDG table ---
    [void]$sb.AppendLine("<h2>Dynamic Distribution Group</h2>")
    [void]$sb.AppendLine("<table $tableStyle>")
    [void]$sb.AppendLine("  <thead><tr><th $headStyle>Property</th><th $headStyle>Value</th></tr></thead>")
    [void]$sb.AppendLine("  <tbody>")
    $ddgRows = @(
        @{ Property = "Display Name";                  Value = $ddg.DisplayName },
        @{ Property = "Primary SMTP";                  Value = $ddg.PrimarySmtpAddress },
        @{ Property = "Alias";                         Value = $ddg.Alias },
        @{ Property = "Hidden from GAL";               Value = $ddg.HiddenFromAddressListsEnabled },
        @{ Property = "Require Sender Authentication"; Value = $ddg.RequireSenderAuthenticationEnabled },
        @{ Property = "Recipient Container";           Value = $ddg.RecipientContainer }
    )
    foreach ($r in $ddgRows) {
        [void]$sb.AppendLine("    <tr><td $cellStyle>$(ConvertTo-HtmlSafe $r.Property)</td><td $cellStyle>$(ConvertTo-HtmlSafe $r.Value)</td></tr>")
    }
    [void]$sb.AppendLine("  </tbody>")
    [void]$sb.AppendLine("</table>")

    # --- Recipient Filter (separate block, monospace) ---
    [void]$sb.AppendLine("<p><strong>Recipient Filter:</strong></p>")
    [void]$sb.AppendLine("<pre style=`"background:#f5f5f5;padding:10px;border:1px solid #ddd;white-space:pre-wrap;word-break:break-all;font-family:Consolas,monospace;font-size:12px;`">$(ConvertTo-HtmlSafe $ddg.RecipientFilter)</pre>")
    [void]$sb.AppendLine("<p><em>Note: Exchange Online automatically appends system mailbox exclusions to the filter. The intent is simply: all UserMailbox recipients.</em></p>")

    # --- Transport Rule ---
    [void]$sb.AppendLine("<h2>Transport Rule (Sender Restriction)</h2>")
    if ($rule) {
        [void]$sb.AppendLine("<table $tableStyle>")
        [void]$sb.AppendLine("  <thead><tr><th $headStyle>Property</th><th $headStyle>Value</th></tr></thead>")
        [void]$sb.AppendLine("  <tbody>")
        $ruleRows = @(
            @{ Property = "Name";                     Value = $rule.Name },
            @{ Property = "State";                    Value = $rule.State },
            @{ Property = "Mode";                     Value = $rule.Mode },
            @{ Property = "Priority";                 Value = $rule.Priority },
            @{ Property = "Sent To Member Of";        Value = ($rule.SentToMemberOf -join ', ') },
            @{ Property = "Except If From Scope";     Value = $rule.ExceptIfFromScope },
            @{ Property = "Except If Sender Domain";  Value = ($rule.ExceptIfSenderDomainIs -join ', ') },
            @{ Property = "Reject Reason";            Value = $rule.RejectMessageReasonText },
            @{ Property = "Enhanced Status Code";     Value = $rule.RejectMessageEnhancedStatusCode },
            @{ Property = "Comments";                 Value = $rule.Comments }
        )
        foreach ($r in $ruleRows) {
            [void]$sb.AppendLine("    <tr><td $cellStyle>$(ConvertTo-HtmlSafe $r.Property)</td><td $cellStyle>$(ConvertTo-HtmlSafe $r.Value)</td></tr>")
        }
        [void]$sb.AppendLine("  </tbody>")
        [void]$sb.AppendLine("</table>")
    } else {
        [void]$sb.AppendLine("<blockquote><strong>Warning:</strong> No matching transport rule found. Sender restriction may not be in effect.</blockquote>")
    }

    # --- Members ---
    [void]$sb.AppendLine("<h2>Current Resolved Members ($($members.Count))</h2>")
    [void]$sb.AppendLine("<p><em>Membership is dynamic and re-evaluated at send time. Snapshot below reflects the directory at generation time.</em></p>")
    [void]$sb.AppendLine("<table $tableStyle>")
    [void]$sb.AppendLine("  <thead><tr><th $headStyle>Display Name</th><th $headStyle>Primary SMTP</th><th $headStyle>Type</th></tr></thead>")
    [void]$sb.AppendLine("  <tbody>")
    foreach ($m in $members) {
        [void]$sb.AppendLine("    <tr><td $cellStyle>$(ConvertTo-HtmlSafe $m.DisplayName)</td><td $cellStyle>$(ConvertTo-HtmlSafe $m.PrimarySmtpAddress)</td><td $cellStyle>$(ConvertTo-HtmlSafe $m.RecipientTypeDetails)</td></tr>")
    }
    [void]$sb.AppendLine("  </tbody>")
    [void]$sb.AppendLine("</table>")

    [void]$sb.AppendLine("<hr/>")
    [void]$sb.AppendLine("<p><em>Markley Technologies</em></p>")

    $output    = $sb.ToString()
    $extension = "html"
}

#endregion

#region --- Build Markdown ---

if ($OutputFormat -eq "Markdown") {
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("# All Staff Mailboxes - $TenantDomain")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("_Documentation generated $generatedStamp by Markley Technologies._")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Purpose")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Distribution channel used by Markley Technologies to send security warnings and")
    [void]$sb.AppendLine("administrative notifications to all mailbox users at $TenantDomain. Sender access")
    [void]$sb.AppendLine("is restricted to internal users and markleytech.com.")
    [void]$sb.AppendLine("")

    [void]$sb.AppendLine("## Dynamic Distribution Group")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Property | Value |")
    [void]$sb.AppendLine("|---|---|")
    [void]$sb.AppendLine("| Display Name | $($ddg.DisplayName) |")
    [void]$sb.AppendLine("| Primary SMTP | $($ddg.PrimarySmtpAddress) |")
    [void]$sb.AppendLine("| Alias | $($ddg.Alias) |")
    [void]$sb.AppendLine("| Hidden from GAL | $($ddg.HiddenFromAddressListsEnabled) |")
    [void]$sb.AppendLine("| Require Sender Authentication | $($ddg.RequireSenderAuthenticationEnabled) |")
    [void]$sb.AppendLine("| Recipient Container | $($ddg.RecipientContainer) |")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Recipient Filter:**")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine($ddg.RecipientFilter)
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("_Note: Exchange Online automatically appends system mailbox exclusions to the filter. The intent is simply: all UserMailbox recipients._")
    [void]$sb.AppendLine("")

    [void]$sb.AppendLine("## Transport Rule (Sender Restriction)")
    [void]$sb.AppendLine("")
    if ($rule) {
        [void]$sb.AppendLine("| Property | Value |")
        [void]$sb.AppendLine("|---|---|")
        [void]$sb.AppendLine("| Name | $($rule.Name) |")
        [void]$sb.AppendLine("| State | $($rule.State) |")
        [void]$sb.AppendLine("| Mode | $($rule.Mode) |")
        [void]$sb.AppendLine("| Priority | $($rule.Priority) |")
        [void]$sb.AppendLine("| Sent To Member Of | $($rule.SentToMemberOf -join ', ') |")
        [void]$sb.AppendLine("| Except If From Scope | $($rule.ExceptIfFromScope) |")
        [void]$sb.AppendLine("| Except If Sender Domain | $($rule.ExceptIfSenderDomainIs -join ', ') |")
        [void]$sb.AppendLine("| Reject Reason | $($rule.RejectMessageReasonText) |")
        [void]$sb.AppendLine("| Enhanced Status Code | $($rule.RejectMessageEnhancedStatusCode) |")
        [void]$sb.AppendLine("| Comments | $($rule.Comments) |")
    } else {
        [void]$sb.AppendLine("> Warning: No matching transport rule found. Sender restriction may not be in effect.")
    }
    [void]$sb.AppendLine("")

    [void]$sb.AppendLine("## Current Resolved Members ($($members.Count))")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("_Membership is dynamic and re-evaluated at send time. Snapshot below reflects the directory at generation time._")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Display Name | Primary SMTP | Type |")
    [void]$sb.AppendLine("|---|---|---|")
    foreach ($m in $members) {
        [void]$sb.AppendLine("| $($m.DisplayName) | $($m.PrimarySmtpAddress) | $($m.RecipientTypeDetails) |")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("_Markley Technologies_")

    $output    = $sb.ToString()
    $extension = "md"
}

#endregion

#region --- Write File ---

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$fileName = "AllStaffMailboxes-$TenantDomain.$extension"
$fullPath = Join-Path $OutputPath $fileName
$output | Out-File -FilePath $fullPath -Encoding UTF8

Write-Host "Documentation written to: $fullPath" -ForegroundColor Green
Write-Host "Format                  : $OutputFormat" -ForegroundColor Cyan
Write-Host "Members documented      : $($members.Count)" -ForegroundColor Cyan

#endregion
