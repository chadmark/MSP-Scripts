# Robocopy File Server Migration Guide
### Mirror a Source File Server to a Destination with ACL Preservation

**Author:** Chad  
**GitHub:** https://github.com/chadmark/MSP-Scripts/blob/main/Guides/Robocopy_File_Server_Migration.md  
**Environment:** Windows Server, Domain-joined  
**Last Updated:** 04-08-2026  
**Version:** 1.0

---

## Table of Contents

- [Robocopy File Server Migration Guide](#robocopy-file-server-migration-guide)
    - [Mirror a Source File Server to a Destination with ACL Preservation](#mirror-a-source-file-server-to-a-destination-with-acl-preservation)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Final Command](#final-command)
  - [Flag Reference](#flag-reference)
  - [Key Behaviors](#key-behaviors)
    - [Mirroring vs. One-Way Copy](#mirroring-vs-one-way-copy)
    - [ACL Preservation](#acl-preservation)
    - [Thread Tuning](#thread-tuning)
    - [Log File](#log-file)
  - [Flags Deliberately Excluded](#flags-deliberately-excluded)
  - [Recommended Workflow](#recommended-workflow)
  - [Exit Codes](#exit-codes)

---

## Overview

This guide covers using Robocopy to mirror a source file server to a destination server with full ACL preservation. The command is designed for a one-way mirror — files on the destination that no longer exist on the source are deleted, making the destination an exact replica of the source.

---

## Final Command

```
robocopy i:\ e:\driveb /MIR /ZB /R:0 /W:0 /NP /MT:16 /COPY:DATSOU /XJ /XD "$RECYCLE.BIN" "System Volume Information" /LOG+:C:\robocopy_migration.log /TEE /A-:SH
```

---

## Flag Reference

| Flag | Value | Purpose |
|------|-------|---------|
| `i:\` | *(source)* | Source drive/path |
| `e:\driveb` | *(destination)* | Destination drive/path |
| `/MIR` | — | Mirror source to destination. Copies new/changed files **and deletes** files on the destination that no longer exist on the source. Implies `/E` (includes empty subdirectories). |
| `/ZB` | — | Uses restartable mode where possible. If access is denied, falls back to Backup mode to bypass file permission restrictions. |
| `/R:0` | 0 retries | No retry attempts on failed files. For bulk migrations, retrying stalls the job — a rerun catches missed files instead. |
| `/W:0` | 0 seconds | No wait between retries. Paired with `/R:0`, failures move on immediately. |
| `/NP` | — | Suppresses per-file percentage progress output. Reduces log noise, especially useful when piping to a log file. |
| `/MT:16` | 16 threads | Multi-threaded copy using 16 parallel threads. Balances throughput without saturating disk I/O or NIC. Tune up or down based on observed performance. |
| `/COPY:DATSOU` | — | Copies file **D**ata, **A**ttributes, **T**imestamps, **S**ecurity (ACLs), **O**wner, and A**U**diting info. Critical for preserving permissions on a file server migration. |
| `/XJ` | — | Excludes junction points. Prevents Robocopy from following directory junctions, which can cause infinite loops or unintended traversal. |
| `/XD` | `"$RECYCLE.BIN"` `"System Volume Information"` | Excludes these system directories from the copy. |
| `/LOG+` | `C:\robocopy_migration.log` | Appends output to a log file. The `+` means successive runs append rather than overwrite, preserving a full run history. |
| `/TEE` | — | Outputs to both the log file and the console simultaneously. Requires `/LOG` to be set. |
| `/A-:SH` | — | Removes the **S**ystem and **H**idden attribute flags from copied files. Confirm this is intentional for your environment before use. |

---

## Key Behaviors

### Mirroring vs. One-Way Copy

`/MIR` makes the destination an exact mirror of the source:

- Files on the source that don't exist on the destination are **copied**
- Files on the destination that don't exist on the source are **deleted**

> ⚠️ **First-run warning:** Before the first `/MIR` run against an existing destination, verify its contents. Robocopy will purge anything in the destination that isn't on the source with no confirmation prompt.

### ACL Preservation

`/COPY:DATSOU` preserves security descriptors (ACLs), owner, and auditing info. The account running Robocopy must have **Backup Operator** rights or `SeBackupPrivilege`. Without this, ACL copying may silently fall back to data-only.

### Thread Tuning

`/MT:16` is a safe starting point. Adjust based on what you observe:

- **High disk queue length** on source or destination → reduce threads
- **Low CPU/disk utilization with fast network** → try `/MT:24` or `/MT:32`

Avoid going above 32 threads — diminishing returns typically kick in well before that point.

### Log File

Review the log at `C:\robocopy_migration.log` after each run. Look for:

- `ERROR` lines (access denied, path too long, etc.)
- Files listed as skipped or failed
- Summary statistics at the bottom (Copied, Skipped, Mismatch, Failed, Extras)

---

## Flags Deliberately Excluded

| Flag | Why Not Used |
|------|-------------|
| `/S` | Redundant — `/MIR` (which implies `/E`) already handles all subdirectories including empty ones |
| `/Z` | Restartable mode adds per-file checkpointing overhead. On a stable LAN the cost outweighs the benefit. `/ZB` already handles access-denied fallback. |

---

## Recommended Workflow

1. **Dry run first** — Add `/L` to simulate without making changes:

```
robocopy i:\ e:\driveb /MIR /ZB /R:0 /W:0 /NP /MT:16 /COPY:DATSOU /XJ /XD "$RECYCLE.BIN" "System Volume Information" /LOG+:C:\robocopy_dryrun.log /TEE /A-:SH /L
```

2. **Review the dry run log** — Confirm the file list and any deletion candidates look correct
3. **Run the live migration** — Execute the command without `/L`
4. **Review the live log** — Check the summary for any failed files
5. **Re-run as needed** — Robocopy is safe to re-run; it only copies changed or new files and skips already-matched files

---

## Exit Codes

Robocopy uses non-standard exit codes. A non-zero exit code does **not** always mean failure.

| Code | Meaning |
|------|---------|
| 0 | No files copied. Source and destination are already in sync. |
| 1 | Files copied successfully. |
| 2 | Extra files or directories detected in destination. |
| 3 | Files copied + extra files detected. |
| 4 | Mismatched files detected (no copy performed). |
| 8+ | At least one failure occurred. Investigate the log. |

Codes below 8 are generally considered successful in automated contexts.

---

*This guide is part of the MSP-Scripts repository. For updates and related scripts visit https://github.com/chadmark/MSP-Scripts*