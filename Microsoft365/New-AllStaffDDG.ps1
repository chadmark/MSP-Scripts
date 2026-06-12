<#
.SYNOPSIS
    Creates an "All Staff Mailboxes" Dynamic Distribution Group in an Exchange Online tenant
    and restricts senders to internal users and markleytech.com only.

.DESCRIPTION
    Creates a DDG named "All Staff Mailboxes" with alias "allstaffmailboxes" that auto-includes
    all UserMailbox recipients. A mail flow (transport) rule is created to reject inbound mail
    to the group from any sender outside the tenant or markleytech.com.

    Run once per client tenant. Requires an active Exchange Online session with sufficient
    permissions (Exchange Admin or higher).

.EXAMPLE
    Connect-ExchangeOnline -UserPrincipalName admin@clientdomain.com
    .\New-AllStaffDDG.ps1 -TenantDomain "clientdomain.com"

    Creates the DDG and transport rule in the specified tenant.

.EXAMPLE
    .\New-AllStaffDDG.ps1 -TenantDomain "clientdomain.com" -PreviewMembers

    Previews the recipients the DDG's filter currently resolves to. Makes no changes.

.NOTES
    Author      : Chad
    Last Edit   : 06-12-2025
    GitHub      : MSP-Scripts/ExchangeOnline/New-AllStaffDDG.ps1
    Environment : Exchange Online (PowerShell 5.1 or 7.x)
    Requires    : ExchangeOnlineManagement module; connect before running
    Version     : 1.6

.CHANGELOG
    1.6 - 06-12-2025 - Fix transport rule predicate (SentTo -> SentToMemberOf) for group recipients
    1.5 - 06-12-2025 - Add .EXAMPLE usage syntax to header
    1.4 - 06-12-2025 - Add -PreviewMembers switch to list resolved DDG recipients
    1.3 - 06-12-2025 - Hide DDG from address lists (HiddenFromAddressListsEnabled)
    1.2 - 06-12-2025 - Wrap DDG and transport rule creation in try/catch with -ErrorAction Stop
    1.1 - 06-12-2025 - Fix RequireSenderAuthenticationEnabled - move to Set- post-creation
    1.0 - 06-12-2025 - Initial release

.LINK
    https://github.com/chadmark/MSP-Scripts
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    # The tenant's primary domain (e.g. "clientdomain.com"). Used to build the group address.
    [Parameter(Mandatory)]
    [string]$TenantDomain,

    # Display name for the group. Defaults to "All Staff Mailboxes".
    [string]$GroupDisplayName = "All Staff Mailboxes",

    # Alias for the group. Defaults to "allstaffmailboxes".
    [string]$GroupAlias = "allstaffmailboxes",

    # Your MSP domain to whitelist as an external sender.
    [string]$MSPDomain = "markleytech.com",

    # When set, skips creation/changes and just lists the recipients the DDG's filter currently resolves to.
    [switch]$PreviewMembers
)

#region --- Pre-flight ---

# Verify we have an active EXO session
try {
    $null = Get-OrganizationConfig -ErrorAction Stop
} catch {
    Write-Error "No active Exchange Online session. Run Connect-ExchangeOnline first."
    exit 1
}

$GroupAddress = "$GroupAlias@$TenantDomain"

#endregion

#region --- Preview Mode ---
# Short-circuits creation logic. Resolves the DDG's RecipientFilter against the directory
# the same way Exchange does at send time, so this is the authoritative "who would get this mail" view.

if ($PreviewMembers) {
    $ddg = Get-DynamicDistributionGroup -Identity $GroupAddress -ErrorAction SilentlyContinue
    if (-not $ddg) {
        Write-Error "DDG '$GroupAddress' not found in this tenant."
        exit 1
    }

    Write-Host "Resolving members for: $GroupAddress" -ForegroundColor Cyan
    Write-Host "Filter: $($ddg.RecipientFilter)" -ForegroundColor DarkGray
    Write-Host ""

    $members = Get-Recipient -RecipientPreviewFilter $ddg.RecipientFilter -ResultSize Unlimited |
        Sort-Object DisplayName

    $members | Select-Object DisplayName, PrimarySmtpAddress, RecipientTypeDetails | Format-Table -AutoSize

    Write-Host "Total recipients: $($members.Count)" -ForegroundColor Green
    exit 0
}

#endregion

#region --- Create Dynamic Distribution Group ---

$ExistingDDG = Get-DynamicDistributionGroup -Identity $GroupAddress -ErrorAction SilentlyContinue

if ($ExistingDDG) {
    Write-Warning "DDG '$GroupAddress' already exists. Skipping creation."
} else {
    Write-Host "Creating Dynamic Distribution Group: $GroupAddress" -ForegroundColor Cyan

    if ($PSCmdlet.ShouldProcess($GroupAddress, "Create Dynamic Distribution Group")) {
        try {
            New-DynamicDistributionGroup `
                -Name               $GroupDisplayName `
                -Alias              $GroupAlias `
                -PrimarySmtpAddress $GroupAddress `
                -RecipientFilter    "(RecipientTypeDetails -eq 'UserMailbox')" `
                -ErrorAction        Stop | Out-Null

            # RequireSenderAuthenticationEnabled is not supported on New-DynamicDistributionGroup;
            # must be set post-creation via Set-DynamicDistributionGroup.
            # HiddenFromAddressListsEnabled also set here to keep the group out of the GAL.
            Set-DynamicDistributionGroup `
                -Identity                           $GroupAddress `
                -RequireSenderAuthenticationEnabled $false `
                -HiddenFromAddressListsEnabled      $true `
                -ErrorAction                        Stop

            Write-Host "DDG created successfully." -ForegroundColor Green
        } catch {
            Write-Error "Failed to create DDG '$GroupAddress': $_"
            exit 1
        }
    }
}

#endregion

#region --- Mail Flow Rule (Transport Rule) ---
# Exchange Online DDGs cannot natively filter by sender domain — they only support
# object-based sender restrictions. A transport rule is the correct mechanism for
# domain-level allow/deny on a specific recipient.
#
# Logic: If mail is TO this group AND the sender is NOT authenticated (internal)
# AND the sender domain is NOT markleytech.com → reject with a clear NDR message.

$RuleName = "Restrict $GroupDisplayName - MSP and Internal Only"
$ExistingRule = Get-TransportRule -Identity $RuleName -ErrorAction SilentlyContinue

if ($ExistingRule) {
    Write-Warning "Transport rule '$RuleName' already exists. Skipping creation."
} else {
    Write-Host "Creating transport rule: $RuleName" -ForegroundColor Cyan

    if ($PSCmdlet.ShouldProcess($RuleName, "Create Transport Rule")) {
        try {
            New-TransportRule `
                -Name                              $RuleName `
                -SentToMemberOf                    $GroupAddress `
                -ExceptIfFromScope                 "InOrganization" `
                -ExceptIfSenderDomainIs            $MSPDomain `
                -RejectMessageReasonText           "You are not authorized to send messages to this distribution group." `
                -RejectMessageEnhancedStatusCode   "5.7.1" `
                -StopRuleProcessing                $true `
                -Comments                          "Created by Markley Technologies. Allows internal senders and $MSPDomain only." `
                -ErrorAction                       Stop | Out-Null

            Write-Host "Transport rule created successfully." -ForegroundColor Green
        } catch {
            Write-Error "Failed to create transport rule '$RuleName': $_"
            exit 1
        }
    }
}

#endregion

#region --- Summary ---

Write-Host ""
Write-Host "=== Deployment Summary ===" -ForegroundColor Yellow
Write-Host "Group Address : $GroupAddress"
Write-Host "Membership    : All UserMailbox recipients (dynamic — auto-updates)"
Write-Host "Visibility    : Hidden from address lists (GAL)"
Write-Host "Allowed Senders:"
Write-Host "  - All internal/authenticated users in $TenantDomain"
Write-Host "  - External senders from $MSPDomain"
Write-Host "Blocked       : All other external senders (via transport rule)"
Write-Host ""
Write-Host "NOTE: Dynamic membership can take up to 2 hours to fully populate on first creation." -ForegroundColor DarkYellow

#endregion
