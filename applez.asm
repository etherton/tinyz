
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

scroll
	sta PAGE2
	jsr .scroll
	sta PAGE1
.scroll
	ldy #40			; 2 bytes
	jmp (scrolltop)	; 3 bytes
	; lines 0-7
	lda $480-1,Y	; 6 bytes ...
	sta $400-1,Y	; ... per line
	lda $500-1,Y
	sta $480-1,y
	lda $580-1,y
	sta $500-1,Y
	lda $600-1,y
	sta $580-1,y
	lda $680-1,Y
	sta $600-1,y
	lda $700-1,y
	sta $680-1,Y
	lda $780-1,y
	sta $700-1,Y
	; lines 8-15
	lda $428-1,Y
	sta $780-1,Y
	lda $4a8-1,Y
	sta $428-1,Y
	lda $528-1,y
	sta $4a8-1,Y
	lda $5a8-1,Y
	sta $528-1,Y
	lda $628-1,Y
	sta $5a8-1,Y
	lda $6a8-1,Y
	sta $628-1,Y
	lda $728-1,Y
	sta $6a8-1,Y
	lda $7a8-1,y
	sta $728-1,Y
	; lines 16-23
	lda $450-1,Y
	sta $728-1,Y
	lda $4d0-1,Y
	sta $450-1,Y
	lda $550-1,y
	sta $4d0-1,Y
	lda $5d0-1,Y
	sta $550-1,Y
	lda $650-1,Y
	sta $5d0-1,Y
	lda $6d0-1,Y
	sta $650-1,Y
	lda $750-1,Y
	sta $6d0-1,Y
	lda $7a0-1,Y
	sta $750-1,Y
	lda #$A0
	sta $7a0-1,Y
	dey
	bne +
	jmp (scrolltop)
+	rts

scrolltop !byte <(.scroll+11),>(.scroll+11)

clr1	
	ldy #0
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
stringptr = $60
globals_lo = $62	; address of globals - 32 bytes
globals_hi = $64	; address of global 112 (index $80)
frame_lo = $66		; address of lower half of stack (+1 = first local, +2 = second...)
frame_hi = $68		; address of upper half of stack


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

; opcode
; (type byte) (type byte for call_vs2) (00=large, 01=small, 10=var, 11=omit)
; (operands)
; (store destination)
; (branch offset)
; (text to print)

; if an instruction would cross a non-contiguous 4k boundary (rare), we copy the entire instruction into a temporary
; location and execute it from there. (eventually)
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
	ldx #0
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
	ldy znext
	jsr operand_small
	bne ._2op_common ; always taken
_2op_v_v
	jsr operand_variable
	ldy znext
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
_2op_var
	jsr decode_types
	jmp ._2op_common
_var
	jsr decode_types
	lda zinsn
	and #$1F
	tay
	lda _var_hi,Y
	pha
	lda _var_lo,Y
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
	ldy zinsn
	lda _0op_hi-$b0,Y
	pha
	lda _0op_lo-$b0,Y
	pha
	rts

decode_types
	lda (zptr),Y
	iny
	sty znext
	sta ztype
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
	jsr variable
	ldy znext
.next_type
	sec 
	rol ztype
	sec
	rol ztype
	bne -
.decode_done
	rts




	; all operand handlers inx before return and so the zero flag is always clear.
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

	; operand_variable destroys y so it needs to be reloaded from znext
	; if there are more types to decode
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
	sbc operands_lo+1
	lda operands_hi+0
	sbc operands_hi+1
	beq branch_failed
	bcs branch_passed
	bcc branch_failed ; always taken

z_jl
	sec
	lda operands_lo+0
	sbc operands_lo+1
	lda operands_hi+0
	sbc operands_hi+1
	bcc branch_passed
	bcs branch_failed ; always taken	

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
	bne branch_failed
	lda operands_hi+0
	and operands_hi+1
	cmp operands_hi+1
	bne branch_failed
	beq branch_passed

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
	lsr operands_lo+1
-	bcc +
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
	beq branch_failed
	bne branch_passed

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
	jmp next_next

attr_bits !byte $80,$40,$20,$10,$08,$04,$02,$01

	; operand+0 contains object index, operand+1 contains attribute.
	; sets obj_ptr and attr_bit appropriately.
attr_setup
	jsr get_object_addr	; sets obj_ptr
	lda operand_lo+1
	and #$7
	tay
	lda attr_bits,Y
	sta attr_bit
	lda operand_lo+1
	lsr
	lsr
	lsr
	tay
	rts

get_object_addr
	; compute objIndex * 9
	lda operand_lo+0
	sta obj_ptr+0
	lda operand_hi+0
	sta obj_ptr+1
	ldy #3
-	asl obj_ptr+0
	rol obj_ptr+1
	dey
	bne -
	clc
	lda obj_ptr+0
	adc operand_lo+0
	adc obj_base
	sta obj_ptr+0
	lda obj_ptr+1
	adc operand_hi+0
	adc obj_base+1
	sta obj_ptr
	rts

z_print_num
	lda #$0
	sta mulTemp
	lda #>10000
	ldx #<10000
	jsr .print_digit
	lda #>1000
	ldx #<1000
	jsr .print_digit
	lda #>100
	ldx #<100
	jsr .print_digit
	lda #>10
	ldx #<10
	jsr .print_digit
	lda operands_lo+0	; last digit always prints even if zero
	adc #$30
	jsr print_char
	jmp next_insn

.print_digit
	; store numerator
	sta operands_hi+1
	stx operands_lo+1
	jsr divide
	lda operands_lo+0
	ora mulTemp
	sta mulTemp
	beq +
	adc #$30
	jsr print_char
+	lda operands_hi+2
	sta operands_hi+0
	lda operands_lo+2
	sta operands_lo+0
	rts

z_print_char
	lda operands_lo+0
	jsr print_char
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

store_common
	jsr store_result
	jmp next_insn

store_result
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
	rts
.store_global_lo
	asl
	sta (globals_lo),y
	txa
	sta (globals_lo),y
	rts
.store_global_hi
	asl
	sta (globals_hi),Y
	txa
	sta (globals_hi),Y
	rts
.store_tos
	ldy stackptr
	sta stack_hi,Y
	txa
	sta stack_lo,y
	inc stackptr
	beq +
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
