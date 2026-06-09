<!-- 
    Title       : Adding a Second NVMe Disk for VM and ISO Storage in Proxmox 9
    Author      : Chad
    Last Edit   : 06-09-2025
    Environment : Proxmox VE 9, NVMe disk
    Version     : 1.0
-->

# Adding a Second NVMe Disk for VM and ISO Storage in Proxmox 9

---

## Overview

This guide covers partitioning, formatting, and registering a second NVMe disk in Proxmox 9 as a directory storage backend for VMs and ISO images.

**NVMe naming note:** NVMe drives use the convention `/dev/nvme0n1` for the disk and `/dev/nvme0n1p1` for the first partition — the `p` prefix distinguishes partitions from the drive itself (unlike SATA drives which use `/dev/sdb1`).

---

## Step 1: Identify the Disk

In the Proxmox shell, run:

```bash
lsblk
```

Confirm your NVMe drive appears (e.g., `/dev/nvme0n1`) and has no partitions under it. Double-check the device name and size before proceeding — wiping the wrong disk is unrecoverable.

---

## Step 2: Wipe Existing Filesystem Signatures

```bash
wipefs -a /dev/nvme0n1
```

This removes any existing partition tables or filesystem headers. Required even on a "new" drive — leftover metadata can cause Proxmox or formatting tools to error or warn.

---

## Step 3: Partition the Disk

```bash
fdisk /dev/nvme0n1
```

Inside the `fdisk` prompt:

| Key | Action |
|-----|--------|
| `g` | Create new GPT partition table |
| `n` | New partition |
| *(Enter x3)* | Accept defaults (partition 1, full disk) |
| `w` | Write and exit |

**Why GPT over MBR:** GPT is required for disks larger than 2TB and is the modern standard. MBR is a legacy format.

---

## Step 4: Format the Partition

```bash
mkfs.ext4 /dev/nvme0n1p1
```

Formats the new partition as ext4. Note the `p1` suffix — this is the partition, not the raw disk. Running `mkfs` directly against `/dev/nvme0n1` (no partition) would work but is not recommended practice.

---

## Step 5: Create the Mount Point and Mount

```bash
mkdir /mnt/storage
mount /dev/nvme0n1p1 /mnt/storage
```

---

## Step 6: Make the Mount Persistent (fstab)

Get the partition UUID — UUIDs are stable across reboots; device names like `/dev/nvme0n1p1` can shift if drive order changes.

```bash
blkid /dev/nvme0n1p1
```

Copy the UUID value from the output, then append an entry to `/etc/fstab` using `echo` (avoids nano syntax issues):

```bash
echo 'UUID=<your-uuid-here>  /mnt/storage  ext4  defaults  0  2' >> /etc/fstab
```

Verify the entry was written correctly:

```bash
tail -1 /etc/fstab
```

Test that the fstab entry mounts correctly without rebooting:

```bash
mount -a
```

No output means success. An error here should be resolved before rebooting.

---

## Step 7: Register the Storage in Proxmox

```bash
pvesm add dir storage --path /mnt/storage --content images,iso
```

Verify it was added:

```bash
pvesm status
```

The `storage` pool should appear in the list. It will also be visible in the Proxmox GUI under **Datacenter → Storage**.

**Alternatively via GUI:** Datacenter → Storage → Add → Directory → set path to `/mnt/storage`, enable content types **Disk image** and **ISO image**.

---

## Summary

| Step | Command |
|------|---------|
| Identify disk | `lsblk` |
| Wipe signatures | `wipefs -a /dev/nvme0n1` |
| Partition | `fdisk /dev/nvme0n1` → g, n, w |
| Format | `mkfs.ext4 /dev/nvme0n1p1` |
| Mount | `mkdir /mnt/storage && mount /dev/nvme0n1p1 /mnt/storage` |
| Get UUID | `blkid /dev/nvme0n1p1` |
| Persist mount | `echo 'UUID=... /mnt/storage ext4 defaults 0 2' >> /etc/fstab` |
| Test fstab | `mount -a` |
| Register in PVE | `pvesm add dir storage --path /mnt/storage --content images,iso` |

---

*Markley Technologies*
