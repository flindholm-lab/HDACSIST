==============================================================================
HDACSIST v1.2 - Atari ST ACSI Hard Disk & SD Card Driver (GNU GPLv3+)
==============================================================================
Works on Atari ST, STe, Mega ST, Mega STe, and TT computers with ACSI2STM,
UltraSatan, or other compatible ACSI DMA adapters.

1. WHAT IS INCLUDED
------------------------------------------------------------------------------
  HDACSIST.PRG   The resident hard disk driver (hdacsist.s)
    Mounts FAT12 and FAT16 drives (C: through P:) using standard Atari TOS
    and GEMDOS calls. It scans all ACSI IDs (0 to 7) so multi-slot adapters
    like UltraSatan or ACSI2STM work out of the box, supports both PC MBR
    partitions and unpartitioned cards, handles drives larger than 1 GB, and
    safely bounces transfers from FastRAM or odd memory addresses. On older
    Atari TOS 1.00 and 1.02 machines, it also fixes the "40-folder bug",
    corrects free-space reporting, and gives slower SD cards extra time to
    wake up at power-on.

  SDPART.PRG     SD card partitioner & FAT16 formatter (sdpart.s)
    Lets you set up partitions right on your Atari ST (40-column friendly):
      [A] Add a partition (8 MB to 2047 MB, up to 14 total C:-P:)
      [E] Erase the card and create 1 to 14 equal partitions (size first)
      [D] Delete all partitions
      [T] Switch to another card/target ID (0-7)
    Creates up to 3 primary MBR partitions plus DOS extended ($05) logical
    partitions when adding 4 or more partitions (14 max). Starts at LBA 128.
    Note: Keep each partition at 510 MB or smaller if you run Atari TOS 1.x.

  INSTALL.PRG    Hard drive autoboot installer (install.s)
    Makes your SD card bootable without needing a floppy in drive A:.
      [I] Install or update the boot driver on the selected card
      [U] Remove the boot loader (keeps your partitions and files safe)
      [T] Switch to another card/target ID (0-7)
    Boot hotkeys:
      Hold [Alternate] at boot -> skip driver completely (pure floppy boot)
      Hold [Control]   at boot -> load driver (C:-P: active), boot from A:

  HDACSIST.ACC   GEM Desk Accessory for mounting/unmounting SD cards (hdacsistacc.s)
    Appears under the Desk menu ("HDACSIST Mount") to unmount before pulling
    an SD card or remount after swapping cards without rebooting.

  hdacsist.st    Ready-to-use 720 KB boot floppy image containing all tools,
                 \AUTO\HDACSIST.PRG, HDACSIST.ACC, and this README.TXT.

2. RECOMMENDED SETUP BY TOS VERSION
------------------------------------------------------------------------------
  Atari TOS 1.00 / 1.02 (early ST/Mega ST)
    - Recommended partition size: <= 255 MB (512 KB ST, 8 KB BCBs) or
      <= 510 MB on 1 MB+ TOS 1.02 (16 KB BCBs, keeps sectors <= 32,760
      signed; keep <= 255 MB on TOS 1.00 for maximum compatibility).
    - HDACSIST automatically fixes the 40-folder bug, Dfree free-space
      sign-extension, TOS 1.02 TRAP #1 jump handling, and adds 400 ms
      cold-boot SD wakeup retries. No extra FOLDRxxx.PRG needed.

  Atari TOS 1.04 / 1.06 / 1.62 (ST/STe)
    - Max partition size: <= 510 MB natively (TOS 1.04+ supports unsigned
      16-bit logical sectors, so 510 MB works on both 512 KB and 1 MB+ RAM;
      <= 255 MB on 512 KB keeps sector numbers signed-safe for old tools).
    - Partitions from 511 MB to ~1 GB require BIGDOS.PRG and 1 MB+ RAM.

  Atari TOS 2.05 / 2.06 / 3.06 (Mega STe, TT, upgrades)
    - Max partition size: <= 510 MB per partition natively.
    - Supports ST-RAM DMA and FastRAM/TT-RAM bounce buffering automatically.
    - Partitions from 511 MB to ~1 GB require BIGDOS.PRG and 1 MB+ RAM.

  EmuTOS
    - Max partition size: up to 2047 MB (2 GB) per FAT16 partition.
    - Auto-detected by HDACSIST: skips Atari TOS BCB RAM allocation and
      allows full unscaled FAT16 partitions up to 2047 MB.

3. FIRST-TIME SETUP
------------------------------------------------------------------------------

  +--------------------------+     +--------------------------+
  | 1. Boot from Floppy      |     | 2. Partition Your Card   |
  | Insert SD + hdacsist.st  | --> | Open A:\SDPART.PRG       |
  | Power on; driver loads   |     | Pick card [T], run [E]   |
  +--------------------------+     +--------------------------+
                                                 |
                                                 v
  +--------------------------+     +--------------------------+
  | 4. Boot Straight from SD |     | 3. Make Card Bootable    |
  | Eject the floppy & reset | <-- | Open A:\INSTALL.PRG      |
  | Desktop opens with C:..  |     | Pick card [T], press [I] |
  +--------------------------+     +--------------------------+

  Tips:
  - If you only ever want to boot from floppy, you can skip Step 3.
  - Upgrading an older driver on an already-bootable card? Boot from the new
    floppy, open INSTALL.PRG, press [I] to update it, and reboot.

4. HOW BOOTING FROM THE SD CARD WORKS
------------------------------------------------------------------------------

  Sector 0                Sectors 1..N            Sectors 128+
  +---------------------+ +---------------------+ +--------------------------+
  | Tiny Boot Loader    | | HDACSIST.PRG        | | Standard FAT16 Drives    |
  | (with PC MBR table) | | (stored raw)        | | C:, D:, ...              |
  +---------------------+ +---------------------+ +--------------------------+
             |                       |                         ^
             v                       v                         |
  +---------------------+ +---------------------+ +--------------------------+
  | Atari TOS reads     | | Loads driver into   | | Scans ACSI IDs 0..7,     |
  | sector 0 at boot    | | ST-RAM and starts   | | applies TOS fixes,       |
  |                     | | it before Desktop   | | mounts drives on Desktop |
  +---------------------+ +---------------------+ +--------------------------+

5. LIMITATIONS
------------------------------------------------------------------------------
  - Filesystems: Supports FAT12 and FAT16 only (no FAT32, exFAT, or NTFS).
  - Partition size on Atari TOS: Native Atari TOS works up to <= 510 MB per
    partition (keep <= 255 MB on 512 KB TOS 1.00/1.02 STs for signed 16-bit
    sector safety, and <= 255 MB on TOS 1.00 generally). Partitions from
    511 MB to ~1 GB require BIGDOS.PRG + 1 MB+ RAM; >1023 MB partitions are
    not mounted under Atari TOS (use EmuTOS for up to 2047 MB).
  - Partition layout: PC MBR (primary + DOS extended/logical $05/$0F partitions)
    or unpartitioned superfloppy cards. AHDI-only partition tables are not
    supported.
  - Drive count: Up to 14 GEMDOS drives total (C: through P:) across all
    ACSI IDs 0 to 7.
  - SDPART.PRG: Can add up to 14 partitions ([A]), wipe and create 1-14
    equal partitions ([E], size per partition first then count), or delete
    all partitions ([D]) - deleting or resizing a single existing partition
    is not supported.
  - INSTALL.PRG boot loader: Requires Partition 1 to leave enough free
    sectors at the start of the card (11+ sectors for HDACSIST.PRG;
    SDPART.PRG always starts Partition 1 at sector 128).
  - Hardware & media: Works on the Atari ACSI DMA bus only (not internal
    IDE or Falcon/TT SCSI). Use HDACSIST.ACC to unmount/remount swapped SD cards.
  - ACSI2STM SD card swap (known limitation & workaround): Removing and
    reinserting an SD card while ACSI2STM is powered can cause "ACSI target
    did not respond" on Mount (no power-switched SD slot / GemDrive mode
    switch).
    Workaround: Unmount in HDACSIST.ACC, swap the card, power-toggle the
    ACSI2STM unit, then click Mount in HDACSIST.ACC (keeps your Atari ST on).

6. BUILDING FROM SOURCE (Linux / vasm)
------------------------------------------------------------------------------
  vasmm68k_mot -nosym -devpac -Ftos -o HDACSIST.PRG hdacsist.s
  vasmm68k_mot -nosym -devpac -Ftos -o SDPART.PRG   sdpart.s
  vasmm68k_mot -nosym -devpac -Ftos -o INSTALL.PRG  install.s
  vasmm68k_mot -nosym -devpac -Ftos -o HDACSIST.ACC hdacsistacc.s

7. LICENSE & CREDITS
------------------------------------------------------------------------------
  Based on sdextjoy.s by Orion_ (2020), modified in 2026 by Ninjabuffy for
  the Atari ACSI DMA bus, multi-target discovery, large FAT16, and TOS fixes.

  Copyright (c) 2020 Orion_
  Copyright (c) 2026 Ninjabuffy

  Licensed under the GNU General Public License v3.0 or later (GPLv3+).
  See the source headers or https://www.gnu.org/licenses/gpl-3.0.html.

8. CHANGES IN v1.2
------------------------------------------------------------------------------
  - HDACSIST.PRG: Fix TOS 1.02 TRAP #1 jump vector patch (6-byte jmp abs.l
    instead of 4-byte .w under -devpac); add REQUEST SENSE ($03) + ACSI
    retry on error status; populate AHDI 3.0+ PUN_INFO ($516.w); add XBRA
    headers ("HDAC") on TRAP #1 / hdv_rw / hdv_mediach; support DOS Extended
    ($05/$0F) logical partitions (C:-P:); add [Alternate] (skip driver) and
    [Control] (keep C:-P: loaded, boot from A:) cold-boot hotkeys.
  - SDPART.PRG v1.2: Support up to 14 partitions (3 primary + DOS Extended $05
    logical chain); prompt for partition size first then count in [E];
    auto-convert slot 4 to extended when adding past 3 partitions in [A].
  - HDACSIST.ACC: New GEM Desk Accessory ("HDACSIST Mount") to unmount
    before removing SD cards or remount swapped cards without rebooting.
  - Documentation & Web: Updated to v1.2 with new screenshots and features.

   (v1.1: Preserve a3 in hdv_rw, bounce Alt-RAM/FastRAM above phystop $42E,
    validate MBR types, remove unsafe Mshrink in prg_entry, fix SDPART
    sectorsPerFat on >511 MB FAT16, remount remaining targets on [D].)
