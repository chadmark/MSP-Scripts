<!--
  Title       : M365 External Email Forwarding with Third-Party Outbound Mail Service
  Author      : Chad
  Last Edit   : 04-06-2026
  GitHub      : https://github.com/chadmark/MSP-Scripts/blob/main/Microsoft365/M365_External_Forwarding_3rdParty_relay.md
  Environment : Microsoft 365 / Exchange Online
  Requires    : Exchange Online PowerShell Module
  Version     : 1.0
  Link        : https://github.com/chadmark/MSP-Scripts
-->

# M365 External Email Forwarding with Third-Party Outbound Mail Service

## Overview

This guide covers how to forward a former employee's mailbox to an external address when the organization uses a third-party outbound mail service (e.g., Sophos Email) that intercepts all outbound traffic. The same approach applies to similar services such as Proofpoint or Mimecast.

**Example scenario used in this guide:**
- **Tenant domain:** `contoso.com`
- **Former employee mailbox:** `jsmith@contoso.com`
- **Forwarding destination:** `support@msp-domain.com`

---

## Problem Summary

Mail sent to former employee `jsmith@contoso.com` was failing to forward to an external address. When a third-party outbound mail service — in this case Sophos — is configured to intercept all outbound traffic, auto-forwarded messages are caught and rejected as unauthorized relay attempts (`550 5.7.1 Command rejected`), because the message originated externally and is being delivered to another external address.

Additionally, Microsoft's default outbound spam filter policy blocks external auto-forwarding unless explicitly allowed.

---

## Root Cause

1. **Sophos outbound connector** was catching all outbound mail globally, including forwarded messages
2. **Outbound spam filter policy** had `AutoForwardingMode: Automatic` (blocks external forwarding by default)
3. A previously created transport rule ("jsmith forward", Priority 5) and spam filter policy ("jsmith Forward") existed but were both **disabled** and **misconfigured**

---

## Resolution Steps

### Step 1 — Set Mailbox Forwarding

Set the forwarding address directly on the mailbox:

```powershell
Set-Mailbox -Identity "jsmith@contoso.com" `
  -ForwardingSmtpAddress "support@msp-domain.com" `
  -DeliverToMailboxAndForward $false
```

**Verify:**
```powershell
Get-Mailbox -Identity "jsmith@contoso.com" | Format-List ForwardingSmtpAddress, DeliverToMailboxAndForward
```

Expected output:
```
ForwardingSmtpAddress     : smtp:support@msp-domain.com
DeliverToMailboxAndForward: False
```

---

### Step 2 — Enable and Scope the Outbound Spam Filter Policy

An existing policy "jsmith Forward" was found with `AutoForwardingMode: On` but its rule was disabled and unscoped. Fix both:

```powershell
Set-HostedOutboundSpamFilterRule -Identity "jsmith Forward" `
  -From "jsmith@contoso.com"

Enable-HostedOutboundSpamFilterRule -Identity "jsmith Forward"
```

**Verify:**
```powershell
Get-HostedOutboundSpamFilterRule | Where-Object {$_.HostedOutboundSpamFilterPolicy -eq "jsmith Forward"} | Format-List Name, From, Priority, State
```

Expected output:
```
Name    : jsmith Forward
From    : {jsmith@contoso.com}
Priority: 1
State   : Enabled
```

---

### Step 3 — Scope the Sophos Outbound Connector to Transport Rule

The Sophos connector was globally scoped (`RecipientDomains: {*}`), intercepting all outbound mail including forwarded messages. Changed it to transport rule scoped so only explicitly routed mail goes through Sophos:

```powershell
Set-OutboundConnector -Identity "Sophos Outbound Connector" `
  -IsTransportRuleScoped $true `
  -RecipientDomains $null
```

> ⚠️ **Warning:** This immediately stops all outbound Sophos routing until the transport rule in Step 4 is created. Run Steps 3 and 4 back to back.

**Verify:**
```powershell
Get-OutboundConnector -Identity "Sophos Outbound Connector" | Format-List Name, IsTransportRuleScoped, RecipientDomains
```

Expected output:
```
Name                  : Sophos Outbound Connector
IsTransportRuleScoped : True
RecipientDomains      : {}
```

---

### Step 4 — Create Transport Rule to Route Outbound via Sophos (with Exception)

Created a new transport rule that routes all outbound mail through Sophos, except mail destined for `support@msp-domain.com` (the forwarding destination):

```powershell
New-TransportRule -Name "Route Outbound via Sophos" `
  -SentToScope NotInOrganization `
  -ExceptIfRecipientAddressMatchesPatterns "support@msp-domain.com" `
  -RouteMessageOutboundConnector "Sophos Outbound Connector" `
  -Mode Enforce `
  -Priority 0
```

> **Note for production:** Replace `support@msp-domain.com` with the real destination address or use `-ExceptIfRecipientDomainIs` to except an entire domain.

---

## Verification — Message Trace

To confirm mail flow is working, use:

```powershell
Get-MessageTraceV2 -RecipientAddress "jsmith@contoso.com" `
  -StartDate (Get-Date).AddHours(-1) `
  -EndDate (Get-Date) | Format-List Received, SenderAddress, RecipientAddress, Status
```

For detailed trace on a specific message:

```powershell
Get-MessageTraceDetailV2 -MessageTraceId "<MessageTraceId>" `
  -RecipientAddress "jsmith@contoso.com" | Format-List Date, Event, Action, Detail
```

> **Note:** `Get-MessageTrace` is deprecated as of September 1, 2025. Use `Get-MessageTraceV2` and `Get-MessageTraceDetailV2` going forward.

---

## Full Configuration Verification Checklist

Run all of the following commands after completing the setup to confirm every component is configured correctly.

### 1 — Mailbox Forwarding

```powershell
Get-Mailbox -Identity "jsmith@contoso.com" | Format-List ForwardingSmtpAddress, DeliverToMailboxAndForward
```

| Field | Expected Value |
|-------|---------------|
| `ForwardingSmtpAddress` | `smtp:support@msp-domain.com` |
| `DeliverToMailboxAndForward` | `False` |

---

### 2 — Outbound Spam Filter Policy

```powershell
Get-HostedOutboundSpamFilterPolicy -Identity "jsmith Forward" | Format-List Name, AutoForwardingMode
```

| Field | Expected Value |
|-------|---------------|
| `Name` | `jsmith Forward` |
| `AutoForwardingMode` | `On` |

---

### 3 — Outbound Spam Filter Rule

```powershell
Get-HostedOutboundSpamFilterRule | Where-Object {$_.HostedOutboundSpamFilterPolicy -eq "jsmith Forward"} | Format-List Name, From, Priority, State
```

| Field | Expected Value |
|-------|---------------|
| `From` | `{jsmith@contoso.com}` |
| `Priority` | `1` |
| `State` | `Enabled` |

---

### 4 — Sophos Outbound Connector

```powershell
Get-OutboundConnector -Identity "Sophos Outbound Connector" | Format-List Name, IsTransportRuleScoped, RecipientDomains, Enabled
```

| Field | Expected Value |
|-------|---------------|
| `IsTransportRuleScoped` | `True` |
| `RecipientDomains` | `{}` |
| `Enabled` | `True` |

---

### 5 — Sophos Transport Rule

```powershell
Get-TransportRule -Identity "Route Outbound via Sophos" | Format-List Name, Priority, State, RouteMessageOutboundConnector, ExceptIfRecipientAddressMatchesPatterns
```

| Field | Expected Value |
|-------|---------------|
| `Priority` | `0` |
| `State` | `Enabled` |
| `RouteMessageOutboundConnector` | `Sophos Outbound Connector` |
| `ExceptIfRecipientAddressMatchesPatterns` | `{support@msp-domain.com}` |

---

### 6 — End-to-End Mail Flow Test

Send a test email to `jsmith@contoso.com` from an external address, then run a message trace to confirm delivery:

```powershell
Get-MessageTraceV2 -RecipientAddress "jsmith@contoso.com" `
  -StartDate (Get-Date).AddMinutes(-30) `
  -EndDate (Get-Date) | Format-List Received, SenderAddress, RecipientAddress, Status
```

| Field | Expected Value |
|-------|---------------|
| `Status` | `Delivered` |

If status shows `Failed`, run the detail trace to identify the failure point:

```powershell
Get-MessageTraceDetailV2 -MessageTraceId "<MessageTraceId from above>" `
  -RecipientAddress "jsmith@contoso.com" | Format-List Date, Event, Action, Detail
```

Look for a `Redirect` event pointing to `support@msp-domain.com` followed by a `Deliver` event — that confirms the full forwarding chain is working correctly.

---

## To Disable Forwarding

If forwarding needs to be removed in the future:

```powershell
Set-Mailbox -Identity "jsmith@contoso.com" `
  -ForwardingSmtpAddress $null
```

---

## Future Considerations

- **License:** The mailbox is still a standard UserMailbox consuming a license. If the user is fully offboarded, consider converting to a shared mailbox to free the license while retaining the forwarding capability.
- **Additional former employees:** For each additional forwarding address added, update the transport rule exception or switch to a domain-based exception (`-ExceptIfRecipientDomainIs`) if all forwarding destinations share a common domain.
- **Sophos connector validation:** The connector shows `IsValidated: False` as of the date of this change. Consider validating it in the Exchange Admin Center under Mail flow → Connectors.
