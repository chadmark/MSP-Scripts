# Apple Business Manager + ADE + NinjaOne MDM — Setup & Deployment Guide

*Reusable MSP procedure. Validated end-to-end on Hutton Companies, 08/31/2026–09/01/2026.*

---

## 1. Prerequisites

- [ ] NinjaOne organization/location created for the client
- [ ] At least one Apple Push Notification service (APNs) certificate configured in NinjaOne
- [ ] Managed Apple ID (org-owned, not a technician's personal ID) for ABM sign-in
- [ ] Devices in hand — either purchased through a linked Customer/Reseller Number, or to be manually registered via Apple Configurator

---

## 2. Configure the ADE Integration in NinjaOne

1. Navigate to **Administration → Apps → Installed → NinjaOne MDM Apple**.
2. Open the **Automated Device Enrollment** tab → **Add ADE profile**.
3. **Step 1:** Download the public key (PEM) file.
4. **Step 2:** Follow the provided link into Apple Business Manager (ABM).

### In ABM:
5. **Devices → Management Services → Add.**
6. Name the server (e.g., "NinjaOne").
7. **Upload Certificate** → select the PEM file from step 3.
8. Click **Next → Download Service Token → Done.**

### Back in NinjaOne:
9. Upload the token file (.p7m) from step 8.
10. Set default **Organization**, **Location**, and **Device Role** (iOS/iPadOS/macOS) — do not leave blank.
11. Assign the **APNs certificate** to tie to this profile.
12. Enter support email/phone (shown to end users during enrollment).
13. Name the profile uniquely → **Save**.

**Token health check:** Green = healthy (90+ days). Yellow/Red = renew before proceeding — an expiring/expired token silently blocks all enrollment.

---

## 3. Configure the Enrollment Profile

1. **Administration → Apps → NinjaOne MDM Apple → Edit** the ADE profile.
2. Set **Skip setup items** as desired (Setup Assistant screens to bypass).
3. **Supervised Mode** should be ON (this is what enables full device control).
4. **MDM Removable** → toggle **OFF** if you need to prevent end-user removal of the MDM profile (requires Supervised).
5. **Save Profile Configuration.**

⚠️ **Policy gotcha:** Do not set apps to "Required for Setup" — this can break the ADE enrollment process. Use **Force Install** instead. Also enable **Installer Deduplication** at Administration → Settings → Agent installer.

---

## 4. Register Devices Into ABM (for devices not purchased under a linked Customer/Reseller Number)

Use **Apple Configurator** — either the iPhone app (NFC/Bluetooth pairing) or macOS app (USB), depending on hardware available.

### Apple Configurator for iPhone:
1. Erase the target device, boot to **"Choose a Wi-Fi Network"** screen — do not proceed further.
2. On the tech's iPhone (Configurator app, BT/Camera permissions granted): hold near target device for NFC pairing, or use **Pair Manually** with the 6-digit code if NFC fails.
3. Once paired: select Wi-Fi profile to share, select MDM server (or None to assign later), confirm.

### Apple Configurator for Mac (USB):
1. Same target-device prep as above.
2. Connect via USB-C, tap **Trust** on device.
3. In Configurator: select device → **Prepare**.
4. **Prepare with:** Manual Configuration.
5. Check **Add to Apple School Manager or Apple Business.**
6. **Uncheck "Activate and complete enrollment"** — this triggers a full erase/activate cycle in Configurator itself and is a common cause of failures/errors mid-Prepare. Leave it off if you just need ABM registration now.
7. Server dropdown will likely only show **New Server** — this is expected; it's just Configurator's registration placeholder, not your real MDM. Name it anything, click through the "unable to verify enrollment URL" warning, don't add a certificate, select your Organization, sign in with your Managed Apple ID, click **Prepare**.
8. Device will restore and reboot as part of this step — normal, not an error.

---

## 5. Assign the Device to Your MDM Server in ABM

1. In ABM: **Devices** → find the device by serial number.
2. Confirm **Device Management Service** field shows your MDM (e.g., NinjaOne) — this is a **per-device assignment**, separate from having the MDM server configured at the org level. Having NinjaOne set up in ABM does not auto-assign every device to it.
3. Also check **Devices → Automated Device Enrollment devices** list in NinjaOne — device should appear with **Profile Status: Assigned**. ("Not registered" at this stage is normal/expected — it just means the device hasn't checked in yet.)

---

## 6. Enroll the Device (the live test)

⚠️ **If this device already has data on it (not a true out-of-box unit), back it up before erasing** — either a local backup (Finder/iTunes on a Mac/PC) or an iCloud backup (Settings → [Name] → iCloud → iCloud Backup → Back Up Now), taken under whichever Apple ID the end user wants to restore from. This is a one-time opportunity — once you erase, the only way back is that backup.

0. Confirm a current backup exists before erasing, if the device isn't already blank/new.
1. Ensure any **stale/old device record** in NinjaOne (e.g., from a prior manual/unsupervised enrollment attempt) is deleted first — a lingering record can conflict with a clean ADE re-enrollment.
2. On the device: **Settings → General → Transfer or Reset iPhone → Erase All Content and Settings.**
3. Let it reboot to language/region selection **only** — do not sign into anything, scan any QR code, or tap any enrollment link.
4. At **"Choose a Wi-Fi Network,"** connect and watch closely.
5. **The critical moment:** within seconds of Wi-Fi connecting, a **"Remote Management"** screen should appear automatically, showing the org name — *before* any other Setup Assistant screen.
   - ✅ If it appears: this confirms ADE is working. Tap through, finish Setup Assistant normally.
   - ❌ If it does NOT appear (goes straight to normal Setup Assistant): stop, don't finish setup, and troubleshoot (see Section 8) before retrying.
6. After setup completes, verify:
   - **On device:** Settings → General → VPN & Device Management shows the enrollment profile, device is Supervised.
   - **In NinjaOne:** device shows **Company Owned** (not "Personally Owned") and **Supervised** (not "Unsupervised"). "Personally Owned" after a supposedly-ADE enrollment means it actually enrolled through an unsupervised/manual path — redo the erase, making sure nothing manual touches the device in between.

### 6a. Restoring Data After Enrollment (if a backup was taken)

If the device had a prior backup, data can be restored **during this same Setup Assistant run**, right after the Remote Management screen:

Continue through Setup Assistant to the **"Apps & Data"** screen
    ↓
Choose **Restore from iCloud Backup** (or Restore from Mac or PC, for a local backup)
    ↓
Sign in with the **same Apple ID** used to create the backup — required, no way around it
    ↓
Restore proceeds — apps, settings, photos (if not already synced to iCloud Photos), messages, etc. all return

**Things to know before doing this:**

- **Check the ADE profile's Skip Setup Items first** (Section 3) — if the "Restore"/Apps & Data screen is set to skip, no restore option will be offered at all, and the device will just set up as new. Adjust that setting and re-erase if you need the restore option available.
- **Supervision/MDM status is NOT inherited from the backup.** Even if the old backup came from a differently-managed (or unmanaged) device, the new device's supervision and enrollment are applied fresh from your ADE profile config — restoring data won't undo or interfere with the ADE enrollment that already happened.
- **Apple's wireless "Quick Start" (phone-to-phone) transfer is NOT supported for ADE-enrolled devices** and will fail or behave unpredictably. iCloud or local (Finder/iTunes) backup restore is the only supported path for moving data onto a device going through ADE.
- **Personal vs. managed Apple ID flag:** if the backup is under the employee's *personal* Apple ID, that personal ID gets signed into iCloud on the device as part of the restore. Decide upfront whether that's acceptable for this client/device, or whether the user should set up fresh and reinstall/re-sign-in manually instead — this ties directly into the device-control/offboarding considerations in Section 9.

---

## 7. Apps and Books (VPP) Setup

1. **In ABM:** your name (bottom of sidebar) → **Preferences → Payments & Billing → Apps and Books.**
2. A payment method is technically required per Apple's docs, even for free apps — but in practice, free-app purchasing has worked without one configured. Test with a free app first; only chase down a payment method if that test is blocked.
3. Locate your **Content Token** on this same page (listed under your org name) → **Download.**
4. **In NinjaOne:** Administration → Apps → NinjaOne MDM Apple → **Apps and Books → Add content token** → upload the downloaded file, name it, optionally assign to specific organizations.
5. Purchase (acquire) free apps for the client under **Apps and Books** in ABM — they'll show in Purchase History at $0.00, Payment Details: "None."
6. In NinjaOne, add apps to the relevant **MDM Policy** (via the **Apps and Books** tab, not Public App Store) as **Force Install** to auto-deploy to supervised devices.

### Content token troubleshooting ("token has been corrupted" / sync errors):
- Delete the token entry in NinjaOne entirely before re-adding — don't upload over an existing broken one.
- Re-download a **fresh** token directly from the ABM Payments & Billing → Apps and Books page each time; don't reuse an old download.
- Don't open/preview/rename the downloaded `.vpptoken` file before uploading — any alteration breaks the signed token.
- If it fails again, try a different browser for the download.
- A token can go stale if re-downloaded multiple times across sessions without re-uploading each time — treat it as a one-time-use secret: download once, upload immediately, avoid re-touching unless deliberately replacing it.
- Confirm the token isn't also linked to a different MDM (Intune, Jamf, etc.) — ABM content tokens can only sync with one MDM at a time. If it is, create a new Location in ABM and generate a separate token tied to that location.

---

## 8. Common Failure Points & Fixes

| Symptom | Likely Cause | Fix |
|---|---|---|
| `CBInternalErrorDomain` / "Broadcast primitives invalidated" during Configurator add | Bluetooth pairing drop (this error is CoreBluetooth, not ABM/Ninja) | Move closer, disconnect other BT accessories, reboot the pairing device, retry |
| "Configurator requires user interaction... because it is not supervised" | Profile pushed manually instead of via a proper Prepare/ADE flow | Tap Continue → manually install via Settings on-device for now; going forward, use Prepare with Supervise on, or true ADE enrollment |
| Prepare throws an error mid-erase | "Activate and complete enrollment" was checked, forcing a full erase/activate cycle that needs solid connectivity | Uncheck that box if you only need ABM registration right now |
| Device shows in ABM + NinjaOne ADE sync, but no MDM profile on-device | Device completed Setup Assistant before ADE assignment was live, or without checking in at the right moment | Erase and redo, watching for the Remote Management screen (Section 6) |
| NinjaOne shows device as "Personally Owned" / Unsupervised despite ABM assignment looking correct | Device actually enrolled via a manual/unsupervised path (QR code, enrollment link, manual profile install) rather than picking up ADE during Setup Assistant | Delete the device record, erase again, don't let anything manual touch the device this time |
| Content token shows "corrupted" or won't sync | File altered in transit, stale re-download, or already linked to another MDM | See Section 7 troubleshooting |
| DNS filtering (AdGuard, Pi-hole, etc.) in the environment | May silently block Apple ADE endpoints | Whitelist `apple.com` and `cdn-apple.com` (with subdomains) at minimum; disable any SSL/HTTPS interception for Apple traffic — Apple hard-fails on inspected connections |

---

## 9. Post-Enrollment: Offboarding & Device Control Considerations

To ensure the MSP/client retains control of a device when an employee leaves:

- Enroll as **Supervised** (Section 2–3) — gives full control regardless of what Apple ID is on the device, and can prevent MDM profile removal.
- Restrict personal Apple ID / Find My sign-in via MDM policy restrictions (**Allow modifying account settings**) if the org doesn't want personal iCloud on the device.
- If Find My/Activation Lock is allowed, confirm NinjaOne is escrowing the **Activation Lock bypass code** at enrollment (available for a limited window post-supervision) — this is what lets you clear the lock later without the ex-employee's credentials.
- Standard offboarding step regardless: have the employee sign out of Settings → [Name] before device return; verify no personal Apple ID remains before wiping.
- A "Person"/Managed Apple ID in ABM is **not required** for standard company-owned device management — only needed for managed iCloud, per-user app licensing, or BYOD-style Account-Driven Enrollment.

---

*Doc maintained for internal MSP reuse. Update as NinjaOne/Apple UI changes.*
