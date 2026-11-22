;
; HDACSIST.ACC - GEM Desk Accessory to Mount & Unmount ACSI SD Drives
; Supports up to 14 drives (C:..P:) and sends SH_WDRAW to refresh GEM Desktop.
; Adapts sdextjoyacc.s for HDACSIST ACSI DMA driver (SD_API_Table at -14(hdv_bpb)).
;
; Copyright (c) 2020 Orion_ (original sdextjoyacc.s / SD_API_Table design)
; Copyright (c) 2026 Ninjabuffy (adapted for HDACSIST 14-drive ACSI & error codes)
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

INSTALL_MARKER		equ	$CEDBCEDB
MAX_MOUNTED_PARTS	equ	14		; TOS drives C:..P:
AC_OPEN			equ	40
SH_WDRAW		equ	72

	section	text

Start:
	; Desk Accessories start with no basepage on stack; set our own internal stack
	lea	acc_stack_top,a7

	; Build the AES parameter block at runtime so the data section holds no
	; relocations (works around TOS-output relocation issues in old vasm)
	lea	aes_pb,a0
	move.l	#control,(a0)+
	move.l	#global,(a0)+
	move.l	#int_in,(a0)+
	move.l	#int_out,(a0)+
	move.l	#addr_in,(a0)+
	move.l	#addr_out,(a0)

	; 1. appl_init()
	move.w	#10,control
	clr.w	control+2
	move.w	#1,control+4
	clr.w	control+6
	clr.w	control+8
	bsr	aes_call
	move.w	int_out,ap_id

	; 2. menu_register(ap_id, "  HDACSIST Mount")
	move.w	#35,control
	move.w	#1,control+2
	move.w	#1,control+4
	move.w	#1,control+6
	clr.w	control+8
	move.w	ap_id,int_in
	move.l	#MenuTitle,addr_in
	bsr	aes_call
	move.w	int_out,menu_id

EventLoop:
	; 3. evnt_mesag(msg_buf)
	move.w	#23,control
	clr.w	control+2
	move.w	#1,control+4
	move.w	#1,control+6
	clr.w	control+8
	move.l	#msg_buf,addr_in
	bsr	aes_call

	cmpi.w	#AC_OPEN,msg_buf
	bne.s	EventLoop

	; Check if HDACSIST driver is installed via Supexec
	pea	SuCheckDriver(pc)
	move.w	#38,-(a7)		; Supexec
	trap	#14
	addq.l	#6,a7
	tst.l	d0
	bne.s	.driver_ok

	lea	AlertNoDriver,a0
	moveq	#1,d0
	bsr	form_alert
	bra.s	EventLoop

.driver_ok:
	bsr	BuildStatusAlert
	lea	AlertMainBuf,a0
	moveq	#1,d0
	bsr	form_alert

	cmpi.w	#1,d0			; Button 1: [Mount]
	beq.s	.do_mount
	cmpi.w	#2,d0			; Button 2: [Unmount]
	beq.s	.do_unmount
	bra.s	EventLoop		; Button 3: [Cancel]

.do_mount:
	pea	SuMount(pc)
	move.w	#38,-(a7)
	trap	#14
	addq.l	#6,a7
	tst.l	d0
	beq.s	.mount_err

	bsr	NotifyDesktopRefresh
	bsr	BuildMountedAlert
	lea	AlertMainBuf,a0
	moveq	#1,d0
	bsr	form_alert
	bra	EventLoop

.mount_err:
	bsr	BuildFailAlert
	lea	AlertMainBuf,a0
	moveq	#1,d0
	bsr	form_alert
	bra	EventLoop

.do_unmount:
	pea	SuUnmount(pc)
	move.w	#38,-(a7)
	trap	#14
	addq.l	#6,a7

	bsr	NotifyDesktopRefresh
	lea	AlertUnmounted,a0
	moveq	#1,d0
	bsr	form_alert
	bra	EventLoop

;----------------------------------------
; Supervisor Helper Routines (via XBIOS Supexec)
;----------------------------------------
SuCheckDriver:
	move.l	$472.w,a0
	cmpi.l	#INSTALL_MARKER,-10(a0)
	bne.s	.no_drv
	move.l	-14(a0),a1
	cmpi.l	#INSTALL_MARKER,(a1)
	bne.s	.no_drv
	move.l	a1,api_ptr
	moveq	#1,d0
	rts
.no_drv:
	moveq	#0,d0
	rts

SuMount:
	move.l	api_ptr,a0
	move.l	6(a0),a1		; SD_Mount
	jsr	(a1)
	rts

SuUnmount:
	move.l	api_ptr,a0
	move.l	10(a0),a1		; SD_Unmount
	jsr	(a1)
	rts

;----------------------------------------
; Build dynamic alerts showing up to 14 mounted drives wrapped within TOS limits
;----------------------------------------
BuildStatusAlert:
	lea	StrPrefix,a1
	lea	StrSuffix,a2
	bra.s	BuildDriveAlert

BuildMountedAlert:
	lea	StrMountPrefix,a1
	lea	StrMountSuffix,a2

; Shared helper: a1 = prefix, a2 = suffix
BuildDriveAlert:
	lea	AlertMainBuf,a0
	bsr	CopyStr
	bsr.s	AppendDriveList
	movea.l	a2,a1
	bsr	CopyStr
	clr.b	(a0)
	rts

; Append active drives from api_ptr->sd_drive[0..13], wrapping at 5 and 11 drives
; so every alert line stays within Atari TOS form_alert width/line limits.
AppendDriveList:
	move.l	api_ptr,a3
	move.l	26(a3),a3		; sd_drive array (MAX_MOUNTED_PARTS words)
	moveq	#0,d3			; active count
	moveq	#MAX_MOUNTED_PARTS-1,d2
.drv_loop:
	move.w	(a3)+,d0
	bmi.s	.next_drv
	tst.w	d3
	beq.s	.emit_drv
	cmpi.w	#5,d3			; wrap after first 5 drives ("Drives: C:..G:")
	beq.s	.wrap_line
	cmpi.w	#11,d3			; wrap after next 6 drives ("H:..M:")
	beq.s	.wrap_line
	move.b	#' ',(a0)+
	bra.s	.emit_drv
.wrap_line:
	move.b	#'|',(a0)+
.emit_drv:
	addq.w	#1,d3
	addi.b	#'A',d0
	move.b	d0,(a0)+
	move.b	#':',(a0)+
.next_drv:
	dbra	d2,.drv_loop

	tst.w	d3
	bne.s	.done_list
	lea	StrNone,a1
	bsr.s	CopyStr
.done_list:
	rts

;----------------------------------------
; Build mount-failure alert using HDACSIST sd_err codes (API v1.5+ at +42)
;----------------------------------------
BuildFailAlert:
	lea	AlertMainBuf,a0
	lea	StrFailPrefix,a1
	bsr.s	CopyStr

	move.l	api_ptr,a2
	cmpi.w	#$0105,4(a2)		; API version
	blo.s	.generic
	move.l	42(a2),a2		; -> sd_err
	moveq	#0,d0
	move.b	(a2),d0
	cmpi.w	#7,d0
	bhi.s	.generic
	add.w	d0,d0
	lea	FailTable,a1
	move.w	(a1,d0.w),d0		; word offset from StrFail0
	lea	StrFail0,a1
	adda.w	d0,a1
	bsr.s	CopyStr
	bra.s	.suffix
.generic:
	lea	StrFailGeneric,a1
	bsr.s	CopyStr
.suffix:
	lea	StrFailSuffix,a1
	bsr.s	CopyStr
	clr.b	(a0)
	rts

CopyStr:
	move.b	(a1)+,d0
	beq.s	.done
	move.b	d0,(a0)+
	bra.s	CopyStr
.done:
	rts

;----------------------------------------
; Broadcast SH_WDRAW (72) to Desktop (App ID 0) to refresh drive icons/windows
;----------------------------------------
NotifyDesktopRefresh:
	move.w	#12,control		; appl_write(0, 16, wdraw_msg)
	move.w	#2,control+2
	move.w	#1,control+4
	move.w	#1,control+6
	clr.w	control+8

	clr.w	int_in			; Dest App ID = 0 (Desktop / Shell)
	move.w	#16,int_in+2		; 16-byte message

	move.w	#SH_WDRAW,wdraw_msg
	move.w	ap_id,wdraw_msg+2
	clr.w	wdraw_msg+4
	move.w	#-1,wdraw_msg+6		; -1 = Refresh all drives
	clr.l	wdraw_msg+8
	clr.l	wdraw_msg+12

	move.l	#wdraw_msg,addr_in
	bsr.s	aes_call
	rts

;----------------------------------------
; AES Wrapper
;----------------------------------------
form_alert:				; a0 = string, d0 = default button
	move.w	#52,control
	move.w	#1,control+2
	move.w	#1,control+4
	move.w	#1,control+6
	clr.w	control+8
	move.w	d0,int_in
	move.l	a0,addr_in
	bsr.s	aes_call
	move.w	int_out,d0
	rts

aes_call:
	move.l	#aes_pb,d1
	move.w	#200,d0
	trap	#2
	rts
	even				; TEXT segment length must be even (GEMDOS loader)

	section	data
	even

MenuTitle:	dc.b	"  HDACSIST Mount",0
AlertNoDriver:	dc.b	"[3][HDACSIST Driver not loaded!|Load HDACSIST.PRG first.][Cancel]",0
AlertUnmounted:	dc.b	"[1][ACSI SD Drives Unmounted.|Safe to remove card.][OK]",0

StrPrefix:	dc.b	"[1][HDACSIST SD Manager|Drives: ",0
StrNone:	dc.b	"None",0
StrSuffix:	dc.b	"|Select action:][Mount|Unmount|Cancel]",0

StrMountPrefix:	dc.b	"[1][ACSI SD Card Mounted!|Drives: ",0
StrMountSuffix:	dc.b	"][OK]",0

StrFailPrefix:	dc.b	"[3][ACSI SD Mount Failed!|",0
StrFailSuffix:	dc.b	"][OK]",0
StrFailGeneric:	dc.b	"Check ACSI power & FAT16 MBR.",0

	even
FailTable:				; word offsets from StrFail0 (no relocations)
	dc.w	StrFail0-StrFail0,StrFail1-StrFail0,StrFail2-StrFail0,StrFail3-StrFail0
	dc.w	StrFail4-StrFail0,StrFail5-StrFail0,StrFail6-StrFail0,StrFail7-StrFail0

StrFail0:	dc.b	"Unknown mount error.",0
StrFail1:	dc.b	"No ACSI target replied.|Check cable, power & ID.",0
StrFail2:	dc.b	"ACSI probe error.",0
StrFail3:	dc.b	"Target found, not ready.|Insert SD card & retry.",0
StrFail4:	dc.b	"ACSI capacity read failed.",0
StrFail5:	dc.b	"Could not read Sector 0.",0
StrFail6:	dc.b	"No MBR and no FAT16 sector.",0
StrFail7:	dc.b	"No valid FAT12/16 partition.",0
	even				; DATA segment length must be even (GEMDOS loader)

	section	bss
	even

aes_pb:		ds.l	6
api_ptr:	ds.l	1
ap_id:		ds.w	1
menu_id:	ds.w	1

control:	ds.w	5
global:		ds.w	15
int_in:		ds.w	16
int_out:	ds.w	7
addr_in:	ds.l	3
addr_out:	ds.l	1

msg_buf:	ds.w	8
wdraw_msg:	ds.w	8
AlertMainBuf:	ds.b	256

		ds.b	2048
acc_stack_top:
	even

