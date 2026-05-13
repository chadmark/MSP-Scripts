<!--
Title:       Disable M365 Quarantine Notifications (Avanan Environments)
Author:      Markley Technologies
Last Edit:   05-13-2026
GitHub:      https://github.com/chadmark/MSP-Scripts/Guides/disable-m365-quarantine-notifications-avanan.md
Environment: Exchange Online PowerShell
Requires:    Exchange Online PowerShell module; Global Admin or Exchange Admin
Version:     1.0
-->

**Title:** Disable M365 Quarantine Notifications (Avanan Environments)
**Prepared By:** Markley Technologies
**Last Updated:** 05-13-2026
**Applies To:** Microsoft 365 tenants using Avanan (Checkpoint Harmony Email) for email security

---

# Disable M365 Quarantine Notifications (Avanan Environments)

## Overview

When Avanan is deployed, it handles quarantine notifications via its own digest emails and end-user portal. Microsoft 365 may independently send its own quarantine notification emails, resulting in duplicate or conflicting messages that confuse end users. This guide walks through auditing the current quarantine policy assignments, identifying which policies are sending notifications, and correcting them.

---

## Table of Contents

1. [Background](#background)
2. [Prerequisites](#prerequisites)
3. [Step 1 — Audit Current Quarantine Policy Assignments](#step-1--audit-current-quarantine-policy-assignments)
4. [Step 2 — Identify the Problem](#step-2--identify-the-problem)
5. [Step 3 — Make the Change](#step-3--make-the-change)
6. [Step 4 — Verify](#step-4--verify)
7. [Notes](#notes)

---

## Background

M365 quarantine notifications are controlled by **Quarantine Policies** assigned to each spam verdict in the anti-spam policy. Three built-in policies are relevant:

| Policy Name | End-User Notifications | End-User Self-Release |
|---|---|---|
| `AdminOnlyAccessPolicy` | Off | No |
| `DefaultFullAccessPolicy` | Off | Yes |
| `DefaultFullAccessWithNotificationPolicy` | **On** | Yes |

Any verdict assigned `DefaultFullAccessWithNotificationPolicy` (or a custom policy with `EsnEnabled = $true`) will send quarantine digest emails to end users. In Avanan environments, this is handled by Avanan — the M365 notifications should be disabled.

---

## Step 1 — Audit Current Quarantine Policy Assignments

Connect to Exchange Online PowerShell, then run:

```powershell
Get-HostedContentFilterPolicy | Select-Object Name, *QuarantineTag*
```

**Expected output columns:**

- `SpamQuarantineTag`
- `HighConfidenceSpamQuarantineTag`
- `PhishQuarantineTag`
- `HighConfidencePhishQuarantineTag`
- `BulkQuarantineTag`

---

## Step 2 — Identify the Problem

Look for any verdict assigned one of the following notification-enabled policies:

- `DefaultFullAccessWithNotificationPolicy`
- Any custom policy name you don't recognize (may have `EsnEnabled = $true`)

The most common offender in environments using Preset Security Policies is `SpamQuarantineTag`. Example output showing the problem:

```
Name                             : Default
SpamQuarantineTag                : NotificationEnabledPolicy    ← sends notifications
HighConfidenceSpamQuarantineTag  : DefaultFullAccessPolicy
PhishQuarantineTag               : DefaultFullAccessPolicy
HighConfidencePhishQuarantineTag : AdminOnlyAccessPolicy
BulkQuarantineTag                : DefaultFullAccessPolicy
```

---

## Step 3 — Make the Change

For each verdict that has notifications enabled, update it to `DefaultFullAccessPolicy` (notifications off, self-release still allowed) or `AdminOnlyAccessPolicy` (notifications off, admin-only release).

**Recommended for Avanan environments — use `DefaultFullAccessPolicy`:**

```powershell
Set-HostedContentFilterPolicy -Identity Default -SpamQuarantineTag DefaultFullAccessPolicy
```

If additional verdicts are also sending notifications, update them in the same command:

```powershell
Set-HostedContentFilterPolicy -Identity Default `
    -SpamQuarantineTag DefaultFullAccessPolicy `
    -HighConfidenceSpamQuarantineTag DefaultFullAccessPolicy `
    -BulkQuarantineTag DefaultFullAccessPolicy
```

> **Note:** If the tenant uses a named custom anti-spam policy instead of `Default`, replace `-Identity Default` with the policy name shown in your audit output.

---

## Step 4 — Verify

Re-run the audit command and confirm no verdict is assigned a notification-enabled policy:

```powershell
Get-HostedContentFilterPolicy | Select-Object Name, *QuarantineTag*
```

All verdicts should show `AdminOnlyAccessPolicy` or `DefaultFullAccessPolicy`. `NotificationEnabledPolicy` or `DefaultFullAccessWithNotificationPolicy` should not appear in the output.

---

## Notes

**`DefaultFullAccessPolicy` vs `AdminOnlyAccessPolicy`**
`DefaultFullAccessPolicy` is recommended for Avanan environments. It disables M365 digest notifications while still allowing users to self-service release their own mail from the M365 quarantine portal if needed. `AdminOnlyAccessPolicy` removes portal access entirely — use this only if you want Avanan to be the exclusive quarantine management interface.

**Multiple anti-spam policies**
Tenants with multiple named anti-spam policies (e.g., scoped to specific user groups) will show multiple rows in the audit output. Repeat Steps 2–3 for each policy row that contains a notification-enabled tag.

**Avanan digest emails getting quarantined by M365**
In some environments, Avanan's own digest emails are quarantined by M365 as high-confidence phish due to Microsoft's "Secure by Default" behavior, which ignores standard EOP overrides. If this occurs, the fix is to whitelist Avanan's sending IP in Defender's **Phishing Simulation** policy — this is one of the few bypasses that survives Secure by Default. Check prior Avanan digest email headers to identify the sending IP.

---

*Markley Technologies — Internal MSP Reference*
