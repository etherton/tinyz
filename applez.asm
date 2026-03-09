
!macro bp {
	bit $c00e
}

_80STOREOFF	= $C000
_80STOREON	= $C001
RAMRDOFF	= $C002 ; read enable main memory
RAMRDON		= $C003 ; read enable aux memory
RAMWRTOFF	= $C004 ; write enable main memory
RAMWRTON	= $C005 ; write enable aux memory
_80COLON	= $C00D
AUXCHARSET	= $C00F

PAGE1		= $C054
PAGE2		= $C055
BANK64k		= $C073		; which aux bank of 64k to use (language card)

DELAY		= $FCA8

; bge <=> bcs
; blt <=> bcc

; Apple 2 boot process; track 0 sector 0 is loaded at $800, and then
; any value up to 16 is how many total sectors will be read consecutively
; $26/$27 is the address to read next. The X register contains the slot number * 16.
; After the first track is read into memory, we manually adjust the drive head one track over
; and then jump to $Cn5C where N is the slot number (and set X to slot * 16)
; To step in 1 track:
; lda $c083,x
; 11.5ms delay (a=46)
; lda $c085,x
; 0.1ms delay (a=2)
; lda $c084,x
; 36.6ms delay (a=84)
; lda $c086,x
; rom delay routine (in cycles) at $fca8 (delay in A, (26 + 27A + 5A^2)/2 cycles (0.98us per cycle)

data_ptr 	= $26
slot_index	= $2B		; $60 for slot 6
sector 		= $3D
track	 	= $41

PH0OFF		= $C080
PH0ON		= $C081
PH1OFF 		= $C082
PH1ON		= $C083
PH2OFF		= $C084
PH2ON		= $C085
PH3OFF		= $C086
PH3ON		= $C087

; WE locations must be accessed twice
BANKA_RAMRD_WP	= $C080
BANKA_ROMRD_WE	= $C081
BANKA_ROMRD_WP	= $C082
BANKA_RAMRD_WE	= $C083

BANKB_RAMRD_WP	= $C088
BANKB_ROMRD_WE	= $C089
BANKB_ROMRD_WP	= $C08A
BANKB_RAMRD_WE	= $C08B

BANK16K_0		= $C084
BANK16K_1		= $C085
BANK16K_2		= $C086
BANK16K_3		= $C087

BANK16K_4		= $C08C
BANK16K_5		= $C08D
BANK16K_6		= $C08E
BANK16K_7		= $C08F

	*=$800
	!byte 16

	lda data_ptr+1
	cmp #$28
	beq endboot

	inc track

	lda PH0OFF,x
	lda PH1ON,x
	lda #86
	jsr DELAY
	sta sector ; A was zero after DELAY, was $10 on entry
	lda PH1OFF,x
	lda PH2ON,x
	lda #86
	jsr DELAY
	lda PH2OFF,x

	jmp $C65C

endboot
	sta _80COLON
	sta AUXCHARSET
	sta _80STOREON

dest_ptr	= $20
src_ptr		= $22
xsave		= $24
ysave		= $25
cursor_x	= $26
temp		= $27
window_split = $28
vblprev = $29

; Memory is broken up into 4k blocks, up to 512k
; It typically starts at $2000 and counts up to $BFFF
; After that, it uses Aux main memory starting at $2000 (interpreter code is shadowed)
; After that, it uses language card memory 4k bank A, then 4k bank B, then 8k
; After that, it uses Aux language card 16k

	lda #$A0
	jsr clear

	ldx #23
	jsr setpos
	lda #0
	sta cursor_x

	jmp zentry

xpos = $80
	lda #0
	sta xpos
	ldx #23
	jsr setpos

-	jsr scroll
	lda xpos
	jsr draw
	;lda #40
	;jsr DELAY
	inc xpos
	lda xpos
	cmp #50
	bne -
--	dec xpos
	beq -
	jsr scroll
	lda xpos
	jsr draw
	;lda #40
	;jsr DELAY
	jmp --

-	jmp -

draw	; $20 is base row, a is column; destroys x,y, carry set on return
	pha
	ldx #0
	lsr
	tay
	bcs draw1
	
-	lda .test,x
	cmp #0
	beq +
	inx

	sta PAGE2
	sta (dest_ptr),y

draw1	
	lda .test,x
	cmp #0
	beq +
	inx

	sta PAGE1
	sta (dest_ptr),y

	iny
	bne -
+	pla
	rts

setpos	; input x, destroys a
	lda .mul40,x
	and #$F8
	sta dest_ptr
	lda .mul40,x
	and #$7
	sta dest_ptr+1
	rts

; FAST_SCROLL = 1

; scroll returns with negative flag always set, so bmi is always taken.
!ifdef FAST_SCROLL {
scroll
	sta PAGE2
	jsr .scroll
	sta PAGE1
.scroll
	ldy #39			; 2 bytes
	jmp (scrolltop)	; 3 bytes
	; lines 0-7
	lda $480,Y	; 6 bytes ...
	 sta $400,Y	; ... per line
	lda $500,Y
	 sta $480,y
	lda $580,y
	 sta $500,Y
	lda $600,y
	 sta $580,y
	lda $680,Y
	 sta $600,y
	lda $700,y
	 sta $680,Y
	lda $780,y
	 sta $700,Y

	; lines 8-15
	lda $428,Y
	 sta $780,Y
	lda $4a8,Y
	 sta $428,Y
	lda $528,y
	 sta $4a8,Y
	lda $5a8,Y
	 sta $528,Y
	lda $628,Y
	 sta $5a8,Y
	lda $6a8,Y
	 sta $628,Y
	lda $728,Y
	 sta $6a8,Y
	lda $7a8,y
	 sta $728,Y

	; lines 16-23
	lda $450,Y
	 sta $7a8,Y
	lda $4d0,Y
	 sta $450,Y
	lda $550,y
	 sta $4d0,Y
	lda $5d0,Y
	 sta $550,Y
	lda $650,Y
	 sta $5d0,Y
	lda $6d0,Y
	 sta $650,Y
	lda $750,Y
	 sta $6d0,Y
	lda $7d0,Y
	 sta $750,Y
	lda #$A0
	 sta $7d0,Y
	dey
	bmi +
	jmp (scrolltop)
+	rts

scrolltop !byte <(.scroll+11),>(.scroll+11)

} else {

scroll
	ldx window_split
	lda .mul40,X
	and #$F8
	sta dest_ptr
	lda .mul40,X
	and #$7
	sta dest_ptr+1
.scroll1
	; X points at src_ptr, the line being copied upward (dest_ptr is line before)
	inx
	lda .mul40,X
	and #$F8
	sta src_ptr
	lda .mul40,X
	and #$7
	sta src_ptr+1

	sta PAGE2
	ldy #39
-	lda (src_ptr),Y
	sta (dest_ptr),Y
	dey
	bpl -

	sta PAGE1
	ldy #39
-	lda (src_ptr),Y
	sta (dest_ptr),Y
	dey
	bpl -

	; current src line is next dest line
	lda src_ptr
	sta dest_ptr
	lda src_ptr+1
	sta dest_ptr+1

	cpx #23
	bne .scroll1

	lda #$A0
	sta PAGE2
	ldy #39
-	sta (dest_ptr),y
	dey
	bpl -
	sta PAGE1
	ldy #39
- 	sta (dest_ptr),Y
	dey
	bpl -
	rts
}

clear
	sta PAGE2
	jsr .clear
	sta PAGE1
.clear	
	ldy #$77
- 	sta $400,y
	sta $480,y
	sta $500,y
	sta $580,Y
	sta $600,y
	sta $680,y
	sta $700,y
	sta $780,y
	dey
	bpl -
	rts

	; destroys A
print_char
	sty ysave
	stx xsave
	cmp #13
	beq .print_char_nl
	ora #$80
	tax
	lda cursor_x
	inc cursor_x
	lsr
	tay
	bcc .print_char_even
.print_char_odd
	sta PAGE1
	txa
	sta (dest_ptr),y
	cpy #39
	bne .print_char_done
.print_char_nl
	ldy #0
	sty cursor_x
	jsr scroll
	bmi .print_char_done ; always taken
.print_char_even
	sta PAGE2
	txa
	sta (dest_ptr),y
.print_char_done
	ldx xsave
	ldy ysave
	rts


.mul40
	!byte 	$04, $84, $05, $85, $06, $86, $07, $87
	!byte	$2C, $AC, $2D, $AD, $2E, $AE, $2F, $AF
	!byte	$54, $D4, $55, $D5, $56, $D6, $57, $D7

	;;; !convtab "apple2e.convtab"
.test	!text "This is an example string."
	!byte 0
	
	; 0-31 @,Inverse capital letters
	; 32-63 Inverse ascii punctuation
	; 64-95 graphics stuff
	; 96-127 `,Inverse lowercase letters
	; 128-159 Normal capital letters
	; 160-191 Normal ascii punctuation
	; 192-223 Normal capital letters
	; 224-255 Normal lowercase letters
	; Normal letters have high bit set
	; Inverse has high bit clear
	; 

mulTemp = $46
attr_bit = $47
ztype = $48
zinsn = $49
zpc_hi = $4A		; upper two bytes of offset in story (big-endian)
zpc_mid = $4B
zptr = $4C			; actual cpu address in memory of current insn (little-endian)
operands_hi = $50
operands_lo = $58
stringptr = $60
obj_hi = $6A
obj_mid = $6B
obj_ptr = $6C
obj_base = $6E		; 9 bytes before first object slot
window_current = $71
output_table = $72
output_enables = $73
zshift = $74		; current shift value for ZSCII
stackptr = $78		; one past top of stack
frameptr = $79		; one before first local (since locals are one-based)

;   0-31: 0101 (small,small) (5)
;  32-63: 0110 (small,variable) (6)
;  64-95: 1001 (variable,small) (9)
; 96-127: 1010 (variable,variable) (10)

!ifdef TARGET_65C02 {

!macro table16 t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15 {
	!word t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15
}

!macro table32 t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16,t17,t18,t19,t20,t21,t22,t23,t24,t25,t26,t27,t28,t29,t30,t31 {
	!word t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16,t17,t18,t19,t20,t21,t22,t23,t24,t25,t26,t27,t28,t29,t30,t31
}

; these versions don't save the arg count. only je and call_vs really care.
!macro dispatch16 label {
	asl
	tax
	jmp (label,x)
}

!macro dispatch32 label {
	asl
	tax
	jmp (label,x)
}

} else {

!macro table16 t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15 {
	!byte <(t0-1),<(t1-1),<(t2-1),<(t3-1),<(t4-1),<(t5-1),<(t6-1),<(t7-1)
	!byte <(t8-1),<(t9-1),<(t10-1),<(t11-1),<(t12-1),<(t13-1),<(t14-1),<(t15-1)
	!byte >(t0-1),>(t1-1),>(t2-1),>(t3-1),>(t4-1),>(t5-1),>(t6-1),>(t7-1)
	!byte >(t8-1),>(t9-1),>(t10-1),>(t11-1),>(t12-1),>(t13-1),>(t14-1),>(t15-1)
}

!macro table32 t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16,t17,t18,t19,t20,t21,t22,t23,t24,t25,t26,t27,t28,t29,t30,t31 {
	!byte <(t0-1),<(t1-1),<(t2-1),<(t3-1),<(t4-1),<(t5-1),<(t6-1),<(t7-1)
	!byte <(t8-1),<(t9-1),<(t10-1),<(t11-1),<(t12-1),<(t13-1),<(t14-1),<(t15-1)
	!byte <(t16-1),<(t17-1),<(t18-1),<(t19-1),<(t20-1),<(t21-1),<(t22-1),<(t23-1)
	!byte <(t24-1),<(t25-1),<(t26-1),<(t27-1),<(t28-1),<(t29-1),<(t30-1),<(t31-1)
	!byte >(t0-1),>(t1-1),>(t2-1),>(t3-1),>(t4-1),>(t5-1),>(t6-1),>(t7-1)
	!byte >(t8-1),>(t9-1),>(t10-1),>(t11-1),>(t12-1),>(t13-1),>(t14-1),>(t15-1)
	!byte >(t16-1),>(t17-1),>(t18-1),>(t19-1),>(t20-1),>(t21-1),>(t22-1),>(t23-1)
	!byte >(t24-1),>(t25-1),>(t26-1),>(t27-1),>(t28-1),>(t29-1),>(t30-1),>(t31-1)
}

!macro dispatch16 label {
	tay
	lda label+16,Y
	pha
	lda label,Y
	pha
	rts
}

!macro dispatch32 label {
	tay
	lda label+32,y
	pha
	lda label,Y
	pha
	rts
}

} // endif

HEADER = $2000
;  +0 version
;  +1 flags
;  +2 pad0
;  +4 high memory address (big-endian)
;  +6 initial PC address (big-endian)
;  +8 dictionary
; +10 object table (defaults, etc)
; +12 globals
; +14 static memory address


!macro skip_insn_byte {
	inc zptr
	bne +
	jsr update_zpc
+
}
; returns next instruction byte in A;
; this version requires 65C02 in apple 2e 
!macro next_insn_byte {
	lda (zptr)
	+skip_insn_byte
}

zentry
	; copy globals into our own shadow storage
	lda HEADER+13
	sta zptr
	lda HEADER+12
	sta zpc_mid
	lda #0
	sta zpc_hi
	ldy #16
	jsr update_zptr
-	+next_insn_byte
	sta globals_hi,y
	+next_insn_byte
	sta globals_lo,Y
	iny
	bne -

	; set up initial pc
	lda HEADER+7
	sta zptr
	lda HEADER+6
	sta zpc_mid
	lda #0
	sta zpc_hi
	sta stackptr
	jsr update_zptr

	; set up object pointer
	lda HEADER+11
!ifdef Z4PLUS {
	adc #(126 - 14)
} else {
	adc #(62 - 9)		; skip defaults, and objects are 1-based
}
	sta obj_ptr
	lda HEADER+10
	adc #>HEADER
	sta obj_ptr+1
	lda #1
	sta window_split
	sta vblprev

	jmp next_insn

dispatch +table16 _2op_s_s,_2op_s_s,_2op_s_v,_2op_s_v,_2op_v_s,_2op_v_s,_2op_v_v,_2op_v_v,_1op_large,_1op_small,_1op_variable,_0op,_2op_var,_2op_var,_vop,_vop

_2opTbl +table32 z_ill,z_je,z_jl,z_jg,z_dec_chk,z_inc_chk,z_jin,z_test,z_or,z_and,z_test_attr,z_set_attr,z_clear_attr,z_store,z_insert_obj,z_loadw,z_loadb,z_get_prop,z_get_prop_addr,z_get_next_prop,z_add,z_sub,z_mul,z_div,z_mod,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill

_1opTbl +table16 z_jz,z_get_sibling,z_get_child,z_get_parent,z_get_prop_len,z_inc,z_dec,z_print_addr,z_ill,z_remove_obj,z_print_obj,z_ret,z_jump,z_print_paddr,z_load,z_not

_0opTbl +table16 z_rtrue,z_rfalse,z_print,z_print_ret,next_insn,z_save,z_restore,z_restart,z_ret_popped,z_pop,z_quit,z_new_line,z_show_status,z_ill,z_ill,z_ill

_varTbl +table32 z_call_vs,z_storew,z_storeb,z_put_prop,z_sread,z_print_char,z_print_num,z_random,z_push,z_pull,z_split_window,z_set_window,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_output_stream,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill

update_zpc
	inc zpc_mid
	bne update_zptr
	inc zpc_hi
update_zptr
	clc
	lda zpc_mid
	; TODO: this needs to go through a table lookup and set up page banks
	adc #>HEADER
	sta zptr+1
	rts

; opcode
; (type byte) (type byte for call_vs2) (00=large, 01=small, 10=var, 11=omit)
; (operands)
; (store destination)
; (branch offset)
; (text to print)

; if an instruction would cross a non-contiguous 4k boundary (rare), we copy the entire instruction into a temporary
; location and execute it from there. (eventually)
next_insn
	lda $c019
	bpl +			; not in vbl
	ldx vblprev
	bmi ++			; didn't just enter vbl
	sta vblprev
	inc $2005
	bne ++
	inc $2004
	bne ++
+	sta vblprev
++

!ifdef DEBUG_TRACE {
	lda zpc_mid
	jsr print_hex_byte
	lda zptr
	jsr print_hex_byte
	lda #13
	jsr print_char
}
	+next_insn_byte
	sta zinsn
	lsr
	lsr
	lsr
	lsr
	+dispatch16 dispatch

; at entry to instruction handler:
; Y contains instruction
; X contains operand count
_2op_s_s
	ldx #0
	jsr operand_small
	jsr operand_small
	bne ._2op_common ; always taken
_2op_s_v
	ldx #0
	jsr operand_small
	jsr operand_variable
	bne ._2op_common ; always taken
_2op_v_s
	ldx #0
	jsr operand_variable
	jsr operand_small
	bne ._2op_common ; always taken
_2op_v_v
	ldx #0
	jsr operand_variable
	jsr operand_variable
._2op_common
	lda zinsn
	and #$1F
	+dispatch32 _2opTbl
_2op_var
	jsr decode_types
	jmp ._2op_common
_vop
	jsr decode_types
	lda zinsn
	and #$1F
	+dispatch32 _varTbl

_1op_large
	ldx #0
	jsr operand_large
	bne ._1op_common ; always taken
_1op_small
	ldx #0
	jsr operand_small
	bne ._1op_common ; always taken
_1op_variable
	ldx #0
	jsr operand_variable
._1op_common
	lda zinsn
	and #$f
	+dispatch16 _1opTbl

_0op
	lda zinsn
	and #$f
	+dispatch16 _0opTbl

decode_types
	+next_insn_byte
	sta ztype
	ldx #0
-	bit ztype
	; large=00, small=01, variable=10, omitted=11
	bmi .var_omit
	bvs .small
	jsr operand_large
	bne .next_type	; always taken
.small
	jsr operand_small
	bne .next_type	; always taken
.var_omit
	bvs .decode_done
	jsr operand_variable
.next_type
	sec 
	rol ztype
	sec
	rol ztype
	bne -			; always taken
.decode_done
	rts

	; all operand handlers inx before return and so the zero flag is always clear.
operand_large
	+next_insn_byte
	!byte $2C	; bit NNNN, skips lda #$0
	; zero flag clear on return (x never zero)
operand_small
	lda #$0
	sta operands_hi,x
	+next_insn_byte
	sta operands_lo,x

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text "operand ",0
	txa
	jsr print_hex_byte
	jsr debug_print
	!text " is inline value ",0
	jsr print_operand
}
	inx
	rts

	; operand_variable destroys y so it needs to be reloaded from znext
	; if there are more types to decode
operand_variable	
!ifdef DEBUG_TRACE {
	jsr debug_print
	!text "operand ",0
	txa
	jsr print_hex_byte
}

	+next_insn_byte
	cmp #$00
	beq .read_tos
	cmp #$10
	bcs .read_global
	; read local
	adc frameptr
	tay
	lda stack_hi,Y
	sta operands_hi,x
	lda stack_lo,Y
	sta operands_lo,x

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text " is local ",0
	tya
	clc
	sbc frameptr
	jsr print_hex_byte
	lda #'='
	jsr print_char
	jsr print_operand
}

	inx
	rts

.read_global
	tay
	lda globals_hi,Y
	sta operands_hi,X
	lda globals_lo,Y
	sta operands_lo,x

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text " is global ",0
	tya
	sec
	sbc #$10
	jsr print_hex_byte
	lda #'='
	jsr print_char
	jsr print_operand
}

	inx
	rts

.read_tos
	dec stackptr
	ldy stackptr
	lda stack_hi,Y
	sta operands_hi,x
	lda stack_lo,Y
	sta operands_lo,X

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text " is TOS=",0
	jsr print_operand
}

	inx
	rts

!ifdef DEBUG_TRACE {
print_operand
	lda operands_hi,X
	jsr print_hex_byte
	lda operands_lo,X
	jsr print_hex_byte
	lda #$d
	jmp print_char
}

z_ill
	jsr fatal_error
	!text "unimplemented insn",0

z_dec_chk
	jsr fatal_error
	!text "dec_chk not impl",0

z_inc_chk
	jsr fatal_error
	!text "inc_chk not impl",0

z_jin
	jsr fatal_error
	!text "jin not impl",0

z_print_ret
	jsr z_print_inline_common
	lda #$0D
	jsr print_char
z_rtrue
	ldx #1
	!byte $2C ; bit NNNN skips the next insn
z_rfalse
	ldx #0
	lda #0
	; frame+0 is lower 16 bits of current PC
	; frame+1 is upper 8 bits of current PC and previous frameptr
	; frame+2 is location to store result, and operand count in V5+ (frame+2 is new frameptr)
.z_ret_common
	sta temp
	ldy frameptr
	dey
	dey
	sty stackptr
	lda stack_lo,Y
	sta zptr
	lda stack_hi,Y
	sta zpc_mid
	lda stack_lo+1,Y
	sta zpc_hi
	lda stack_hi+1,Y
	sta frameptr
	lda stack_lo+2,Y
	jsr update_zptr
	; TODO: On V4+, might be a non-storing call
	jsr store_result_2
	jmp next_insn

z_ret
	ldx operands_lo+0
	lda operands_hi+0
	jmp .z_ret_common

z_jump
	lda operands_lo+0
	ldx operands_hi+0
	jmp .compute_newpc

; on entry, op0/op1 contain decoded operands
; on exit, x contains low byte of result, a contains high byte
z_je
	dex
-	lda operands_lo
	cmp operands_lo,X
	bne .je_failed
	lda operands_hi
	cmp operands_hi,x
	beq branch_passed
.je_failed
	dex
	bne -
	jmp branch_failed

.branch_short
	and #$3F
	beq z_rfalse
	cmp #$1
	beq z_rtrue
	ldx #0
.compute_newpc
	clc
	adc zptr
	sta zptr
	txa
	adc zpc_mid
	sta zpc_mid
	bcc +
	inc zpc_hi
	clc
+	lda #$FE
	adc zptr
	sta zptr
	bcs +
	lda #$FF
	adc zpc_mid
	sta zpc_mid
	bcs +
	lda #$FF
	adc zpc_hi
	sta zpc_hi
+	jsr update_zptr
	jmp next_insn

branch_failed
	+next_insn_byte
	cmp #$80
	bcc .branch_passed
.branch_failed
	cmp #$40
	bcs .short_branch_failed
	+skip_insn_byte
.short_branch_failed
	jmp next_insn
branch_passed
	+next_insn_byte
	cmp #$80
	bcc .branch_failed
.branch_passed
	and #$7f
	ldx #0
	cmp #$40
	bcs .branch_short
	cmp #$20
	bcc .long_branch_positive
	ora #$fc
.long_branch_positive
	tax
	+next_insn_byte
	; x contains high byte of offset, a contains low byte
	; compute pc = pc + offset - 2
	jmp .compute_newpc

; http://6502.org/tutorials/compare_beyond.html
; Example 6.3: a 16-bit signed comparison that branches to LABEL4 if NUM1 < NUM2 (similar to Example 4.1.1 in Section 4.1)
;
;           SEC
;           LDA NUM1H  ; compare high bytes
;           SBC NUM2H
;           BVC LABEL1 ; the equality comparison is in the Z flag here
;           EOR #$80   ; the Z flag is affected here
;    LABEL1 BMI LABEL4 ; if NUM1H < NUM2H then NUM1 < NUM2
;           BVC LABEL2 ; the Z flag was affected only if V is 1
;           EOR #$80   ; restore the Z flag to the value it had after SBC NUM2H
;    LABEL2 BNE LABEL3 ; if NUM1H <> NUM2H then NUM1 > NUM2 (so NUM1 >= NUM2)
;           LDA NUM1L  ; compare low bytes
;           SBC NUM2L
;           BCC LABEL4 ; if NUM1L < NUM2L then NUM1 < NUM2
;    LABEL3

z_jl
	sec
	lda operands_hi+0
	sbc operands_hi+1
	bvc +
	eor #$80
+	bmi branch_passed ; op0_h < op1_h?
	bvc +
	eor #$80
+	bne branch_failed	; if op0_h != op1_h then op0 > op1
	lda operands_lo+0
	sbc operands_lo+1
	bcc branch_passed
	bcs branch_failed	; always taken

; same as above but with operands reversed
z_jg
	sec
	lda operands_hi+1
	sbc operands_hi+0
	bvc +
	eor #$80
+	bmi branch_passed ; op1_h < op0_h?
	bvc +
	eor #$80
+	bne branch_failed	; if op1_h != op0_h then op1 > op0
	lda operands_lo+1
	sbc operands_lo+0
	bcc branch_passed
	bcs branch_failed	; always taken

z_jz
	lda operands_lo+0
	ora operands_hi+0
	bne branch_failed
	beq branch_passed	; always taken

z_or
	lda operands_lo+0
	ora operands_lo+1
	tax
	lda operands_hi+0
	ora operands_hi+1
	jmp store_common

z_and
	lda operands_lo+0
	and operands_lo+1
	tax
	lda operands_hi+0
	and operands_hi+1
	jmp store_common

z_test 	; does op0 & op1 == op1?
	lda operands_lo+0
	and operands_lo+1
	cmp operands_lo+1
	bne +
	lda operands_hi+0
	and operands_hi+1
	cmp operands_hi+1
	bne +
	jmp branch_passed
+	jmp branch_failed

z_add
	clc
	lda operands_lo+0
	adc operands_lo+1
	tax
	lda operands_hi+0
	adc operands_hi+1
	jmp store_common

z_sub
	sec
	lda operands_lo+0
	sbc operands_lo+1
	tax
	lda operands_hi+0
	sbc operands_hi+1
	jmp store_common

z_mul
	lda operands_hi+0
	ora operands_hi+1
	bmi .z_mul_signed	; is either result signed?
	beq .z_mul_8x8		; can we use faster 8x8 mul?
	; standard 16x16->16 unsigned
.z_mul_signed
	jsr fatal_error
	!text "only mul 8x8 implemented",13,0

	; https://llx.com/Neil/a2/mult.html
.z_mul_8x8
	lda #0
	ldx #8
-	lsr operands_lo+1
	bcc +
	clc
	adc operands_lo+0
+	ror
	ror mulTemp
	dex
	bne -
	ldx mulTemp
	jmp store_common

z_div
	jsr divide
	lda operands_hi+1
	ldx operands_lo+0
	jmp store_common

z_mod
	jsr divide
	lda operands_hi+2
	ldx operands_lo+2
	jmp store_common

z_test_attr
	jsr attr_setup
	lda (obj_ptr),Y
	and attr_bit
	beq +
	jmp branch_passed
+	jmp branch_failed

z_set_attr
	jsr attr_setup
	lda (obj_ptr),y
	ora attr_bit
	sta (obj_ptr),Y
	jmp next_insn

z_clear_attr
	jsr attr_setup
	lda attr_bit
	eor #$ff
	sta attr_bit
	lda (obj_ptr),Y
	and attr_bit
	sta (obj_ptr),Y
	jmp next_insn

z_get_sibling
	jsr get_object_addr
	ldy #$5 ; sibling
z_get_common
	lda (obj_ptr),Y
z_get_common_zero
	tax
	lda #0
	jmp store_common

z_get_parent
	; get_parent(0) is always 0.
	lda operands_lo+0
	beq z_get_common_zero
	jsr get_object_addr
	ldy #4 ; parent
	bne z_get_common

z_get_child
	jsr get_object_addr
	ldy #6 ; child
	bne z_get_common

z_remove_obj
	jsr fatal_error
	!text "z_remove_obj not impl",0

;	jsr get_object_addr
;	ldy #4 ; parent
;	lda (obj_ptr),Y
;	bne +
;	jmp next_insn	; parent is zero, already removed from terminate
;+	sta operands_lo+0
;	jsr get_object_addr

z_insert_obj
	jsr fatal_error
	!text "z_insert_obj not impl",0

z_get_prop_addr
	jsr get_object_addr
	ldy #8		; property addr
	lda (obj_ptr),Y
	tax
	dey
	lda (obj_ptr),y
	jmp store_common

z_get_prop
	jsr fatal_error
	!text "z_get_prop not impl",0

z_put_prop
	jsr fatal_error
	!text "z_put_prop not impl",0

z_get_next_prop
	jsr fatal_error
	!text "z_get_next_prop not impl",0

z_get_prop_len
	jsr fatal_error
	!text "z_get_prop_len",0

!macro z_print_string zp {
	lda #$FF
	sta zshift
-	lda (zp)
	php		; remember if negative
	and #$7C
	lsr
	lsr
	jsr printz
	lda (zp)
	and #$3
	sta xsave
	inc zp
	bne +
	inc zp+1
+	lda (zp)
	asl
	rol xsave
	asl
	rol xsave
	asl
	rol xsave
	lda xsave
	jsr printz
	lda (zp)
	inc zp
	bne +
	inc zp+1
+	and #$1F
	jsr printz
	plp
	bpl -
}

z_print_obj
	jsr get_object_addr
	ldy #8
	lda (obj_ptr),y	; low byte
	tax
	dey
	lda (obj_ptr),Y ; high byte
	sta obj_ptr+1
	stx obj_ptr
	inc obj_ptr
	bne z_print_common
	inc obj_ptr+1

	; obj_ptr contains address in dynamic/static memory
z_print_common
	+z_print_string obj_ptr
	jmp next_insn

z_print_addr
	lda operands_lo+0
	sta obj_ptr
	lda operands_hi+0
	clc
	adc #>HEADER
	sta obj_ptr+1
	bne z_print_common	; always taken

	; stores a packed address in operands+0 in four zp slots
!macro get_mem_addr_packed hi,mid,ptr {
	lda operands_lo+0
	sta ptr
	lda operands_hi+0
	sta mid
	lda #0
	sta hi
	asl ptr
	rol mid
	rol hi
!ifdef Z4PLUS {
	asl ptr
	rol mid
	rol hi
!ifdef Z8 {
	asl ptr
	rol mid
	rol hi
}
}
	; carry always clear because zpc_hi cannot overflow
	lda mid
	adc #>HEADER
	sta ptr+1
}

z_print_paddr
	+get_mem_addr_packed obj_hi,obj_mid,obj_ptr
	+z_print_string obj_ptr
	jmp next_insn

printz
	cmp #4
	beq .print_shift_1
	cmp #5
	beq .print_shift_2
	cmp #6
	bcs .print_tabled
	; TODO: abbreviations
	; print a space
	lda #$FF
	sta zshift
	lda #32
	jmp print_char
.print_tabled
	adc zshift ; zshift is one less because carry always set
	tay
	lda #$FF
	sta zshift
	lda zalphabet-6,Y
	jmp print_char
.print_shift_1
	lda #25
	sta zshift
	rts
.print_shift_2
	lda #(25+25)
	sta zshift
	rts

	; loads must be in contiguous dynamic+static memory
	; stores must be in contiguous dynamic memory
z_loadb
	clc
	lda operands_lo+0
	adc operands_lo+1
	sta obj_ptr
	lda operands_hi+0
	adc operands_hi+1
	adc #>HEADER
	sta obj_ptr+1
	; ldy #0
	lda (obj_ptr)
	tax
	lda #0
	jmp store_common

z_storeb
	clc
	lda operands_lo+0
	adc operands_lo+1
	sta obj_ptr
	lda operands_hi+0
	adc operands_hi+1
	adc #>HEADER
	sta obj_ptr+1
	; ldy #0
	lda operands_lo+2
	sta (obj_ptr)
	jmp next_insn

z_loadw
	clc
	asl operands_lo+1
	rol operands_hi+1
	lda operands_lo+0
	adc operands_lo+1
	sta obj_ptr
	lda operands_hi+0
	adc operands_hi+1
	adc #>HEADER
	sta obj_ptr+1
	; TODO: if this crosses a 4k boundary we need multiple calls
	ldy #1
	lda (obj_ptr),Y
	tax
	dey
	lda (obj_ptr),y
	jmp store_common

z_storew
	clc
	asl operands_lo+1
	rol operands_hi+1
	lda operands_lo+0
	adc operands_lo+1
	sta obj_ptr
	lda operands_hi+0
	adc operands_hi+1
	adc #>HEADER
	sta obj_ptr+1
	; TODO: if this crosses a 4k boundary we need multiple calls
	ldy #1
	lda operands_lo+2
	sta (obj_ptr),Y
	dey
	lda operands_hi+2
	sta (obj_ptr),Y
	jmp next_insn

z_random
	jsr fatal_error
	!text "z_random not impl",0

z_sread
	jsr fatal_error
	!text "z_sread not impl",0

z_inc
	lda operands_lo+0
	beq .inc_tos
	cmp #$10
	bcs .inc_global
	; carry is clear here
	adc frameptr
	tax
	inc stack_lo,X
	bne +
	inc stack_hi,X
+	jmp next_insn
.inc_global
	tax
	inc globals_lo,x
	bne +
	inc globals_hi,x
+	jmp next_insn
.inc_tos
	ldx stackptr
	inc stack_lo-1,X
	bne +
	inc stack_hi-1,X
+	jmp next_insn

z_dec
	jsr fatal_error
	!text "z_dec not impl",0

z_not
	lda operands_lo+0
	eor #$ff
	tax
	lda operands_hi+0
	eor #$ff
	jmp store_common

z_load
	jsr fatal_error
	!text "z_load not impl",0

z_print
	jsr z_print_inline_common
	jmp next_insn

z_print_inline_common
	+z_print_string zptr 
	rts

	; all call instructions route through here, x=1..7
	
z_call_vs
	lda operands_lo+0
	ora operands_hi+0
	bne +
	ldx #0
	; call to zero returns zero immediately
	jmp store_common

	; compute larger of local count and parameter count (x)
	; new frame starts at stackptr
	; frame+0 is lower 16 bits of current PC
	; frame+1 is upper 8 bits of current PC and previous frameptr
	; frame+2 is location to store result, and operand count in V5+ (frame+2 is new frameptr)
	; frame+3 is the first parameter / local variable
	; new stack ptr is just past last local
+	+next_insn_byte		; get storage location
	stx		xsave		; operand count
	tax					; local count

	ldy stackptr
	lda zpc_mid
	sta stack_hi,Y
	lda zptr
	sta stack_lo,Y

	lda zpc_hi
	sta stack_lo+1,Y
	lda frameptr
	sta stack_hi+1,Y

	; location to store result
	txa
	sta stack_lo+2,y

	iny
	iny
	sty frameptr
	iny

	+get_mem_addr_packed zpc_hi,zpc_mid,zptr
	+next_insn_byte
	; get local count in A
	sta temp
!ifdef Z4PLUS {
	; zero out the locals
} else {
	; copy local values
	cmp #$0
	beq +
-	+next_insn_byte	; local high byte
	sta stack_hi,y
	+next_insn_byte	; local low byte
	sta stack_lo,Y
	iny
	dec temp
	bne -
+	sty stackptr
}
	; now copy incoming parameters past 0
	dec xsave
	beq +
	ldx #1
	ldy frameptr
.copyparam
	lda operands_lo,x
	sta stack_lo+1,Y
	lda operands_hi,X
	sta stack_hi+1,Y
	inx
	iny
	dec xsave
	bne .copyparam
	; new sp is larger of operand count and local count
	cpy stackptr
	bcc +
	sty stackptr
+	jmp next_insn

z_save
	jsr fatal_error
	!text "z_save not impl",0

z_restore
	jsr fatal_error
	!text "z_restore not impl",0

z_restart
	jsr fatal_error
	!text "z_restart not impl",0

z_ret_popped
	dec stackptr
	ldy stackptr
	ldx stack_lo,Y
	lda stack_hi,Y
	jmp .z_ret_common

z_pop
	dec stackptr
	jmp next_insn

z_push
	ldy stackptr
	inc stackptr
	lda operands_lo+0
	sta stack_lo,Y
	lda operands_hi+0
	sta stack_hi,Y
	jmp next_insn

z_pull
	dec stackptr
	ldy stackptr
	lda stack_lo,Y
	tax
	lda stack_hi,Y
	jmp store_common

z_set_window
	lda operands_lo+0
	sta window_current
	jmp next_insn

z_split_window
	lda operands_lo+0
	sta window_split
-	jmp next_insn

z_output_stream
	lda operands_lo+0
	beq -
	bpl .output_enable
	tay
	lda #$ff
	clc
-	rol 
	iny
	bne -
	and output_enables
	sta output_enables
	jmp next_insn
.output_enable
	cmp #3
	bne +
	ldx operands_lo+0
	stx output_table
	ldx operands_hi+0
	stx output_table+1
	inc output_table
	bne +
	inc output_table+1
+	tay
	lda #0
	sec
-	rol
	dey
	bne -
	jmp next_insn

z_quit
	jsr fatal_error
	!text "z_quit not impl",0

attr_bits !byte $80,$40,$20,$10,$08,$04,$02,$01

	; operand+0 contains object index, operand+1 contains attribute.
	; sets obj_ptr and attr_bit appropriately, y contains attribute byte index
attr_setup
	jsr get_object_addr	; sets obj_ptr
	lda operands_lo+1
	and #$7
	tay
	lda attr_bits,Y
	sta attr_bit
	lda operands_lo+1
	lsr
	lsr
	lsr
	tay
	rts

	; operand+0 contains object number; return y=0
get_object_addr
	; compute objIndex * 9
	lda operands_lo+0
	sta obj_ptr+0
	lda operands_hi+0
	sta obj_ptr+1
	ldy #3
-	asl obj_ptr+0
	rol obj_ptr+1
	dey
	bne -
	clc
	lda obj_ptr+0
	adc operands_lo+0
	adc obj_base
	sta obj_ptr+0
	lda obj_ptr+1
	adc operands_hi+0
	adc obj_base+1
	sta obj_ptr
	rts

print_hex_byte
	pha
	lsr
	lsr
	lsr
	lsr
	jsr print_hex_digit
	pla
	and #$f
print_hex_digit
	clc
	adc #$30
	cmp #$3A
	bcc +
	adc #$6	; carry is always set
+	jmp print_char

; print number in operands+0
!macro process_digit value {
	ldx #0
	lda operands_hi+0
.top
	cmp #>value
	bcc .done 
	bne .sub
	lda operands_lo+0
	cmp #<value
	bcc .done
.sub
	sec
	lda operands_lo+0
	sbc #<value
	sta operands_lo+0
	lda operands_hi+0
	sbc #>value
	sta operands_hi+0
	inx
	bne .top
.done
	txa
	ora mulTemp
	beq .noprint
	sta mulTemp
	txa
	clc
	adc #$30
	jsr print_char
.noprint
}

z_print_num
	lda #0
	sta mulTemp
	+process_digit 10000
	+process_digit 1000
	+process_digit 100
	+process_digit 10
	lda operands_lo+0
	clc
	adc #$30
	jsr print_char ; last digit always prints even if it's zero
	jmp next_insn

z_new_line
	lda #13
	!byte $2C ; skip lda zp
z_print_char
	lda operands_lo+0
	jsr print_char
	jmp next_insn

z_show_status
	; TODO: print obj name, score, and moves in top window.
	jmp next_insn

	; divide operands+0 by operands+1, quotient in operands+0, remainder in operands+2
divide
	lda #0
	sta operands_lo+2
	sta operands_hi+2
	ldx #16
-	asl operands_lo+0
	rol operands_hi+0
	rol operands_lo+2
	rol operands_hi+2
	lda operands_lo+2
	sec
	sbc operands_lo+1
	tay
	lda operands_hi+2
	sbc operands_hi+1
	bcc +
	sta operands_hi+2
	sty operands_lo+2
	inc operands_lo+1
+	dex
	bne -
	rts

z_store
	lda operands_hi+1
	sta temp
	ldx operands_lo+1
	lda operands_lo+0
	jsr store_result_2
	jmp next_insn

store_common
	jsr store_result
	jmp next_insn

	; incoming: x is low byte, a is high byte of result to store
store_result
	sta temp
	+next_insn_byte
store_result_2
	cmp #$00
	;beq .store_tos
	bne +
	jmp .store_tos
+
	cmp #$10
	bcs .store_global
	; store local
	adc frameptr
	tay
	lda temp
	sta stack_hi,Y
	txa
	sta stack_lo,y

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text "store ",0
	lda stack_hi,y
	jsr print_hex_byte
	lda stack_lo,Y
	jsr print_hex_byte
	jsr debug_print
	!text " to local ",0
	tya
	clc	; need to subtract an additional 1 to get local index back
	sbc frameptr
	jsr print_hex_byte
	lda #$d
	jsr print_char
}
	rts
.store_global
	tay
	lda temp
	sta globals_hi,y
	txa
	sta globals_lo,y

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text "store ",0
	lda globals_hi,y
	jsr print_hex_byte
	lda globals_lo,Y
	jsr print_hex_byte
	jsr debug_print
	!text " to global ",0
	tya
	sec
	sbc #$10
	jsr print_hex_byte
	lda #$d
	jsr print_char
}
	rts
.store_tos
	ldy stackptr
	lda 	temp
	sta stack_hi,Y
	txa
	sta stack_lo,y
	inc stackptr
	beq +

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text "store ",0
	lda stack_hi,y
	jsr print_hex_byte
	lda stack_lo,Y
	jsr print_hex_byte
	jsr debug_print
	!text " to TOS",13,0
}
	rts
+ 	jsr fatal_error
	!text "stack overflow",13,0

fatal_error
	pla
	sta stringptr
	pla
	sta stringptr+1
	ldy #1
-	lda (stringptr),Y
--	beq --		; hang forever
	jsr print_char
	iny
	bne -		; always taken

!ifdef DEBUG_TRACE {
	; destroys A
debug_print
	pla
	sta stringptr
	pla
	sta stringptr+1
-	inc stringptr
	bne +
	inc stringptr+1
+	lda (stringptr)
	beq +
	jsr print_char
	jmp -
+	lda stringptr+1
	pha
	lda stringptr
	pha
	rts
}

	; each 4k in the story file is mapped to a byte in this table
	; maximum story size is 512k, so 128 slots are needed
	; 0-15 is main memory and language card (12=4k a, 13=4kb, 14/15=8k)
	; 16-31 is aux memory and language card
	; 32-35 is Saturn bank 0
	; 36-39 is Saturn bank 1, etc
tlb 	!fill 128
	; another idea - map first 64k of memory to $4000-$BFFF
	; except that even/odd bytes are in different banks. this means
	; all memory is contiguuous but you're constantly fussing with banks

	; on V5 the version in the story is copied over this
zalphabet
	!text "abcdefghijklmnopqrstuvwxyz"
	!text "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	!text 13,"0123456789.,!?_#'",34,"/",92,"-:()"

	; stack is split into lower and upper bytes so we can treat the Y register as a stack pointer.
	!align 255, 0
stack_lo	!fill 256
stack_hi	!fill 256

	; we could have the current frame's locals here as well, but then we have to copy out to the
	; stack on any call or return. first 16 bytes of each could be used for something else
globals_lo	!fill 256
globals_hi	!fill 256

	; round interpreter up to next 4k boundary for alignment (we start at 2k)
	!align 4095, 0