;
; SDPART.PRG v1.2 - SD Card Partitioner & FAT16 Formatter for Atari ST / HDACSIST
; 40-column layout (ST low resolution).
;
;  [A] Add a partition: enter its size in MB; placed directly after the last
;      existing partition (uses DOS Extended $05 + EBR chain beyond 3 primaries,
;      up to 14 partitions C:..P:), formatted FAT16, remounted. Others untouched.
;  [E] Create equal partitions: enter size in MB first, then count (up to 14);
;      erases everything and formats all partitions FAT16.
;  [D] Delete all partitions (wipe the MBR table).
;
; Every MBR / EBR / boot sector write is read back and verified. After remount
; the driver's result (partition count or failure stage) is shown.
;
; Copyright (c) 2026 Ninjabuffy
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
;

INSTALL_MARKER	equ	$CEDBCEDB
FIRST_SECTOR	equ	128		; first partition starts here
EBR_GAP		equ	2		; EBR sector + 1 padding sector (even LBA)
MAX_PARTS	equ	14		; C:..P: (matches HDACSIST MAX_MOUNTED_PARTS)
MAX_EBR_HOPS	equ	32		; cap EBR chain against corrupt loops
MAX_PART_SECT	equ	4193280		; 65520 clusters x 64 sectors: 2047 MB, the FAT16 limit
MIN_PART_SECT	equ	16384		; 8 MB (keeps the volume FAT16)

	section	text

	move.l	4(a7),a0		; basepage
	lea	stack_top,a7		; own stack, before Mshrink frees the TPA top
	move.l	24(a0),a1
	adda.l	28(a0),a1
	suba.l	a0,a1
	move.l	a1,-(a7)
	move.l	a0,-(a7)
	clr.w	-(a7)
	move.w	#$4A,-(a7)		; Mshrink
	trap	#1
	lea	12(a7),a7

	clr.l	-(a7)
	move.w	#$20,-(a7)		; Super(NULL)
	trap	#1
	addq.l	#6,a7
	move.l	d0,sstack

	move.l	$472.w,a0
	cmpi.l	#INSTALL_MARKER,-10(a0)
	bne	NoDriver
	move.l	-14(a0),a1
	cmpi.l	#INSTALL_MARKER,(a1)
	bne	NoDriver
	move.l	a1,api_ptr
	move.w	#-1,active_target
	clr.l	target_mask
	clr.b	has_tgt_api
	cmpi.w	#$0109,4(a1)
	blo.s	MainMenu
	move.b	#1,has_tgt_api

;----------------------------------------
; Main menu
;----------------------------------------
MainMenu:
	lea	MsgHeader,a0
	bsr	PrintMsg

	tst.b	has_tgt_api
	bne.s	.has_tgt_hdr
	lea	MsgOldDriver,a0
	bsr	PrintMsg
	bra.s	.no_tgt_hdr
.has_tgt_hdr:
	bsr	RefreshTargets
	bsr	PrintTargetLine
.no_tgt_hdr:

	move.l	api_ptr,a0
	move.l	22(a0),a1		; SD_ReadCapacity
	jsr	(a1)
	move.l	d0,total_sectors
	bne.s	.card_ok
	lea	MsgNoCard,a0
	bsr	PrintMsg
	tst.b	has_tgt_api
	beq	WaitAndExit
	tst.b	target_mask
	beq	WaitAndExit
	bra.s	.menu_prompt
.card_ok:
	lea	MsgCardCap,a0
	bsr	PrintMsg
	move.l	total_sectors,d0
	bsr	PrintMB
	lea	MsgCRLF,a0
	bsr	PrintMsg

	bsr	ReadMBR
	tst.l	d0
	bne	ReadError
	bsr	ParseMBR
	bsr	DisplayPartitions

.menu_prompt:
	lea	MsgMenu,a0
	bsr	PrintMsg
	tst.b	has_tgt_api
	beq.s	.menu_q
	lea	MsgMenuTgt,a0
	bsr	PrintMsg
.menu_q:
	lea	MsgMenuQuit,a0
	bsr	PrintMsg
	bsr	WaitKey
	bsr	ToUpper
	cmpi.b	#'Q',d0
	beq	ExitApp
	cmpi.b	#'A',d0
	beq	AddPartition
	cmpi.b	#'E',d0
	beq	CreateEqual
	cmpi.b	#'D',d0
	beq	DeleteAll
	tst.b	has_tgt_api
	beq	MainMenu
	cmpi.b	#'T',d0
	beq.s	SwitchTarget
	bra	MainMenu

;----------------------------------------
; [T] Switch active ACSI target ID (0-7)
;----------------------------------------
SwitchTarget:
	lea	MsgAskTarget,a0
	bsr	PrintMsg
	bsr	WaitKey
	cmpi.b	#'0',d0
	blo	MainMenu
	cmpi.b	#'7',d0
	bhi	MainMenu
	subi.b	#'0',d0
	andi.w	#7,d0
	move.w	d0,d2
	movem.l	d2-d7/a2-a6,-(a7)
	move.l	api_ptr,a0
	move.l	50(a0),a1		; SD_SelectTarget
	jsr	(a1)
	movem.l	(a7)+,d2-d7/a2-a6
	tst.l	d0
	bne.s	.tgt_fail
	move.w	d2,active_target
	bra	MainMenu
.tgt_fail:
	lea	MsgTgtNotReady,a0
	bra	MsgAndMenu

; Refresh target_mask and ensure active_target is valid if any target ready
RefreshTargets:
	movem.l	d2-d7/a2-a6,-(a7)
	move.l	api_ptr,a0
	move.l	50(a0),a1		; SD_SelectTarget(-1)
	moveq	#-1,d0
	jsr	(a1)
	movem.l	(a7)+,d2-d7/a2-a6
	move.l	d0,target_mask
	move.w	d1,active_target
	tst.w	d1
	bpl.s	.rt_done
	tst.l	d0
	beq.s	.rt_done
	moveq	#0,d2
.find_first:
	btst.l	d2,d0
	bne.s	.sel_first
	addq.w	#1,d2
	cmpi.w	#8,d2
	blo.s	.find_first
	bra.s	.rt_done
.sel_first:
	movem.l	d2-d7/a2-a6,-(a7)
	move.w	d2,d0
	move.l	api_ptr,a0
	move.l	50(a0),a1
	jsr	(a1)
	movem.l	(a7)+,d2-d7/a2-a6
	tst.l	d0
	bne.s	.rt_done
	move.w	d2,active_target
.rt_done:
	rts

PrintTargetLine:
	movem.l	d0-d3/a0-a1,-(a7)
	lea	MsgTargetID,a0
	bsr	PrintMsg
	move.w	active_target,d0
	bpl.s	.has_id
	move.w	#'-',d0
	bsr	PrintChar
	bra.s	.pr_ready
.has_id:
	addi.w	#'0',d0
	bsr	PrintChar
.pr_ready:
	lea	MsgTgtReady,a0
	bsr	PrintMsg
	move.l	target_mask,d2
	bne.s	.list_bits
	lea	MsgTgtNone,a0
	bsr	PrintMsg
	bra.s	.pt_end
.list_bits:
	moveq	#0,d1			; bit index 0..7
	moveq	#0,d3			; space flag
.bit_loop:
	btst.l	d1,d2
	beq.s	.bit_next
	tst.w	d3
	beq.s	.no_sp
	move.w	#' ',d0
	bsr	PrintChar
.no_sp:
	moveq	#1,d3
	move.w	#'0',d0
	add.w	d1,d0
	bsr	PrintChar
.bit_next:
	addq.w	#1,d1
	cmpi.w	#8,d1
	blo.s	.bit_loop
.pt_end:
	lea	MsgTgtEnd,a0
	bsr	PrintMsg
	movem.l	(a7)+,d0-d3/a0-a1
	rts

PrintChar:
	movem.l	d0-d2/a0-a2,-(a7)
	andi.w	#$00FF,d0
	move.w	d0,-(a7)
	move.w	#$02,-(a7)		; Cconout
	trap	#1
	addq.l	#4,a7
	movem.l	(a7)+,d0-d2/a0-a2
	rts

; Print message in a0, wait for a key, back to the menu
MsgAndMenu:
	bsr	PrintMsg
	lea	MsgAnyKey,a0
	bsr	PrintMsg
	bsr	WaitKey
	bra	MainMenu

;----------------------------------------
; [A] Add one partition after the last existing one
; Uses primary MBR slots for first 3 partitions, then creates/appends inside
; a DOS Extended ($05/$0F) EBR chain up to MAX_PARTS (14).
;----------------------------------------
AddPartition:
	cmpi.w	#MAX_PARTS,part_count
	blo.s	.cnt_ok
	lea	MsgTableFull,a0
	bra	MsgAndMenu
.cnt_ok:
	move.l	next_free,d4		; default placement start
	moveq	#0,d5			; d5 = extra sectors reserved for EBR

	tst.w	ext_slot
	bmi.s	.no_ext_yet

	; Card already has a DOS Extended ($05/$0F) container
	tst.b	pri_after_ext
	beq.s	.use_logical
	; Primary sits after extended container: only safe if a primary MBR slot is free
	tst.w	first_free_slot
	bpl.s	.use_primary
	lea	MsgNoExtSlot,a0
	bra	MsgAndMenu

.no_ext_yet:
	cmpi.w	#3,mbr_used
	blo.s	.use_primary
	cmpi.w	#3,mbr_used
	beq.s	.check_new_ext
	lea	MsgNoExtSlot,a0
	bra	MsgAndMenu
.check_new_ext:
	tst.w	first_free_slot
	bpl.s	.use_new_ext
	lea	MsgNoExtSlot,a0
	bra	MsgAndMenu

.use_primary:
	clr.b	add_mode
	bra.s	.calc_avail

.use_new_ext:
	move.b	#1,add_mode
	move.l	d4,add_ebr_lba
	moveq	#EBR_GAP,d5
	bra.s	.calc_avail

.use_logical:
	move.b	#2,add_mode
	tst.l	last_ebr
	bne.s	.log_at_next
	move.l	ext_base,d0
	cmp.l	d4,d0
	bls.s	.log_at_next
	move.l	d0,d4			; empty extended container starts after next_free
.log_at_next:
	move.l	d4,add_ebr_lba
	moveq	#EBR_GAP,d5

.calc_avail:
	move.l	total_sectors,d0
	sub.l	d4,d0
	bls.s	.no_space
	sub.l	d5,d0
	bls.s	.no_space
	cmpi.l	#MIN_PART_SECT,d0
	bhs.s	.space_ok
.no_space:
	lea	MsgNoSpace,a0
	bra	MsgAndMenu
.space_ok:
	cmpi.l	#MAX_PART_SECT,d0
	bls.s	.cap_ok
	move.l	#MAX_PART_SECT,d0
.cap_ok:
	lsr.l	#8,d0
	lsr.l	#3,d0			; sectors -> MB
	move.l	d0,max_mb

	lea	MsgEnterSize,a0
	bsr	PrintMsg
	move.l	max_mb,d0
	bsr	PrintDec32
	lea	MsgEnterSize2,a0
	bsr	PrintMsg
	bsr	ReadDec			; d0 = value, d1 = digits typed
	tst.w	d1
	beq	MainMenu		; nothing typed: cancel
	cmpi.l	#8,d0
	blo.s	.bad
	cmp.l	max_mb,d0
	bhi.s	.bad
	move.l	d0,d2			; d2 = size in MB
	lsl.l	#8,d0
	lsl.l	#3,d0			; MB -> sectors
	move.l	d0,part_size_sectors
	cmpi.l	#510,d2
	bls.s	.confirm
	lea	MsgWarnTOS,a0
	bsr	PrintMsg
	bra.s	.confirm
.bad:
	lea	MsgBadSize,a0
	bra	MsgAndMenu
.confirm:
	lea	MsgConfirmAdd,a0
	bsr	PrintMsg
	bsr	WaitKey
	bsr	ToUpper
	cmpi.b	#'Y',d0
	bne	MainMenu

	lea	MsgWorking,a0
	bsr	PrintMsg
	; NOTE: no SD_Unmount here. It clears sd_type, after which the driver's
	; read/write use byte addressing - wrong for SDHC cards. SD_Mount at the
	; end re-initialises everything itself.

	cmpi.b	#1,add_mode
	beq.s	.do_new_ext
	cmpi.b	#2,add_mode
	beq	.do_append_log

	; --- Primary partition in first_free_slot ---
	bsr	ReadMBR
	tst.l	d0
	bne	ReadError
	tst.w	mbr_valid
	bne.s	.have_mbr
	bsr	ClearSectorBuf		; no MBR yet: start a fresh one
	clr.w	first_free_slot
.have_mbr:
	move.w	first_free_slot,d0
	bmi	MainMenu
	lsl.w	#4,d0
	lea	sector_buf+446,a1
	adda.w	d0,a1			; a1 -> first free entry
	move.l	next_free,d4		; start sector
	bsr	FillMBREntry
	bsr	WriteMBR
	tst.l	d0
	bne	WriteError
	bra	.do_format

.do_new_ext:
	; 1. Write first EBR at add_ebr_lba
	bsr	ClearSectorBuf
	lea	sector_buf+446,a1
	moveq	#EBR_GAP,d0
	move.l	part_size_sectors,d1
	bsr	FillDataEntry
	move.l	add_ebr_lba,d0
	bsr	WriteEBR
	tst.l	d0
	bne	WriteError

	; 2. Update MBR slot first_free_slot with Extended $05 container
	bsr	ReadMBR
	tst.l	d0
	bne	ReadError
	move.w	first_free_slot,d0
	bmi	MainMenu
	lsl.w	#4,d0
	lea	sector_buf+446,a1
	adda.w	d0,a1
	move.l	add_ebr_lba,d0
	move.l	part_size_sectors,d1
	addq.l	#EBR_GAP,d1
	moveq	#$05,d2
	bsr	WritePartEntry
	bsr	WriteMBR
	tst.l	d0
	bne	WriteError

	move.l	add_ebr_lba,d4
	addq.l	#EBR_GAP,d4
	bra	.do_format

.do_append_log:
	; 1. Write new EBR at add_ebr_lba first (crash-safe before linking)
	bsr	ClearSectorBuf
	lea	sector_buf+446,a1
	moveq	#EBR_GAP,d0
	move.l	part_size_sectors,d1
	bsr	FillDataEntry
	move.l	add_ebr_lba,d0
	bsr	WriteEBR
	tst.l	d0
	bne	WriteError

	; 2. Link previous EBR Entry 1 -> new EBR (relative to ext_base)
	move.l	last_ebr,d0
	beq.s	.chk_grow_mbr
	moveq	#1,d1
	lea	sector_buf,a0
	bsr	CallRawRead
	tst.l	d0
	bne	ReadError
	lea	sector_buf+462,a1
	move.l	add_ebr_lba,d0
	sub.l	ext_base,d0
	move.l	part_size_sectors,d1
	addq.l	#EBR_GAP,d1
	move.b	ext_type,d2
	bsr	WritePartEntry
	move.l	last_ebr,d0
	bsr	WriteEBR
	tst.l	d0
	bne	WriteError

.chk_grow_mbr:
	; 3. Grow MBR extended container length if new logical extends past ext_len
	move.l	add_ebr_lba,d2
	addq.l	#EBR_GAP,d2
	add.l	part_size_sectors,d2
	sub.l	ext_base,d2		; needed ext_len
	cmp.l	ext_len,d2
	bls.s	.log_ready_fmt
	bsr	ReadMBR
	tst.l	d0
	bne	ReadError
	move.w	ext_slot,d0
	lsl.w	#4,d0
	lea	sector_buf+446+12,a0
	adda.w	d0,a0
	move.l	d2,d0
	bsr	WriteLE32
	bsr	WriteMBR
	tst.l	d0
	bne	WriteError

.log_ready_fmt:
	move.l	add_ebr_lba,d4
	addq.l	#EBR_GAP,d4

.do_format:
	bsr	FormatPartition		; d4 = start, part_size_sectors = length
	tst.l	d0
	bne	WriteError

	bsr	Remount
	lea	MsgDone,a0
	bra	MsgAndMenu

;----------------------------------------
; [E] Create equal FAT16 partitions (user picks size in MB first, then count)
; Creates 1-4 primary partitions, or 3 primary + Extended ($05) up to 14.
;----------------------------------------
CreateEqual:
	move.l	total_sectors,d0
	cmpi.l	#FIRST_SECTOR,d0
	bls	.eq_no_space
	subi.l	#FIRST_SECTOR,d0
	cmpi.l	#MIN_PART_SECT,d0
	blo	.eq_no_space
	cmpi.l	#MAX_PART_SECT,d0
	bls.s	.eq_cap_ok
	move.l	#MAX_PART_SECT,d0
.eq_cap_ok:
	lsr.l	#8,d0
	lsr.l	#3,d0			; max single partition in MB
	move.l	d0,max_mb

	; Step 1: Ask partition size in MB first
	lea	MsgEqSize1,a0
	bsr	PrintMsg
	move.l	max_mb,d0
	bsr	PrintDec32
	lea	MsgCloseCancel,a0
	bsr	PrintMsg
	bsr	ReadDec			; d0 = MB, d1 = digits typed
	tst.w	d1
	beq	MainMenu
	cmpi.l	#8,d0
	blo	.eq_bad_size
	cmp.l	max_mb,d0
	bhi	.eq_bad_size
	move.l	d0,d6			; d6 = partition size in MB
	lsl.l	#8,d0
	lsl.l	#3,d0
	move.l	d0,part_size_sectors

	; Compute how many partitions of this size fit (up to MAX_PARTS = 14)
	move.l	total_sectors,d5
	subi.l	#FIRST_SECTOR,d5	; available sectors
	moveq	#0,d2			; max_fit
	moveq	#1,d3			; n = 1..MAX_PARTS
	moveq	#0,d4			; running n * part_size_sectors
.fit_loop:
	add.l	part_size_sectors,d4
	bcs.s	.fit_done
	move.l	d4,d0
	cmpi.w	#5,d3
	blo.s	.fit_chk
	move.w	d3,d1
	subq.w	#3,d1
	mulu.w	#EBR_GAP,d1		; (n - 3) EBR gaps
	add.l	d1,d0
	bcs.s	.fit_done
.fit_chk:
	cmp.l	d5,d0
	bhi.s	.fit_done
	move.w	d3,d2
	addq.w	#1,d3
	cmpi.w	#MAX_PARTS,d3
	bls.s	.fit_loop
.fit_done:
	tst.w	d2
	beq	.eq_no_space
	move.w	d2,max_eq_parts

	; Step 2: Ask how many partitions (1..max_eq_parts)
	lea	MsgEqCount1,a0
	bsr	PrintMsg
	moveq	#0,d0
	move.w	max_eq_parts,d0
	bsr	PrintDec32
	lea	MsgCloseCancel,a0
	bsr	PrintMsg
	bsr	ReadDec
	tst.w	d1
	beq	MainMenu
	tst.l	d0
	beq	.eq_bad_count
	moveq	#0,d1
	move.w	max_eq_parts,d1
	cmp.l	d1,d0
	bhi	.eq_bad_count
	move.w	d0,num_parts_req

	cmpi.l	#510,d6
	bls.s	.tos_ok_eq
	lea	MsgWarnTOS,a0
	bsr	PrintMsg
.tos_ok_eq:
	lea	MsgConfirmEq1,a0
	bsr	PrintMsg
	moveq	#0,d0
	move.w	num_parts_req,d0
	bsr	PrintDec32
	lea	MsgConfirmEq2,a0
	bsr	PrintMsg
	move.l	d6,d0
	bsr	PrintDec32
	lea	MsgConfirmEq3,a0
	bsr	PrintMsg
	bsr	WaitKey
	bsr	ToUpper
	cmpi.b	#'Y',d0
	bne	MainMenu

	lea	MsgWorking,a0
	bsr	PrintMsg
	; no SD_Unmount here (see AddPartition)

	cmpi.w	#4,num_parts_req
	bhi	.eq_extended

	; --- 1..4 primary partitions ---
	bsr	ClearSectorBuf
	lea	sector_buf+446,a1
	move.l	#FIRST_SECTOR,d4
	move.w	num_parts_req,d5
	subq.w	#1,d5
.mbr_loop:
	bsr	FillMBREntry
	add.l	part_size_sectors,d4
	lea	16(a1),a1
	dbra	d5,.mbr_loop
	bsr	WriteMBR
	tst.l	d0
	bne	WriteError

	move.l	#FIRST_SECTOR,d4
	move.w	num_parts_req,d5
	subq.w	#1,d5
.fmt_loop:
	bsr	FormatPartition
	tst.l	d0
	bne	WriteError
	add.l	part_size_sectors,d4
	dbra	d5,.fmt_loop

	bsr	Remount
	lea	MsgDone,a0
	bra	MsgAndMenu

.eq_no_space:
	lea	MsgNoSpace,a0
	bra	MsgAndMenu
.eq_bad_size:
	lea	MsgBadSize,a0
	bra	MsgAndMenu
.eq_bad_count:
	lea	MsgBadCount,a0
	bra	MsgAndMenu

	; --- 5..14 partitions: 3 primary + Extended ($05) with EBR chain ---
.eq_extended:
	bsr	ClearSectorBuf
	lea	sector_buf+446,a1
	move.l	#FIRST_SECTOR,d4
	moveq	#2,d5
.mbr_pri3:
	bsr	FillMBREntry
	add.l	part_size_sectors,d4
	lea	16(a1),a1
	dbra	d5,.mbr_pri3

	move.l	d4,ext_base		; start of $05 container
	move.l	part_size_sectors,d7
	addq.l	#EBR_GAP,d7		; d7 = sectors per logical slot (EBR + data)

	; ext_len = num_logical * slot_stride
	moveq	#0,d1
	move.w	num_parts_req,d5
	subq.w	#4,d5			; num_logical - 1
.ext_len_loop:
	add.l	d7,d1
	dbra	d5,.ext_len_loop

	move.l	d4,d0
	moveq	#$05,d2
	bsr	WritePartEntry		; slot 3 = Extended $05
	bsr	WriteMBR
	tst.l	d0
	bne	WriteError

	; Write EBR chain: k = 0 .. num_logical - 1
	move.l	ext_base,d4		; current EBR LBA
	moveq	#0,d3			; next EBR offset relative to ext_base
	move.w	num_parts_req,d5
	subq.w	#4,d5			; remaining EBRs - 1
.ebr_wr_loop:
	bsr	ClearSectorBuf
	lea	sector_buf+446,a1
	moveq	#EBR_GAP,d0
	move.l	part_size_sectors,d1
	bsr	FillDataEntry
	tst.w	d5
	beq.s	.ebr_wr_do
	add.l	d7,d3
	lea	sector_buf+462,a1
	move.l	d3,d0
	move.l	d7,d1
	moveq	#$05,d2
	bsr	WritePartEntry
.ebr_wr_do:
	move.l	d4,d0
	bsr	WriteEBR
	tst.l	d0
	bne	WriteError
	add.l	d7,d4
	dbra	d5,.ebr_wr_loop

	; Format 3 primary partitions
	move.l	#FIRST_SECTOR,d4
	moveq	#2,d5
.fmt_pri3:
	bsr	FormatPartition
	tst.l	d0
	bne	WriteError
	add.l	part_size_sectors,d4
	dbra	d5,.fmt_pri3

	; Format logical partitions
	move.l	ext_base,d4
	addq.l	#EBR_GAP,d4
	move.w	num_parts_req,d5
	subq.w	#4,d5
.fmt_log:
	bsr	FormatPartition
	tst.l	d0
	bne	WriteError
	add.l	d7,d4
	dbra	d5,.fmt_log

	bsr	Remount
	lea	MsgDone,a0
	bra	MsgAndMenu

;----------------------------------------
; [D] Delete all partitions (empty MBR table)
;----------------------------------------
DeleteAll:
	lea	MsgConfirmDel,a0
	bsr	PrintMsg
	bsr	WaitKey
	bsr	ToUpper
	cmpi.b	#'Y',d0
	bne	MainMenu

	bsr	ClearSectorBuf
	bsr	WriteMBR
	tst.l	d0
	bne	WriteError
	; Remount so any other ACSI target stays mounted cleanly
	movem.l	d2-d7/a2-a6,-(a7)
	move.l	api_ptr,a0
	move.l	6(a0),a1		; SD_Mount
	jsr	(a1)
	movem.l	(a7)+,d2-d7/a2-a6
	move.l	d0,-(a7)
	lea	MsgRemount,a0
	bsr	PrintMsg
	move.l	(a7)+,d0
	bsr	PrintDec32
	lea	MsgMounted,a0
	bsr	PrintMsg
	tst.b	has_tgt_api
	beq.s	.del_done
	move.w	active_target,d0
	bmi.s	.del_done
	movem.l	d2-d7/a2-a6,-(a7)
	move.l	api_ptr,a0
	move.l	50(a0),a1		; Keep selected target active after remount
	jsr	(a1)
	movem.l	(a7)+,d2-d7/a2-a6
.del_done:
	lea	MsgDone,a0
	bra	MsgAndMenu

;----------------------------------------
; MBR handling
;----------------------------------------
; ReadMBR: sector 0 -> sector_buf. d0 = 0 ok / -1 error
ReadMBR:
	moveq	#0,d0
	moveq	#1,d1
	lea	sector_buf,a0
	bsr	CallRawRead
	rts

; WriteMBR: set signature, guard against $1234 TOS boot checksum,
; write sector_buf to sector 0, read back, compare. d0 = 0 ok / -1 error
WriteMBR:
	movem.l	d1/a1,-(a7)
	lea	MsgWriteMBR,a0
	bsr	PrintMsg
	lea	sector_buf,a0
	move.b	#$55,510(a0)
	move.b	#$AA,511(a0)

	; If Stage-1 ('A2ST') boot code is present, update checksum word 444(a0)
	; so sum == $1234 stays valid; otherwise guard against accidental $1234.
	cmpi.l	#'A2ST',2(a0)
	bne.s	.no_stage1
	cmpi.b	#$60,(a0)
	bne.s	.no_stage1
	clr.w	444(a0)
	movea.l	a0,a1
	moveq	#0,d0
	move.w	#255,d1
.s1_sum:
	add.w	(a1)+,d0
	dbra	d1,.s1_sum
	move.w	#$1234,d1
	sub.w	d0,d1
	move.w	d1,444(a0)
	bra.s	.cksum_ok

.no_stage1:
	; Ensure 16-bit big-endian word sum of sector 0 != $1234
	; (otherwise Atari TOS executes the MBR as boot code and crashes)
	movea.l	a0,a1
	moveq	#0,d0
	move.w	#255,d1
.cksum:
	add.w	(a1)+,d0
	dbra	d1,.cksum
	cmpi.w	#$1234,d0
	bne.s	.cksum_ok
	addq.b	#1,444(a0)
.cksum_ok:
	moveq	#0,d0
	bsr	WriteVerify
	movem.l	(a7)+,d1/a1
	rts

; WriteEBR: set $55/$AA signature, write sector_buf to sector d0, verify.
; d0 = 0 ok / -1 error (falls through into WriteVerify)
WriteEBR:
	move.l	d0,-(a7)
	lea	MsgWriteEBR,a0
	bsr	PrintMsg
	lea	sector_buf,a0
	move.b	#$55,510(a0)
	move.b	#$AA,511(a0)
	move.l	(a7)+,d0

; WriteVerify: write sector_buf to sector d0, read it back into verify_buf
; and compare. Prints OK / Verify failed. d0 = 0 ok / -1 error
WriteVerify:
	movem.l	d1-d3/a0-a1,-(a7)
	move.l	d0,d3
	moveq	#1,d1
	lea	sector_buf,a0
	bsr	CallRawWrite
	tst.l	d0
	bne.s	.err
	move.l	d3,d0
	moveq	#1,d1
	lea	verify_buf,a0
	bsr	CallRawRead
	tst.l	d0
	bne.s	.err
	lea	sector_buf,a0
	lea	verify_buf,a1
	move.w	#127,d2
.cmp:
	cmpm.l	(a0)+,(a1)+
	bne.s	.mismatch
	dbra	d2,.cmp
	lea	MsgOK,a0
	bsr	PrintMsg
	moveq	#0,d0
	bra.s	.out
.mismatch:
	lea	MsgVerifyFail,a0
	bsr	PrintMsg
.err:
	moveq	#-1,d0
.out:
	movem.l	(a7)+,d1-d3/a0-a1
	rts

; ParseMBR: fills mbr_valid, part_count, mbr_used, first_free_slot, ext_slot,
; ext_base, ext_len, ext_type, last_ebr, pri_after_ext, part_start[], part_len[],
; part_kind[], and next_free from sector_buf (reads EBR chain via verify_buf).
ParseMBR:
	movem.l	d0-d6/a0-a3,-(a7)
	clr.w	part_count
	clr.w	mbr_used
	clr.w	mbr_valid
	move.w	#-1,first_free_slot
	move.w	#-1,ext_slot
	move.b	#$05,ext_type
	clr.l	ext_base
	clr.l	ext_len
	clr.l	last_ebr
	clr.b	pri_after_ext
	move.l	#FIRST_SECTOR,next_free

	lea	part_start,a3
	moveq	#(MAX_PARTS*2)-1,d3
.clr_arrays:
	clr.l	(a3)+
	dbra	d3,.clr_arrays
	lea	part_kind,a3
	moveq	#MAX_PARTS-1,d3
.clr_kind:
	clr.b	(a3)+
	dbra	d3,.clr_kind

	lea	sector_buf,a1
	cmpi.b	#$55,510(a1)
	bne	.align
	cmpi.b	#$AA,511(a1)
	bne	.align
	move.w	#1,mbr_valid
	lea	446(a1),a2
	moveq	#0,d4			; MBR slot index 0..3
.loop:
	lea	12(a2),a0
	bsr	ReadLE32		; length
	tst.l	d0
	bne.s	.slot_used
	tst.w	first_free_slot
	bpl.s	.next_slot
	move.w	d4,first_free_slot
	bra.s	.next_slot
.slot_used:
	addq.w	#1,mbr_used
	move.l	d0,d2			; d2 = length
	lea	8(a2),a0
	bsr	ReadLE32
	move.l	d0,d1			; d1 = start
	move.b	4(a2),d3		; partition type
	cmpi.b	#$05,d3
	beq.s	.found_ext
	cmpi.b	#$0F,d3
	beq.s	.found_ext

	moveq	#'P',d3
	bsr	.record_part
	bra.s	.next_slot

.found_ext:
	tst.w	ext_slot
	bpl.s	.next_slot		; keep first extended container only
	move.w	d4,ext_slot
	move.b	d3,ext_type
	move.l	d1,ext_base
	move.l	d2,ext_len
.next_slot:
	lea	16(a2),a2
	addq.w	#1,d4
	cmpi.w	#4,d4
	blo.s	.loop

	; If Extended container exists, check primaries after it and walk EBR chain
	tst.w	ext_slot
	bmi	.align

	move.l	ext_base,d0
	add.l	ext_len,d0
	bcs.s	.walk_ebr		; overflow: nothing can start past container
	move.w	part_count,d3
	beq.s	.walk_ebr
	subq.w	#1,d3
	lea	part_start,a0
.chk_pri_after:
	cmp.l	(a0)+,d0
	bhi.s	.chk_pri_next
	move.b	#1,pri_after_ext
	bra.s	.walk_ebr
.chk_pri_next:
	dbra	d3,.chk_pri_after

.walk_ebr:
	move.l	ext_base,d5		; current EBR LBA
	beq	.align
	moveq	#MAX_EBR_HOPS-1,d6
.ebr_loop:
	move.l	d5,d0
	moveq	#1,d1
	lea	verify_buf,a0
	bsr	CallRawRead
	tst.l	d0
	bne	.align
	lea	verify_buf,a2
	cmpi.b	#$55,510(a2)
	bne	.align
	cmpi.b	#$AA,511(a2)
	bne	.align
	move.l	d5,last_ebr

	; Entry 0 (+446): logical partition (start relative to cur EBR d5)
	lea	446+12(a2),a0
	bsr	ReadLE32
	move.l	d0,d2			; length
	beq.s	.ebr_next
	move.b	446+4(a2),d3
	cmpi.b	#$05,d3
	beq.s	.ebr_next
	cmpi.b	#$0F,d3
	beq.s	.ebr_next
	lea	446+8(a2),a0
	bsr	ReadLE32
	add.l	d5,d0
	bcs.s	.ebr_next
	move.l	d0,d1
	moveq	#'L',d3
	bsr.s	.record_part

.ebr_next:
	; Entry 1 (+462): next EBR (start relative to ext_base)
	lea	462+12(a2),a0
	bsr	ReadLE32
	tst.l	d0
	beq.s	.align
	move.b	462+4(a2),d3
	cmpi.b	#$05,d3
	beq.s	.ebr_has_next
	cmpi.b	#$0F,d3
	bne.s	.align
.ebr_has_next:
	lea	462+8(a2),a0
	bsr	ReadLE32
	add.l	ext_base,d0
	bcs.s	.align
	cmp.l	d5,d0			; self-loop guard
	beq.s	.align
	move.l	d0,d5
	dbra	d6,.ebr_loop

.align:
	move.l	next_free,d0
	addq.l	#1,d0
	bcc.s	.align_mask
	move.l	#$FFFFFFFE,d0
.align_mask:
	andi.l	#$FFFFFFFE,d0		; even sector
	cmpi.l	#FIRST_SECTOR,d0
	bhs.s	.ok
	move.l	#FIRST_SECTOR,d0
.ok:
	move.l	d0,next_free
	movem.l	(a7)+,d0-d6/a0-a3
	rts

; Helper local to ParseMBR: record partition (d1=start, d2=len, d3.b='P'/'L')
; Updates part_start[], part_len[], part_kind[], part_count, next_free. Preserves d4-d6/a2.
.record_part:
	move.w	part_count,d0
	cmpi.w	#MAX_PARTS,d0
	bhs.s	.rp_end
	lea	part_kind,a0
	move.b	d3,0(a0,d0.w)
	lsl.w	#2,d0
	lea	part_start,a0
	move.l	d1,0(a0,d0.w)
	lea	part_len,a0
	move.l	d2,0(a0,d0.w)
	addq.w	#1,part_count
.rp_end:
	move.l	d1,d0
	add.l	d2,d0
	bcs.s	.rp_ret
	cmp.l	next_free,d0
	bls.s	.rp_ret
	move.l	d0,next_free
.rp_ret:
	rts

; FreeSectors: d0 = sectors after the last partition (0 if none)
FreeSectors:
	move.l	total_sectors,d0
	sub.l	next_free,d0
	bhi.s	.ok
	moveq	#0,d0
.ok:
	rts

; FillMBREntry: a1 -> 16-byte entry, d4 = start, part_size_sectors = length
FillMBREntry:
	move.l	d0,-(a7)
	move.l	d1,-(a7)
	move.l	d2,-(a7)
	move.l	d4,d0
	move.l	part_size_sectors,d1
	bsr.s	FillDataEntry
	move.l	(a7)+,d2
	move.l	(a7)+,d1
	move.l	(a7)+,d0
	rts

; FillDataEntry: a1 -> 16-byte entry, d0 = start/offset, d1 = length
; Chooses type $06 (FAT16 >= 32 MB) or $04 (FAT16 < 32 MB).
FillDataEntry:
	move.b	#$06,d2
	cmpi.l	#65536,d1
	bhs.s	WritePartEntry
	move.b	#$04,d2

; WritePartEntry: a1 -> 16-byte entry, d0 = start, d1 = length, d2.b = type
WritePartEntry:
	movem.l	d0/a0,-(a7)
	clr.b	0(a1)			; boot indicator
	move.b	#$01,1(a1)		; dummy start CHS
	move.b	#$01,2(a1)
	clr.b	3(a1)
	move.b	d2,4(a1)		; partition type
	move.b	#$FE,5(a1)		; dummy end CHS
	move.b	#$3F,6(a1)
	move.b	#$01,7(a1)
	lea	8(a1),a0
	bsr	WriteLE32		; LBA start
	move.l	d1,d0
	lea	12(a1),a0
	bsr	WriteLE32		; LBA length
	movem.l	(a7)+,d0/a0
	rts

;----------------------------------------
; FormatPartition: FAT16 format at sector d4, length part_size_sectors
; 512-byte sectors, cluster size chosen so clusters <= 65520 (PC style).
; d0 = 0 ok / -1 error
;----------------------------------------
FormatPartition:
	movem.l	d1-d7/a0-a3,-(a7)

	lea	MsgFormatting,a0
	bsr	PrintMsg
	move.l	d4,d0
	bsr	PrintDec32
	lea	MsgCRLF,a0
	bsr	PrintMsg

	; sectorsPerCluster (d6) and shift (d7) so clusters <= 32760
	; Keeps clusters <= 32767 to avoid signed 16-bit Dfree overflow in Atari TOS 1.x
	move.l	part_size_sectors,d0
	moveq	#2,d6
	moveq	#1,d7
.spc_loop:
	move.l	d0,d1
	lsr.l	d7,d1
	cmpi.w	#64,d6			; max FAT16 sectors/cluster is 64
	bhs.s	.spc_ok
	cmpi.l	#32760,d1
	bls.s	.spc_ok
	add.w	d6,d6
	addq.w	#1,d7
	bra.s	.spc_loop
.spc_ok:
	; sectorsPerFat (d3) = ((clusters + 2) * 2 + 511) / 512
	addq.l	#2,d1
	add.l	d1,d1
	addi.l	#511,d1
	lsr.l	#8,d1
	lsr.l	#1,d1
	move.w	d1,d3

	; Boot sector
	bsr	ClearSectorBuf
	lea	sector_buf,a0
	move.b	#$EB,0(a0)
	move.b	#$3C,1(a0)
	move.b	#$90,2(a0)
	move.b	#'T',3(a0)
	move.b	#'O',4(a0)
	move.b	#'S',5(a0)
	move.b	#'F',6(a0)
	move.b	#'A',7(a0)
	move.b	#'T',8(a0)
	move.b	#'1',9(a0)
	move.b	#'6',10(a0)
	clr.b	11(a0)			; bytesPerSector = 512
	move.b	#$02,12(a0)
	move.b	d6,13(a0)		; sectorsPerCluster
	move.b	#$01,14(a0)		; reservedSectorCount = 1
	clr.b	15(a0)
	move.b	#$02,16(a0)		; fatCount = 2
	clr.b	17(a0)			; rootDirEntryCount = 512
	move.b	#$02,18(a0)

	move.l	part_size_sectors,d0
	cmpi.l	#65536,d0
	bhs.s	.use_tot32
	move.b	d0,19(a0)		; totalSectors16
	lsr.w	#8,d0
	move.b	d0,20(a0)
	bra.s	.tot_set
.use_tot32:
	lea	32(a0),a0
	bsr	WriteLE32		; totalSectors32
	lea	sector_buf,a0
.tot_set:
	move.b	#$F8,21(a0)		; media descriptor
	move.w	d3,d0
	move.b	d0,22(a0)		; sectorsPerFat16
	lsr.w	#8,d0
	move.b	d0,23(a0)
	move.b	#32,24(a0)		; sectorsPerTrack
	move.b	#64,26(a0)		; headCount
	move.l	d4,d0
	lea	28(a0),a0
	bsr	WriteLE32		; hiddenSectors = partition start
	lea	sector_buf,a0
	move.b	#$80,36(a0)		; drive number
	move.b	#$29,38(a0)		; extended boot signature
	move.b	#$12,39(a0)		; volume serial
	move.b	#$34,40(a0)
	move.b	#$56,41(a0)
	move.b	#$78,42(a0)
	lea	43(a0),a1
	lea	StrLabel,a0
	bsr	CopyBytes		; "SDCARD     " (11 bytes)
	lea	StrFSType,a0
	bsr	CopyBytes		; "FAT16   " (8 bytes)
	lea	sector_buf,a0
	move.b	#$55,510(a0)
	move.b	#$AA,511(a0)

	lea	MsgWriteBoot,a0
	bsr	PrintMsg
	move.l	d4,d0
	bsr	WriteVerify
	tst.l	d0
	bne	.fmt_err

	; FAT1 and FAT2 head sectors: F8 FF FF FF
	bsr	ClearSectorBuf
	lea	sector_buf,a0
	move.b	#$F8,0(a0)
	move.b	#$FF,1(a0)
	move.b	#$FF,2(a0)
	move.b	#$FF,3(a0)

	lea	MsgWriteFAT,a0
	bsr	PrintMsg
	move.l	d4,d0
	addq.l	#1,d0			; FAT1 = start + 1
	moveq	#1,d1
	lea	sector_buf,a0
	bsr	CallRawWrite
	tst.l	d0
	bne	.fmt_err

	move.l	d4,d0
	addq.l	#1,d0
	moveq	#0,d2
	move.w	d3,d2
	add.l	d2,d0			; FAT2 = start + 1 + sectorsPerFat
	moveq	#1,d1
	lea	sector_buf,a0
	bsr	CallRawWrite
	tst.l	d0
	bne	.fmt_err

	; Zero the rest of FAT1
	bsr	ClearSectorBuf
	move.l	d4,d5
	addq.l	#2,d5
	move.w	d3,d6
	subq.w	#2,d6
	bmi.s	.fat1_done
.zfat1:
	move.l	d5,d0
	moveq	#1,d1
	lea	sector_buf,a0
	bsr	CallRawWrite
	tst.l	d0
	bne.s	.fmt_err
	addq.l	#1,d5
	dbra	d6,.zfat1
.fat1_done:

	; Zero the rest of FAT2 + 32 root directory sectors
	move.l	d4,d5
	addq.l	#2,d5
	moveq	#0,d2
	move.w	d3,d2
	add.l	d2,d5
	move.w	d3,d6
	addi.w	#32-2,d6
.zfat2_root:
	move.l	d5,d0
	moveq	#1,d1
	lea	sector_buf,a0
	bsr	CallRawWrite
	tst.l	d0
	bne.s	.fmt_err
	addq.l	#1,d5
	dbra	d6,.zfat2_root

	lea	MsgOK,a0
	bsr	PrintMsg
	moveq	#0,d0
.fmt_err:
	movem.l	(a7)+,d1-d7/a0-a3
	rts

; CopyBytes: copy 0-terminated string at a0 to a1 (no terminator copied)
CopyBytes:
	move.b	(a0)+,d0
	beq.s	.done
	move.b	d0,(a1)+
	bra.s	CopyBytes
.done:
	rts

;----------------------------------------
; Display parsed partition table and free space (40 columns)
; Detailed (1/line) for <= 7 partitions; compact 2-column for 8..14 partitions.
;----------------------------------------
DisplayPartitions:
	movem.l	d0-d4/a0-a4,-(a7)
	tst.w	mbr_valid
	bne.s	.valid
	lea	MsgNoMBR,a0
	bsr	PrintMsg
	bra	.free
.valid:
	move.w	part_count,d0
	bne.s	.list
	lea	MsgNoParts,a0
	bsr	PrintMsg
	bra	.free
.list:
	cmpi.w	#7,d0
	bhi.s	.compact

	; --- Detailed view (1..7 partitions): " P1: 200 MB at sector 128" ---
	moveq	#0,d2			; index 0..part_count-1
	move.w	d0,d3			; total count
.loop:
	move.b	#' ',d0
	bsr	PrintChar
	lea	part_kind,a0
	move.b	0(a0,d2.w),d0
	bsr	PrintChar
	moveq	#1,d0
	add.w	d2,d0
	bsr	PrintDec32
	lea	MsgColon,a0
	bsr	PrintMsg
	move.w	d2,d0
	lsl.w	#2,d0
	lea	part_len,a0
	move.l	0(a0,d0.w),d0
	bsr	PrintMB
	lea	MsgAtSector,a0
	bsr	PrintMsg
	move.w	d2,d0
	lsl.w	#2,d0
	lea	part_start,a0
	move.l	0(a0,d0.w),d0
	bsr	PrintDec32
	lea	MsgCRLF,a0
	bsr	PrintMsg
	addq.w	#1,d2
	cmp.w	d3,d2
	blo.s	.loop
	bra.s	.free

	; --- Compact 2-column view (8..14 partitions) ---
.compact:
	moveq	#0,d2			; index 0..part_count-1
	move.w	d0,d3
.cloop:
	lea	line_buf,a1
	bsr.s	.fmt_cell		; append " P1: 200 MB" to line_buf
	addq.w	#1,d2
	cmp.w	d3,d2
	bhs.s	.cflush
	lea	line_buf+19,a2
.cpad:
	move.b	#' ',(a1)+
	cmpa.l	a2,a1
	blo.s	.cpad
	bsr.s	.fmt_cell
	addq.w	#1,d2
.cflush:
	move.b	#$0D,(a1)+
	move.b	#$0A,(a1)+
	clr.b	(a1)
	lea	line_buf,a0
	bsr	PrintMsg
	cmp.w	d3,d2
	blo.s	.cloop

.free:
	lea	MsgFree,a0
	bsr	PrintMsg
	bsr	FreeSectors
	bsr	PrintMB
	lea	MsgCRLF,a0
	bsr	PrintMsg
	movem.l	(a7)+,d0-d4/a0-a4
	rts

; Helper local to DisplayPartitions: format " <P/L><n>: <MB> MB" at (a1)+
; Entry: d2.w = 0-based partition index. Clobbers d0/a0.
.fmt_cell:
	move.b	#' ',(a1)+
	lea	part_kind,a0
	move.b	0(a0,d2.w),(a1)+
	moveq	#1,d0
	add.w	d2,d0
	bsr.s	.app_dec
	move.b	#':',(a1)+
	move.b	#' ',(a1)+
	move.w	d2,d0
	lsl.w	#2,d0
	lea	part_len,a0
	move.l	0(a0,d0.w),d0
	lsr.l	#8,d0
	lsr.l	#3,d0
	bsr.s	.app_dec
	move.b	#' ',(a1)+
	move.b	#'M',(a1)+
	move.b	#'B',(a1)+
	rts

; Append unsigned d0.l decimal into (a1)+
.app_dec:
	movem.l	d0-d2/a0,-(a7)
	lea	num_str+11,a0
	clr.b	-(a0)
	tst.l	d0
	bne.s	.ad_loop
	move.b	#'0',-(a0)
	bra.s	.ad_copy
.ad_loop:
	tst.l	d0
	beq.s	.ad_copy
	move.l	d0,d1
	clr.w	d1
	swap	d1
	divu.w	#10,d1
	move.w	d1,d2
	move.w	d0,d1
	divu.w	#10,d1
	move.w	d2,d0
	swap	d0
	move.w	d1,d0
	swap	d1
	addi.b	#'0',d1
	move.b	d1,-(a0)
	bra.s	.ad_loop
.ad_copy:
	move.b	(a0)+,d0
	beq.s	.ad_done
	move.b	d0,(a1)+
	bra.s	.ad_copy
.ad_done:
	movem.l	(a7)+,d0-d2/a0
	rts

;----------------------------------------
; Driver calls
;----------------------------------------
Unmount:
	movem.l	d0-d2/a0-a2,-(a7)
	move.l	api_ptr,a0
	move.l	10(a0),a1		; SD_Unmount
	jsr	(a1)
	movem.l	(a7)+,d0-d2/a0-a2
	rts

; Remount: calls SD_Mount and reports its result
Remount:
	movem.l	d0-d2/a0-a2,-(a7)
	lea	MsgRemount,a0
	bsr	PrintMsg
	move.l	api_ptr,a0
	move.l	6(a0),a1		; SD_Mount -> d0 = partitions mounted
	jsr	(a1)
	tst.l	d0
	beq.s	.failed
	bsr	PrintDec32
	lea	MsgMounted,a0
	bsr	PrintMsg
	bra.s	.out
.failed:
	lea	MsgMountFail,a0
	bsr	PrintMsg
	move.l	api_ptr,a0
	cmpi.w	#$0105,4(a0)		; v1.5+: sd_err available
	blo.s	.out
	move.l	42(a0),a0
	moveq	#0,d0
	move.b	(a0),d0
	bsr	PrintDec32
	lea	MsgCRLF,a0
	bsr	PrintMsg
.out:
	tst.b	has_tgt_api
	beq.s	.done_remount
	move.w	active_target,d0
	bmi.s	.done_remount
	movem.l	d3-d7/a3-a6,-(a7)
	move.l	api_ptr,a0
	move.l	50(a0),a1		; Keep selected target active after remount
	jsr	(a1)
	movem.l	(a7)+,d3-d7/a3-a6
.done_remount:
	movem.l	(a7)+,d0-d2/a0-a2
	rts

CallRawRead:
	movem.l	d2-d7/a2-a6,-(a7)
	move.l	api_ptr,a1
	move.l	14(a1),a1		; SD_ReadData
	jsr	(a1)
	movem.l	(a7)+,d2-d7/a2-a6
	rts

CallRawWrite:
	movem.l	d2-d7/a2-a6,-(a7)
	move.l	api_ptr,a1
	move.l	18(a1),a1		; SD_WriteData
	jsr	(a1)
	movem.l	(a7)+,d2-d7/a2-a6
	rts

;----------------------------------------
; Helpers
;----------------------------------------
; DivU32: d0.l = d0.l / d1.l (unsigned, d1 > 0)
DivU32:
	movem.l	d2-d4,-(a7)
	moveq	#0,d2			; quotient
	moveq	#0,d3			; remainder
	moveq	#31,d4
.dloop:
	add.l	d0,d0
	addx.l	d3,d3
	add.l	d2,d2
	cmp.l	d1,d3
	bcs.s	.no_sub
	sub.l	d1,d3
	addq.l	#1,d2
.no_sub:
	dbra	d4,.dloop
	move.l	d2,d0
	movem.l	(a7)+,d2-d4
	rts

ClearSectorBuf:
	movem.l	d0/a0,-(a7)
	lea	sector_buf,a0
	moveq	#127,d0
.cl:
	clr.l	(a0)+
	dbra	d0,.cl
	movem.l	(a7)+,d0/a0
	rts

WriteLE32:
	move.b	d0,(a0)+
	lsr.l	#8,d0
	move.b	d0,(a0)+
	lsr.l	#8,d0
	move.b	d0,(a0)+
	lsr.l	#8,d0
	move.b	d0,(a0)+
	rts

ReadLE32:
	moveq	#0,d0
	move.b	3(a0),d0
	lsl.w	#8,d0
	move.b	2(a0),d0
	swap	d0
	move.b	1(a0),d0
	lsl.w	#8,d0
	move.b	0(a0),d0
	rts

ToUpper:
	cmpi.b	#'a',d0
	blo.s	.done
	cmpi.b	#'z',d0
	bhi.s	.done
	subi.b	#$20,d0
.done:
	rts

; PrintMB: d0 = sectors -> prints "<n> MB" (d0 preserved)
PrintMB:
	move.l	d0,-(a7)
	lsr.l	#8,d0
	lsr.l	#3,d0
	bsr	PrintDec32
	lea	MsgMB,a0
	bsr	PrintMsg
	move.l	(a7)+,d0
	rts

; PrintDec32: print d0.l as unsigned decimal
PrintDec32:
	movem.l	d0-d4/a0-a2,-(a7)
	lea	num_str+11,a1
	clr.b	-(a1)
	tst.l	d0
	bne.s	.div_loop
	move.b	#'0',-(a1)
	bra.s	.print_it
.div_loop:
	tst.l	d0
	beq.s	.print_it
	move.l	d0,d1
	clr.w	d1
	swap	d1
	divu.w	#10,d1
	move.w	d1,d2
	move.w	d0,d1
	divu.w	#10,d1
	move.w	d2,d0
	swap	d0
	move.w	d1,d0
	swap	d1
	addi.b	#'0',d1
	move.b	d1,-(a1)
	bra.s	.div_loop
.print_it:
	move.l	a1,a0
	bsr	PrintMsg
	movem.l	(a7)+,d0-d4/a0-a2
	rts

; ReadDec: decimal input (max 5 digits), echo, backspace, Enter ends.
; Returns d0.l = value, d1.w = digits typed (0 = nothing entered)
ReadDec:
	movem.l	d2-d3/a0,-(a7)
	moveq	#0,d2			; value
	moveq	#0,d3			; digits
.loop:
	bsr	ConIn
	cmpi.b	#$0D,d0
	beq.s	.done
	cmpi.b	#$08,d0
	beq.s	.bs
	cmpi.b	#'0',d0
	blo.s	.loop
	cmpi.b	#'9',d0
	bhi.s	.loop
	cmpi.w	#5,d3
	bhs.s	.loop
	bsr	ConOut
	subi.b	#'0',d0
	andi.l	#$0F,d0
	move.l	d2,d1
	lsl.l	#3,d2
	add.l	d1,d1
	add.l	d1,d2			; value * 10
	add.l	d0,d2
	addq.w	#1,d3
	bra.s	.loop
.bs:
	tst.w	d3
	beq.s	.loop
	subq.w	#1,d3
	move.l	d2,d0
	moveq	#10,d1
	bsr	DivU32
	move.l	d0,d2
	lea	StrBS,a0
	bsr	PrintMsg
	bra.s	.loop
.done:
	lea	MsgCRLF,a0
	bsr	PrintMsg
	move.l	d2,d0
	move.w	d3,d1
	movem.l	(a7)+,d2-d3/a0
	rts

PrintMsg:
	movem.l	d0-d7/a0-a6,-(a7)
	move.l	a0,-(a7)
	move.w	#$09,-(a7)		; Cconws
	trap	#1
	addq.l	#6,a7
	movem.l	(a7)+,d0-d7/a0-a6
	rts

ConIn:
	movem.l	d1-d7/a0-a6,-(a7)
	move.w	#$08,-(a7)		; Cnecin
	trap	#1
	addq.l	#2,a7
	movem.l	(a7)+,d1-d7/a0-a6
	rts

ConOut:
	movem.l	d0-d7/a0-a6,-(a7)
	andi.w	#$00FF,d0
	move.w	d0,-(a7)
	move.w	#$02,-(a7)		; Cconout
	trap	#1
	addq.l	#4,a7
	movem.l	(a7)+,d0-d7/a0-a6
	rts

WaitKey:
	movem.l	d1-d7/a0-a6,-(a7)
	move.w	#$07,-(a7)		; Crawcin
	trap	#1
	addq.l	#2,a7
	movem.l	(a7)+,d1-d7/a0-a6
	rts

NoDriver:
	lea	MsgNoDrv,a0
	bsr	PrintMsg
	bra.s	WaitAndExit
ReadError:
	lea	MsgRdErr,a0
	bsr	PrintMsg
	bra.s	WaitAndExit
WriteError:
	lea	MsgWrErr,a0
	bsr	PrintMsg
	bsr	Remount			; bring back whatever is still valid
WaitAndExit:
	lea	MsgAnyKey,a0
	bsr	PrintMsg
	bsr	WaitKey
ExitApp:
	move.l	sstack,-(a7)
	move.w	#$20,-(a7)		; Super(old ssp)
	trap	#1
	addq.l	#6,a7
	clr.w	-(a7)			; Pterm0
	trap	#1
	even

	section	data
	even

; All lines are kept under 40 characters for ST low resolution.
MsgHeader:
	dc.b	$1B,"E",$1B,"p"
	dc.b	" HDACSIST SD Partitioner / FAT16 v1.2 "
	dc.b	$1B,"q",$0D,$0A,$0D,$0A,0

MsgTargetID:	dc.b	"Target ID: ",0
MsgTgtReady:	dc.b	" (ready: ",0
MsgTgtNone:	dc.b	"none",0
MsgTgtEnd:	dc.b	")",$0D,$0A,0
MsgAskTarget:	dc.b	$0D,$0A,"Select target ID (0-7): ",0
MsgTgtNotReady:	dc.b	$0D,$0A,"Target not ready!",$0D,$0A,0
MsgOldDriver:	dc.b	"Old driver loaded (run INSTALL!)",$0D,$0A,0

MsgCardCap:	dc.b	"Card: ",0
MsgMB:		dc.b	" MB",0
MsgCRLF:	dc.b	$0D,$0A,0
MsgColon:	dc.b	": ",0
MsgAtSector:	dc.b	" at sector ",0
MsgNoParts:	dc.b	" No partitions.",$0D,$0A,0
MsgNoMBR:	dc.b	" No valid MBR on card.",$0D,$0A,0
MsgFree:	dc.b	" Free after last: ",0

MsgMenu:
	dc.b	$0D,$0A
	dc.b	"[A] Add partition (size in MB)",$0D,$0A
	dc.b	"[E] Equal partitions (erase)",$0D,$0A
	dc.b	"[D] Delete all partitions",$0D,$0A,0
MsgMenuTgt:
	dc.b	"[T] Switch ACSI target (0-7)",$0D,$0A,0
MsgMenuQuit:
	dc.b	"[Q] Quit",$0D,$0A,0

MsgEnterSize:	dc.b	$0D,$0A,"Size in MB (8-",0
MsgEnterSize2:	dc.b	"), Enter=cancel",$0D,$0A,"> ",0
MsgEqSize1:	dc.b	$0D,$0A,"Size per part MB (8-",0
MsgEqCount1:	dc.b	$0D,$0A,"How many partitions (1-",0
MsgCloseCancel:	dc.b	")",$0D,$0A,"Enter=cancel > ",0
MsgWarnTOS:	dc.b	$0D,$0A,"WARNING: >510MB not TOS 1.x compatible!",$0D,$0A,0
MsgConfirmAdd:	dc.b	"Add and format? (Y/N): ",0
MsgConfirmEq1:	dc.b	$0D,$0A,"WARNING: erases ALL data!",$0D,$0A,"Create ",0
MsgConfirmEq2:	dc.b	" x ",0
MsgConfirmEq3:	dc.b	" MB? (Y/N): ",0
MsgConfirmDel:
	dc.b	$0D,$0A,"Delete all partitions? (Y/N): ",0
MsgWorking:	dc.b	$0D,$0A,"Working...",$0D,$0A,0
MsgWriteMBR:	dc.b	"Write MBR... ",0
MsgWriteEBR:	dc.b	"Write EBR... ",0
MsgFormatting:	dc.b	"Format partition at ",0
MsgWriteBoot:	dc.b	" Boot sector... ",0
MsgWriteFAT:	dc.b	" FATs + root dir... ",0
MsgOK:		dc.b	"OK",$0D,$0A,0
MsgVerifyFail:	dc.b	"VERIFY FAILED",$0D,$0A,0
MsgRemount:	dc.b	"Remount: ",0
MsgMounted:	dc.b	" partition(s) mounted",$0D,$0A,0
MsgMountFail:	dc.b	"driver failed, stage ",0
MsgDone:	dc.b	"Done.",$0D,$0A,0
MsgAnyKey:	dc.b	"Press any key...",$0D,$0A,0
MsgTableFull:	dc.b	$0D,$0A,"Table full (max 14 partitions).",$0D,$0A,0
MsgNoExtSlot:	dc.b	$0D,$0A,"4 primary slots full (no ext).",$0D,$0A,0
MsgNoSpace:	dc.b	$0D,$0A,"Not enough free space (8 MB min).",$0D,$0A,0
MsgBadSize:	dc.b	"Invalid size.",$0D,$0A,0
MsgBadCount:	dc.b	"Invalid partition count.",$0D,$0A,0
StrBS:		dc.b	$08," ",$08,0
StrLabel:	dc.b	"SDCARD     ",0
StrFSType:	dc.b	"FAT16   ",0

MsgNoDrv:	dc.b	"HDACSIST driver not installed!",$0D,$0A,0
MsgNoCard:	dc.b	"Cannot read card capacity!",$0D,$0A,0
MsgRdErr:	dc.b	"Read error!",$0D,$0A,0
MsgWrErr:	dc.b	"Write error!",$0D,$0A,0
	even

	section	bss
	even

sstack:			ds.l	1
api_ptr:		ds.l	1
total_sectors:		ds.l	1
part_size_sectors:	ds.l	1
next_free:		ds.l	1
max_mb:			ds.l	1
ext_base:		ds.l	1
ext_len:		ds.l	1
last_ebr:		ds.l	1
add_ebr_lba:		ds.l	1
part_start:		ds.l	MAX_PARTS
part_len:		ds.l	MAX_PARTS
num_parts_req:		ds.w	1
part_count:		ds.w	1
mbr_used:		ds.w	1
first_free_slot:	ds.w	1
ext_slot:		ds.w	1
mbr_valid:		ds.w	1
active_target:		ds.w	1
max_eq_parts:		ds.w	1
target_mask:		ds.l	1
part_kind:		ds.b	MAX_PARTS
has_tgt_api:		ds.b	1
ext_type:		ds.b	1
pri_after_ext:		ds.b	1
add_mode:		ds.b	1
num_str:		ds.b	12
line_buf:		ds.b	44
	even
sector_buf:		ds.b	512
verify_buf:		ds.b	512
	even
stack:			ds.l	512		; 2 KB private stack
stack_top: