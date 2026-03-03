
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

BOOTPTR 	= $26
BOOTSLOT16	= $2B		; $60 for slot 6
BOOTSEC 	= $3D
BOOTTRK 	= $41

PH0OFF		= $C080
PH0ON		= $C081
PH1OFF 		= $C082
PH1ON		= $C083
PH2OFF		= $C084
PH2ON		= $C085
PH3OFF		= $C086
PH3ON		= $C087

	*=$800
	!byte 16

	lda BOOTPTR+1
	cmp #$28
	beq endboot

	inc BOOTTRK

	lda PH0OFF,x
	lda PH1ON,x
	lda #86
	jsr DELAY
	sta BOOTSEC ; A was zero after DELAY, was $10 on entry
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

; Memory is broken up into 4k blocks, up to 512k
; It typically starts at $2000 and counts up to $BFFF
; After that, it uses Aux main memory starting at $2000 (interpreter code is shadowed)
; After that, it uses language card memory 4k bank A, then 4k bank B, then 8k
; After that, it uses Aux language card 16k

	lda #$A0
	sta PAGE2
	jsr clr1
	sta PAGE1
	jsr clr1

	lda #0

-	tay
	jsr setpos
	tya
	jsr draw
	adc #0
	cmp #24
	bne -

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
	sta ($20),y

draw1	lda .test,x
	cmp #0
	beq +
	inx

	sta PAGE1
	sta ($20),y

	iny
	bne -
+	pla
	rts

setpos	; input y, destroys a
	lda .mul40,y
	and #$F8
	sta $20
	lda .mul40,y
	and #$7
	sta $21
	rts

clr1	ldy #0
- 	sta $400,y
	sta $500,y
	sta $600,y
	sta $700,y
	iny
	bne -
	rts

.mul40
	!byte 	$04, $84, $05, $85, $06, $86, $07, $87
	!byte	$2C, $AC, $2D, $AD, $2E, $AE, $2F, $AF
	!byte	$54, $D4, $55, $D5, $56, $D6, $57, $D7

	!convtab "apple2e.convtab"
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

znext = $4A
zptr = $4B
insn = $4D
stackptr = $4E
type_byte = $4F
operands_hi = $50
operands_lo = $58

; retrieve next insn byte, and recompute if
; we cross a 4k boundary. note by the time we
; get to here, language card pages etc are set
next_byte
	inc zptr
	bne +
	lda zptr+1
	and #$f
	cmp #$f
	bne +
+	ldy #0
	lda (zptr),Y
	rts

;   0-31: 0101 (small,small) (5)
;  32-63: 0110 (small,variable) (6)
;  64-95: 1001 (variable,small) (9)
; 96-127: 1010 (variable,variable) (10)

dispatch_lo
	!byte <(_2op_s_s-1),<(_2op_s_s-1),<(_2op_s_v-1),<(_2op_s_v-1),<(_2op_v_s-1),<(_2op_v_s-1),<(_2op_v_v-1),<(_2op_v_v-1)
	!byte <(_1op_large-1),<(_1op_small-1),<(_1op_variable-1),<(_0op-1),<(_2op_var-1),<(_2op_var-1),<(_var-1),<(_var-1)
dispatch_hi
	!byte >(_2op_s_s-1),>(_2op_s_s-1),>(_2op_s_v-1),>(_2op_s_v-1),>(_2op_v_s-1),>(_2op_v_s-1),>(_2op_v_v-1),>(_2op_v_v-1)
	!byte >(_1op_large-1),>(_1op_small-1),>(_1op_variable-1),>(_0op-1),>(_2op_var-1),>(_2op_var-1),>(_var-1),>(_var-1)

_2op_lo
	!byte <(z_ill-1),<(z_je-1),<(z_jg-1),<(z_dec_chk-1),<(z_inc_chk-1),<(z_jin-1),<(z_test-1)
	!byte <(z_or-1),<(z_and-1),<(z_test_attr-1),<(z_set_attr-1),<(z_clear_attr-1),<(z_store-1),<(z_insert_obj-1),<(z_loadw-1)
	!byte <(z_loadb-1),<(z_get_prop-1),<(z_get_prop_addr-1),<(z_get_next_prop-1),<(z_add-1),<(z_sub-1),<(z_mul-1),<(z_div-1)
	!byte <(z_mod-1),<(z_ill-1),<(z_ill-1),<(z_ill-1),<(z_ill-1)

; if an instruction would cross a non-contiguous 4k boundary (rare), we copy the entire instruction into a temporary
; location and execute it from there.
next_insn
	ldy znext
	lda (zptr),y
	sta zinsn
	lsr
	lsr
	lsr
	lsr
	lda dispatch_hi,Y
	pha
	lda dispatch_lo,Y
	pha
	rts

; zptr is not within 11 bytes of a 4k boundary.
; at entry to instruction handler:
; Y contains instruction
; X contains operand count
; znext contains offset from (zptr) of next insn byte.
_2op_s_s
	jsr operand_small
	jsr operand_small
	bne ._2op_common ; always taken
_2op_s_v
	jsr operand_small
	jsr operand_variable
	bne ._2op_common ; always taken
_2op_v_s
	jsr operand_variable
	jsr operand_small
	bne ._2op_common ; always taken
_2op_v_v
	jsr operand_variable
	jsr operand_variable
._2op_common
	lda zinsn
	and #$1F
	tay
	lda _2op_hi,Y
	pha
	lda _2op_lo,Y
	pha
	rts

_1op_large
	jsr operand_large
	bne ._1op_common
_1op_small
	jsr operand_small
	bne ._1op_common
_1op_variable
	jsr operand_variable
._1op_common
	lda zinsn
	and #$f
	lda _1op_hi,Y
	pha
	lda _1op_lo,Y
	pha
	rts

_0op
	lda zinsn
	and #$f	; could eliminate mask if we bias the lookup addresses
	tay
	lda _0op_hi,Y
	pha
	lda _0op_lo,Y
	pha
	rts

operand_types
	!byte %01011111,%01011111,%01101111,%01101111,%10011111,%10011111,%10101111,%10101111
	!byte $00111111,%01111111,%10111111,%11111111,%00000000,%00000000,%00000000,%00000000
; opcode
; (type byte) (type byte for call_vs2) (00=large, 01=small, 10=var, 11=omit)
; operands
; (store destination)
; (branch offset)
; (text to print)
next_insn
	jsr next_byte
	sta insn
	lsr
	lsr
	lsr
	lsr
	tay
	ldx #0
	lda operand_types,Y
	bne .load_type
	jsr next_byte
	; TODO: call_vs2 eventually
	; the type bytes are now in A
.load_type
	sta type_byte
	bit type_byte
	bmi .var_omit
	bvs .small
	jsr next_byte
	sta operands_hi,x
	jsr next_byte
.next_type

	sec
	rol type_byte
	sec
	rol type_byte
	bne .load_type ; always taken

	; all operand handlers inx before return
	; and so the zero flag is always clear.
operand_large
	lda (zptr),Y
	iny
	!byte $2C	; bit NNNN, skips lda #$0
	; zero flag clear on return (x never zero)
operand_small
	lda #$0
	sta operands_hi,x
	lda (zptr),y
	iny
	sta operands_lo,x
	sty znext
	inx
	rts

operand_variable	
	lda (zptr),Y
	iny
	sty znext
	beq .read_tos
	bmi .read_global_hi
	cmp #$10
	bcs .read_global_lo
	; read local
	tay
	lda (frame_hi),Y
	sta operands_hi,x
	lda (frame_lo),Y
	sta operands_lo,x
	inx
	rts
.read_global_lo
	asl
	tay
	lda (globals_lo),Y
	sta operands_hi,X
	iny
	lda (globals_lo),Y
	sta operands_lo,x
	inx
	rts
.read_global_hi
	asl
	tay
	lda (globals_hi),y
	sta operands_hi,x
	iny
	lda (globals_hi),Y
	sta operands_lo,X
	inx
	rts
.read_tos
	dec stackptr
	ldy stackptr
	lda stack_hi,Y
	sta operands_hi,x
	lda stack_lo,Y
	sta operands_lo,X
	inx
	rts

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

branch_failed

branch_passed

z_jg
	sec
	lda operands_lo+0
	sbc operands_hi+0
	lda operands_lo+1
	sbc operands_hi+1
	beq branch_failed
	bcs branch_passed
	bcc branch_failed ; always taken

z_jl
	sec
	lda operands_lo+0
	sbc operands_hi+0
	lda operands_lo+1
	sbc operands_hi+1
	bcc branch_passed
	bcs branch_failed ; always taken	

z_or
	lda operands_lo+0
	or operands_lo+1
	tax
	lda operands_hi+0
	or operands_hi+1
	jmp store_common

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

store_common
	ldy znext
	inc znext
	lda (zptr),y
	beq .store_tos
	bmi .store_global_hi
	cmp #$10
	bcs .store_global_lo
	; store local
	sta (frame_hi),Y
	txa
	sta (frame_lo),Y
	jmp next_insn
.store_global_lo
	asl
	sta (globals_lo),y
	txa
	sta (globals_lo),y
	jmp next_insn
.store_global_hi
	asl
	sta (globals_hi),Y
	txa
	sta (globals_hi),Y
	jmp next_insn
.store_tos
	ldy stackptr
	sta stack_hi,Y
	txa
	sta stack_lo,y
	inc stackptr
	beq +
	jmp next_insn
+ 	jsr fatal_error
	!text "stack overflow"

