# HDACSIST — Free Atari ST ACSI Hard Disk & SD Driver

<img width="264" height="240" alt="image" src="https://github.com/user-attachments/assets/0416f922-63a1-4848-bd65-74d76202afa4" />


A free, cold-bootable ACSI hard disk driver, FAT16 partitioner, and boot installer for the Atari ST family. Designed to smooth over early Atari TOS quirks and let you move SD cards effortlessly between your Atari ST and a modern PC.

> **Latest Release:** **v1.2** (`hdacsist-v1.2.zip` | `hdacsist.st` Floppy Image) — Licensed under **GPLv3**

---

## Table of Contents

- [Why Use HDACSIST on Your Atari ST?](#why-use-hdacsist-on-your-atari-st)
- [What’s Included](#whats-included)
- [Optional Companion Utility: ST Mounter](#optional-companion-utility-st-mounter)
- [Getting Started](#getting-started)
- [Atari TOS & Hardware Support](#atari-tos--hardware-support)
- [Screenshots](#screenshots)
- [Current Limitations & Known Workarounds](#current-limitations--known-workarounds)
- [Building from Source](#building-from-source)
- [Downloads (v1.2)](#downloads-v12)

---

## Why Use HDACSIST on Your Atari ST?

### Read Your Atari ST SD Card on Any PC
HDACSIST uses standard PC DOS MBR partition tables (primary and extended `$05`/`$0F`) and plain FAT16 partitions. Pull the SD card out of your Atari adapter, plug it into a Windows, macOS, or Linux PC to drop games and demos on it, and pop it straight back into your ST—no special tools or proprietary disk formats required.

### Fixes Early Atari TOS & STe Bad DMA Headaches
Early ROMs like TOS 1.00 and 1.02 can be notoriously fussy with hard drives. HDACSIST automatically:
- Expands the folder pool by **200 blocks** (preventing the infamous 40-folder bug).
- Fixes the free-space reporting bug (`Dfree`) and TOS 1.02 `TRAP #1` handling.
- Waits up to **400 ms** for slower SD adapters on power-on.
- Prevents the Atari STe **"Bad DMA" (`C025913-38`)** write corruption issue in software by using separate `move.w` register writes instead of `move.l`.

---

## What’s Included

### `HDACSIST.PRG` — Atari ST ACSI DMA Driver
- Scans ACSI IDs `0–7` automatically across primary and DOS extended (`$05`/`$0F`) partitions.
- Mounts up to **14 GEMDOS drives (`C:`–`P:`)** with support for cards over 1 GB.
- Built-in fixes for the 40-folder bug, `Dfree`, TOS 1.02, and slow SD spin-up.
- Retries ACSI transfers with `REQUEST SENSE`, exposes AHDI `PUN_INFO` (`$516`), and uses XBRA chains.
- Uses safe 16-bit DMA register writes to avoid the early STe "Bad DMA" (`C025913-38`) write corruption bug.
- Automatic DMA bounce buffer for Fast-RAM/Alt-RAM and odd addresses.

### `SDPART.PRG` (v1.2) — FAT16 SD Card Partitioner
- Press **`[A]`** to add a PC-compatible FAT16 partition (`8–2047 MB`, up to 14 drives).
- Press **`[E]`** to format a card into `1–14` equal drives (pick the size first, then count).
- Creates up to 3 primary partitions plus DOS extended (`$05`) drives automatically.
- Press **`[D]`** to wipe the partition table or **`[T]`** to switch ACSI ID (`0–7`).

### `INSTALL.PRG` — Cold-Boot Installer & Hotkeys
- Press **`[I]`** so your Atari ST boots straight from the SD card without a floppy.
- Press **`[U]`** to remove the boot loader anytime without touching your files.
- Hold **`[Alternate]`** at startup to skip the driver completely and boot from floppy.
- Hold **`[Control]`** at startup to keep `C:`–`P:` mounted while booting from `A:` / Gotek.

### `HDACSIST.ACC` — GEM Desk Accessory (Mount / Unmount)
- Adds **HDACSIST Mount** right under your Atari’s **Desk** menu.
- Unmount cleanly before pulling out an SD card, or remount after swapping cards.
- Avoids rebooting just to refresh drives `C:`–`P:` on the GEM Desktop.

---

## Optional Companion Utility: ST Mounter

> **Note:** Separate download (not bundled inside the core HDACSIST driver archive).

### `STMOUNT.ACC` / `STMOUNT.PRG`
An optional floppy-image accessory that pairs nicely with a hard drive: once you copy `.ST` or compressed `.MSA` floppy images onto your SD card from a PC, **ST Mounter** lets you load them into RAM as virtual Drive `A:` or `B:` right from the Atari GEM Desktop—no real floppies or Gotek needed.

- Works with raw `.ST` images (`360K–1.44M`) and `.MSA` archives (fast in-RAM decompression and save-back).
- Run up to two virtual floppy drives (`A:` and `B:`) side by side, or use **Boot** to launch boot-sector games and demos straight from the image.
- Drop `STMOUNT.ACC` in `C:\` to open it from the Desk menu, or launch `STMOUNT.PRG` directly when needed.

---

## Getting Started

1. **Boot from Floppy**  
   Write `hdacsist.st` to a floppy disk or Gotek USB drive, or copy `HDACSIST.PRG`, `SDPART.PRG`, `INSTALL.PRG`, and `HDACSIST.ACC` to a disk.
2. **Partition the SD Card**  
   Run `SDPART.PRG`, press **`[T]`** to select your ACSI device ID, and use **`[A]`** or **`[E]`** to create up to 14 FAT16 partitions (`C:`–`P:`).
3. **Make It Bootable**  
   Run `INSTALL.PRG` from the same folder as `HDACSIST.PRG`, verify the target ID, and press **`[I]`**.
4. **Boot Without a Floppy**  
   Eject the floppy and power-cycle your Atari ST. Hold **`[Alternate]`** for a pure floppy boot, or hold **`[Control]`** to boot from `A:` while keeping drives `C:`–`P:` active.

### How Cold Boot Works on the SD Card

```text
Sector 0        -> Stage-1 DMA boot loader (loaded automatically by Atari TOS)
Sectors 1..N    -> Stage-2 HDACSIST.PRG (stored safely before Partition 1)
Sectors 128+    -> Up to 14 partitions (DOS MBR primary + extended $05/$0F, C:..P:)
```

---

## Atari TOS & Hardware Support

| Atari OS / ROM | Native Partition Size | Notes |
| :--- | :--- | :--- |
| **Atari TOS 1.00 / 1.02** | Up to **255 MB** (512 KB RAM)<br>Up to **510 MB** (1 MB+ TOS 1.02) | Uses 8 KB cache buffers on 512 KB STs (keeping sectors $\le 32,760$ signed-safe) and 16 KB buffers on 1 MB+ machines; keep $\le 255\text{ MB}$ on TOS 1.00 for safest compatibility. Automatically adds `+200` folder-pool blocks, fixes `Dfree` space reporting and TOS 1.02 `TRAP #1` handling, and waits up to 400 ms for slow adapters. |
| **Atari TOS 1.04 / 1.06 / 1.62** | Up to **510 MB** | TOS 1.04+ handles unsigned 16-bit sectors, so up to 510 MB works on both 512 KB (8 KB buffers) and 1 MB+ (16 KB buffers) machines; $\le 255\text{ MB}$ on 512 KB keeps sectors signed-safe for old tools. Partitions from 511 MB to ~1 GB need `BIGDOS.PRG` + 1 MB+ RAM. On STe models (TOS 1.06 / 1.62), spaced 16-bit DMA writes avoid the "Bad DMA" (`C025913-38`) write bug. |
| **Atari TOS 2.05 / 2.06 / 3.06** | Up to **510 MB** | Partitions from 511 MB to ~1 GB need `BIGDOS.PRG` + 1 MB+ RAM. Works with STe, Mega STe, and TT ACSI DMA ports. |
| **EmuTOS** | Up to **2047 MB** | Handles full 2047 MB FAT16 partitions natively using 512-byte sectors without extra extensions. |

---

## Screenshots

### Core Driver & Utilities
- **Cold Boot Banner:** `HDACSIST` v1.2 scanning targets and mounting FAT16 partitions at power-on.
- **Atari GEM Desktop:** PC-readable FAT16 drives ready to browse on the Atari desktop.
- **`SDPART.PRG`:** Partition and format an SD card with up to 14 FAT16 drives.
- **`INSTALL.PRG`:** Install, update, or remove the Atari ST cold-boot loader.
- **`HDACSIST.ACC`:** Mount or unmount SD card drives straight from the Desk menu.

### Optional Add-on: ST Mounter
- **ST Mounter Dialog:** Pick Drive `A:` or `B:` to load, swap, save, or eject floppy images.
- **Mount & Boot `.ST` / `.MSA` Images:** Return to Desktop or click **Boot** to start games and demos right from the image.

---

## Current Limitations & Known Workarounds

- **ACSI DMA Ports Only:** Designed for Atari ACSI DMA ports (ST, STe, Mega ST, Mega STe, TT). Does not drive internal IDE or Falcon/TT SCSI buses.
- **Filesystem Limits:** Supports FAT12 and FAT16 filesystems (up to 2047 MB using 64 sectors/cluster).
- **Partition Editing:** `SDPART.PRG` adds or wipes partitions (up to 14 total) rather than resizing or deleting a single individual partition.
- **ACSI2STM Hot-Swap Limitation:** Removing and reinserting an SD card while an ACSI2STM adapter is powered on can cause an *"ACSI target did not respond"* error on Mount.
  - **Workaround:** Unmount in `HDACSIST.ACC`, swap the SD card, power-toggle the ACSI2STM unit, and then click **Mount** (no Atari reboot needed).

---

## Building from Source

Assemble all binaries from the 68000 assembly source files using `vasm`:

```sh
vasmm68k_mot -nosym -devpac -Ftos -o HDACSIST.PRG hdacsist.s
vasmm68k_mot -nosym -devpac -Ftos -o SDPART.PRG   sdpart.s
vasmm68k_mot -nosym -devpac -Ftos -o INSTALL.PRG  install.s
vasmm68k_mot -nosym -devpac -Ftos -o HDACSIST.ACC hdacsistacc.s
```

---

## Downloads (v1.2)

### Core Distribution & Binaries

| File | Size | Description |
| :--- | :--- | :--- |
| **`hdacsist-v1.2.zip`** | 92,612 B | Everything in one archive: Atari ST binaries (including `HDACSIST.ACC`), 68000 source code, floppy image, README, and GPLv3 license. |
| **`hdacsist.st`** | 737,280 B | Ready-to-use 720 KB Atari ST floppy disk image for real hardware, Gotek drives, or Hatari. |
| **`HDACSIST.PRG`** | 5,422 B | The Atari ST ACSI DMA driver itself (for installing to Sector 0 or running from `AUTO`). |
| **`SDPART.PRG`** | 6,440 B | Atari ST partitioner (v1.2) supporting up to 14 PC-compatible FAT16 partitions (primary + DOS extended). |
| **`INSTALL.PRG`** | 3,479 B | Boot-sector tool to install, update, or remove the Atari ST cold-boot loader. |
| **`HDACSIST.ACC`** | 1,545 B | GEM Desk Accessory (**HDACSIST Mount**) to unmount and remount SD cards cleanly. |
| **`README.TXT`** | 9,982 B | Complete plain-text setup guide, Atari TOS notes, and changelog. |

### Optional Add-on: ST Mounter (Separate Download)

| File | Size | Description |
| :--- | :--- | :--- |
| **`stmount.zip`** | 36,786 B | ST Mounter archive with `STMOUNT.ACC`, `STMOUNT.PRG`, source code, tests, and README. |
| **`STMOUNT.ACC`** | 16,197 B | Optional ST Mounter desk accessory — copy to `C:\` to mount `.ST` and `.MSA` floppy images in RAM. |
| **`STMOUNT.PRG`** | 16,197 B | Standalone GEM program version of ST Mounter. |
