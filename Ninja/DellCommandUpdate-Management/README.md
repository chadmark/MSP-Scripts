# Dell Command Update Management (NinjaOne)

`ninja_manage_dell_command_update.ps1` — v1.0

Fleet-wide Dell driver, firmware, and BIOS update automation via Dell Command Update (DCU), deployed through NinjaOne RMM. This is a customized fork of NinjaOne's built-in "Manage Dell Command Update" catalog script, adapted for reliability across a ~100-endpoint Dell fleet sharing a single internet connection.

## Why this exists

The original lightweight approach (`dcu-cli.exe /applyUpdates`) worked but had no visibility into failures, no prerequisite handling, and no retry logic. When ~100 Dell endpoints hit Dell's catalog servers around the same time from behind one public IP, scans intermittently failed with:

```
Error while downloading the necessary catalogs.
A problem occurred attempting to connect to your network.
```

DNS, TLS, and firewall checks all came back clean — the failures were transient catalog/CDN contention. NinjaOne's official DCU template was adopted as the base (it already handles DCU install, hash/signature verification, and per-update reporting) and three things were added on top:

1. Randomized fleet start delay
2. One retry for recognized transient scan failures
3. An option to exclude Dell "Application" packages (e.g. SupportAssist plugins) from normal installs

## What the script does

```
NinjaOne task starts
    ↓
Validate Dell hardware/model
    ↓
Locate dcu-cli.exe
    ↓
Missing? → install if enabled (installs .NET Desktop Runtime 10.0.8+, then DCU 5.7.1)
    ↓
Randomized 0–15 min delay (if enabled)
    ↓
DCU scan (attempt 1)
    ↓
Transient failure? → wait 2–5 min → DCU scan (attempt 2)
    ↓
Parse update list
    ↓
Exclude Application-type updates (if enabled)
    ↓
Download → verify hash → verify signature → install
    ↓
Record results, detect reboot requirement
    ↓
Report to NinjaOne (activity feed + custom fields)
```

## NinjaOne script variables

Create these as script variables when uploading to NinjaOne. Names must match exactly (they map to `$env:` variables the script reads).

| Display Name | Calculated Name | Type | Recommended (production) |
|---|---|---|---|
| Install DCU And Required Dot Net Runtime If Needed | `InstallDCUAndRequiredDotNetRuntimeIfNeeded` | Checkbox | **Enabled** |
| Randomize Start Delay | `RandomizeStartDelay` | Checkbox | **Enabled** |
| Skip Application Updates | `SkipApplicationUpdates` | Checkbox | **Enabled** |
| Suspend BitLocker And Reboot If Needed | `SuspendBitLockerAndRebootIfNeeded` | Checkbox | Per maintenance policy |
| Destination Folder Path | `DestinationFolderPath` | Text | Leave blank (defaults to `C:\ProgramData\Dell\UpdateService`) |
| Sort Updates By | `SortUpdatesBy` | Dropdown | `Severity` (default) — also accepts Name, Type, Category, ReleaseDate |
| Wysiwyg Custom Field Name | `WysiwygCustomFieldName` | Text | `Dell Updates` |
| Multiline Custom Field Name | `MultilineCustomFieldName` | Text | `Dell Updates List` |
| Install All Updates | `InstallAllUpdates` | Checkbox | Enabled for standard "install everything found" runs |
| Install Updates By Package ID | `InstallUpdatesByPackageID` | Text | Comma-separated Package IDs — targeted installs only |
| Install Updates By Category | `InstallUpdatesByCategory` | Text | Single category — targeted installs only |
| Install Updates By Severity | `InstallUpdatesBySeverity` | Text | `Recommended`, `Urgent`, or `Optional` — targeted installs only |
| Install Updates By Type | `InstallUpdatesByType` | Text | `BIOS`, `Firmware`, `Driver`, or `Application` — targeted installs only |

**Note on install targeting:** only one of `InstallAllUpdates` / `InstallUpdatesByPackageID` / `InstallUpdatesByCategory` / `InstallUpdatesBySeverity` / `InstallUpdatesByType` should be used at a time. If more than one is set, the script logs a warning and honors just one, in that priority order.

### Configuration steps in NinjaOne

1. Upload the script under **Administration → Library → Automation → Scripting**.
2. Add each variable above under the script's **Script Variables** tab, matching the **Calculated Name** column exactly (case-sensitive) — this is what the checkbox/text env var binding depends on.
3. Set checkbox variables to their recommended production values.
4. If you want update results written back to a device custom field, create the WYSIWYG and multiline custom fields first (**Administration → Devices → Global Custom Fields**) — named `Dell Updates` and `Dell Updates List` respectively — then reference those names in the corresponding script variables.
5. Assign to a scheduled task or policy running **as SYSTEM**, targeted at Dell devices.
6. For the initial fleet rollout, run once with `RandomizeStartDelay` disabled on a single test device to confirm DCU install and scan succeed end-to-end before enabling it fleet-wide.

## Key behaviors worth knowing

- **`InstallDCUAndRequiredDotNetRuntimeIfNeeded` is independent of `SkipApplicationUpdates`.** Even with Application updates excluded from normal installs, DCU itself will still be installed via winget/direct download if missing — these are two separate lifecycles.
- **Retry only fires on recognized transient failures** (catalog/download errors, DCU codes 501/503) — not on arbitrary scan failures. On retry, the failed attempt's `DCUScan.log` is preserved as `DCUScan-Attempt1-Failed.log` before the second attempt runs.
- **Randomized delay (0–15 min) happens only after DCU is confirmed available**, immediately before the scan — not before a potential DCU install.
- **No legacy variable compatibility.** The old NinjaOne variable name `InstallDCUAndDotNet8IfNeeded` is not read by this script. If migrating an existing NinjaOne policy from the stock template, update the field name to `InstallDCUAndRequiredDotNetRuntimeIfNeeded`.
- Primary DCU scan log: `C:\ProgramData\Dell\UpdateService\DCUScan.log` (or your custom `DestinationFolderPath`). Dell's own service logs remain at `C:\ProgramData\Dell\UpdateService\Log`.

## NinjaOne script variables — configured

![NinjaOne script variables panel showing Randomize Start Delay, Suspend BitLocker and Reboot If Needed, Install DCU And Required DotNet Runtime If Needed, Skip Application Updates, Destination Folder Path, Sort Updates By, Dell Updates, and Dell Updates List](./ninja-script-variables.png)

## Sample successful run (test device, DCU not previously installed)

```
[Info] Dell Command Update is not installed. Installing the latest version of Dell Command Update.

[Info] Dell Command Update 5.7.1 requires .NET Desktop Runtime 10 (64-bit), version 10.0.8 or higher, but it is not installed.
[Info] Downloading the .NET Desktop Runtime 10.0.11 installer...
[Info] Successfully verified the SHA512 hash of the .NET Desktop Runtime installer.
[Info] Successfully verified the digital signature of the .NET Desktop Runtime installer.
[Info] Successfully installed .NET Desktop Runtime 10.0.11.

[Info] Downloading the Dell Command Update version 5.7.1 installer...
[Info] Successfully verified the SHA256 hash of the Dell Command Update installer.
[Info] Successfully verified the digital signature of the Dell Command Update installer.
[Info] Successfully installed Dell Command Update version 5.7.1.

[Info] Randomized start delay is disabled.
[Info] Scanning for available updates. Attempt 1 of 2.
[Info] Found 7 available updates for this system.

PackageID   : DDG23
Name        : Dell Pro Tower Plus QBT1250/... System BIOS
Type        : BIOS
Severity    : Urgent
Status      : Not installed

  ... (6 more: TPM firmware, Intel ME, SupportAssist plugin, Intel graphics,
       Intel platform framework, Intel PPM provisioning — full list in activity log)

[Info] Working on the 'Dell Pro Tower Plus... System BIOS' update.
[Info] Successfully verified the update's SHA256 hash.
[Info] Successfully verified the update's digital signature.
[Info] Successfully installed the update.
[Info] The update '...System BIOS' requires a reboot to complete the installation.

  ... (remaining 6 updates install the same way)

[Info] Finished installing updates.
[Info] 7 update(s) installed successfully. 0 update(s) failed to install. There are now 0 available update(s) for this system.

[Warning] A reboot is required to complete the installation of some updates, but the
'Suspend BitLocker and Reboot If Needed' option was not selected. Please reboot the
system manually to complete the update process.
```

This run had `SkipApplicationUpdates` disabled, so the SupportAssist plugin (Type: Application) was included — with it enabled, that package would be excluded and only BIOS/Firmware/Driver updates installed.

## Requirements

- Windows 10 (build 10240) or later
- Run as SYSTEM with local admin rights
- Internet access to Dell catalog/CDN endpoints
- Dell hardware (script validates model before proceeding)

## Version history

See the script's `.CHANGELOG` block for full detail. v1.0 is the initial commit to this repo — a fork of NinjaOne's stock "Manage Dell Command Update" template with fleet-staggering, transient-retry, and Application-update filtering added.
