;
; HDACSIST v1.2 - ACSI SD/Hard Disk driver for Atari ST/STe/Mega ST/Mega STe/TT (ACSI DMA bus)
;
; Key Features:
;  - Standard Atari TOS / GEMDOS compatible hard disk driver (_drvbits C:..P:,
;    hdv_bpb, hdv_rw, hdv_mediach, and automatic _bufl BCB expansion; auto-detects
;    EmuTOS vs Atari TOS and scales logical sector sizes for large FAT16 volumes)
;  - Built-in Atari TOS 1.00 / 1.02 stability fixes: expands the 64-byte GEMDOS
;    folder/OFD pool (+200 blocks for 40-folder bug), masks bogus Dfree ($36)
;    sign-extension on TRAP #1, and retries cold-boot TEST UNIT READY up to 400 ms
;  - Multi-target ACSI bus discovery across IDs 0..7 (supports ACSI2STM,
;    UltraSatan, and multi-slot ACSI devices; mounts up to 14 partitions C:..P:)
;  - Dual boot support: runs from AUTO\HDACSIST.PRG or as an ACSI DMA boot driver
;    installed on sector 0 + reserved sectors via INSTALL.PRG (boot ID gets C:)
;  - Supports PC-style MBR (FAT12/FAT16 partitions) and superfloppy (unpartitioned)
;    media with 6-byte ACSI ($08/$0A) and ICD extended 10-byte SCSI ($1F+$25/$28/$2A)
;    commands for >1 GB drives (LBA >= $200000)
;  - High-speed word-aligned ST-RAM DMA (up to 128 sectors/chunk) with 512-byte
;    bounce buffer for odd/FastRAM transfers and flock ($43E) / MFP _IRQ locking
;  - Resident SD_API_Table at -14(hdv_bpb) for SDPART.PRG / INSTALL.PRG
;    including live multi-target switching (SD_SelectTarget)
;
; Copyright (c) 2020 Orion_ (original sdextjoy.s driver framework, MBR/BPB & BIOS hooks)
; Copyright (c) 2026 Ninjabuffy (modified for ACSI DMA, multi-target scan, large FAT16 & TOS fixes)
;
; Based on sdextjoy.s by Orion_ (April / May / August / September 2020),
; modified in 2026 by Ninjabuffy to use the Atari ACSI DMA bus instead of
; bit-banged SPI over the extended joystick port.
;
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;========================================>

; Atari ST ACSI / DMA / MFP hardware registers & TOS system variables
FLOCK				equ	$43E		; Floppy VBL lock (word)
HZ_200				equ	$4BA		; 200 Hz system tick counter (long)

DMA_DATA			equ	$FFFF8604	; DMA Data / Sector Count
DMA_CTRL			equ	$FFFF8606	; DMA Mode / Status
DMA_BASE_H			equ	$FFFF8609	; DMA Base Address High (byte)
DMA_BASE_M			equ	$FFFF860B	; DMA Base Address Mid (byte)
DMA_BASE_L			equ	$FFFF860D	; DMA Base Address Low (byte)
GPIP_MFP			equ	$FFFFFA01	; MFP GPIP register
ACSI_IRQ_BIT			equ	5		; Active-low ACSI _IRQ on bit 5

; Target discovery configuration: -1 = auto-scan IDs 0..7, or 0..7 = fixed ID
ACSI_TARGET_ID			equ	-1
ACSI_MAX_CHUNK			equ	128		; Max sectors per single DMA xfer
ACSI_CMD_TIMEOUT		equ	20		; 100 ms (20 * 5 ms) per cmd byte
ACSI_DMA_TIMEOUT		equ	1000		; 5000 ms for DMA + status phase

mbr_partition_offset		equ	446
mbr_partition_next		equ	16
mbr_n_partitions		equ	4
MAX_MOUNTED_PARTS		equ	14		; TOS drives C:..P: across all targets

mbr_boot_type_b			equ	0
mbr_firstSector_l		equ	8
mbr_totalSectors_l		equ	12
mbr_magic_word_w		equ	510

bpb_bytesPerSector_w		equ	11
bpb_sectorsPerCluster_b		equ	13
bpb_reservedSectorCount_w	equ	14
bpb_fatCount_b			equ	16
bpb_rootDirEntryCount_w		equ	17
bpb_totalSectors16_w		equ	19
bpb_mediaType_b			equ	21
bpb_sectorsPerFat16_w		equ	22
bpb_sectorsPerTrtack_w		equ	24
bpb_headCount_w			equ	26
bpb_totalSectors32_l		equ	32
bpb_size			equ	9
bpb_size_b			equ	(bpb_size*2)

MAX_FAT16_CLUSTERS		equ	65524
MAX_FAT12_CLUSTERS		equ	4084

INSTALL_MARKER			equ	$CEDBCEDB

; Logical sector scaling / BIOS BCB extension (Atari TOS 1.x/2.x >32MB support)
MAX_BCB_SIZE_1MB		equ	16384	; 4 * 16KB = 64KB (supports up to 510MB signed)
MAX_BCB_SIZE_512K		equ	8192	; 4 * 8KB  = 32KB (for 512KB machines)
MAX_BCB_POOL_BYTES		equ	(MAX_BCB_SIZE_1MB*4)
BCB_STRUCT_SIZE			equ	20	; Atari TOS BCB struct size

; TOS 1.00 / 1.02 GEMDOS folder/OFD pool extension (fixes "40-folder bug")
FOLDR_BLOCKS			equ	200	; 200 extra 64-byte root[4] blocks
FOLDR_SLOT_SIZE			equ	66	; 2-byte block header (4) + 64-byte payload
FOLDR_POOL_BYTES		equ	(FOLDR_BLOCKS*FOLDR_SLOT_SIZE)
PART_INFO_SIZE			equ	32	; Per-partition logical->physical mapping struct
p_scale_w			equ	0
p_shift_w			equ	2
p_l_fat2_l			equ	4
p_l_root_l			equ	8
p_l_data_l			equ	12
p_fat1_off_w			equ	16
p_fat1_end_w			equ	18
p_fat2_off_w			equ	20
p_fat2_end_w			equ	22
p_root_off_w			equ	24
p_root_end_w			equ	26
p_data_off_l			equ	28

; sd_err codes (API table +42 -> pointer to byte)
ERR_NONE			equ	0
ERR_CMD0			equ	1	; no ACSI target responded during scan
ERR_CMD8			equ	2	; reserved
ERR_ACMD41			equ	3	; ACSI target found but unit/medium not ready
ERR_CMD58			equ	4	; reserved
ERR_MBR_READ			equ	5	; could not read sector 0
ERR_NO_FAT			equ	6	; no MBR and sector 0 is not a FAT16 boot sector
ERR_NO_PART			equ	7	; MBR found but no valid FAT12/16 partition

	section	text

start:
	bra.s	prg_entry		; +0: Normal GEMDOS PRG launch (2 bytes)
	nop				; +2: Pad so boot_entry is fixed at +4
	bra.w	boot_entry		; +4: DMA boot sector launch (Supervisor)

prg_entry:
	; Hold Alternate during boot to skip loading the driver completely
	move.w	#-1,-(a7)
	move.w	#11,-(a7)		; BIOS Kbshift(-1)
	trap	#13
	addq.l	#4,a7
	btst.l	#3,d0			; Bit 3 = Alternate
	beq.s	.prg_run
	lea	MsgAltSkipped,a0
	bsr	PrintMsg
	clr.w	-(a7)			; Pterm0
	trap	#1
.prg_run:
	move.l	4(a7),a0
	move.l	24(a0),a1
	adda.l	28(a0),a1
	suba.l	a0,a1
	move.l	a1,GlobalProgramSize

	lea	MsgInit,a0
	bsr	PrintMsg

	clr.l	-(a7)
	move.w	#$20,-(a7)		; Super(NULL)
	trap	#1
	addq.l	#6,a7
	move.l	d0,sstack

	move.l	$472.w,a0		; hdv_bpb
	cmpi.l	#INSTALL_MARKER,-10(a0)
	bne.s	.notInstalled

	lea	MsgAlreadyInstalled,a0
	bsr	PrintMsg

	move.l	sstack,-(a7)
	move.w	#$20,-(a7)
	trap	#1
	addq.l	#6,a7

	clr.w	-(a7)			; Pterm0
	trap	#1

.notInstalled:
	bsr	InitDriverCommon

	; Restore User Mode and stay resident
	move.l	sstack,-(a7)
	move.w	#$20,-(a7)
	trap	#1
	addq.l	#6,a7

	clr.w	-(a7)
	move.l	GlobalProgramSize,-(a7)
	move.w	#$31,-(a7)		; Ptermres
	trap	#1

;----------------------------------------
; boot_entry: Called from Stage-1 DMA boot sector at TEXT+4.
; Input: d7.b = (boot_acsi_id << 5). Supervisor mode already active.
;----------------------------------------
boot_entry:
	movem.l	d1-d7/a0-a6,-(a7)
	; Defense-in-depth: if Alternate is held, abort without installing
	move.w	#-1,-(a7)
	move.w	#11,-(a7)		; BIOS Kbshift(-1)
	trap	#13
	addq.l	#4,a7
	btst.l	#3,d0			; Bit 3 = Alternate
	beq.s	.boot_proceed
	lea	MsgAltSkipped,a0
	bsr	PrintMsg
	movem.l	(a7)+,d1-d7/a0-a6
	rts

.boot_proceed:
	andi.b	#$E0,d7
	ori.b	#$01,d7
	move.b	d7,boot_pref

	lea	MsgInit,a0
	bsr	PrintMsg

	move.l	$472.w,a0		; hdv_bpb
	cmpi.l	#INSTALL_MARKER,-10(a0)
	bne.s	.boot_install

	lea	MsgAlreadyInstalled,a0
	bsr	PrintMsg
	movem.l	(a7)+,d1-d7/a0-a6
	rts

.boot_install:
	bsr.s	InitDriverCommon
	tst.l	d0
	beq.s	.boot_done
	move.w	sd_drive,d0
	bmi.s	.boot_done

	; Hold Control to keep C:..P: mounted while leaving _bootdev on A: (floppy/Gotek)
	move.w	d0,d6
	move.w	#-1,-(a7)
	move.w	#11,-(a7)		; BIOS Kbshift(-1)
	trap	#13
	addq.l	#4,a7
	btst.l	#2,d0			; Bit 2 = Control
	beq.s	.set_hd_boot
	lea	MsgCtrlBootA,a0
	bsr	PrintMsg
	bra.s	.boot_done

.set_hd_boot:
	move.w	d6,$446.w		; _bootdev = first mounted SD drive (C:)
	move.w	d6,-(a7)
	move.w	#$0E,-(a7)		; GEMDOS Dsetdrv
	trap	#1
	addq.l	#4,a7
.boot_done:
	movem.l	(a7)+,d1-d7/a0-a6
	rts

;----------------------------------------
; InitDriverCommon: Shared initialization for PRG and DMA boot modes.
; Returns d0.l = mounted partition count. Supervisor mode required.
;----------------------------------------
InitDriverCommon:
	; Detect EmuTOS vs Atari TOS and size BIOS cache buffers (_bufl) accordingly
	clr.b	is_emutos
	move.w	#1,max_log_scale
	movea.l	$4F2.w,a0		; _sysbase -> OSHEADER
	movea.l	8(a0),a1		; os_beg
	cmpi.l	#'ETOS',$2C(a1)		; EmuTOS magic in OSHEADER?
	bne.s	.atari_tos
	move.b	#1,is_emutos
	subi.l	#MAX_BCB_POOL_BYTES,GlobalProgramSize
	bra.s	.os_bcb_done
.atari_tos:
	move.w	#16,max_log_scale	; 8KB BCBs (32KB) for 512KB machines
	cmpi.l	#$100000,$42E.w		; phystop >= 1MB?
	bcs.s	.bcb_512k
	move.w	#32,max_log_scale	; 16KB BCBs (64KB) for >=1MB machines
	bra.s	.bcb_install
.bcb_512k:
	subi.l	#(MAX_BCB_POOL_BYTES/2),GlobalProgramSize
.bcb_install:
	bsr	InstallBigBCBs
.os_bcb_done:
	bsr	InstallEarlyTosFixes

	; Initialize all drive slots to -1 (unassigned)
	lea	sd_drive,a0
	moveq	#MAX_MOUNTED_PARTS-1,d0
.clr_drv_init:
	move.w	#-1,(a0)+
	dbra	d0,.clr_drv_init

	; Hook BIOS vectors immediately so ACC/PRG can locate driver
	bsr	HookupXbiosVectors

	; Mount card at boot
	move.b	#1,boot_verbose
	bsr	SD_Mount
	clr.b	boot_verbose
	rts

;----------------------------------------
; InstallBigBCBs: Replace Atari TOS _bufl[0..1] chains with 4 larger BCBs
; (2 FAT/DIR + 2 DATA) sized to max_log_scale * 512 bytes.
; Clobbers d0-d1/a0-a1. Supervisor mode required.
;----------------------------------------
InstallBigBCBs:
	moveq	#0,d1
	move.w	max_log_scale,d1
	moveq	#9,d0
	lsl.l	d0,d1			; d1 = bytes per logical sector buffer

	lea	bcb_pool,a0
	lea	bcb_data,a1

	; Clear 4 * 20 = 80 bytes
	moveq	#(4*BCB_STRUCT_SIZE/4)-1,d0
.clr_bcb:
	clr.l	(a0)+
	dbra	d0,.clr_bcb

	lea	bcb_pool,a0
	; FAT/DIR BCB #0 (+0)
	lea	BCB_STRUCT_SIZE(a0),a1
	move.l	a1,(a0)			; b_link -> FAT #1
	move.w	#-1,4(a0)		; b_bufdrv = -1
	lea	bcb_data,a1
	move.l	a1,16(a0)		; b_bufr = bcb_data + 0

	; FAT/DIR BCB #1 (+20)
	lea	BCB_STRUCT_SIZE(a0),a0
	move.w	#-1,4(a0)		; b_link = 0, b_bufdrv = -1
	adda.l	d1,a1
	move.l	a1,16(a0)		; b_bufr = bcb_data + 1*d1

	; DATA BCB #0 (+40)
	lea	BCB_STRUCT_SIZE(a0),a0
	lea	BCB_STRUCT_SIZE(a0),a1
	move.l	a1,(a0)			; b_link -> DATA #1
	move.w	#-1,4(a0)
	lea	bcb_data,a1
	adda.l	d1,a1
	adda.l	d1,a1
	move.l	a1,16(a0)		; b_bufr = bcb_data + 2*d1

	; DATA BCB #1 (+60)
	lea	BCB_STRUCT_SIZE(a0),a0
	move.w	#-1,4(a0)		; b_link = 0, b_bufdrv = -1
	adda.l	d1,a1
	move.l	a1,16(a0)		; b_bufr = bcb_data + 3*d1

	lea	bcb_pool,a0
	move.l	a0,$4B2.w		; _bufl[0] = FAT/DIR chain
	lea	(2*BCB_STRUCT_SIZE)(a0),a0
	move.l	a0,$4B6.w		; _bufl[1] = DATA chain
	rts

;----------------------------------------
; InstallEarlyTosFixes
; Checks OS version via _sysbase ($4F2.w).
; If Atari TOS <= 1.02 ($0102) and not EmuTOS:
;   1. Expands GEMDOS 64-byte DND/OFD pool (40-folder bug fix)
;   2. Patches TRAP #1 Dfree ($36) to clear bogus $FFFF sign-extension
;----------------------------------------
InstallEarlyTosFixes:
	movem.l	d0-d2/a0-a4,-(a7)
	movea.l	$4F2.w,a0		; _sysbase -> OSHEADER copy
	movea.l	8(a0),a0		; os_beg -> ROM OSHEADER
	cmpi.l	#'ETOS',$2C(a0)		; skip EmuTOS
	beq.s	.early_done
	move.w	2(a0),d0		; os_version (BCD)
	cmpi.w	#$0102,d0		; Atari TOS 1.00 or 1.02?
	bhi.s	.early_done

	bsr.s	InstallFoldrPool
	bsr	InstallTrap1Fix

.early_done:
	movem.l	(a7)+,d0-d2/a0-a4
	rts

;----------------------------------------
; InstallFoldrPool
; Links FOLDR_BLOCKS 64-byte blocks into GEMDOS root[4] (+16 of _root).
; Entry: a0 = ROM OSHEADER, d0.w = os_version (<= $0102)
;----------------------------------------
InstallFoldrPool:
	cmpi.w	#$0102,d0
	blo.s	.tos100_root
	movea.l	$20(a0),a1		; TOS 1.02 os_root pointer
	bra.s	.have_root
.tos100_root:
	move.w	$1C(a0),d1		; os_conf (bits 1..7 = country)
	lsr.w	#1,d1
	andi.w	#$007F,d1
	cmpi.w	#4,d1			; Spain?
	bne.s	.tos100_std
	lea	$00007E0A,a1		; Spanish TOS 1.00 _root
	bra.s	.have_root
.tos100_std:
	lea	$000056FA,a1		; US/UK/DE/FR/SG/DK/FI TOS 1.00 _root
.have_root:
	cmpa.l	#$00000800,a1		; sanity check _root address
	blo.s	.foldr_done
	cmpa.l	#$00040000,a1
	bhs.s	.foldr_done

	lea	foldr_pool,a2
	movea.l	16(a1),a3		; existing root[4] head
	move.w	#(FOLDR_BLOCKS-1),d2
.foldr_loop:
	move.w	#4,(a2)+		; block size index = 4 (checked by xmfreblk)
	move.l	a3,(a2)			; o_link -> previous free block payload
	movea.l	a2,a3
	lea	(FOLDR_SLOT_SIZE-2)(a2),a2
	dbra	d2,.foldr_loop
	move.l	a3,16(a1)		; update root[4]
.foldr_done:
	rts

;========================================>
; Public API Table & Routines
; Located via pointer at -14(hdv_bpb)
; All API calls must be made in supervisor mode.
;

SD_API_Table:
	dc.l	INSTALL_MARKER		; +0: Magic
	dc.w	$0109			; +4: API ABI revision ($0109 table layout)
	dc.l	SD_Mount		; +6: Mount / Remount cards -> d0.l = partition count
	dc.l	SD_Unmount		; +10: Unmount all SD drives -> d0.l = 0
	dc.l	SD_ReadData		; +14: d0=sector, d1=count, a0=buf -> d0.l
	dc.l	SD_WriteData		; +18: d0=sector, d1=count, a0=buf -> d0.l
	dc.l	SD_ReadCapacity		; +22: -> d0.l = total sectors (0 on error)
	dc.l	sd_drive		; +26: Pointer to MAX_MOUNTED_PARTS words of drive numbers
	dc.l	sd_first_sector		; +30: Pointer to MAX_MOUNTED_PARTS longs of partition starts
	dc.l	sd_good_partition	; +34: Pointer to MAX_MOUNTED_PARTS bytes of active flags
	dc.l	sd_type			; +38: Pointer to unit type byte (0=none, 3=ACSI ready)
	dc.l	sd_err			; +42: Pointer to last error byte (ERR_* above), v1.5+
	dc.l	sd_last_r1		; +46: Pointer to last ACSI status byte, v1.6+
	dc.l	SD_SelectTarget		; +50: v1.9+: d0.w=-1 scan mask (d0=mask,d1=cur) or 0..7 select

;----------------------------------------
; SD_Unmount: Unmounts active SD partitions from _drvbits
; Preserves sd_type so subsequent raw sector I/O (e.g. sdpart.s DeleteAll) works.
;----------------------------------------
SD_Unmount:
	movem.l	d1-d2/a0-a2,-(a7)
	lea	sd_drive,a0
	lea	sd_good_partition,a1
	lea	sd_mediach_flag,a2
	move.l	$4C2.w,d0		; _drvbits
	moveq	#MAX_MOUNTED_PARTS-1,d2
.unloop:
	clr.b	(a1)+
	move.b	#2,(a2)+		; Mark media changed
	move.w	(a0),d1
	bmi.s	.skip
	bclr.l	d1,d0			; Remove drive bit from _drvbits
	move.w	#-1,(a0)
.skip:
	addq.l	#2,a0
	dbra	d2,.unloop
	move.l	d0,$4C2.w
	bsr	UpdatePunInfo
	movem.l	(a7)+,d1-d2/a0-a2
	moveq	#0,d0
	rts

;----------------------------------------
; SD_Mount: Scans ready ACSI targets (0..7 or boot_pref first), parses MBR/BPBs,
;           mounts partitions across all ready card slots into C:..P: (_drvbits).
; Returns d0.l = number of mounted partitions (0 if failed, see sd_err)
;----------------------------------------
SD_Mount:
	movem.l	d1-d7/a0-a6,-(a7)

	bsr	SD_Unmount		; Reset previous state
	clr.b	sd_err
	clr.b	sd_type
	clr.b	probe_saw_dev
	clr.b	mount_saw_ready
	move.b	#-1,mount_first_tgt
	move.b	#-1,mount_boot_id

	lea	sd_good_partition,a0
	moveq	#MAX_MOUNTED_PARTS-1,d0
.clr_gp:
	clr.b	(a0)+
	dbra	d0,.clr_gp

	moveq	#0,d6			; d6.w = total mounted partition slots

	IFGE	ACSI_TARGET_ID
	moveq	#ACSI_TARGET_ID,d4
	bsr.s	.scan_one_target
	ELSE
	btst.b	#0,boot_pref
	beq.s	.no_boot_pref
	moveq	#0,d4
	move.b	boot_pref,d4
	andi.b	#$E0,d4
	lsr.b	#5,d4
	move.b	d4,mount_boot_id
	bsr.s	.scan_one_target
.no_boot_pref:
	moveq	#0,d4
.scan_loop:
	cmp.b	mount_boot_id,d4
	beq.s	.next_id		; Already probed boot target first
	bsr.s	.scan_one_target
.next_id:
	addq.w	#1,d4
	cmpi.w	#8,d4
	blo.s	.scan_loop
	ENDC

	; Check overall scan result across all targets
	tst.b	mount_saw_ready
	bne.s	.have_ready
	clr.b	sd_type
	tst.b	probe_saw_dev
	bne.s	.err_not_ready
	move.b	#ERR_CMD0,sd_err	; No ACSI device responded
	bra	.mount_fail
.err_not_ready:
	move.b	#ERR_ACMD41,sd_err	; Target responded, no medium ready
	bra	.mount_fail

.have_ready:
	move.b	mount_first_tgt,acsi_target
	move.b	#3,sd_type
	tst.w	d6
	bne.s	.have_parts
	move.b	#ERR_NO_PART,sd_err	; Ready card(s) found, no valid FAT partition
	bra	.mount_fail

.have_parts:
	tst.b	boot_verbose
	beq	.AssignDrives
	lea	MsgOK,a0
	bsr	PrintMsg
	bra	.AssignDrives

; Subroutine local to SD_Mount: probe target d4.b (0..7) and mount its partitions
.scan_one_target:
	cmpi.w	#MAX_MOUNTED_PARTS,d6
	bhs	.scan_ret

	move.b	d4,d0
	lsl.b	#5,d0
	move.b	d0,acsi_target
	bsr	SD_ProbeUnit
	tst.l	d0
	bne	.scan_ret

	move.b	#1,mount_saw_ready
	move.b	#3,sd_type
	tst.b	mount_first_tgt
	bpl.s	.first_saved
	move.b	acsi_target,mount_first_tgt
.first_saved:
	moveq	#0,d0
	moveq	#1,d1
	lea	data,a0
	bsr	SD_ReadData
	tst.l	d0
	bne	.scan_ret

	lea	data,a1
	lea	mbr_magic_word_w(a1),a0
	bsr	LE_2_BE_W
	cmpi.w	#$AA55,d0
	bne	.tgt_superfloppy

	clr.l	ext_base_lba
	lea	mbr_partition_offset(a1),a1
	lea	cur_first_sector,a2
	moveq	#0,d2			; valid primary partition count in MBR
	moveq	#mbr_n_partitions-1,d1
.checkPartition:
	clr.l	(a2)
	bsr	.check_part_entry
	tst.l	d0
	beq.s	.partfail
	cmpi.b	#$05,d3			; $05 = DOS Extended CHS
	beq.s	.found_ext
	cmpi.b	#$0F,d3			; $0F = DOS Extended LBA
	beq.s	.found_ext

	move.l	d0,(a2)
	addq.w	#1,d2
	bra.s	.partfail

.found_ext:
	tst.l	ext_base_lba		; record first extended partition container
	bne.s	.partfail
	move.l	d0,ext_base_lba

.partfail:
	addq.l	#4,a2
	lea	mbr_partition_next(a1),a1
	dbra	d1,.checkPartition

	tst.w	d2
	bne.s	.mount_primaries
	tst.l	ext_base_lba
	beq	.tgt_superfloppy
	bra.s	.scan_extended		; MBR has extended partition only (0 primary)

.mount_primaries:
	lea	cur_first_sector,a3
	moveq	#mbr_n_partitions-1,d5
.readBPBs:
	cmpi.w	#MAX_MOUNTED_PARTS,d6
	bhs	.scan_ret
	move.l	(a3)+,d7
	beq.s	.nextPart
	bsr	.try_mount_lba
.nextPart:
	dbra	d5,.readBPBs

.scan_extended:
	move.l	ext_base_lba,d0
	beq	.scan_ret
	moveq	#31,d5			; cap EBR chain at 32 hops against corrupt loops
.ebr_loop:
	cmpi.w	#MAX_MOUNTED_PARTS,d6
	bhs	.scan_ret
	move.l	d0,cur_ebr_lba
	clr.l	next_ebr_lba

	moveq	#1,d1
	lea	data,a0
	bsr	SD_ReadData
	tst.l	d0
	bne	.scan_ret

	lea	data,a1
	lea	mbr_magic_word_w(a1),a0
	bsr	LE_2_BE_W
	cmpi.w	#$AA55,d0
	bne	.scan_ret

	; Entry 1 -> next EBR LBA (relative to ext_base_lba); extract before data is overwritten
	lea	mbr_partition_offset+mbr_partition_next(a1),a1
	bsr	.check_part_entry
	tst.l	d0
	beq.s	.ebr_entry0
	cmpi.b	#$05,d3
	beq.s	.ebr_has_next
	cmpi.b	#$0F,d3
	bne.s	.ebr_entry0
.ebr_has_next:
	add.l	ext_base_lba,d0
	bcs.s	.ebr_entry0		; overflow guard
	cmp.l	cur_ebr_lba,d0
	beq.s	.ebr_entry0		; self-loop guard
	move.l	d0,next_ebr_lba

.ebr_entry0:
	; Entry 0 -> logical partition LBA (relative to cur_ebr_lba)
	lea	data+mbr_partition_offset,a1
	bsr.s	.check_part_entry
	tst.l	d0
	beq.s	.ebr_next
	cmpi.b	#$05,d3
	beq.s	.ebr_next
	cmpi.b	#$0F,d3
	beq.s	.ebr_next
	add.l	cur_ebr_lba,d0
	bcs.s	.ebr_next		; overflow guard
	move.l	d0,d7
	bsr.s	.try_mount_lba

.ebr_next:
	move.l	next_ebr_lba,d0
	beq.s	.scan_ret
	dbra	d5,.ebr_loop
	rts

.tgt_superfloppy:
	cmpi.w	#MAX_MOUNTED_PARTS,d6
	bhs.s	.scan_ret
	moveq	#0,d7
	bsr.s	.record_bpb_in_data
.scan_ret:
	rts

; Helper local to .scan_one_target:
; Validate 16-byte MBR/EBR partition entry at a1.
; Returns d0.l = relative start LBA (0 if invalid/empty), d3.b = partition type. Clobbers a0.
.check_part_entry:
	lea	mbr_totalSectors_l(a1),a0
	bsr	LE_2_BE_L
	cmpi.l	#100,d0
	blo.s	.cpe_bad
	move.b	mbr_boot_type_b(a1),d0
	andi.b	#$7F,d0
	bne.s	.cpe_bad
	move.b	4(a1),d3
	beq.s	.cpe_bad
	lea	mbr_firstSector_l(a1),a0
	bsr	LE_2_BE_L
	rts
.cpe_bad:
	moveq	#0,d0
	rts

; Helper local to .scan_one_target:
; Read boot sector at d7.l into data and mount if valid FAT12/FAT16 BPB.
; Preserves d4/d5/a3; updates d6 on mount.
.try_mount_lba:
	move.l	d7,d0
	moveq	#1,d1
	lea	data,a0
	bsr	SD_ReadData
	tst.l	d0
	bne.s	.tml_done
.record_bpb_in_data:
	move.w	d6,d0
	mulu.w	#bpb_size_b,d0
	lea	tos_bpb,a4
	adda.w	d0,a4
	bsr	CheckBPB
	tst.b	d0
	beq.s	.tml_done
	move.w	d6,d0
	lsl.w	#2,d0
	lea	sd_first_sector,a0
	move.l	d7,0(a0,d0.w)
	lea	sd_good_partition,a0
	move.b	#1,0(a0,d6.w)
	lea	part_acsi_id,a0
	move.b	acsi_target,0(a0,d6.w)
	addq.w	#1,d6
.tml_done:
	rts

.AssignDrives:
	lea	sd_drive,a0
	lea	sd_good_partition,a1
	lea	sd_mediach_flag,a2

	move.l	$4C2.w,d0		; _drvbits
	moveq	#2,d1			; Assign starting from C: (2)
	moveq	#0,d6			; Count actually assigned drives
	moveq	#MAX_MOUNTED_PARTS-1,d2
.next_part:
	tst.b	(a1)+
	bne.s	.next_drive
	move.w	#-1,(a0)+
	clr.b	(a2)+
	bra.s	.nxt
.next_drive:
	cmpi.w	#16,d1			; TOS supports A:..P: (0..15)
	bhs.s	.no_drive_left
	btst.l	d1,d0
	beq.s	.drive_available
	addq.w	#1,d1
	bra.s	.next_drive
.no_drive_left:
	move.w	#-1,(a0)+
	clr.b	-1(a1)
	clr.b	(a2)+
	bra.s	.nxt
.drive_available:
	move.w	d1,(a0)+
	bset.l	d1,d0
	move.b	#2,(a2)+		; Set MEDIAMAYBECHANGED (2)
	addq.w	#1,d1
	addq.w	#1,d6
.nxt:
	dbra	d2,.next_part

	move.l	d0,$4C2.w
	bsr	UpdatePunInfo

	tst.b	boot_verbose
	beq.s	.done_mount
	lea	MsgHook,a0
	bsr	PrintMsg
.done_mount:
	moveq	#0,d0
	move.w	d6,d0
	movem.l	(a7)+,d1-d7/a0-a6
	rts

.mount_fail:
	tst.b	boot_verbose
	beq.s	.silent_fail
	lea	MsgErr,a0
	bsr	PrintMsg
.silent_fail:
	clr.b	sd_type
	moveq	#0,d0
	movem.l	(a7)+,d1-d7/a0-a6
	rts

;----------------------------------------
; SD_ReadCapacity: Issue ICD READ CAPACITY(10) ($1F + $25) + FIFO flush
; Returns d0.l = total sectors (0 on error)
;----------------------------------------
SD_ReadCapacity:
	movem.l	d1-d5/a0-a3,-(a7)
	tst.b	sd_type
	bne.s	.inited
	bsr	SD_Init
	tst.b	d0
	bne.s	.cap_fail
.inited:
	lea	dma_bounce_buf,a1
	clr.l	(a1)
	clr.l	4(a1)

	lea	CMD_READ_CAPACITY,a0
	moveq	#11,d0			; $1F + 10-byte CDB
	moveq	#1,d1			; DMA sector count = 1
	move.w	#$0400,d2		; DMA read, keep flock locked for FIFO flush
	bsr	ACSI_Transfer
	tst.l	d0
	bne.s	.cap_fail

	; Flush the 16-byte Atari DMA FIFO (READ CAPACITY only sends 8 bytes)
	; using a chained INQUIRY without resetting the FIFO or DMA address.
	lea	CMD_INQUIRY,a0
	moveq	#6,d0
	moveq	#1,d1
	move.w	#$0200,d2		; bit 9: chain DMA, release flock on exit
	bsr	ACSI_Transfer
	tst.l	d0
	bne.s	.cap_fail

	lea	dma_bounce_buf,a0
	cmpi.l	#512,4(a0)		; verify 512-byte sector size
	bne.s	.cap_fail
	move.l	(a0),d0			; big-endian Last LBA
	addq.l	#1,d0			; total_sectors = Last LBA + 1
	beq.s	.cap_fail		; guard against $FFFFFFFF overflow
	movem.l	(a7)+,d1-d5/a0-a3
	rts

.cap_fail:
	moveq	#0,d0
	movem.l	(a7)+,d1-d5/a0-a3
	rts

;-------------------------------

CheckBPB:
	movem.l	d1-d7/a0-a6,-(a7)
	tst.b	boot_verbose
	beq.s	.no_bpb_msg
	lea	MsgBPB,a0
	bsr	PrintMsg
.no_bpb_msg:

	lea	data,a1

	lea	mbr_magic_word_w(a1),a0
	bsr	LE_2_BE_W
	cmpi.w	#$AA55,d0
	bne	.BPBfail

	; Compute partition index 0..3 from a4 -> part_info pointer a3
	move.l	a4,d0
	subi.l	#tos_bpb,d0
	divu.w	#bpb_size_b,d0
	ext.l	d0
	lsl.l	#5,d0			; * PART_INFO_SIZE (32)
	lea	part_info,a3
	adda.l	d0,a3

	lea	bpb_bytesPerSector_w(a1),a0
	bsr	LE_2_BE_W
	cmpi.w	#512,d0			; Physical SD sector size must be 512
	bne	.BPBfail

	moveq	#0,d3
	move.b	bpb_sectorsPerCluster_b(a1),d3	; d3 = clsiz_phys
	beq	.BPBfail
	cmpi.w	#64,d3			; clsizb <= 32768 (fits 16-bit BPB.clsizb)
	bhi	.BPBfail
	move.w	d3,d1
	subq.w	#1,d1
	and.w	d3,d1			; power-of-2 check
	bne	.BPBfail

	moveq	#0,d0
	move.b	bpb_fatCount_b(a1),d0	; fat_count (1 or 2)
	beq	.BPBfail
	cmpi.w	#2,d0
	bhi	.BPBfail
	movea.w	d0,a5			; a5 = fat_count

	moveq	#0,d0
	lea	bpb_rootDirEntryCount_w(a1),a0
	bsr	LE_2_BE_W
	tst.w	d0
	beq	.BPBfail
	lsl.l	#5,d0
	addi.l	#511,d0
	moveq	#9,d1
	lsr.l	d1,d0
	move.w	d0,d5			; d5 = rdlen_phys

	lea	bpb_sectorsPerFat16_w(a1),a0
	bsr	LE_2_BE_W
	tst.w	d0
	beq	.BPBfail
	move.w	d0,d6			; d6 = fsiz_phys

	lea	bpb_reservedSectorCount_w(a1),a0
	bsr	LE_2_BE_W
	tst.w	d0
	beq	.BPBfail
	move.w	d0,d7			; d7 = resvd_phys

	moveq	#0,d0
	lea	bpb_totalSectors16_w(a1),a0
	bsr	LE_2_BE_W
	tst.w	d0
	bne.s	.tsect16
	lea	bpb_totalSectors32_l(a1),a0
	bsr	LE_2_BE_L
.tsect16:
	move.l	d0,d4			; d4 = total_phys

	; data_off_phys = resvd_phys + fat_count * fsiz_phys + rdlen_phys
	moveq	#0,d2
	move.w	a5,d2
	mulu.w	d6,d2
	moveq	#0,d0
	move.w	d7,d0
	add.l	d0,d2
	move.w	d5,d0
	add.l	d0,d2
	cmpi.l	#65535,d2		; metadata offsets stored as 16-bit unsigned words
	bhi	.BPBfail
	movea.l	d2,a6			; a6 = data_off_phys

	move.l	d4,d0
	sub.l	d2,d0
	bls	.BPBfail

	move.l	d3,-(a7)		; DivU32ByPowerOfTwo clobbers d2/d3
	move.w	d3,d1
	bsr	DivU32ByPowerOfTwo
	move.l	(a7)+,d3

	cmpi.l	#MAX_FAT16_CLUSTERS,d0
	ble.s	.checkFAT16

	lea	MsgF32,a0
	bra	.fail

.checkFAT16:
	move.l	d0,d4			; d4 = numcl

	; Choose smallest power-of-2 scale S in [1 .. min(max_log_scale, clsiz_phys)]
	; such that total_log <= 32760 (signed 16-bit recno safe).
	; Note: EmuTOS sets max_log_scale = 1, forcing S = 1.
	move.w	max_log_scale,d2
	cmp.w	d3,d2
	bls.s	.cap_ok
	move.w	d3,d2
.cap_ok:
	move.w	d2,-(a7)		; cap on stack
	moveq	#1,d0			; d0 = S
	moveq	#0,d1			; d1 = shift

.try_scale:
	bsr	.compute_scaled_layout	; returns total_log in d2.l
	tst.b	is_emutos
	bne.s	.scale_chosen
	cmpi.l	#32760,d2
	bls.s	.scale_chosen
	add.w	d0,d0
	addq.w	#1,d1
	cmp.w	(a7),d0
	bls.s	.try_scale

	; Fallback: try max allowed S (= cap) with unsigned < 65530 limit
	lsr.w	#1,d0
	subq.w	#1,d1
	bsr	.compute_scaled_layout
	cmpi.l	#65530,d2
	bls.s	.scale_chosen
	addq.l	#2,a7
	bra	.BPBfail

.scale_chosen:
	addq.l	#2,a7
	move.w	d0,p_scale_w(a3)
	move.w	d1,p_shift_w(a3)

	cmpi.w	#1,d0
	bne.s	.build_scaled
	move.w	d7,d2			; L_resvd = resvd_phys
	move.w	d6,-(a7)		; L_fsiz = fsiz_phys
	move.w	d5,-(a7)		; L_rdlen = rdlen_phys
	bra.s	.fill_structs
.build_scaled:
	move.w	d0,d2
	subq.w	#1,d2			; S - 1
	moveq	#0,d0
	move.w	d6,d0
	add.w	d2,d0
	lsr.w	d1,d0			; L_fsiz
	move.w	d0,-(a7)
	moveq	#0,d0
	move.w	d5,d0
	add.w	d2,d0
	lsr.w	d1,d0			; L_rdlen
	move.w	d0,-(a7)
	moveq	#1,d2			; L_resvd = 1

.fill_structs:
	; Stack: (sp)=L_rdlen.w, 2(sp)=L_fsiz.w; d1=shift, d2=L_resvd
	movea.l	a4,a2

	; recsiz = 512 << shift
	move.w	#512,d0
	lsl.w	d1,d0
	move.w	d0,(a2)+

	; clsiz = clsiz_phys >> shift
	move.w	d3,d0
	lsr.w	d1,d0
	move.w	d0,(a2)+

	; clsizb = clsiz_phys * 512
	move.w	d3,d0
	moveq	#9,d1
	lsl.w	d1,d0
	move.w	d0,(a2)+

	; rdlen = L_rdlen
	move.w	(a7),d0
	move.w	d0,(a2)+

	; fsiz = L_fsiz
	move.w	2(a7),d1
	move.w	d1,(a2)+

	; fatrec = L_resvd + (fat_count==2 ? L_fsiz : 0)
	cmpa.w	#2,a5
	bne.s	.one_fat_rec
	add.w	d1,d2
.one_fat_rec:
	move.w	d2,(a2)+
	moveq	#0,d0
	move.w	d2,d0
	move.l	d0,p_l_fat2_l(a3)

	; L_root_start = fatrec + L_fsiz
	add.w	d1,d2
	moveq	#0,d0
	move.w	d2,d0
	move.l	d0,p_l_root_l(a3)

	; datrec = L_root_start + L_rdlen
	add.w	(a7),d2
	move.w	d2,(a2)+
	moveq	#0,d0
	move.w	d2,d0
	move.l	d0,p_l_data_l(a3)

	addq.l	#4,a7

	; numcl & b_flags
	move.w	d4,(a2)+
	lea	MsgF16,a0
	moveq	#1,d1
	cmpi.l	#MAX_FAT12_CLUSTERS,d4
	bgt.s	.FAT16
	lea	MsgF12,a0
	moveq	#0,d1
.FAT16:
	cmpa.w	#1,a5
	bne.s	.flags_done
	ori.w	#2,d1			; B_1FAT
.flags_done:
	move.w	d1,(a2)

	; Populate physical region bounds in part_info(a3)
	move.w	d7,p_fat1_off_w(a3)
	move.w	d7,d0
	add.w	d6,d0
	move.w	d0,p_fat1_end_w(a3)
	cmpa.w	#2,a5
	beq.s	.two_fats_phys
	move.w	d7,p_fat2_off_w(a3)
	move.w	d0,p_fat2_end_w(a3)
	bra.s	.root_phys
.two_fats_phys:
	move.w	d0,p_fat2_off_w(a3)
	add.w	d6,d0
	move.w	d0,p_fat2_end_w(a3)
.root_phys:
	move.w	d0,p_root_off_w(a3)
	add.w	d5,d0
	move.w	d0,p_root_end_w(a3)
	move.l	a6,p_data_off_l(a3)

	tst.b	boot_verbose
	beq.s	.no_fmsg
	bsr	PrintMsg
.no_fmsg:
	movem.l	(a7)+,d1-d7/a0-a6
	moveq	#1,d0
	rts

.BPBfail:
	lea	MsgErr,a0
.fail:
	tst.b	boot_verbose
	beq.s	.no_emsg
	bsr	PrintMsg
.no_emsg:
	movem.l	(a7)+,d1-d7/a0-a6
	moveq	#0,d0
	rts

; Helper for CheckBPB:
; Input: d0=S, d1=shift, d3=clsiz_phys, d4.l=numcl, d5=rdlen_phys, d6=fsiz_phys,
;        a5=fat_count, a6=data_off_phys
; Output: d2.l = total_log. Preserves d0, d1, d3-d7, a0-a6.
.compute_scaled_layout:
	movem.l	d0-d1/d3,-(a7)
	cmpi.w	#1,d0
	bne.s	.csl_scaled
	move.l	a6,d2			; L_datrec = data_off_phys
	bra.s	.csl_data
.csl_scaled:
	move.w	d0,d3			; d3 = S (temp)
	subq.w	#1,d3			; d3 = S - 1
	moveq	#0,d2
	move.w	d6,d2
	add.w	d3,d2
	lsr.w	d1,d2			; L_fsiz
	cmpa.w	#2,a5
	bne.s	.csl_onefat
	add.w	d2,d2
.csl_onefat:
	addq.w	#1,d2			; + L_resvd(1)
	moveq	#0,d0
	move.w	d5,d0
	add.w	d3,d0
	lsr.w	d1,d0			; L_rdlen
	add.l	d0,d2			; d2 = L_datrec
	move.l	8(a7),d3		; restore clsiz_phys from stack
.csl_data:
	move.w	d3,d0
	lsr.w	d1,d0			; L_clsiz = clsiz_phys >> shift
	mulu.w	d4,d0			; numcl * L_clsiz (32-bit unsigned)
	add.l	d0,d2			; total_log
	movem.l	(a7)+,d0-d1/d3
	rts

;========================================>
; ACSI DMA Hardware Layer
;

;----------------------------------------
; ACSI_WaitIrq: Poll MFP GPIP bit 5 (active-low _IRQ) with _hz_200 timeout.
; Input:  d0.l = timeout in 200 Hz ticks (5 ms each)
; Output: d0.l = 0 (Z=1) on _IRQ asserted, -1 (Z=0) on timeout
; Clobbers d0. Supervisor mode required.
;----------------------------------------
ACSI_WaitIrq:
	movem.l	d1-d2,-(a7)
	move.l	HZ_200.w,d1		; start tick
.wait:
	btst.b	#ACSI_IRQ_BIT,GPIP_MFP.w
	beq.s	.ok
	move.l	HZ_200.w,d2
	sub.l	d1,d2			; wrap-safe elapsed ticks
	cmp.l	d0,d2
	blo.s	.wait
	moveq	#-1,d0
	movem.l	(a7)+,d1-d2
	rts
.ok:
	moveq	#0,d0
	movem.l	(a7)+,d1-d2
	rts

;----------------------------------------
; ACSI_Transfer: Execute an ACSI command with optional DMA and chaining.
; Input:
;   a0.l = command bytes (byte 0 has opcode/escape without target ID)
;   a1.l = ST-RAM DMA buffer (even, < $01000000; unused if d1.w==0 or chain)
;   d0.w = command byte count (>= 2, e.g. 6 or 11)
;   d1.w = DMA sector count (0 = no DMA, 1..128)
;   d2.w = flags:
;          bit 8 ($0100): 1 = write (RAM->ACSI), 0 = read (ACSI->RAM)
;          bit 9 ($0200): 1 = chain DMA (skip FIFO reset / addr / sector count)
;          bit 10 ($0400): 1 = keep FLOCK ($43E) locked on success (for chained flush)
; Output:
;   d0.l = ACSI status byte (0..255) on success, or -1 on timeout
;   sd_last_r1 = status byte (or $FF on timeout)
; Preserves d3-d7/a2-a6. Supervisor mode required.
;----------------------------------------
ACSI_Transfer:
	movem.l	d3-d6/a2-a3,-(a7)
	st	FLOCK.w			; Lock floppy VBL before touching DMA

	lea	DMA_DATA.w,a2
	lea	DMA_CTRL.w,a3
	move.w	d0,d5			; d5.w = cmd_len
	move.w	d1,d4			; d4.w = sector count
	move.w	d2,d6			; d6.w = flags

	tst.w	d4
	beq.s	.no_dma_init
	btst	#9,d6			; Chain DMA?
	bne.s	.no_dma_init

	; Toggle write/read bit to clear 16-byte DMA FIFO before sector count
	btst	#8,d6
	bne.s	.fifo_wr
	move.w	#$0190,(a3)		; Read: $0190 -> $0090
	move.w	#$0090,(a3)
	bra.s	.set_dma_addr
.fifo_wr:
	move.w	#$0090,(a3)		; Write: $0090 -> $0190
	move.w	#$0190,(a3)

.set_dma_addr:
	move.l	a1,d0
	move.b	d0,DMA_BASE_L.w
	lsr.l	#8,d0
	move.b	d0,DMA_BASE_M.w
	lsr.w	#8,d0
	move.b	d0,DMA_BASE_H.w

	move.w	d4,(a2)			; Set DMA sector count

.no_dma_init:
	move.w	d6,d3
	andi.w	#$0100,d3		; Keep R/W direction bit
	ori.w	#$0088,d3		; Assert A1=0 (first command byte)
	move.w	d3,(a3)

	moveq	#0,d0
	move.b	(a0)+,d0
	or.b	acsi_target,d0		; Inject ACSI target ID (bits 7..5)
	move.w	d0,(a2)			; Send byte 0

	ori.w	#$0002,d3		; Deassert A1 (A1=1 for remaining bytes)
	move.w	d3,(a3)

	moveq	#ACSI_CMD_TIMEOUT,d0
	bsr	ACSI_WaitIrq
	bne.s	.timeout

	subq.w	#3,d5			; Middle bytes: cmd_len - 2 (dbra count)
	bmi.s	.last_byte
.cmd_loop:
	moveq	#0,d0
	move.b	(a0)+,d0
	move.w	d0,(a2)
	moveq	#ACSI_CMD_TIMEOUT,d0
	bsr	ACSI_WaitIrq
	bne.s	.timeout
	dbra	d5,.cmd_loop

.last_byte:
	moveq	#0,d0
	move.b	(a0)+,d0
	move.w	d0,(a2)			; Send final command byte

	tst.w	d4
	beq.s	.wait_status
	andi.w	#$0100,d3		; Clear bit 7 ($0000/$0100) to enable DMA
	move.w	d3,(a3)

.wait_status:
	move.l	#ACSI_DMA_TIMEOUT,d0
	bsr	ACSI_WaitIrq
	bne.s	.timeout

	ori.w	#$008A,d3		; Disable DMA, select ACSI status byte
	move.w	d3,(a3)
	move.w	(a2),d0
	andi.l	#$000000FF,d0
	move.b	d0,sd_last_r1

	tst.l	d0
	bne.s	.unlock_flock
	btst	#10,d6			; Keep FLOCK locked only on status=0 for chained flush
	bne.s	.done_locked
.unlock_flock:
	clr.w	FLOCK.w
.done_locked:
	movem.l	(a7)+,d3-d6/a2-a3
	rts

.timeout:
	move.w	#$0080,(a3)		; Disable DMA on timeout
	move.b	#$FF,sd_last_r1
	moveq	#-1,d0
	clr.w	FLOCK.w			; Always unlock FLOCK on error
	movem.l	(a7)+,d3-d6/a2-a3
	rts

;----------------------------------------
; ACSI_RwChunk: Execute one DMA read or write chunk (1..128 sectors).
; Input:
;   d6.l = physical LBA
;   d3.w = sector count (1..128)
;   a0.l = ST-RAM buffer (word-aligned, < $01000000)
;   d7.w = $0000 (read) or $0100 (write)
; Output:
;   d0.l = 0 on success, -1 on error
; Preserves d3-d7/a3-a6 (clobbers d0-d2/a0-a2).
;----------------------------------------
ACSI_RwChunk:
	movea.l	a0,a1			; a1 = DMA buffer
	lea	acsi_cmd_buf,a2

	cmpi.l	#$200000,d6		; LBA >= $200000 requires ICD 10-byte cmd
	bhs.s	.use_10byte

	; 6-byte ACSI READ(6) $08 / WRITE(6) $0A
	moveq	#$08,d0
	tst.w	d7
	beq.s	.op6
	moveq	#$0A,d0
.op6:
	move.b	d0,(a2)+
	move.l	d6,d0
	swap	d0
	andi.b	#$1F,d0
	move.b	d0,(a2)+		; LBA[20:16]
	move.l	d6,d0
	lsr.w	#8,d0
	move.b	d0,(a2)+		; LBA[15:8]
	move.b	d6,(a2)+		; LBA[7:0]
	move.b	d3,(a2)+		; Sector count (1..128)
	clr.b	(a2)			; Control = 0
	moveq	#6,d0
	bra.s	.issue

.use_10byte:
	; ICD escape $1F + 10-byte SCSI READ(10) $28 / WRITE(10) $2A
	move.b	#$1F,(a2)+
	moveq	#$28,d0
	tst.w	d7
	beq.s	.op10
	moveq	#$2A,d0
.op10:
	move.b	d0,(a2)+
	clr.b	(a2)+			; LUN/flags = 0
	move.l	d6,d0
	rol.l	#8,d0
	move.b	d0,(a2)+		; LBA[31:24]
	rol.l	#8,d0
	move.b	d0,(a2)+		; LBA[23:16]
	rol.l	#8,d0
	move.b	d0,(a2)+		; LBA[15:8]
	rol.l	#8,d0
	move.b	d0,(a2)+		; LBA[7:0]
	clr.b	(a2)+			; Group = 0
	clr.b	(a2)+			; Count high = 0
	move.b	d3,(a2)+		; Count low (1..128)
	clr.b	(a2)			; Control = 0
	moveq	#11,d0

.issue:
	; d0.w = cmd_len, a1 = ST-RAM DMA buffer, d3.w = count, d7.w = flags.
	; Retry up to 2 times on non-timeout error status; clear CHECK CONDITION ($02)
	; with REQUEST SENSE ($03) into sense_buf so dma_bounce_buf stays intact.
	movem.l	d4-d5/a4,-(a7)
	move.w	d0,d4
	movea.l	a1,a4
	moveq	#2,d5
.retry_xfer:
	lea	acsi_cmd_buf,a0
	movea.l	a4,a1
	move.w	d4,d0
	move.w	d3,d1
	move.w	d7,d2
	bsr	ACSI_Transfer
	tst.l	d0
	beq.s	.chunk_ok
	bmi.s	.chunk_err		; Do not multi-retry 5 s bus timeout
	subq.w	#1,d5
	bmi.s	.chunk_err
	cmpi.b	#$02,d0			; CHECK CONDITION (e.g. UNIT ATTENTION)?
	bne.s	.retry_xfer
	bsr.s	SD_RequestSense
	bra.s	.retry_xfer
.chunk_ok:
	movem.l	(a7)+,d4-d5/a4
	moveq	#0,d0
	rts
.chunk_err:
	movem.l	(a7)+,d4-d5/a4
	moveq	#-1,d0
	rts

;----------------------------------------
; SD_RequestSense: Issue REQUEST SENSE ($03, 16 bytes) into dedicated sense_buf
; to clear UNIT ATTENTION / CHECK CONDITION without overwriting dma_bounce_buf.
; Clobbers d0-d2/a0-a1.
;----------------------------------------
SD_RequestSense:
	lea	CMD_REQUEST_SENSE,a0
	lea	sense_buf,a1
	moveq	#6,d0
	moveq	#1,d1			; 1 sector (drains 16-byte DMA FIFO burst)
	moveq	#0,d2			; DMA read
	bsr	ACSI_Transfer
	rts

;----------------------------------------
; SD_ReadData: Read physical sectors via ACSI DMA
; Input:  d0.l = start physical LBA, d1.w = sector count, a0.l = buffer
; Output: d0.l = 0 on success, -1 on error
;----------------------------------------
SD_ReadData:
	tst.w	d1
	bgt.s	.do_read
	moveq	#0,d0
	rts
.do_read:
	movem.l	d3-d7/a2-a4,-(a7)
	moveq	#0,d7			; d7.w = $0000 (DMA read)
	bra.s	ACSI_RwCommon

;----------------------------------------
; SD_WriteData: Write physical sectors via ACSI DMA
; Input:  d0.l = start physical LBA, d1.w = sector count, a0.l = buffer
; Output: d0.l = 0 on success, -1 on error
;----------------------------------------
SD_WriteData:
	tst.w	d1
	bgt.s	.do_write
	moveq	#0,d0
	rts
.do_write:
	movem.l	d3-d7/a2-a4,-(a7)
	move.w	#$0100,d7		; d7.w = $0100 (DMA write)

ACSI_RwCommon:
	move.l	d0,d6			; d6.l = current LBA
	move.w	d1,d5			; d5.w = remaining sectors
	movea.l	a0,a4			; a4.l = caller buffer

	; Auto-reinitialize if unmounted / not yet initialized
	tst.b	sd_type
	bne.s	.ready
	bsr	SD_Init
	tst.b	d0
	bne.s	.rw_fail
.ready:
	; Use 1-sector bounce path if caller buffer is odd or outside ST-RAM (>= phystop)
	move.l	a4,d0
	btst	#0,d0
	bne.s	.bounce_loop
	cmp.l	$42E.w,d0
	bhs.s	.bounce_loop

	; Direct ST-RAM word-aligned DMA path (chunks of up to 128 sectors)
.direct_loop:
	move.w	d5,d3
	cmpi.w	#ACSI_MAX_CHUNK,d3
	bls.s	.chunk_ok
	move.w	#ACSI_MAX_CHUNK,d3
.chunk_ok:
	movea.l	a4,a0
	bsr	ACSI_RwChunk
	tst.l	d0
	bne.s	.rw_fail

	moveq	#0,d0
	move.w	d3,d0
	add.l	d0,d6			; advance LBA
	moveq	#9,d1
	lsl.l	d1,d0
	adda.l	d0,a4			; advance buffer by chunk * 512
	sub.w	d3,d5
	bne.s	.direct_loop

.rw_ok:
	moveq	#0,d0
	movem.l	(a7)+,d3-d7/a2-a4
	rts

.rw_fail:
	moveq	#-1,d0
	movem.l	(a7)+,d3-d7/a2-a4
	rts

	; Bounce path: 1 sector at a time through dma_bounce_buf
.bounce_loop:
	moveq	#1,d3
	tst.w	d7
	beq.s	.bounce_read

	; Write: copy 512 bytes from caller (a4)+ to dma_bounce_buf, then DMA write
	lea	dma_bounce_buf,a0
	move.w	#511,d0
.cp_to_bounce:
	move.b	(a4)+,(a0)+
	dbra	d0,.cp_to_bounce

	lea	dma_bounce_buf,a0
	bsr	ACSI_RwChunk
	tst.l	d0
	bne.s	.rw_fail
	bra.s	.bounce_next

.bounce_read:
	; Read: DMA read 1 sector into dma_bounce_buf, then copy 512 bytes to (a4)+
	lea	dma_bounce_buf,a0
	bsr	ACSI_RwChunk
	tst.l	d0
	bne.s	.rw_fail

	lea	dma_bounce_buf,a0
	move.w	#511,d0
.cp_from_bounce:
	move.b	(a0)+,(a4)+
	dbra	d0,.cp_from_bounce

.bounce_next:
	addq.l	#1,d6
	subq.w	#1,d5
	bne.s	.bounce_loop
	bra.s	.rw_ok

;----------------------------------------
; SD_ProbeUnit: Test currently selected acsi_target with INQUIRY + TEST UNIT READY.
;----------------------------------------
; SD_ProbeUnit: Probe current acsi_target with INQUIRY + TEST UNIT READY.
; Sets probe_saw_dev = 1 if any target answered INQUIRY.
; Returns d0.l = 0 (Z=1) if ready, -1 (Z=0) otherwise. Preserves d3-d7/a2-a6.
;----------------------------------------
SD_ProbeUnit:
	movem.l	d3-d4,-(a7)
	moveq	#1,d4			; Allow 1 INQUIRY retry after CHECK CONDITION
.inq_try:
	lea	CMD_INQUIRY,a0
	lea	dma_bounce_buf,a1
	moveq	#6,d0
	moveq	#1,d1			; DMA sector count = 1 (32 bytes = 2x16 FIFO bursts)
	moveq	#0,d2			; DMA read
	bsr	ACSI_Transfer
	tst.l	d0
	bmi.s	.probe_fail		; timeout: no target at this ID
	move.b	#1,probe_saw_dev	; at least one ACSI device answered
	tst.l	d0
	beq.s	.inq_ok
	cmpi.b	#$02,d0			; CHECK CONDITION (UNIT ATTENTION)?
	bne.s	.probe_fail
	bsr	SD_RequestSense
	subq.w	#1,d4
	bpl.s	.inq_try
	bra.s	.probe_fail
.inq_ok:

	move.b	dma_bounce_buf,d0
	andi.b	#$1F,d0			; peripheral device type 0 = direct-access block dev
	bne.s	.probe_fail

	moveq	#19,d3			; up to 20 TEST UNIT READY attempts (400 ms max)
.tur_retry:
	lea	CMD_TEST_UNIT_READY,a0
	moveq	#6,d0
	moveq	#0,d1			; no DMA
	moveq	#0,d2
	bsr	ACSI_Transfer
	tst.l	d0
	beq.s	.probe_ok
	bmi.s	.probe_fail		; timeout
	cmpi.b	#$02,d0
	bne.s	.tur_wait
	bsr	SD_RequestSense		; clear UNIT ATTENTION before next TUR
.tur_wait:
	moveq	#4,d0			; 20 ms pause before retry (400 ms max)
	bsr	Delay
	dbra	d3,.tur_retry
.probe_fail:
	moveq	#-1,d0
.probe_ok:
	movem.l	(a7)+,d3-d4
	tst.l	d0
	rts

;----------------------------------------
; SD_Init: Discover ACSI2STM target (IDs 0..7 or fixed ACSI_TARGET_ID)
; using INQUIRY ($12) + TEST UNIT READY ($00).
; If boot_pref bit 0 is set, probes that ACSI boot ID first.
; Sets sd_type = 3 when target is ready.
; Returns d0.b = 0 OK, 1 error (sd_err set).
; Preserves d3-d7/a2-a6. Supervisor mode required.
;----------------------------------------
SD_Init:
	movem.l	d3-d6/a2,-(a7)
	clr.b	sd_type
	clr.b	probe_saw_dev

	btst.b	#0,boot_pref
	beq.s	.no_pref
	move.b	boot_pref,d0
	andi.b	#$E0,d0
	move.b	d0,acsi_target
	bsr	SD_ProbeUnit
	beq.s	.unit_ready
.no_pref:
	IFGE	ACSI_TARGET_ID
	moveq	#ACSI_TARGET_ID,d4
	moveq	#ACSI_TARGET_ID,d5
	ELSE
	moveq	#0,d4			; scan ID 0..7
	moveq	#7,d5
	ENDC

.scan_id:
	move.b	d4,d0
	lsl.b	#5,d0
	move.b	d0,acsi_target
	bsr	SD_ProbeUnit
	beq.s	.unit_ready

	addq.b	#1,d4
	cmp.b	d5,d4
	ble.s	.scan_id

	; No ready target found
	clr.b	sd_type
	tst.b	probe_saw_dev
	bne.s	.not_ready
	move.b	#ERR_CMD0,sd_err	; no ACSI device responded
	bra.s	.init_err
.not_ready:
	move.b	#ERR_ACMD41,sd_err	; target present, medium/unit not ready
.init_err:
	moveq	#1,d0
	movem.l	(a7)+,d3-d6/a2
	rts

.unit_ready:
	clr.b	sd_err
	move.b	#3,sd_type		; ACSI block-addressed unit ready
	moveq	#0,d0
	movem.l	(a7)+,d3-d6/a2
	rts

;----------------------------------------
; SD_SelectTarget: Query ready targets or select active ACSI target (API v1.9+, +50)
; Input:  d0.w = -1 (scan IDs 0..7 without changing active target)
;              or 0..7 (probe target ID and make it active if ready)
; Output: If d0.w < 0:
;           d0.l = bitmask of ready block targets (bit t = target t ready)
;           d1.w = current active target ID (0..7) or -1 if none (sd_type == 0)
;         If d0.w = 0..7:
;           d0.l = 0 on success (acsi_target updated, sd_type = 3)
;                  -1 on error (previous acsi_target and sd_type preserved)
; Preserves d2-d7/a2-a6. Supervisor mode required.
;----------------------------------------
SD_SelectTarget:
	movem.l	d2-d7/a2-a6,-(a7)
	move.b	acsi_target,d7		; save previous acsi_target
	move.b	sd_type,d6		; save previous sd_type

	tst.w	d0
	bmi.s	.scan_all

	IFGE	ACSI_TARGET_ID
	cmpi.w	#ACSI_TARGET_ID,d0
	bne.s	.sel_fail
	ELSE
	cmpi.w	#7,d0
	bhi.s	.sel_fail
	ENDC

	lsl.b	#5,d0
	move.b	d0,acsi_target
	bsr	SD_ProbeUnit
	tst.l	d0
	bne.s	.sel_restore
	move.b	#3,sd_type
	clr.b	sd_err
	moveq	#0,d0
	movem.l	(a7)+,d2-d7/a2-a6
	rts

.sel_restore:
	move.b	d7,acsi_target
	move.b	d6,sd_type
.sel_fail:
	moveq	#-1,d0
	movem.l	(a7)+,d2-d7/a2-a6
	rts

.scan_all:
	moveq	#0,d5			; d5.l = ready bitmask
	IFGE	ACSI_TARGET_ID
	moveq	#ACSI_TARGET_ID,d4
	moveq	#ACSI_TARGET_ID,d3
	ELSE
	moveq	#0,d4
	moveq	#7,d3
	ENDC
.scan_tgt_loop:
	move.b	d4,d0
	lsl.b	#5,d0
	move.b	d0,acsi_target
	bsr	SD_ProbeUnit
	tst.l	d0
	bne.s	.scan_tgt_next
	bset.l	d4,d5
.scan_tgt_next:
	addq.w	#1,d4
	cmp.w	d3,d4
	ble.s	.scan_tgt_loop

	move.b	d7,acsi_target		; restore caller's active target
	move.b	d6,sd_type
	moveq	#-1,d1
	tst.b	d6
	beq.s	.scan_out
	moveq	#0,d1
	move.b	d7,d1
	lsr.b	#5,d1
	andi.w	#7,d1
.scan_out:
	move.l	d5,d0
	movem.l	(a7)+,d2-d7/a2-a6
	rts

;========================================>
; BIOS Vectors
;

HookupXbiosVectors:
	move.l	$472.w,old_hdv_bpb+2
	move.l	#hdv_bpb,$472.w

	move.l	$476.w,old_hdv_rw_vec
	move.l	#hdv_rw,$476.w

	move.l	$47E.w,old_hdv_mediach_vec
	move.l	#hdv_mediach,$47E.w
	rts

;----------------------------------------
; InstallTrap1Fix
; Hooks GEMDOS TRAP #1 ($84.w) on TOS 1.00/1.02 to mask bogus $FFFF
; upper-word sign-extension in Dfree ($36) DISKINFO results.
;----------------------------------------
InstallTrap1Fix:
	move.l	$84.w,old_trap1_vec
	move.l	#trap1_handler,$84.w
	rts

	even
	dc.b	"XBRA"
	dc.b	"HDAC"
old_trap1_vec:
	dc.l	0
trap1_handler:
	move.l	a0,-(a7)
	btst.b	#5,4(a7)		; caller in supervisor mode?
	beq.s	.from_user
	lea	10(a7),a0		; TOS 1.00/1.02 68000 exception frame (saved a0 + SR + PC)
	bra.s	.check_fn
.from_user:
	move.l	usp,a0
.check_fn:
	cmpi.w	#$36,(a0)		; GEMDOS Dfree?
	bne.s	.pass_through

	move.l	2(a0),-(a7)		; keep buf for post-call fixup
	move.w	6(a0),-(a7)		; Dfree arg: drv
	move.l	2(a0),-(a7)		; Dfree arg: buf
	move.w	#$36,-(a7)		; Dfree opcode
	pea	.dfree_ret(pc)
	move.w	sr,-(a7)		; supervisor bit set for TOS _enter
	bra.s	.jump_old

.dfree_ret:
	addq.l	#8,a7			; pop Dfree args
	movea.l	(a7)+,a0		; pop buf
	tst.l	d0			; Dfree succeeded?
	bne.s	.dfree_exit
	cmpa.w	#0,a0			; non-NULL buf?
	beq.s	.dfree_exit
	clr.w	(a0)			; b_free   &= $0000FFFF
	clr.w	4(a0)			; b_total  &= $0000FFFF
	clr.w	8(a0)			; b_secsiz &= $0000FFFF
	clr.w	12(a0)			; b_clsiz  &= $0000FFFF
.dfree_exit:
	movea.l	(a7)+,a0		; restore caller's a0
	rte

.pass_through:
	movea.l	(a7)+,a0
.jump_old:
	move.l	old_trap1_vec(pc),-(a7)
	rts

	; hdv_bpb preserves -14(SD_API_Table) / -10(INSTALL_MARKER) public API ABI
	dc.l	SD_API_Table		; -14(hdv_bpb): Pointer to API table
	dc.l	INSTALL_MARKER		; -10(hdv_bpb): Magic marker
old_hdv_bpb:
	jmp	$CEDBCEDB
hdv_bpb:
	cmp.w	#0,4(a7)
	beq.s	old_hdv_bpb
	cmp.w	#1,4(a7)
	beq.s	old_hdv_bpb
	lea	sd_drive,a0
	lea	tos_bpb,a1
	lea	sd_mediach_flag,a2
	moveq	#MAX_MOUNTED_PARTS-1,d1
.next:
	move.w	(a0)+,d0
	cmp.w	4(a7),d0
	beq.s	.ok
	lea	bpb_size_b(a1),a1
	addq.l	#1,a2
	dbra	d1,.next
	bra.s	old_hdv_bpb
.ok:
	clr.b	(a2)			; Acknowledge media change on Getbpb
	move.l	a1,d0
	rts

	even
	dc.b	"XBRA"
	dc.b	"HDAC"
old_hdv_rw_vec:
	dc.l	0
hdv_rw:
	cmp.w	#0,14(a7)
	beq.w	.pass_rw
	cmp.w	#1,14(a7)
	beq.w	.pass_rw
	lea	sd_drive,a0
	lea	sd_first_sector,a1
	lea	part_info,a2
	moveq	#MAX_MOUNTED_PARTS-1,d1
.next:
	move.w	(a0)+,d0
	cmp.w	14(a7),d0
	beq.s	.DevOK
	addq.l	#4,a1
	adda.w	#PART_INFO_SIZE,a2
	dbra	d1,.next
	bra.w	.pass_rw
.DevOK:
	moveq	#MAX_MOUNTED_PARTS-1,d0
	sub.w	d1,d0			; d0.w = mounted slot index
	lea	sd_mediach_flag,a0
	tst.l	6(a7)
	bne.s	.has_buf
	move.b	11(a7),0(a0,d0.w)	; Rwabs(rw, NULL, mode, ...) updates mediach state
	bra.w	.mediach_noop
.has_buf:
	btst.b	#1,5(a7)		; rwflag bit 1: ignore media change?
	bne.s	.chk_ok
	tst.b	0(a0,d0.w)
	beq.s	.chk_ok
	moveq	#-14,d0			; E_CHNG: force TOS re-login + cache invalidation
	rts
.chk_ok:
	tst.w	10(a7)
	ble.w	.mediach_noop

	lea	part_acsi_id,a0
	move.b	acsi_target,-(a7)	; +2 bytes on stack: preserve active target
	move.b	0(a0,d0.w),acsi_target	; route I/O to this partition's ACSI ID

	move.l	6+2(a7),a0
	move.w	10+2(a7),d1
	moveq	#0,d0
	move.w	12+2(a7),d0
	cmpi.w	#-1,d0
	bne.s	.ok
	move.l	16+2(a7),d0
.ok:
	cmpi.w	#1,p_scale_w(a2)
	bne.s	.scaled_rw
	add.l	(a1),d0
	btst.b	#0,5+2(a7)
	bne.s	.write
	bsr	SD_ReadData
	move.b	(a7)+,acsi_target
	tst.l	d0
	beq.s	.done
	moveq	#-11,d0			; EREADF
	rts
.write:
	bsr	SD_WriteData
	move.b	(a7)+,acsi_target
	tst.l	d0
	beq.s	.done
	moveq	#-10,d0			; EWRITF
.done:
	rts

.scaled_rw:
	movem.l	d3-d7/a3-a5,-(a7)
	btst.b	#0,5+34(a7)		; rwflag bit 0 (2 + 32 bytes pushed)
	sne	d4			; d4.b: $FF=write, 0=read
	move.w	d1,d5			; d5.w = remaining logical count
	move.l	d0,d7			; d7.l = current logical recno
	movea.l	(a1),a3			; a3 = partition start physical LBA
	movea.l	a0,a4			; a4 = current DMA buffer
	move.w	p_shift_w(a2),d2
	move.l	#512,d6
	lsl.l	d2,d6			; d6.l = logical recsiz in bytes

.srw_loop:
	cmp.l	p_l_data_l(a2),d7
	bcs.s	.srw_meta

	; Bulk DATA transfer: chunk <= 256 logical sectors so (d3 * S) <= 8192
.srw_bulk_loop:
	move.w	d5,d3
	cmpi.w	#256,d3
	bls.s	.srw_bulk_cnt_ok
	move.w	#256,d3
.srw_bulk_cnt_ok:
	move.l	d7,d0
	sub.l	p_l_data_l(a2),d0
	move.w	p_shift_w(a2),d2
	lsl.l	d2,d0
	add.l	p_data_off_l(a2),d0
	add.l	a3,d0
	move.w	d3,d1
	lsl.w	d2,d1			; phys count = chunk * S
	movea.l	a4,a0
	tst.b	d4
	bne.s	.srw_bulk_wr
	bsr	SD_ReadData
	tst.l	d0
	bne	.srw_read_err
	bra.s	.srw_bulk_next
.srw_bulk_wr:
	bsr	SD_WriteData
	tst.l	d0
	bne	.srw_write_err
.srw_bulk_next:
	moveq	#0,d0
	move.w	d3,d0
	add.l	d0,d7			; advance logical recno
	move.w	d6,d0
	mulu.w	d3,d0			; chunk * recsiz (32-bit unsigned)
	adda.l	d0,a4			; advance DMA buffer
	sub.w	d3,d5
	bne.s	.srw_bulk_loop
	bra	.srw_ok

.srw_meta:
	; Single logical record inside BOOT / FAT1 / FAT2 / ROOT
	move.w	p_shift_w(a2),d2
	tst.l	d7
	bne.s	.not_boot
	moveq	#0,d0			; phys_off = 0
	moveq	#0,d1
	move.w	p_fat1_off_w(a2),d1	; phys_end = resvd_phys
	bra.s	.meta_xfer
.not_boot:
	cmp.l	p_l_fat2_l(a2),d7
	bcc.s	.not_fat1
	move.l	d7,d0
	subq.l	#1,d0
	lsl.l	d2,d0
	moveq	#0,d1
	move.w	p_fat1_off_w(a2),d1
	add.l	d1,d0
	move.w	p_fat1_end_w(a2),d1
	bra.s	.meta_xfer
.not_fat1:
	cmp.l	p_l_root_l(a2),d7
	bcc.s	.is_root
	move.l	d7,d0
	sub.l	p_l_fat2_l(a2),d0
	lsl.l	d2,d0
	moveq	#0,d1
	move.w	p_fat2_off_w(a2),d1
	add.l	d1,d0
	move.w	p_fat2_end_w(a2),d1
	bra.s	.meta_xfer
.is_root:
	move.l	d7,d0
	sub.l	p_l_root_l(a2),d0
	lsl.l	d2,d0
	moveq	#0,d1
	move.w	p_root_off_w(a2),d1
	add.l	d1,d0
	move.w	p_root_end_w(a2),d1

.meta_xfer:
	; d0.l = phys_off, d1.l = phys_end -> avail = d1 - d0
	sub.l	d0,d1
	bgt.s	.avail_pos
	moveq	#0,d1
.avail_pos:
	moveq	#0,d3
	move.w	p_scale_w(a2),d3
	cmp.l	d3,d1
	bls.s	.cnt_clamped
	move.l	d3,d1
.cnt_clamped:
	; d1.w = to_xfer (0..S), d3.w = S, d0.l = phys_off
	add.l	a3,d0			; absolute SD LBA
	movea.l	a4,a0			; buf
	tst.b	d4
	bne.s	.meta_write

	; Read metadata record + zero-pad trailing unmapped sectors
	tst.w	d1
	beq.s	.meta_pad
	movem.l	d1/d3/d7,-(a7)
	bsr	SD_ReadData
	movem.l	(a7)+,d1/d3/d7
	tst.l	d0
	bne.s	.srw_read_err
.meta_pad:
	sub.w	d1,d3			; pad_sectors = S - to_xfer
	beq.s	.meta_next
	moveq	#9,d0
	lsl.l	d0,d1
	movea.l	a4,a0
	adda.l	d1,a0
	lsl.w	d0,d3
	subq.w	#1,d3
.pad_clr:
	clr.b	(a0)+
	dbra	d3,.pad_clr
	bra.s	.meta_next

.meta_write:
	tst.w	d1
	beq.s	.meta_next
	move.l	d7,-(a7)
	bsr	SD_WriteData
	move.l	(a7)+,d7
	tst.l	d0
	bne.s	.srw_write_err

.meta_next:
	adda.l	d6,a4
	addq.l	#1,d7
	subq.w	#1,d5
	bne	.srw_loop

.srw_ok:
	movem.l	(a7)+,d3-d7/a3-a5
	move.b	(a7)+,acsi_target
	moveq	#0,d0
	rts
.srw_read_err:
	movem.l	(a7)+,d3-d7/a3-a5
	move.b	(a7)+,acsi_target
	moveq	#-11,d0			; EREADF
	rts
.srw_write_err:
	movem.l	(a7)+,d3-d7/a3-a5
	move.b	(a7)+,acsi_target
	moveq	#-10,d0			; EWRITF
	rts
.mediach_noop:
	moveq	#0,d0
	rts
.pass_rw:
	move.l	old_hdv_rw_vec(pc),-(a7)
	rts

	even
	dc.b	"XBRA"
	dc.b	"HDAC"
old_hdv_mediach_vec:
	dc.l	0
hdv_mediach:
	cmp.w	#0,4(a7)
	beq.s	.pass_mediach
	cmp.w	#1,4(a7)
	beq.s	.pass_mediach
	lea	sd_drive,a0
	lea	sd_mediach_flag,a1
	moveq	#MAX_MOUNTED_PARTS-1,d1
.next:
	move.w	(a0)+,d0
	cmp.w	4(a7),d0
	beq.s	.ok
	addq.l	#1,a1
	dbra	d1,.next
	bra.s	.pass_mediach
.ok:
	moveq	#0,d0
	move.b	(a1),d0			; Returns 2 (MEDIACHANGE) until Getbpb clears it
	rts
.pass_mediach:
	move.l	old_hdv_mediach_vec(pc),-(a7)
	rts

;----------------------------------------
; UpdatePunInfo: Maintain Atari AHDI 3.0+ PUN_INFO struct at pun_ptr ($516.w).
; Preserves all registers. Supervisor mode required.
;----------------------------------------
PUN_PTR		equ	$0516
PUN_MAGIC	equ	$41484449	; 'AHDI'
PUN_INFO_SIZE	equ	158		; 2 + 16 + 64 + 4 + 4 + 2 + 2 + 64

UpdatePunInfo:
	movem.l	d0-d5/a0-a5,-(a7)
	movea.l	PUN_PTR.w,a5
	cmpa.w	#0,a5
	beq.s	.init_ours
	cmpa.l	#pun_info,a5
	beq.s	.have_pun
	cmpi.l	#PUN_MAGIC,82(a5)
	bne.s	.init_ours
	lea	82(a5),a0
	cmpa.l	86(a5),a0
	beq.s	.have_pun

.init_ours:
	lea	pun_info,a5
	movea.l	a5,a0
	moveq	#(PUN_INFO_SIZE/2)-1,d0
.clr_pi:
	clr.w	(a0)+
	dbra	d0,.clr_pi
	lea	2(a5),a0
	moveq	#15,d0
.fill_ff:
	move.b	#$FF,(a0)+
	dbra	d0,.fill_ff
	move.l	#PUN_MAGIC,82(a5)
	lea	82(a5),a0
	move.l	a0,86(a5)
	move.w	#$0300,90(a5)
	move.w	#512,92(a5)
	move.l	a5,PUN_PTR.w

.have_pun:
	move.w	pun_owned_mask,d3
	moveq	#2,d1
.clr_owned:
	btst.l	d1,d3
	beq.s	.next_clr
	move.b	#$FF,2(a5,d1.w)
	move.w	d1,d0
	lsl.w	#2,d0
	clr.l	18(a5,d0.w)
.next_clr:
	addq.w	#1,d1
	cmpi.w	#16,d1
	blo.s	.clr_owned

	clr.w	d3
	move.w	#512,d4
	tst.b	is_emutos
	bne.s	.scan_slots
	move.w	max_log_scale,d0
	moveq	#9,d1
	lsl.w	d1,d0
	cmp.w	d4,d0
	bls.s	.scan_slots
	move.w	d0,d4
.scan_slots:
	lea	sd_drive,a0
	lea	sd_first_sector,a1
	lea	part_acsi_id,a2
	lea	tos_bpb,a3
	moveq	#MAX_MOUNTED_PARTS-1,d2
.slot_loop:
	move.w	(a0)+,d1
	bmi.s	.slot_skip
	cmpi.w	#16,d1
	bhs.s	.slot_skip
	bset.l	d1,d3
	move.b	(a2),d0
	lsr.b	#5,d0
	andi.b	#$07,d0
	move.b	d0,2(a5,d1.w)
	move.w	d1,d0
	lsl.w	#2,d0
	move.l	(a1),18(a5,d0.w)
	move.w	(a3),d0
	cmp.w	d4,d0
	bls.s	.slot_skip
	move.w	d0,d4
.slot_skip:
	addq.l	#4,a1
	addq.l	#1,a2
	lea	bpb_size_b(a3),a3
	dbra	d2,.slot_loop

	move.w	d3,pun_owned_mask
	cmp.w	92(a5),d4
	bls.s	.count_puns
	move.w	d4,92(a5)

.count_puns:
	moveq	#0,d3
	moveq	#2,d1
.cnt_drv:
	move.b	2(a5,d1.w),d0
	bmi.s	.cnt_next
	andi.w	#$07,d0
	bset.l	d0,d3
.cnt_next:
	addq.w	#1,d1
	cmpi.w	#16,d1
	blo.s	.cnt_drv
	moveq	#0,d4
	moveq	#7,d2
.pop_cnt:
	btst.l	d2,d3
	beq.s	.pop_next
	addq.w	#1,d4
.pop_next:
	dbra	d2,.pop_cnt
	move.w	d4,(a5)

	movem.l	(a7)+,d0-d5/a0-a5
	rts

;========================================>
; Utils

PrintMsg:
	move.l	a0,-(a7)
	move.w	#$09,-(a7)
	trap	#1
	addq.l	#6,a7
	rts

;----------------------------------------
; Delay: d0.l = ticks at 200 Hz (5 ms each). Clobbers d0.
; Supervisor mode required (_hz_200).
;----------------------------------------
Delay:
	movem.l	d1-d2,-(a7)
	move.l	HZ_200.w,d1		; start tick
.w:
	move.l	HZ_200.w,d2
	sub.l	d1,d2			; wrap-safe elapsed ticks
	cmp.l	d0,d2
	blo.s	.w
	movem.l	(a7)+,d1-d2
	rts

LE_2_BE_W:
	move.b	1(a0),d0
	lsl.w	#8,d0
	move.b	(a0),d0
	rts

LE_2_BE_L:
	addq.l	#4,a0
	move.b	-(a0),d0
	lsl.w	#8,d0
	move.b	-(a0),d0
	swap	d0
	move.b	-(a0),d0
	lsl.w	#8,d0
	move.b	-(a0),d0
	rts

DivU32ByPowerOfTwo:
	moveq	#0,d2
	moveq	#1,d3
.again:
	cmp.w	d1,d3
	bge.s	.found
	addq.w	#1,d2
	add.w	d3,d3
	bne.s	.again
.found:
	lsr.l	d2,d0
	rts

;========================================>

	section	data
	even

CMD_TEST_UNIT_READY:
	dc.b	$00,$00,$00,$00,$00,$00
CMD_REQUEST_SENSE:
	dc.b	$03,$00,$00,$00,$10,$00
CMD_INQUIRY:
	dc.b	$12,$00,$00,$00,$20,$00
CMD_READ_CAPACITY:
	dc.b	$1F,$25,$00,$00,$00,$00,$00,$00,$00,$00,$00

MsgInit:
	dc.b	$0D,$0A,$1B,$70
	dc.b	"HDACSIST - Atari ST ACSI Driver"
	dc.b	$0D,$0A,$1B,$71
	dc.b	"MBR + FAT12/FAT16 TOS Driver",$0D,$0A
	dc.b	"Driver v1.2 (ACSI DMA)",$0D,$0A
	dc.b	"ACSI Init: ",0

MsgAlreadyInstalled:	dc.b	"Driver already installed !",$0D,$0A,0
MsgOK:	dc.b	"OK",$0D,$0A,0
MsgErr:	dc.b	"Error",$0D,$0A,0
MsgF32:	dc.b	"Error: Not "
MsgF16:	dc.b	"FAT16",$0D,$0A,0
MsgF12:	dc.b	"FAT12",$0D,$0A,0
MsgHook:	dc.b	"Initializing...",$0D,$0A,0
MsgBPB:	dc.b	"Reading BPB: ",0
MsgAltSkipped:	dc.b	$0D,$0A,"HDACSIST skipped (Alt)",$0D,$0A,0
MsgCtrlBootA:	dc.b	"Booting from A: (Ctrl)",$0D,$0A,0

	section	bss
	even

GlobalProgramSize:	ds.l	1
sstack:			ds.l	1
sd_drive:		ds.w	MAX_MOUNTED_PARTS
sd_first_sector:	ds.l	MAX_MOUNTED_PARTS
cur_first_sector:	ds.l	mbr_n_partitions
ext_base_lba:		ds.l	1
cur_ebr_lba:		ds.l	1
next_ebr_lba:		ds.l	1
sd_good_partition:	ds.b	MAX_MOUNTED_PARTS
sd_mediach_flag:	ds.b	MAX_MOUNTED_PARTS
part_acsi_id:		ds.b	MAX_MOUNTED_PARTS
	even
data:			ds.b	512
	even
dma_bounce_buf:		ds.b	512
sense_buf:		ds.b	32
pun_info:		ds.b	PUN_INFO_SIZE
	even
pun_owned_mask:		ds.w	1
tos_bpb:		ds.w	bpb_size*MAX_MOUNTED_PARTS
acsi_cmd_buf:		ds.b	12
acsi_target:		ds.b	1
boot_pref:		ds.b	1
sd_type:		ds.b	1
boot_verbose:		ds.b	1
sd_err:			ds.b	1
sd_last_r1:		ds.b	1
is_emutos:		ds.b	1
probe_saw_dev:		ds.b	1
mount_saw_ready:	ds.b	1
mount_first_tgt:	ds.b	1
mount_boot_id:		ds.b	1
	even
max_log_scale:		ds.w	1
part_info:		ds.b	(PART_INFO_SIZE*MAX_MOUNTED_PARTS)
foldr_pool:		ds.b	FOLDR_POOL_BYTES
bcb_pool:		ds.b	(BCB_STRUCT_SIZE*4)
bcb_data:		ds.b	MAX_BCB_POOL_BYTES
	even
