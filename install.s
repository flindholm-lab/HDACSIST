;
; INSTALL.PRG v1.2 - Hard Drive Boot Installer for HDACSIST.PRG (Atari ST)
; 40-column layout (ST low resolution).
;
; Installs HDACSIST.PRG into reserved sectors 1..N (between MBR at sector 0
; and Partition 1) and writes a Stage-1 DMA boot loader into MBR bytes 0..439
; with checksum $1234 in bytes 444..445 while preserving the PC MBR partition
; table (446..509) and $55AA signature (510..511).
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
MAX_PRG_BYTES	equ	32768		; 64 sectors max payload
MAX_PRG_SECTS	equ	64

	section	text

	move.l	4(a7),a0		; basepage
	lea	stack_top,a7		; own stack before Mshrink
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

	move.l	$472.w,a0		; hdv_bpb
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
	bra	.show_menu
.card_ok:
	lea	MsgCardCap,a0
	bsr	PrintMsg
	move.l	total_sectors,d0
	bsr	PrintMB
	lea	MsgCRLF,a0
	bsr	PrintMsg

	; Read sector 0 (MBR)
	moveq	#0,d0
	moveq	#1,d1
	lea	mbr_buf,a0
	bsr	CallRawRead
	tst.l	d0
	bne	ReadError

	bsr	InspectMBR

	tst.w	mbr_valid
	bne.s	.mbr_ok
	lea	MsgNoMBR,a0
	bsr	PrintMsg
	bra.s	.show_menu
.mbr_ok:
	lea	MsgMinPart,a0
	bsr	PrintMsg
	move.l	min_part_start,d0
	bsr	PrintDec32
	lea	MsgCRLF,a0
	bsr	PrintMsg

	lea	MsgBootStat,a0
	bsr	PrintMsg
	tst.w	boot_installed
	bne.s	.is_inst
	lea	MsgNotInst,a0
	bra.s	.pr_stat
.is_inst:
	lea	MsgInst,a0
.pr_stat:
	bsr	PrintMsg

.show_menu:
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
	cmpi.b	#'I',d0
	beq	DoInstall
	cmpi.b	#'U',d0
	beq	DoUninstall
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

RefreshTargets:
	movem.l	d2-d7/a2-a6,-(a7)
	move.l	api_ptr,a0
	move.l	50(a0),a1
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
	moveq	#0,d1
	moveq	#0,d3
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

MsgAndMenu:
	bsr	PrintMsg
	lea	MsgAnyKey,a0
	bsr	PrintMsg
	bsr	WaitKey
	bra	MainMenu

;----------------------------------------
; [I] Install / Update boot loader + driver payload
;----------------------------------------
DoInstall:
	tst.w	mbr_valid
	bne.s	.mbr_ok
	lea	MsgRunPart,a0
	bra	MsgAndMenu
.mbr_ok:
	bsr	LoadDriverPRG
	tst.l	d0
	beq.s	.prg_ok
	lea	MsgNoPRG,a0
	bra	MsgAndMenu
.prg_ok:
	; Verify space before first partition: 1 + sectors_needed <= min_part_start
	moveq	#0,d0
	move.w	prg_sectors,d0
	addq.l	#1,d0
	cmp.l	min_part_start,d0
	bls.s	.space_ok
	lea	MsgNoGap,a0
	bra	MsgAndMenu
.space_ok:
	lea	MsgFoundPRG,a0
	bsr	PrintMsg
	move.l	prg_len,d0
	bsr	PrintDec32
	lea	MsgBytesSects,a0
	bsr	PrintMsg
	moveq	#0,d0
	move.w	prg_sectors,d0
	bsr	PrintDec32
	lea	MsgSectsEnd,a0
	bsr	PrintMsg

	lea	MsgConfirmInst,a0
	bsr	PrintMsg
	bsr	WaitKey
	bsr	ToUpper
	cmpi.b	#'Y',d0
	bne	MainMenu

	; 1. Write Stage-2 driver payload to sectors 1..prg_sectors
	lea	MsgWriteStage2,a0
	bsr	PrintMsg
	moveq	#1,d0
	move.w	prg_sectors,d1
	lea	prg_buf,a0
	bsr	CallRawWrite
	tst.l	d0
	bne	WriteError

	moveq	#1,d0
	move.w	prg_sectors,d1
	lea	verify_buf,a0
	bsr	CallRawRead
	tst.l	d0
	bne	ReadError

	; Compare sectors_needed * 512 bytes
	move.w	prg_sectors,d0
	lsl.w	#7,d0			; * 128 longs per sector
	subq.w	#1,d0
	lea	prg_buf,a0
	lea	verify_buf,a1
.cmp_s2:
	cmpm.l	(a0)+,(a1)+
	bne	VerifyFail
	dbra	d0,.cmp_s2
	lea	MsgOK,a0
	bsr	PrintMsg

	; 2. Build Stage-1 boot sector in mbr_buf (preserving 440..443 and 446..511)
	lea	MsgWriteStage1,a0
	bsr	PrintMsg

	; Zero 0..439
	lea	mbr_buf,a0
	move.w	#439,d0
.clr_bs:
	clr.b	(a0)+
	dbra	d0,.clr_bs

	; Copy Stage-1 code
	lea	stage1_start,a0
	lea	mbr_buf,a1
	move.w	#(stage1_end-stage1_start)-1,d0
.cp_s1:
	move.b	(a0)+,(a1)+
	dbra	d0,.cp_s1

	; Patch prg_sectors and prg_alloc_size into mbr_buf
	lea	mbr_buf,a0
	move.w	prg_sectors,(stage1_sectors-stage1_start)(a0)
	move.l	prg_alloc_size,(stage1_alloc_size-stage1_start)(a0)

	; Compute 16-bit big-endian word checksum excluding bytes 444..445,
	; then set bytes 444..445 so total checksum == $1234
	clr.w	444(a0)
	movea.l	a0,a1
	moveq	#0,d0
	move.w	#255,d1
.sum_s1:
	add.w	(a1)+,d0
	dbra	d1,.sum_s1
	move.w	#$1234,d1
	sub.w	d0,d1
	move.w	d1,444(a0)

	; Write and verify sector 0
	moveq	#0,d0
	moveq	#1,d1
	lea	mbr_buf,a0
	bsr	CallRawWrite
	tst.l	d0
	bne	WriteError

	moveq	#0,d0
	moveq	#1,d1
	lea	verify_buf,a0
	bsr	CallRawRead
	tst.l	d0
	bne	ReadError

	lea	mbr_buf,a0
	lea	verify_buf,a1
	move.w	#127,d0
.cmp_s1:
	cmpm.l	(a0)+,(a1)+
	bne	VerifyFail
	dbra	d0,.cmp_s1
	lea	MsgOK,a0
	bsr	PrintMsg

	lea	MsgDone,a0
	bra	MsgAndMenu

;----------------------------------------
; [U] Uninstall Stage-1 boot loader from sector 0
;----------------------------------------
DoUninstall:
	tst.w	mbr_valid
	bne.s	.mbr_ok
	lea	MsgRunPart,a0
	bra	MsgAndMenu
.mbr_ok:
	lea	MsgConfirmUninst,a0
	bsr	PrintMsg
	bsr	WaitKey
	bsr	ToUpper
	cmpi.b	#'Y',d0
	bne	MainMenu

	lea	MsgUninstalling,a0
	bsr	PrintMsg

	; Clear bytes 0..445 (leaving PC MBR 446..511 intact)
	lea	mbr_buf,a0
	move.w	#445,d0
.clr_un:
	clr.b	(a0)+
	dbra	d0,.clr_un

	; Guard against accidental $1234 checksum
	lea	mbr_buf,a0
	movea.l	a0,a1
	moveq	#0,d0
	move.w	#255,d1
.sum_un:
	add.w	(a1)+,d0
	dbra	d1,.sum_un
	cmpi.w	#$1234,d0
	bne.s	.ck_ok
	addq.b	#1,444(a0)
.ck_ok:
	moveq	#0,d0
	moveq	#1,d1
	bsr	CallRawWrite
	tst.l	d0
	bne	WriteError

	moveq	#0,d0
	moveq	#1,d1
	lea	verify_buf,a0
	bsr	CallRawRead
	tst.l	d0
	bne	ReadError

	lea	mbr_buf,a0
	lea	verify_buf,a1
	move.w	#127,d0
.cmp_un:
	cmpm.l	(a0)+,(a1)+
	bne	VerifyFail
	dbra	d0,.cmp_un

	lea	MsgOK,a0
	bsr	PrintMsg
	lea	MsgDone,a0
	bra	MsgAndMenu

;----------------------------------------
; InspectMBR: sets mbr_valid, boot_installed, min_part_start
;----------------------------------------
InspectMBR:
	movem.l	d0-d3/a0-a1,-(a7)
	clr.w	mbr_valid
	clr.w	boot_installed
	clr.l	min_part_start

	lea	mbr_buf,a0
	cmpi.b	#$55,510(a0)
	bne.s	.done
	cmpi.b	#$AA,511(a0)
	bne.s	.done

	; Check if 'A2ST' signature is at offset 2 and 256-word sum == $1234
	cmpi.l	#'A2ST',2(a0)
	bne.s	.chk_parts
	movea.l	a0,a1
	moveq	#0,d0
	move.w	#255,d1
.sum:
	add.w	(a1)+,d0
	dbra	d1,.sum
	cmpi.w	#$1234,d0
	bne.s	.chk_parts
	move.w	#1,boot_installed

.chk_parts:
	move.l	#$FFFFFFFF,d2		; min_part_start candidate
	lea	446(a0),a1
	moveq	#3,d3
.ploop:
	lea	12(a1),a0
	bsr	ReadLE32		; partition length
	tst.l	d0
	beq.s	.pnext
	lea	8(a1),a0
	bsr	ReadLE32		; partition start LBA
	tst.l	d0
	beq.s	.pnext
	cmp.l	d2,d0
	bhs.s	.pnext
	move.l	d0,d2
.pnext:
	lea	16(a1),a1
	dbra	d3,.ploop

	cmpi.l	#$FFFFFFFF,d2
	beq.s	.done			; no non-empty partition found
	move.l	d2,min_part_start
	move.w	#1,mbr_valid
.done:
	movem.l	(a7)+,d0-d3/a0-a1
	rts

;----------------------------------------
; LoadDriverPRG: Locate and read ACSI2STM.PRG into prg_buf.
; Sets prg_len, prg_sectors, prg_alloc_size.
; Returns d0.l = 0 ok, -1 error.
;----------------------------------------
LoadDriverPRG:
	movem.l	d1-d3/a0-a2,-(a7)
	lea	PrgPathList,a2
.try_path:
	move.l	(a2)+,d0
	beq	.not_found
	movea.l	d0,a0
	clr.w	-(a7)			; mode 0 = read-only
	move.l	a0,-(a7)
	move.w	#$3D,-(a7)		; Fopen
	trap	#1
	addq.l	#8,a7
	tst.l	d0
	bmi.s	.try_path

	move.w	d0,d3			; d3.w = file handle

	; Zero prg_buf so sector padding is clean
	lea	prg_buf,a0
	move.w	#(MAX_PRG_BYTES/4)-1,d0
.zprg:
	clr.l	(a0)+
	dbra	d0,.zprg

	; Read up to MAX_PRG_BYTES
	pea	prg_buf
	move.l	#MAX_PRG_BYTES,-(a7)
	move.w	d3,-(a7)
	move.w	#$3F,-(a7)		; Fread
	trap	#1
	lea	12(a7),a7
	move.l	d0,d2			; d2.l = bytes read

	move.w	d3,-(a7)
	move.w	#$3E,-(a7)		; Fclose
	trap	#1
	addq.l	#4,a7

	cmpi.l	#28,d2
	blt.s	.not_found
	cmpi.l	#MAX_PRG_BYTES,d2
	bge.s	.not_found		; reject oversized/truncated files

	lea	prg_buf,a0
	cmpi.w	#$601A,(a0)		; TOS PRG header magic?
	bne.s	.not_found

	move.l	d2,prg_len
	addi.l	#511,d2
	moveq	#9,d0
	lsr.l	d0,d2
	move.w	d2,prg_sectors

	move.l	2(a0),d0		; tlen
	add.l	6(a0),d0		; + dlen
	add.l	10(a0),d0		; + blen
	addi.l	#28,d0			; + 28-byte PRG header
	move.l	d0,prg_alloc_size

	moveq	#0,d0
	bra.s	.out
.not_found:
	moveq	#-1,d0
.out:
	movem.l	(a7)+,d1-d3/a0-a2
	rts

;----------------------------------------
; Driver calls
;----------------------------------------
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
; Stage-1 DMA Boot Sector (must fit in <= 440 bytes)
; Executed by Atari TOS dmaboot inside _dskbufp with d7.w = (acsi_id << 5).
;----------------------------------------
	even
stage1_start:
	bra.s	stage1_boot		; +0
	dc.b	'A','2','S','T'		; +2: 'A2ST' marker
stage1_sectors:
	dc.w	0			; +6: patched by INSTALL.PRG
stage1_alloc_size:
	dc.l	0			; +8: patched by INSTALL.PRG

stage1_boot:
	movem.l	d0-d7/a0-a6,-(a7)

	; Hold Alternate during boot to skip loading the HD driver (pure floppy boot)
	move.w	#-1,-(a7)
	move.w	#11,-(a7)		; BIOS Kbshift(-1)
	trap	#13
	addq.l	#4,a7
	btst.l	#3,d0			; Bit 3 = Alternate
	bne	.s1_done

	; Skip if driver is already installed
	movea.l	$472.w,a0		; hdv_bpb
	cmpi.l	#INSTALL_MARKER,-10(a0)
	beq	.s1_done

	; Allocate resident memory (shrink by 32KB on 512KB ST)
	move.l	stage1_alloc_size(pc),d0
	cmpi.l	#$100000,$42E.w		; phystop >= 1MB?
	bhs.s	.s1_alloc
	subi.l	#32768,d0
.s1_alloc:
	move.l	d0,d6			; d6 = allocated byte size
	move.l	d0,-(a7)
	move.w	#$48,-(a7)		; GEMDOS Malloc
	trap	#1
	addq.l	#6,a7
	tst.l	d0
	ble	.s1_done
	movea.l	d0,a4			; a4 = resident block base

	; Read Stage-2 payload from LBA 1..N using ACSI READ(6) ($08)
	move.w	stage1_sectors(pc),d5
	andi.w	#$00E0,d7		; keep ACSI boot target ID in bits 7..5
	move.w	d7,d4
	ori.w	#$0008,d4		; byte 0 = (id << 5) | $08

	st	$43E.w			; lock FLOCK
	lea	$FFFF8604.w,a2
	lea	$FFFF8606.w,a3
	moveq	#0,d1			; zero register for write-only DMA stores (avoid 68000 CLR read cycle)
	moveq	#3,d3			; up to 4 attempts on cold boot
.s1_retry:
	move.w	#$0190,(a3)		; reset DMA FIFO (read)
	move.w	#$0090,(a3)
	move.l	a4,d0
	move.b	d0,$FFFF860D.w
	lsr.l	#8,d0
	move.b	d0,$FFFF860B.w
	lsr.w	#8,d0
	move.b	d0,$FFFF8609.w
	move.w	d5,(a2)			; sector count

	move.w	#$0088,(a3)		; A1 = 0
	move.w	d4,(a2)			; byte 0: (id << 5) | $08
	move.w	#$008A,(a3)		; A1 = 1
	bsr	.s1_wait_cmd
	bne.s	.s1_next_try

	move.w	d1,(a2)			; byte 1: LBA[20:16] = 0
	bsr	.s1_wait_cmd
	bne.s	.s1_next_try
	move.w	d1,(a2)			; byte 2: LBA[15:8] = 0
	bsr	.s1_wait_cmd
	bne.s	.s1_next_try
	move.w	#1,(a2)			; byte 3: LBA[7:0] = 1
	bsr	.s1_wait_cmd
	bne.s	.s1_next_try
	move.w	d5,(a2)			; byte 4: sector count
	bsr	.s1_wait_cmd
	bne.s	.s1_next_try

	move.w	d1,(a2)			; byte 5: control = 0
	move.w	d1,(a3)			; $0000: enable DMA read

	move.l	#1000,d0		; 5 s timeout for DMA + status
	bsr	.s1_wait_irq
	bne.s	.s1_next_try
	move.w	#$008A,(a3)
	move.w	(a2),d0
	andi.w	#$00FF,d0
	beq.s	.s1_read_ok
.s1_next_try:
	move.w	#$0080,(a3)
	moveq	#4,d0
	add.l	$4BA.w,d0
.s1_pause:
	cmp.l	$4BA.w,d0
	bhi.s	.s1_pause
	dbra	d3,.s1_retry
	bra.s	.s1_read_err
.s1_read_ok:
	clr.w	$43E.w			; unlock FLOCK

	; Validate TOS PRG magic ($601A)
	cmpi.w	#$601A,(a4)
	bne.s	.s1_free_fail

	; Relocate TOS PRG in place: a5 = TEXT base = a4 + 28
	lea	28(a4),a5
	tst.w	26(a4)			; abs_flag != 0 means no reloc table
	bne.s	.s1_reloc_done

	move.l	2(a4),d0		; tlen
	add.l	6(a4),d0		; + dlen
	movea.l	a5,a2
	adda.l	d0,a2
	adda.l	14(a4),a2		; a2 -> reloc table (after TEXT+DATA+SYM)

	move.l	(a2)+,d0		; first reloc offset (0 = none)
	beq.s	.s1_reloc_done
	lea	0(a5,d0.l),a3
	move.l	a5,d1			; reloc delta = TEXT base
	add.l	d1,(a3)
	moveq	#0,d0
.s1_reloc_loop:
	move.b	(a2)+,d0
	beq.s	.s1_reloc_done
	cmpi.b	#1,d0
	bne.s	.s1_reloc_step
	adda.w	#254,a3
	bra.s	.s1_reloc_loop
.s1_reloc_step:
	adda.w	d0,a3
	add.l	d1,(a3)
	bra.s	.s1_reloc_loop

.s1_reloc_done:
	; Clear BSS (from TEXT + tlen + dlen to end of allocated block)
	move.l	2(a4),d0
	add.l	6(a4),d0
	lea	0(a5,d0.l),a0
	lea	0(a4,d6.l),a1
.s1_clr_bss:
	clr.b	(a0)+
	cmpa.l	a1,a0
	blo.s	.s1_clr_bss

	; Jump to driver's DMA boot entry point (TEXT + 4), passing d7 = id << 5
	jsr	4(a5)

.s1_done:
	movem.l	(a7)+,d0-d7/a0-a6
	rts

.s1_read_err:
	move.w	#$0080,(a3)
	clr.w	$43E.w
.s1_free_fail:
	move.l	a4,-(a7)
	move.w	#$49,-(a7)		; GEMDOS Mfree
	trap	#1
	addq.l	#6,a7
	bra.s	.s1_done

.s1_wait_cmd:
	moveq	#20,d0
.s1_wait_irq:
	add.l	$4BA.w,d0
.s1_wloop:
	btst.b	#5,$FFFFFA01.w
	beq.s	.s1_wok
	cmp.l	$4BA.w,d0
	bhi.s	.s1_wloop
	moveq	#-1,d0
	rts
.s1_wok:
	moveq	#0,d0
	rts
stage1_end:

	IFGT	(stage1_end-stage1_start)-440
	FAIL	"Stage-1 boot sector exceeds 440 bytes!"
	ENDC

;----------------------------------------
; Helpers
;----------------------------------------
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

PrintMB:
	move.l	d0,-(a7)
	lsr.l	#8,d0
	lsr.l	#3,d0
	bsr	PrintDec32
	lea	MsgMB,a0
	bsr	PrintMsg
	move.l	(a7)+,d0
	rts

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

PrintMsg:
	movem.l	d0-d7/a0-a6,-(a7)
	move.l	a0,-(a7)
	move.w	#$09,-(a7)		; Cconws
	trap	#1
	addq.l	#6,a7
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
	bra.s	WaitAndExit
VerifyFail:
	lea	MsgVerifyFail,a0
	bsr	PrintMsg
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

PrgPathList:
	dc.l	StrPath1
	dc.l	StrPath2
	dc.l	StrPath3
	dc.l	StrPath4
	dc.l	0

StrPath1:	dc.b	"HDACSIST.PRG",0
StrPath2:	dc.b	"\AUTO\HDACSIST.PRG",0
StrPath3:	dc.b	"A:\HDACSIST.PRG",0
StrPath4:	dc.b	"A:\AUTO\HDACSIST.PRG",0

; All lines strictly under 40 characters for ST low resolution.
MsgHeader:
	dc.b	$1B,"E",$1B,"p"
	dc.b	" HDACSIST Hard Drive Installer v1.2   "
	dc.b	$1B,"q",$0D,$0A,$0D,$0A,0

MsgTargetID:	dc.b	"Target ID: ",0
MsgTgtReady:	dc.b	" (ready: ",0
MsgTgtNone:	dc.b	"none",0
MsgTgtEnd:	dc.b	")",$0D,$0A,0
MsgAskTarget:	dc.b	$0D,$0A,"Select target ID (0-7): ",0
MsgTgtNotReady:	dc.b	$0D,$0A,"Target not ready!",$0D,$0A,0
MsgOldDriver:	dc.b	"Old driver loaded - [I] updates",$0D,$0A,0

MsgCardCap:	dc.b	"Card: ",0
MsgMB:		dc.b	" MB",0
MsgCRLF:	dc.b	$0D,$0A,0
MsgNoMBR:	dc.b	"No valid partitioned MBR.",$0D,$0A,0
MsgMinPart:	dc.b	"First partition at LBA ",0
MsgBootStat:	dc.b	"Boot loader: ",0
MsgInst:	dc.b	"Installed",$0D,$0A,0
MsgNotInst:	dc.b	"Not installed",$0D,$0A,0

MsgMenu:
	dc.b	$0D,$0A
	dc.b	"[I] Install / Update boot driver",$0D,$0A
	dc.b	"[U] Uninstall boot loader",$0D,$0A,0
MsgMenuTgt:
	dc.b	"[T] Switch ACSI target (0-7)",$0D,$0A,0
MsgMenuQuit:
	dc.b	"[Q] Quit",$0D,$0A,0

MsgRunPart:	dc.b	$0D,$0A,"Run SDPART.PRG first!",$0D,$0A,0
MsgNoPRG:	dc.b	$0D,$0A,"HDACSIST.PRG not found!",$0D,$0A,0
MsgNoGap:	dc.b	$0D,$0A,"Not enough space before P1!",$0D,$0A,0
MsgFoundPRG:	dc.b	$0D,$0A,"Driver: ",0
MsgBytesSects:	dc.b	" bytes (",0
MsgSectsEnd:	dc.b	" sectors)",$0D,$0A,0
MsgConfirmInst:	dc.b	"Install boot driver? (Y/N): ",0
MsgConfirmUninst:
	dc.b	$0D,$0A,"Remove boot loader? (Y/N): ",0
MsgWriteStage2:	dc.b	$0D,$0A,"Write Stage-2 sectors... ",0
MsgWriteStage1:	dc.b	"Write Stage-1 MBR boot... ",0
MsgUninstalling:
	dc.b	$0D,$0A,"Clearing boot loader... ",0
MsgOK:		dc.b	"OK",$0D,$0A,0
MsgVerifyFail:	dc.b	"VERIFY FAILED!",$0D,$0A,0
MsgDone:	dc.b	"Done. Reboot without floppy!",$0D,$0A,0
MsgAnyKey:	dc.b	"Press any key...",$0D,$0A,0

MsgNoDrv:	dc.b	"HDACSIST driver not installed!",$0D,$0A,0
MsgNoCard:	dc.b	"Cannot read card capacity!",$0D,$0A,0
MsgRdErr:	dc.b	"Read error!",$0D,$0A,0
MsgWrErr:	dc.b	"Write error!",$0D,$0A,0
	even

	section	bss
	even

sstack:		ds.l	1
api_ptr:	ds.l	1
total_sectors:	ds.l	1
min_part_start:	ds.l	1
prg_len:	ds.l	1
prg_alloc_size:	ds.l	1
prg_sectors:	ds.w	1
mbr_valid:	ds.w	1
boot_installed:	ds.w	1
active_target:	ds.w	1
target_mask:	ds.l	1
has_tgt_api:	ds.b	1
num_str:	ds.b	12
	even
mbr_buf:	ds.b	512
	even
prg_buf:	ds.b	MAX_PRG_BYTES
verify_buf:	ds.b	MAX_PRG_BYTES
	even
stack:		ds.l	512		; 2 KB private stack
stack_top:
