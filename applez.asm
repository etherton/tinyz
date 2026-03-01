
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

	lda #160
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
	and #248
	sta $20
	lda .mul40,y
	and #7
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
