
!macro bp {
	bit $c00e
}

!macro skip_imm {
	!byte $2C ; bit NNNN causes next two bytes to be skipped
}

!macro inca {
!ifdef TARGET_65C02 {
	inc
} else {
	clc
	adc #1
}
}

!macro lsr5 {
	lsr
	lsr
	lsr
	lsr
	lsr
}

_80STOREOFF	= $C000
_80STOREON	= $C001
RAMRDOFF	= $C002 ; read enable main memory
RAMRDON		= $C003 ; read enable aux memory
RAMWRTOFF	= $C004 ; write enable main memory
RAMWRTON	= $C005 ; write enable aux memory
_80COLON	= $C00D
AUXCHARSET	= $C00F
RAMRD		= $C013	; bit 7 on if AUX memory active from $200-$BFFF

PAGE1		= $C054
PAGE2		= $C055

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
; rom delay routine (in cycles) at $fca8 (delay in A, (26 + 27A + 5A^2)/2 cycles (0.98us per cycle))

; Hardware specific layer uses $20-$3F
dest_ptr	= $20
src_ptr		= $22
xsave		= $24
ysave		= $25
cursor_x	= $26
window_split = $28
vblprev = 	$29
top_cursor_x = $2A
slot_index	= $2B		; $60 for slot 6 (this comes from boot loader)
prev_top_cursor_x = $2C
text_ptr = $2D

data_page = $30
track = $31
trackbit = $32
sector = $33
tracks_remaining = $34
sector_map_lo = $35
sector_map_hi = $36
seed = $38

PH0OFF		= $C080
PH0ON		= $C081
PH1OFF 		= $C082
PH1ON		= $C083
PH2OFF		= $C084
PH2ON		= $C085
PH3OFF		= $C086
PH3ON		= $C087
MOTOROFF	= $C088
MOTORON		= $C089

; WE locations must be accessed twice if not already in WE state.
BANKA_RAMRD_WP	= $C080
BANKA_ROMRD_WE	= $C081
BANKA_ROMRD_WP	= $C082
BANKA_RAMRD_WE	= $C083

BANKB_RAMRD_WP	= $C088
BANKB_ROMRD_WE	= $C089
BANKB_ROMRD_WP	= $C08A
BANKB_RAMRD_WE	= $C08B


	*=$E000		; actually loads at $800 hence the magic numbers in .copy below
	!byte 3		; this is the sector to stop loading at (rest of our code and lookup tables)

	sta BANKA_RAMRD_WE	; +1
	sta BANKA_RAMRD_WE	; +4

	; We load the first 4k track at $800, and immediately relocate everything to $e000
	; y is zero
.copy
	lda $800,Y			; +7
	sta $E000,Y			; +10
	iny
	bne .copy
	inc $809
	inc $80C
	dec $800
	bne .copy
	jmp stage1

stage1
	; patch instructions before we reach time critical parts.
	txa
	ora #$8C
	sta slotpatch1+1
	sta slotpatch2+1
	sta slotpatch3+1
	sta slotpatch4+1
	sta slotpatch5+1
	sta slotpatch6+1

	; read rest of track with our faster code
	sty track
	lda #$E0
	sta data_page
	lda #$F8				; already read first three sectors
	sta sector_map_lo

	jsr read_rest_track_1

	; read second half of interpreter
	jsr read_next_track

	; read first track of story to get entire size
	lda #>HEADER
	sta data_page
	jsr read_next_track

	; round story size (which is half its actual value) up to next 4k multiple
	; for V3 it's (size + $7ff) >> 8+3
	; for V4/5 it's (size + $3ff) >> 8+2
	; for V8 it's (size + $1ff) >> 8+1
	lda HEADER+27
	clc
	adc #$ff
	lda HEADER+26
!if ZVERSION=8 {
	adc #1
} else if (ZVERSION>3) {
	adc #3
} else {
	adc #7
}
	; shift it right to get the rounded-up size in 4k blocks
!if (ZVERSION<8) {
	lsr
!if (ZVERSION=3) {
	lsr
}
}
	lsr
	; A contains number of 4k tracks we need to load, but we already loaded one
	sta tracks_remaining

-	lda #$FF
	dec tracks_remaining
	beq +
	ldy tracks_remaining
	sta $500-1,y
	jsr read_next_track
	lda data_page
	cmp #$C0
	bne -
	sta _80STOREON
	sta PAGE1	; switch to aux memory
	sta RAMWRTON
	; sta RAMRDON ; not necessary now that we do single read pass

	lda #$10
	sta data_page
	bne -		; always taken
	ldx slot_index
	sta MOTOROFF,x
+	jmp endboot

next_track
	lda track
	and #1
	asl				; carry is clear
	asl
	sta trackbit	; trackbit is 0 if track was even, 4 if track was odd
	inc track

	; if original track was even, do PH0OFF, PH1ON, delay, PH1OFF, PH2ON delay PH2OFF
	; if original track was odd, do PH2OFF, PH3ON, delay, PH3OFF, PH0ON delay PH0OFF
	lda slot_index
	eor trackbit
	tax

	lda PH0OFF,x
	lda PH1ON,x
	lda #86
	jsr delay	; can't use rom version since we swap language card
	lda PH1OFF,x

	txa
	eor #4
	tax

	lda PH0ON,x
	lda #86
	jsr delay
	lda PH0OFF,x
	rts

RDBYTE6 = $C000	; bad value to make sure it's patched ($C08C + slot*16)

; we don't use much of the stack
; have to start higher to avoid page crossing
; use this area because it swaps as same time as ZP and high memory
twos_buffer = $12C

; returns A zero (and zero flag set) if it's the data part, nonzero if header part
read_d5_aa
	jsr read_byte
	cmp #$d5
	bne read_d5_aa
	jsr read_byte
	cmp #$aa
	bne read_d5_aa
	jsr read_byte
	eor #$ad
	rts

read_next_track
	jsr next_track
	lda #$FF
	sta sector_map_lo
read_rest_track_1
	lda #$FF
	sta sector_map_hi
-	jsr read_sector
	lda sector_map_lo
	ora sector_map_hi
	bne -
	clc
	lda data_page
	adc #$10
	sta data_page
	rts

read_sector
	; loop until we find next address
	; address header is $d5, $aa, $96 XX YY XX YY XX YY XX YY (volume, track, sector, checksum)
read_header
	jsr read_d5_aa
	beq read_header

	ldy #5			; skip volume and track, ending on sector
-	jsr read_byte
	dey
	bne -

	; we have a limited amount of time here; there's a sector header epilog and then
	; some sync bytes and then the sector data header.
	; we need a pretty big table to decode the bits so let's use the third column of interleave
	sec
	rol	
	sta sector
	jsr read_byte
	and sector
	sta sector

	asl
	asl				; multiply by four so we can use the big table (carry clear)
	tay

	ldx		interleave+3,Y		; get low or high byte of sector_map_hi
	lda		interleave+3+64,y	; get shifted value
	and		sector_map_lo,X
	beq		read_header
	
	lda data_page
	adc sector		; this was final sector address (carry still clear)

	sta patch2+2
	sta patch3+2
	sbc #0			; carry was clear so this is a decrement
	sta patch1+2

read_data
	jsr read_d5_aa
	bne read_header	

	; a now zero
	; read twos in reverse order
	; so we can merge with sixes with a single counter.
	tay
read_twos
	ldy #$2A
slotpatch1
-	ldx RDBYTE6				; 4
	bpl -					; 2 when not taken
	eor conv_tab-$96,x		; 4
	sta twos_buffer-$2A,Y	; 5
	iny						; 2
	bpl -					; 3, 2 when not taken on final iteration

	; the following code is extremely timing sensitive
	; we can't afford any branches crossing page boundaries here.
	; normally we'd start at $55 and count downward, but we need the bytes
	; in the correct order and we also can't afford the compare instruction.
	; but we also have to watch out for page crossings.
	ldy #$2A
slotpatch2
-	ldx RDBYTE6			; 4 - read next 6's byte
	bpl -				; 2 - when not taken
	eor conv_tab-$96,X	; 4 - convert to 6 bit (pre-shifted) value
	ldx twos_buffer-$2A,Y; 4 - get matching 2's entry (no crossing)
	ora interleave,X	; 4 - merge them
patch1
	sta $ff00-$2A,Y		; 5+1 - store the result (page crossing)
	and #$fc			; 2 - clear the bits so next ora works.
	iny					; 2 - stops at 128 (need this to have fewer page crossings)
	bpl -				; 3 - 31 cycles per byte (30 cycles on last iteration)

	; note that after this point are in perfect lockstep; there are two
	; cycles available for the reload of Y, then the next byte is latched (32 cycles)

	ldy #$2A
slotpatch3
-	ldx RDBYTE6
	bpl -
	eor conv_tab-$96,X
	ldx twos_buffer-$2A,Y
	ora interleave+1,X
patch2
	sta $ff56-$2A,Y			; no page crossing this time!
	and #$fc
	iny
	bpl -					; 30 cycles per byte, 29 on last iteration

	ldy #$2C
slotpatch4
-	ldx RDBYTE6
	bpl -
	eor conv_tab-$96,X
	ldx twos_buffer-$2C,Y
	ora interleave+2,X
patch3
	sta $ffac-$2C,Y
	and #$fc
	iny
	bpl -					; 30 cycles per byte, 29 on last iteration

slotpatch5
-	ldy RDBYTE6
	bpl -
	eor conv_tab-$96,y
	beq +
	jmp read_header	; checksum failure 
	; if we got here, remember that we successfully read the sector
+	lda sector
	asl
	asl
	tay
	ldx interleave+3,Y			; get which byte in sector map to update
	lda interleave+3+128,Y		; get inverted shifted bit
	and sector_map_lo,X
	sta sector_map_lo,x
	rts

	; we cannot afford page crossings for either of these tables.
	!align 255, 256-(13*8+2)
conv_tab
	!byte 0*4,1*4
	!byte 255,255,2*4,3*4,255,4*4,5*4,6*4
read_byte
slotpatch6
	lda RDBYTE6
	bpl read_byte
	rts
	!byte 7*4,8*4
delay
	sec
	bcs delay2
	!byte 9*4,10*4,11*4,12*4,13*4
	!byte 255,255,14*4,15*4,16*4,17*4,18*4,19*4
	!byte 255,20*4,21*4,22*4,23*4,24*4,25*4,26*4
	; hide this 11 byte routine in an unused part of the table
delay2
--	pha
-	sbc #$01
	bne -
	pla
	sbc #$01
	bne --
	rts
	!byte 27*4,255,28*4,29*4,30*4
	!byte 255,255,255,31*4,255,255,32*4,33*4
	!byte 255,34*4,35*4,36*4,37*4,38*4,39*4,40*4
	!byte 255,255,255,255,255,41*4,42*4,43*4
	!byte 255,44*4,45*4,46*4,47*4,48*4,49*4,50*4
	!byte 255,255,51*4,52*4,53*4,54*4,55*4,56*4
	!byte 255,57*4,58*4,59*4,60*4,61*4,62*4,63*4
	!align 255, 0
; +0 is first two bits, reversed, +1 is second two bits, reversed, +2 is third two bits, reversed
; +3 is a bit table used to manage the sector map; first 16 rows is (sector/8), next is (1<<(sector&7),
; last 16 rows is ~(1<<(sector&7))
interleave
	!byte 0,0,0,0
	!byte 2,0,0,0
	!byte 1,0,0,0
	!byte 3,0,0,0
	!byte 0,2,0,0
	!byte 2,2,0,0
	!byte 1,2,0,0
	!byte 3,2,0,0

	!byte 0,1,0,1
	!byte 2,1,0,1
	!byte 1,1,0,1
	!byte 3,1,0,1
	!byte 0,3,0,1
	!byte 2,3,0,1
	!byte 1,3,0,1
	!byte 3,3,0,1

	!byte 0,0,2,1
	!byte 2,0,2,2
	!byte 1,0,2,4
	!byte 3,0,2,8
	!byte 0,2,2,16
	!byte 2,2,2,32
	!byte 1,2,2,64
	!byte 3,2,2,128

	!byte 0,1,2,1
	!byte 2,1,2,2
	!byte 1,1,2,4
	!byte 3,1,2,8
	!byte 0,3,2,16
	!byte 2,3,2,32
	!byte 1,3,2,64
	!byte 3,3,2,128

	!byte 0,0,1,255-1
	!byte 2,0,1,255-2
	!byte 1,0,1,255-4
	!byte 3,0,1,255-8
	!byte 0,2,1,255-16
	!byte 2,2,1,255-32
	!byte 1,2,1,255-64
	!byte 3,2,1,255-128

	!byte 0,1,1,255-1
	!byte 2,1,1,255-2
	!byte 1,1,1,255-4
	!byte 3,1,1,255-8
	!byte 0,3,1,255-16
	!byte 2,3,1,255-32
	!byte 1,3,1,255-64
	!byte 3,3,1,255-128

	!byte 0,0,3,0
	!byte 2,0,3,0
	!byte 1,0,3,0
	!byte 3,0,3,0
	!byte 0,2,3,0
	!byte 2,2,3,0
	!byte 1,2,3,0
	!byte 3,2,3,0
	
	!byte 0,1,3,0
	!byte 2,1,3,0
	!byte 1,1,3,0
	!byte 3,1,3,0
	!byte 0,3,3,0
	!byte 2,3,3,0
	!byte 1,3,3,0
	!byte 3,3,3,0

endboot
	; these are part of boot code but we're tight on space there.
+	sta RAMWRTOFF
	; sta RAMRDOFF


!if COLUMNS=80 {
	sta _80COLON
	sta _80STOREON
}
	sta AUXCHARSET

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
	sta top_cursor_x

print_char = $00
encode_buffer = $03		; takes either 6 bytes or 9 bytes

	lda #$4C
	sta print_char
	jmp zentry

setpos	; input x, destroys a
	lda .mul40,x
	and #$F8
	sta dest_ptr
	lda .mul40,x
	and #$7
	sta dest_ptr+1
	rts

!if COLUMNS=40 {
	FAST_SCROLL=1
}

; scroll returns with negative flag always set, so bmi is always taken.
!ifdef FAST_SCROLL {
scroll
!if COLUMNS=80 {
	sta PAGE2
	jsr .scroll
	sta PAGE1
}
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

!if (COLUMNS=80) {
	sta PAGE2
	ldy #39
-	lda (src_ptr),Y
	sta (dest_ptr),Y
	dey
	bpl -

	sta PAGE1
}
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
!if COLUMNS=80 {
	sta PAGE2
	ldy #39
-	sta (dest_ptr),y
	dey
	bpl -
	sta PAGE1
}
	ldy #39
- 	sta (dest_ptr),Y
	dey
	bpl -
	rts
}

	; destroys A
print_char_lower
	sty ysave
!if COLUMNS=80 {
	stx xsave
}
	cmp #13
	beq .print_char_nl
!ifdef TARGET_APPLE2PLUS {
	cmp #96
	bcc +
	sbc #32
}
+	ora #$80

!if COLUMNS=80 {
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
} else {
	ldy cursor_x
	inc cursor_x
	sta (dest_ptr),Y
}
	cpy #39
	bne .print_char_done
.print_char_nl
	ldy #0
	sty cursor_x
	jsr scroll
!if COLUMNS=80 {
	bmi .print_char_done ; always taken
.print_char_even
	sta PAGE2
	txa
	sta (dest_ptr),y
}
.print_char_done
!if COLUMNS=80 {
	ldx xsave
}
	ldy ysave
	rts

clear
!if COLUMNS=80 {
	sta PAGE2
	jsr .clear
	sta PAGE1
}
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

	; destroys a
print_char_upper
	sty ysave
!if COLUMNS=80 {
	stx xsave
}
	cmp #$40
	bcc .notupper
!ifndef TARGET_APPLE2PLUS {
	cmp #$60
	bcs .notupper
}
	and #$1F
.notupper
!if COLUMNS=80 {
	tax
	lda top_cursor_x
	inc top_cursor_x
	lsr
	tay
	bcc .upper_even
.upper_odd
	sta PAGE1
-	txa
	sta $400,Y
	ldx xsave
	ldy ysave
	rts
.upper_even
	sta PAGE2
	jmp -
} else {
	ldy top_cursor_x
	inc top_cursor_x
	sta $400,y
	ldy ysave
	rts
}

.mul40
	!byte 	$04, $84, $05, $85, $06, $86, $07, $87
	!byte	$2C, $AC, $2D, $AD, $2E, $AE, $2F, $AF
	!byte	$54, $D4, $55, $D5, $56, $D6, $57, $D7
	
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

	; returns last keypress in A
read_char
	lda $C000
	bpl read_char
	bit $C010
	and #$7f
	rts

	; text_ptr contains address to store input line
	; first byte is maximum length
	; on return, first byte is actual length
	; on V3, first byte is maximum length, and input is 0-terminated
	; on V5+, first byte is maximum length, and second byte is total amount
read_line
!ifdef TARGET_65C02 {
	lda (text_ptr)
} else {
	ldy #0
	lda (text_ptr),Y
}
	sta .max_length+1
!ifdef V5PLUS {
	ldy #1
	lda (text_ptr),y
	tay
	iny
} else {
	ldy #0
}
.update_cursor
	lda #'_'
	jsr print_char
	lda #' '
	jsr print_char
	dec cursor_x
	dec cursor_x
.next_char
	jsr read_char
	cmp #$08
	beq .backsp
	cmp #$7F
	beq .backsp
	cmp #$0D
	beq .return
	cmp #$20
	bcc .next_char
.max_length
	cpy #99
	beq .next_char
	iny
	pha
	jsr print_char
	pla
	cmp #'A'
	bcc .notupper2
	cmp #'Z'+1
	bcs .notupper2
	adc #32
.notupper2
	sta (text_ptr),y
	jmp .update_cursor
.backsp
	cpy #0
	beq .next_char
	dec cursor_x
	dey
	jmp .update_cursor
.return
	lda #$20
	jsr print_char
	lda #$0D
	jsr print_char
	lda #0
	iny
	sta (text_ptr),y
	rts

; Portable code ZP use starts at $40
mulTemp = $46
attr_bit = $47
ztype = $48
zinsn = $49
zpc_hi = $4A		; upper two bytes of offset in story (big-endian)
zpc_mid = $4B
zptr = $4C			; actual cpu address in memory of current insn (little-endian)
store_hi = $4E
operand_count = $4F
operands_hi = $50
operands_lo = $58
stringptr = $60

obj_ptr_alt = $62
obj_hi = $6A
obj_mid = $6B
obj_ptr = $6C
obj_base = $6E		; 9 bytes before first object slot
window_current = $71
output_table = $72
output_enables = $73
zshift = $74		; one less than current shift value for ZSCII ($ff for none)
abbrev = $75		; $FF if not halfway through abbreviation, else 0/32/64
accum_char = $76
stackptr = $78		; one past top of stack
frameptr = $79		; one before first local (since locals are one-based)
abbrev_ptr = $7A
default_props_ptr = $7C
dict_ptr = $7E
parse_ptr = $80
text_offset = $82
parse_offset = $83
entry_ptr = $84
low_index = $86
high_index = $88
entry_size = $8A
char_index = $8B
chars_stored = $8C
last_status_room = $8D
zchar_hi = $8E
zchar_lo = $8F

!if ZVERSION>4 {
DICT_SIZE = 6
DICT_WORD_LEN = 9
} else {
DICT_SIZE = 4
DICT_WORD_LEN = 6
}

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
	!byte <(t0),<(t1),<(t2),<(t3),<(t4),<(t5),<(t6),<(t7)
	!byte <(t8),<(t9),<(t10),<(t11),<(t12),<(t13),<(t14),<(t15)
	!byte >(t0),>(t1),>(t2),>(t3),>(t4),>(t5),>(t6),>(t7)
	!byte >(t8),>(t9),>(t10),>(t11),>(t12),>(t13),>(t14),>(t15)
}

!macro table32 t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16,t17,t18,t19,t20,t21,t22,t23,t24,t25,t26,t27,t28,t29,t30,t31 {
	!byte <(t0),<(t1),<(t2),<(t3),<(t4),<(t5),<(t6),<(t7)
	!byte <(t8),<(t9),<(t10),<(t11),<(t12),<(t13),<(t14),<(t15)
	!byte <(t16),<(t17),<(t18),<(t19),<(t20),<(t21),<(t22),<(t23)
	!byte <(t24),<(t25),<(t26),<(t27),<(t28),<(t29),<(t30),<(t31)
	!byte >(t0),>(t1),>(t2),>(t3),>(t4),>(t5),>(t6),>(t7)
	!byte >(t8),>(t9),>(t10),>(t11),>(t12),>(t13),>(t14),>(t15)
	!byte >(t16),>(t17),>(t18),>(t19),>(t20),>(t21),>(t22),>(t23)
	!byte >(t24),>(t25),>(t26),>(t27),>(t28),>(t29),>(t30),>(t31)
}

; sta abs is 4x2 cycles, jmp abs is 3 - 11 total
; sta zp is 3x2 cycles, jmp ind is 5 - 11 total
; pha is 3 3x2 cycles, rts is is 6 - 12 total
!macro dispatch16 label {
	tax
	lda label+16,x
	sta .target+2
	lda label,x
	sta .target+1
.target jmp $1234
}

!macro dispatch32 label {
	tax
	lda label+32,x
	sta .target+2
	lda label,x
	sta .target+1
.target jmp $1234
}

} // endif

HEADER = $1000
;  +0 version
;  +1 flags
;  +2 pad0
;  +4 high memory address (big-endian)
;  +6 initial PC address (big-endian)
;  +8 dictionary
; +10 object table (defaults, etc)
; +12 globals
; +14 static memory address

!ifdef TARGET_65C02 {
!macro skip_insn_byte {
	inc zptr
	bne +
	jsr increment_zpc_mid
+
}

!macro zeroy {
}

!macro next_insn_byte_y0 {
	lda (zptr)
	inc zptr
	bne +
	jsr increment_zpc_mid
+
}

} else {

!macro skip_insn_byte {
	inc zptr
	bne +
	jsr increment_zpc_mid
+
}

!macro zeroy {
	ldy #0
}

!macro next_insn_byte_y0 {
	lda (zptr),y
	inc zptr
	bne +
	jsr increment_zpc_mid
+
}
}

!ifdef TAGET_APPLE2SPLUS {
!macro begin_dynamic {
}
!macro end_dynamic {
}
} else {
; begin dynamic memory reference; remember if we were using alt memory, then switch to main
; modifies N/Z/V flags
!macro begin_dynamic {
	bit RAMRD
	php
	sta RAMRDOFF
}
; remember old setting and if it was active, re-enable it. destroys flags.
!macro end_dynamic {
	plp
	bpl +
	sta RAMRDON
+
}
}
	; preserves A/X/Y
	; if high byte of zptr is $C0, we need to update the TLB
increment_zpc_mid
	inc zpc_mid
	bne +
	inc zpc_hi
+	inc zptr+1
	sta .update_zpc_restorea+1
	lda zptr+1
	cmp #$C0
	bne .update_zpc_restorea
.update_zptr
	jsr update_zptr
.update_zpc_restorea
	lda #$FF
	rts

	; destroys A
update_zptr
	lda zpc_hi
	bne .update_zptr_hi
	lda zpc_mid
	cmp #$B0
	bcs .update_zptr_upper
	adc #>HEADER	; carry clear
	sta RAMRDOFF
	sta zptr+1
	rts

	; B0->10, C0->20, D0->30, E0->40, F0->50
.update_zptr_upper
	; carry already set (A contains upper byte)
	sbc #$A0
	sta zptr+1
	sta RAMRDON
	+bp
	rts
	; 100->60, 110->70, 120->80 etc 
.update_zptr_hi
	clc
	lda zpc_mid
	adc #$60
	sta zptr+1
	sta RAMRDON
	+bp
	rts

zentry
	; copy globals into our own shadow storage
	lda HEADER+13
	sta zptr
	lda HEADER+12
	sta zpc_mid
	lda #0
	sta zpc_hi
	ldx #16
	jsr update_zptr
	+zeroy
-	+next_insn_byte_y0
	sta globals_hi,x
	+next_insn_byte_y0
	sta globals_lo,x
	inx
	bne -
	
	jsr default_print_char
	lda HEADER
	cmp #ZVERSION
	beq +
	jsr fatal_error
	!text "story version isn't compatible with interpreter",13,0
+
	; set up initial pc
	lda HEADER+7
	sta zptr
	lda HEADER+6
	sta zpc_mid
	lda #0
	sta chars_stored
	sta zpc_hi
	sta stackptr
	jsr update_zptr

	; set up 1-based object table address
	clc
	lda HEADER+11
	sta default_props_ptr
!if ZVERSION>3 {
	adc #(126 - 14)
} else {
	adc #(62 - 9)		; skip defaults, and objects are 1-based
}
	sta obj_base

	lda HEADER+10
	adc #>HEADER
	sta obj_base+1
	lda HEADER+10
	adc #>HEADER
	sta default_props_ptr+1

	lda HEADER+9
	sta dict_ptr
	lda HEADER+8
	adc #>HEADER
	sta dict_ptr+1
	ldy #0
	lda (dict_ptr),y
	cmp #3
	beq +		; also sets carry
	jsr fatal_error
	!text "dictionary does not have three separators",13,0
+	ldy #4
	lda (dict_ptr),Y
	sta entry_size
	lda dict_ptr
	adc #$6			; carry is always set, so add 7
	sta entry_ptr
	lda dict_ptr+1
	adc #0
	sta entry_ptr+1

	lda #1
	sta window_split
	sta vblprev
	lda #(COLUMNS)
	sta prev_top_cursor_x

	; avoid ZP use by modifying the one place we need abbreviations
	lda HEADER+25
	sta abbrev_load+1
	sta abbrev_load2+1
	lda HEADER+24
	adc #>HEADER
	sta abbrev_load+2
	sta abbrev_load2+2

	lda #COLUMNS
	sta HEADER+$21
	lda #24
	sta HEADER+$20

	; generate zencode table
	ldx #31
-	lda zalphabet-6,x
	tay
	txa
	sta zencode-32,Y

	lda zalphabet+26-6,X
	tay
	txa
	ora #(4*32)
	sta zencode-32,Y

	dex
	cpx #5
	bne -

	ldx #31
-	lda zalphabet+52-6,X
	tay
	txa
	ora #(5*32)
	sta zencode-32,Y
	dex
	cpx #7	; first two slots in last row are special and cannot be overidden.
	bne - 

	jmp next_insn

; opcode
; (type byte) (type byte for call_vs2) (00=large, 01=small, 10=var, 11=omit)
; (operands)
; (store destination)
; (branch offset)
; (text to print)



; if an instruction would cross a non-contiguous 4k boundary (rare), we copy the entire instruction into a temporary
; location and execute it from there. (eventually)
	; !align 255,0
next_insn
!ifndef TARGET_APPLE2PLUS {
	lda $c019
	bpl +			; not in vbl
	ldx vblprev
	bmi ++			; didn't just enter vbl
	inc HEADER+5
	bne +
	inc HEADER+4
+	sta vblprev
++
}

!ifdef DEBUG_TRACE {
	lda #13
	jsr print_char
	lda zpc_hi
	jsr print_hex_byte
	lda zpc_mid
	jsr print_hex_byte
	lda zptr
	jsr print_hex_byte
}
	+zeroy
	+next_insn_byte_y0
	sta zinsn
	lsr
	lsr
	lsr
!ifdef TARGET_65C02 {
	and #$FE
	tax
	jmp (dispatch,x)
} else {
	lsr
	tax
	lda dispatch,x
	sta .jump+1
.jump jmp _2op_s_s
}

	!align 255, 0
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
	stx operand_count
._2op_common_2
	lda zinsn
	and #$1F
	+dispatch32 _2opTbl
_2op_var
	jsr decode_types
	jmp ._2op_common_2
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
	+next_insn_byte_y0
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
	stx operand_count ; je and call_vs need arg count
	rts

	; all operand handlers inx before return and so the zero flag is always clear.
operand_large
	+next_insn_byte_y0
	+skip_imm
	; zero flag clear on return (x never zero)
operand_small
	lda #$0
	sta operands_hi,x
	+next_insn_byte_y0
	sta operands_lo,x

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text " op ",0
	txa
	jsr print_hex_byte
	jsr debug_print
	!text " is ",0
	jsr print_operand
}
	inx
	rts

	; operand_variable destroys y so it needs to be reloaded from znext
	; if there are more types to decode
operand_variable	
!ifdef DEBUG_TRACE {
	jsr debug_print
	!text " op ",0
	txa
	jsr print_hex_byte
}
	+next_insn_byte_y0
	cmp #$00
	beq .read_tos
!ifndef FRAME_USES_GLOBALS {
	cmp #$10
	bcs .read_global
	; read local
	adc frameptr
	tay
	lda stack_hi,Y
	sta operands_hi,x
	lda stack_lo,Y
	sta operands_lo,x
	+zeroy

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
}
	tay
	lda globals_hi,Y
	sta operands_hi,X
	lda globals_lo,Y
	sta operands_lo,x
	+zeroy

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
	+zeroy

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
	lda #32
	jmp print_char
}

z_ill
	lda zinsn
	jsr print_hex_byte
	lda #32
	jsr print_char
	jsr fatal_error
	!text "unimplemented insn",13,0

; branch(var(operands[0].getS()).dec() < operands[1].getS()); break;
z_dec_chk

	jsr fatal_error
	!text "dec_chk not impl",0

; branch(var(operands[0].getS()).inc() > operands[1].getS()); break;
z_inc_chk
	lda operands_lo+0
	beq .inc_chk_tos
!ifndef FRAME_USES_GLOBALS {
	cmp #$10
	bcs .inc_chk_global
	; carry is clear here
	adc frameptr
	tax
	inc stack_lo,X
	lda stack_lo,X
	sta operands_lo+0
	bne +
	inc stack_hi,X
+	lda stack_hi,X
	sta operands_hi+0
	jmp z_jg
.inc_chk_global
}
	tax
	inc globals_lo,x
	lda globals_lo,X
	sta operands_lo+0
	bne +
	inc globals_hi,x
+	lda globals_hi,X
	sta operands_hi+0
	jmp z_jg
.inc_chk_tos
	ldx stackptr
	inc stack_lo-1,X
	lda stack_lo-1,X
	sta operands_lo+0
	bne +
	inc stack_hi-1,X
+	lda stack_hi-1,X
	sta operands_hi+0
	jmp z_jg

	; is operands+0's parent operand+1?
z_jin
	jsr get_object_addr
	ldy #4 ; parent
	cmp operands_lo+1
	beq +
	jmp branch_failed
+	jmp branch_passed

z_print_ret
	jsr z_print_inline_common
	lda #$0D
	jsr print_char
z_rtrue
	ldx #1
	+skip_imm
z_rfalse
	ldx #0
	lda #0
	; frame+0 is lower 16 bits of current PC
	; frame+1 is upper 8 bits of current PC and previous frameptr
	; frame+2 is location to store result, and operand count in V5+ (frame+2 is new frameptr)
.z_ret_common
	sta store_hi
	ldy frameptr
	dey
	dey
	sty stackptr

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text "sp value during return is ",0
	lda stackptr
	jsr print_hex_byte
	lda #$d
	jsr print_char
}
	lda stack_lo,Y
	sta zptr
	lda stack_hi,Y
	sta zpc_mid
	lda stack_lo+1,Y
	sta zpc_hi
	lda stack_hi+1,Y
	sta frameptr
	
	jsr update_zptr

	lda stack_lo+2,Y
	; TODO: On V4+, might be a non-storing call
	jsr store_result_2
	jmp next_insn

z_ret
	ldx operands_lo+0
	lda operands_hi+0
	jmp .z_ret_common

z_jump
	lda operands_lo+0
	ldx operands_hi+0	; msb of X needs to be replicated through Y
	jmp .compute_newpc

z_jz
	lda operands_lo+0
	ora operands_hi+0
	bne branch_failed
	beq branch_passed	; always taken

; on entry, op0/op1 contain decoded operands
; on exit, x contains low byte of result, a contains high byte
z_je
	ldx operand_count
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
	bne +
	jmp  z_rtrue
+	ldx #0

	; x is high byte of offset, a is low byte
	; we want pc + (offset-2) so do that first
	; so we don't need to process all three bytes
	; note the sign will never change because 0/1
	; are already handled above.
.compute_newpc
	sec
	sbc #2
	tay
	txa
	sbc #0
	; hey guess what transfers affect N and Z flags.
	tax
	tya
	cpx #0
	bpl +
	ldy #$FF
	+skip_imm
+	ldy #0

	clc
	adc zptr
	sta zptr
	txa
	adc zpc_mid
	sta zpc_mid
	tya
	adc zpc_hi
	sta zpc_hi
	jsr update_zptr
	jmp next_insn

branch_failed
	+zeroy
	+next_insn_byte_y0
	cmp #$80
	bcc .branch_passed
.branch_failed
	and #$40
	bne .short_branch_failed
	+skip_insn_byte
.short_branch_failed
	jmp next_insn
branch_passed
	+zeroy
	+next_insn_byte_y0
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
	+next_insn_byte_y0
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
	jmp branch_failed	; always taken

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
	beq .z_mul_8x8u		; can we use faster 8x8 mul?
	jsr .z_mul_16x16u
	lda operands_hi+2
	ldx operands_lo+2
	jmp store_common

	; standard 16x16->16 unsigned
.z_mul_16x16u
	; result -> operands_lo+2, result+1 -> operands_hi+2, result+2 -> operands_lo+3, result+3 -> operands_hi+3
	; destroys A, X, Y, operands+1 (num2); operands+0 (num1) is preserved
	lda #0
	sta operands_lo+3	; result+2
	ldx #16
-	lsr operands_hi+1	; num2+1
	ror operands_lo+1	; num2
	bcc +
	tay
	clc
	lda operands_lo+0	; num1
	adc operands_lo+3	; result+2
	sta operands_lo+3	; result+2
	tya
	adc operands_hi+0	; num1+1
+	ror
	ror operands_lo+3	; result+2
	ror operands_hi+2	; result+1
	ror operands_lo+2	; result
	dex
	bne -
	sta operands_hi+3	; result+3
	rts

.z_mul_signed
	jsr fatal_error
	!text "only unsigned mul implemented",13,0

	; https://llx.com/Neil/a2/mult.html
	; result in A (high) and X (low)
.z_mul_8x8u
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

z_random
	lda operands_hi+1
	bmi .seed_random
	bpl .random_range
	ldx operands_lo+1
	bne .random_range
	; random(0) should seed based on system randomness.
	eor #$FF
.seed_random
	sta seed+1
	ldx operands_lo+1
	stx seed
	lda #0
	ldx #0
	jmp store_common
.random_range
	; LFSR (came from google AI query)
    lda seed
    lsr
    lda seed+1
    ror
    eor seed
    sta seed
    eor seed+1
    lsr
    lda seed
    ror
    eor seed
    sta seed
    eor seed+1
    sta seed+1
	; divide seed by range
	lda operands_lo+0
	sta operands_lo+1
	lda operands_hi+0
	sta operands_hi+1
	lda seed
	sta operands_lo+0
	lda seed+1
	sta operands_hi+1
	jsr divide
	; increment result
	lda operands_hi+0
	ldx operands_lo+0
	inx
	bne +
	clc
	adc #1
+	jmp store_common

z_div
	jsr divide
	lda operands_hi+0
	ldx operands_lo+0
	jmp store_common

z_mod
	jsr divide
	lda operands_hi+2
	ldx operands_lo+2
	jmp store_common

z_test_attr
	+begin_dynamic
	jsr attr_setup
	lda (obj_ptr),Y
	+end_dynamic
	and attr_bit
	beq +
	jmp branch_passed
+	jmp branch_failed

z_set_attr
	+begin_dynamic
	jsr attr_setup
	lda (obj_ptr),y
	ora attr_bit
	sta (obj_ptr),Y
	+end_dynamic
	jmp next_insn

z_clear_attr
	+begin_dynamic
	jsr attr_setup
	lda attr_bit
	eor #$ff
	sta attr_bit
	lda (obj_ptr),Y
	and attr_bit
	sta (obj_ptr),Y
	+end_dynamic
	jmp next_insn

z_get_child
	+begin_dynamic
	jsr get_object_addr
	ldy #6 ; child
	bne +
z_get_sibling
	+begin_dynamic
	jsr get_object_addr
	ldy #$5 ; sibling
+	lda (obj_ptr),Y
	+end_dynamic
	cmp #0
	beq .child_sibling_zero
	tax
	lda #0
	jsr store_result
	jmp branch_passed
.child_sibling_zero
	tax
	jsr store_result
	jmp branch_failed

	; get_parent doesn't branch
z_get_parent
	; get_parent(0) is always 0.
	lda operands_lo+0
	beq +
	; otherwise get object address
	+begin_dynamic
	jsr get_object_addr
	ldy #4 ; parent
	lda (obj_ptr),Y
	+end_dynamic
+	tax
	lda #0
	jmp store_common

z_remove_obj
	jsr remove_obj
	jmp next_insn
	; operands_lo+4 is previous operands_lo+0
remove_obj
	lda operands_lo+0
	sta operands_lo+4
	+begin_dynamic
	jsr get_object_addr
	lda obj_ptr
	sta obj_ptr_alt
	lda obj_ptr+1
	sta obj_ptr_alt+1
	ldy #4 ; parent
	lda (obj_ptr),Y
	beq .remove_obj_no_parent
	sta operands_lo+0
	jsr get_object_addr
	ldy #6 ; child
.remove_obj_check_prev
	lda (obj_ptr),Y
	cmp operands_lo+4
	bne .remove_obj_not_direct
	sty ysave
	ldy #5	; sibling
	lda (obj_ptr_alt),Y	
	ldy ysave
	sta (obj_ptr),y		; parent's child is our sibling (or our predecessor's sibling is our sibling)
	ldy #5
	lda #0
	sta (obj_ptr_alt),Y	; zero out our sibling
.remove_obj_no_parent
	+end_dynamic
	rts
	; walk next sibling in the list instead
.remove_obj_not_direct
	sta operands_lo+0
	jsr get_object_addr
	ldy #5
	bne .remove_obj_check_prev	; always take	

z_insert_obj
	jsr remove_obj
	; set our new parent
	ldy #4		; parent
	lda operands_lo+1
	+begin_dynamic
	sta (obj_ptr_alt),y
	; our sibling is parent's child
	lda operands_lo+1
	sta operands_lo+0
	jsr get_object_addr
	ldy #6 		; child
	lda (obj_ptr),y
	dey			; sibling
	sta (obj_ptr_alt),Y
	; parent's child is now us
	lda operands_lo+4
	iny			; child
	sta (obj_ptr),Y
	+end_dynamic
	jmp next_insn

z_get_prop_addr
	+begin_dynamic
	jsr prop_common
	+end_dynamic
	ldx obj_ptr
	lda obj_mid
	jmp store_common

	; on input, operands+0 is object number, operands+1 is property index
	; on return, y is property length or zero if not found; obj_ptr points
	; at the property payload
prop_common
!ifdef DEBUG_PROP_COMMON {
	lda operands_lo+0
	jsr print_hex_byte
	lda #','
	jsr print_char
	lda operands_lo+1
	jsr print_hex_byte
	jsr debug_print
	!text ": prop_common object",13,0
}
	jsr get_object_addr
	ldy #8		; property addr
	lda (obj_ptr),Y
	tax
	dey
	clc
	lda (obj_ptr),y

	; now obj_ptr points at property table
	sta obj_mid
	adc #>HEADER
	sta obj_ptr+1
	stx obj_ptr

!ifdef DEBUG_PROP_COMMON {
	lda obj_ptr+1
	jsr print_hex_byte
	lda obj_ptr
	jsr print_hex_byte
	jsr debug_print
	!text ": object table addr",13,0
}
	; get object length byte
!ifdef TARGET_65C02 {
	lda (obj_ptr)
} else {
	ldy #0
	lda (obj_ptr),y
}
	asl
	adc #1		; this won't handle extremely long object names
	adc obj_ptr
	sta obj_ptr
	bcc .find_property
	inc obj_ptr+1
	; now we're at the first property; they are in descending order, terminated with zero
	; on V3, upper 3 bits are size-1, lower 5 bits are property index, 1-31
.find_property
!ifdef DEBUG_PROP_COMMON {
	lda obj_ptr+1
	jsr print_hex_byte
	lda obj_ptr
	jsr print_hex_byte
	jsr debug_print
	!text ": next prop addr",13,0
}
!ifdef TARGET_65C02 {
	lda (obj_ptr)
} else {
	ldy #0
	lda (obj_ptr),y
}
	tay
	inc obj_ptr
	bne +
	inc obj_ptr+1
+	and #$1F
	beq .property_not_found

!ifdef DEBUG_PROP_COMMON {
	pha
	jsr print_hex_byte
	lda #'='
	jsr print_char
	lda operands_lo+1
	jsr print_hex_byte
	jsr debug_print
	!text "?",13,0
	pla
}
	cmp operands_lo+1
	beq .matched_property
	; if operands_lo+1 > current property, it's not here
	bcc .property_not_found
	jsr .matched_property	; get length in Y
	tya
	clc
	adc obj_ptr
	sta obj_ptr
	bcc .find_property
	inc obj_ptr+1
	bne .find_property
.matched_property
	tya
	+lsr5
	tay
	iny
	rts			; zero flag clear
.property_not_found
	ldy #0
	rts			; zero flag set

z_get_prop
	+begin_dynamic
	jsr prop_common
	beq .default_prop
	dey
	lda (obj_ptr),Y
	tax
	dey
	bmi +
	lda (obj_ptr),y
	+skip_imm
+	lda #0
	+end_dynamic
	jmp store_common

.default_prop
	lda operands_lo+0
	asl
	tay
	iny
	lda (default_props_ptr),Y
	tax
	dey
	lda (default_props_ptr),Y
	+end_dynamic
	jmp store_common


z_put_prop
	+begin_dynamic
	jsr prop_common
	beq invalid_property
	dey
	lda operands_lo+2
	sta (obj_ptr),Y
	dey
	bmi +
	lda operands_hi+2
	sta (obj_ptr),Y
	+end_dynamic
+	jmp store_common
invalid_property
	lda operands_lo+1
	jsr print_hex_byte
	jsr fatal_error
	!text ":invalid property for operation:",0

z_get_next_prop
	jsr fatal_error
	!text "z_get_next_prop not impl",0

z_get_prop_len
	; get_prop_len of zero is zero
	lda operands_lo+0
	ora operands_hi+0
	bne +
	ldx #0
	jmp store_common
	; otherwise go back one byte to find its length
+	lda operands_lo+0
	clc
	adc #<(HEADER-1)
	sta obj_ptr
	lda operands_hi+0
	adc #>(HEADER-1)
	sta obj_ptr+1
	+begin_dynamic
!ifdef TARGET_65C02 {
	lda (obj_ptr)
} else {
	ldy #0
	lda (obj_ptr),Y
}
	+end_dynamic
	+lsr5
	adc #1		; carry always clear from lsr
	tax
	lda #0
	jmp store_common

!macro z_print_string_hi hi,mid,zp {
	lda #$FF
	sta zshift
	sta abbrev
	sta accum_char
!ifdef TARGET_65C02 {
-	lda (zp)
} else {
	sty .restore_y+1
	ldy #0
-	lda (zp),Y
}
	php		; remember if negative
	and #$7C
	lsr
	lsr
	jsr printz
!ifdef TARGET_65C02 {
	lda (zp)
} else {
	lda (zp),Y
}
	and #$3
	sta xsave
	inc zp
	bne +
	inc zp+1
	inc mid
	bne +
	inc hi
!ifdef TARGET_65C02 {
+	lda (zp)
} else {
+	lda (zp),Y
}
	asl
	rol xsave
	asl
	rol xsave
	asl
	rol xsave
	lda xsave
	jsr printz
!ifdef TARGET_65C02 {
	lda (zp)
} else {
	lda (zp),y
}
	inc zp
	bne +
	inc zp+1
	inc mid
	bne +
	inc hi
+	and #$1F
	jsr printz
	plp
	bpl -
!ifndef TARGET_65C02 {
.restore_y
	ldy #$12
}
}
!macro z_print_string zp {
	lda #$FF
	sta zshift
	sta abbrev
	sta accum_char
	sty .restore_y+1
	ldy #0
-	lda (zp),y
	php		; remember if negative
	and #$7C
	lsr
	lsr
	jsr printz
	lda (zp),y
	and #$3
	sta xsave
	iny
	bne +
	inc zp+1
+	lda (zp),y
	asl
	rol xsave
	asl
	rol xsave
	asl
	rol xsave
	lda xsave
	jsr printz
	lda (zp),Y
	iny
	bne +
	inc zp+1
+	and #$1F
	jsr printz
	plp
	bpl -
.restore_y
	ldy #$12
}

z_print_obj
	jsr print_obj
	jmp next_insn

print_obj
	+begin_dynamic
	jsr get_object_addr
	ldy #7
	lda (obj_ptr),y	; high byte
	tax
	iny
	lda (obj_ptr),Y ; low byte
	clc
	adc #$01
	sta obj_ptr
	txa
	adc #>HEADER
	sta obj_ptr+1
print_obj_ptr
	+z_print_string obj_ptr
	+end_dynamic
	rts

z_print_addr
	lda operands_lo+0
	sta obj_ptr
	lda operands_hi+0
	clc
	adc #>HEADER
	sta obj_ptr+1
	; obj_ptr contains address in dynamic/static memory
z_print_common
	jsr print_obj_ptr
	jmp next_insn

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
!if ZVERSION>3 {
	asl ptr
	rol mid
	rol hi
!if ZVERSION=8 {
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
	+z_print_string_hi obj_hi,obj_mid,obj_ptr
	jmp next_insn

	; destroys A,X
	; 5, 6, N>>4, N encodes any character not in dictionary
printz
	ldx abbrev
	bpl .print_abbrev
	ldx accum_char
	bmi .not_accum
	asl accum_char
	asl accum_char
	asl accum_char
	asl accum_char
	asl accum_char
	ora accum_char
	sta accum_char
	cmp #$20
	bcc .print_shift_ret
	ldx #$ff
	stx accum_char
	jmp print_char
.not_accum
	cmp #6
	bcs .print_tabled
	cmp #5
	beq .print_shift_2
	cmp #4
	beq .print_shift_1
	cmp #1
	bcs .abbrev
	; print a space
	lda #$FF
	sta zshift
	lda #32
	jmp print_char
.print_tabled
	adc zshift 	; zshift is one less because carry always set
	tax
	lda #$FF
	sta zshift
	lda zalphabet-6,x
	beq .escape
	jmp print_char
.print_shift_1
	lda #(26-1)
	+skip_imm
.print_shift_2
	lda #(52-1)
	sta zshift
.print_shift_ret
	rts
.abbrev
	sbc #1		; carry always set
	asl
	asl
	asl
	asl
	asl
	sta abbrev	; 0/32/64
	rts
.print_abbrev
	clc
	adc abbrev
	asl
	tax
abbrev_load
	lda $1234,x
	sta obj_ptr_alt+1
	inx
abbrev_load2
	lda $1234,x
	sta obj_ptr_alt
	; abbreviations are word addresses
	asl obj_ptr_alt
	rol obj_ptr_alt+1
	lda obj_ptr_alt+1
	adc #>HEADER
	sta obj_ptr_alt+1
	+z_print_string obj_ptr_alt
	lda #$ff
	sta zshift	; abbreviation might have had padding character
	rts
.escape
	sta accum_char
	rts

	; loads must be in contiguous dynamic+static memory
	; stores must be in contiguous dynamic memory
z_loadb
	clc
	lda operands_lo+0
	adc operands_lo+1
	sta load_addr+1
	lda operands_hi+0
	adc operands_hi+1
	adc #>HEADER
	sta load_addr+2
	+begin_dynamic
load_addr
	ldx $1234
	+end_dynamic
	lda #0
	jmp store_common

z_storeb
	clc
	lda operands_lo+0
	adc operands_lo+1
	sta store_addr+1
	lda operands_hi+0
	adc operands_hi+1
	adc #>HEADER
	sta store_addr+2
	lda operands_lo+2
	+begin_dynamic
store_addr
	sta $1234
	+end_dynamic
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
	+begin_dynamic
	; TODO: if this crosses a 4k boundary we need multiple calls
	ldy #1
	lda (obj_ptr),Y
	tax
	dey
	lda (obj_ptr),y
	+end_dynamic
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
	+begin_dynamic
	ldy #1
	lda operands_lo+2
	sta (obj_ptr),Y
	dey
	lda operands_hi+2
	sta (obj_ptr),Y
	+end_dynamic
	jmp next_insn

operands_to_text_ptr
	lda operands_lo+0
	sta text_ptr
	lda operands_hi+0
	clc
	adc #>HEADER
	sta text_ptr+1
	rts

z_sread
	jsr operands_to_text_ptr
!if ZVERSION=3 {
	; this destroys operands+0
	jsr show_status
}
	+begin_dynamic
	jsr read_line
	+end_dynamic
	jmp tokenise

z_tokenise
	jsr operands_to_text_ptr
tokenise
	+begin_dynamic
	lda operands_lo+1
	sta parse_ptr
	lda operands_hi+1
	clc
	adc #>HEADER
	sta parse_ptr+1
!ifdef Z5PLUS {
	ldy #2
} else {
	ldy #1
}
	sty text_offset
	lda #0
	ldy #1
	sta (parse_ptr),Y	; number of words parsed
	ldy #4
	sty parse_offset
	ldx #0

	; byte zero is the maximum number of words we can parse
	; the actual number of words is stored in byte one
	; for each word parsed, four bytes are written:
	; bytes 0 and 1 are the big-endian address of the word in the dictionary,
	; or zero if the word was not found. byte 2 is the length of the word,
	; and byte 3 is the offset in text_buffer of the word
	
	; dictionary header
	; +0 - number of separators (typically 3)
	; +1/2/3 separator characters (space shouldn't be here)
	; +n size of each entry (at least 4 in V3, at least 6 otherwise)
	; +n+1/2 number of dictionary words
	; the dictionary words themselves follow

.next_word
!ifdef DEBUG_TOKENISE {
	jsr debug_print
	!text "text_offset = ",0
	lda text_offset
	jsr print_hex_byte
	jsr debug_print
	!text ", parse_offset = ",0
	lda parse_offset
	jsr print_hex_byte
	lda #13
	jsr print_char
}
	; skip all spaces and stop at EOL (zero)
	ldy text_offset
	lda (text_ptr),Y
	bne +
!ifdef DEBUG_TOKENISE {
	jsr debug_print
	!text "max parsed=",0
	lda (parse_ptr)
	jsr print_hex_byte
	jsr debug_print
	!text ", actual parsed=",0
	ldy #1
	lda (parse_ptr),y
	jsr print_hex_byte
	lda #$d
	jsr print_char
	ldy #2
.print_parsed_data
	lda (parse_ptr),Y
	jsr print_hex_byte
	iny
	lda (parse_ptr),Y
	jsr print_hex_byte
	jsr debug_print
	!text ": length ",0
	iny
	lda (parse_ptr),Y
	jsr print_hex_byte
	jsr debug_print
	!text ", starting at ",0
	iny
	lda (parse_ptr),Y
	jsr print_hex_byte
	lda #$d
	jsr print_char
	iny
	cpy parse_offset
	bcc .print_parsed_data
}
	+end_dynamic
	jmp next_insn
+	cmp #32
	bne .new_word
	inc text_offset
	jmp .next_word	; always taken
.new_word
	ldy parse_offset
	lda text_offset
	iny
	sta (parse_ptr),Y	; starting offset of word
	lda #0
	dey
	sta (parse_ptr),y	; length of word
	; if the current start of word is a separator, it's an entire word.
	ldy text_offset
	lda (text_ptr),Y
	jsr is_separator
	bne .not_separator
	tay
	lda zencode-32,Y
	bpl +
	pha
	+lsr5
	sta encode_buffer,X
	inx
	pla
	and #$1F
+	sta encode_buffer,X
	inx
	ldy parse_offset
	lda #1
	sta (parse_ptr),y	; length of word
	inc text_offset
	bne .end_word ; always taken
.next_letter
	ldy text_offset
	lda (text_ptr),Y
	beq .end_word
	cmp #32
	beq .end_word
	jsr is_separator
	beq .end_word
.not_separator
	cpx #DICT_WORD_LEN
	beq .skip_store
	tay
	lda zencode-32,y
	bpl .unshifted
	pha
	+lsr5
	sta encode_buffer,X
	inx
	pla
	and #$1F
	cpx #DICT_WORD_LEN
	beq .skip_store
.unshifted
	sta encode_buffer,X
	inx
.skip_store
	inc text_offset
	ldy parse_offset
	lda (parse_ptr),Y	; length of word
	+inca
	sta (parse_ptr),y
	bne .next_letter	; always taken
.end_word
	; fill dict word with padding
-	cpx #DICT_WORD_LEN
	beq +
	lda #5
	sta encode_buffer,x
	inx
	bne -	; always taken
	; now encode it (either 4 or 6 bytes)
+
	ldx #0
	ldy #0
	jsr encode_three
!if ZVERSION>3 {
	jsr encode_three
}
	lda encode_buffer,x
	jsr encode_three_final
!ifdef DEBUG_TOKENISE {
	jsr debug_print
	!text "encoded word [",0
	lda encode_buffer+0
	jsr print_hex_byte
	lda encode_buffer+1
	jsr print_hex_byte
	lda encode_buffer+2
	jsr print_hex_byte
	lda encode_buffer+3
	jsr print_hex_byte
	jsr debug_print
	!text "]",13,0
}
	; now encode_buffer+0/1/2/3 (+4/5 in V4+) contains encoded word
	lda #0
	sta low_index
	sta low_index+1
	sta char_index
	ldy #6
	lda (dict_ptr),Y
	sec
	sbc #1
	sta high_index
	dey
	lda (dict_ptr),Y
	sbc #0
	sta high_index+1

	; returns entry_ptr pointing at matching word or 0:0 if no match
bsearch
!ifdef DEBUG_TOKENISE_VERBOSE {
	jsr debug_print
	!text "low_index = ",0
	lda low_index
	jsr print_hex_byte
	jsr debug_print
	!text ", high_index = ",0
	lda high_index
	jsr print_hex_byte
	lda #13
	jsr print_char
}
	; while (low_index <= high_index)
	lda low_index + 1
	cmp high_index + 1
	beq +
	bcs .search_failed
+	lda low_index
	cmp high_index
	beq +
	bcs .search_failed
	; mid_index = (low_index + high_index)>>1
+	lda low_index
	clc
	adc high_index
	sta operands_lo+0
	lda low_index+1
	adc high_index+1
	lsr
	sta	operands_hi+0
	ror operands_lo+0
	lda #0
	sta operands_hi+1
	sta char_index
	lda entry_size
	sta operands_lo+1
	jsr .z_mul_16x16u
	; operands_lo+2 contains offset
	clc
	lda entry_ptr
	adc operands_lo+2
	sta obj_ptr
	lda entry_ptr+1
	adc operands_hi+2
	sta obj_ptr+1
	; encode_buffer contains string to test againsg
	; obj_ptr contains entry to compare
.compare_char
	ldy char_index
	lda encode_buffer,Y
	cmp (obj_ptr),Y
	bcs +
	; high = mid-1
	lda operands_lo+0
	sec
	sbc #1
	sta high_index+0
	lda operands_hi+0
	sbc #0
	sta high_index+1
	bmi .search_failed	; top of loop does unsigned comparison so catch negative here and exit
	jmp bsearch
+	bne +
	inc char_index
	iny
	cpy #DICT_SIZE
	bne .compare_char

	; search succeeded
	lda obj_ptr
	ldy parse_offset
	dey
	sta (parse_ptr),Y
	lda obj_ptr+1
	sec
	sbc #>HEADER
	jmp .word_done
	; low = mid+1
+	lda operands_lo+0
	clc
	adc #1
	sta low_index+0
	lda operands_hi+0
	adc #0
	sta low_index+1
	jmp bsearch
.search_failed
	lda #0
	ldy parse_offset
	dey
	sta (parse_ptr),Y
.word_done
	dey
	sta (parse_ptr),Y
	; update parse_offset to next word
	lda parse_offset	
	clc
	adc #4
	sta parse_offset
	; increment number of words parsed
	ldy #1
	lda (parse_ptr),Y
	+inca ; TODO: carry probably always clear here?
	sta (parse_ptr),Y
	jmp .next_word

	; is the character in A a separator character (Z flag set if so)
	; A is preserved, Y is destroyed
is_separator
	pha
!ifdef TARGET_65C02 {
	lda (dict_ptr)
} else {
	ldy #0
	lda (dict_ptr),Y
}
	tay
	pla
-	cmp (dict_ptr),y
	beq +
	dey
	bne -
	dey				; force nonzero
+	rts

	; x points at unshifted input (3 bytes per call), y points at shifted output (2 bytes per call)
encode_three
	lda encode_buffer,X
	+skip_imm
encode_three_final
	ora #$20
	asl
	asl
	sta encode_buffer,Y
	inx
	lda encode_buffer,x
	lsr
	lsr
	lsr
	ora encode_buffer,Y
	sta encode_buffer,Y
	iny
	lda encode_buffer,X
	asl
	asl
	asl
	asl
	asl
	inx
	ora encode_buffer,x
	inx
	sta encode_buffer,Y
	iny
	rts

z_inc
	lda operands_lo+0
	beq .inc_tos
!ifndef FRAME_USES_GLOBALS {
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
}
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
	lda operands_lo+0
	beq .dec_tos
!ifndef FRAME_USES_GLOBALS {
	cmp #$10
	bcs .dec_global
	; carry is clear here
	adc frameptr
	tax
	dec stack_lo,X
	lda #$ff
	cmp stack_lo,X
	bne +
	dec stack_hi,X
+	jmp next_insn
.dec_global
}
	tax
	dec globals_lo,x
	lda #$ff
	cmp globals_lo,X
	bne +
	dec globals_hi,x
+	jmp next_insn
.dec_tos
	ldx stackptr
	dec stack_lo-1,X
	lda stack_lo-1,X
	cmp #$FF
	bne +
	dec stack_hi-1,X
+	jmp next_insn

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
	lda #$FF
	sta zshift
	sta abbrev
	sta accum_char
	+zeroy
-	+next_insn_byte_y0
	cmp #$80
	php			; remember if negative
	sta zchar_hi
	and #$7C
	lsr
	lsr
	jsr printz
	lda zchar_hi
	and #$3
	sta zchar_hi
	+next_insn_byte_y0
	sta zchar_lo
	asl
	rol zchar_hi
	asl
	rol zchar_hi
	asl
	rol zchar_hi
	lda zchar_hi
	jsr printz
	lda zchar_lo
	and #$1F
	jsr printz
	plp
	bcc -
	rts


	; all call instructions route through here, x=1..7
	; the current frame's locals are kept in globals array to simplify decode logic
	; this means that when making a call, we need to copy as many variables as the
	; caller uses onto the stack before resetting them for the caller. likewise, on
	; return we need to copy the caller's variables back from the stack to the
	; current frame. this increases the cost of call_vs / ret slightly in favor
	; of improving the access speed of any local or global variable.
	; since all calls are variable typed (for now, not on V5) the arg count is in xsave
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
+	+zeroy
	+next_insn_byte_y0		; get storage location
	sta mulTemp				; set it aside for now

!ifdef DEBUG_TRACE {
	jsr debug_print
	!text "call_vs sp is ",0
	lda stackptr
	jsr print_hex_byte
	lda #$d
	jsr print_char
}
	ldx stackptr
	lda zpc_mid
	sta stack_hi,x
	lda zptr
	sta stack_lo,x

	inx
	lda zpc_hi 
	sta stack_lo,x
	lda frameptr
	sta stack_hi,x

	; location to store result
	inx
	lda mulTemp
	sta stack_lo,x

	stx frameptr
	inx

	+get_mem_addr_packed zpc_hi,zpc_mid,zptr
	+zeroy
	+next_insn_byte_y0
	; get local count in A
	sta mulTemp
!if ZVERSION>3 {
	; zero out the locals
} else {
	; copy local values
	cmp #$0
	beq +
-	+next_insn_byte_y0	; local high byte
	sta stack_hi,x
	+next_insn_byte_y0	; local low byte
	sta stack_lo,x
	inx
	dec mulTemp
	bne -
+	stx stackptr
}
	; now copy incoming parameters over previous locals
	dec operand_count
	beq +
	ldx #1
	ldy frameptr
.copyparam
	iny
	lda operands_lo,x
	sta stack_lo,Y
	lda operands_hi,X
	sta stack_hi,Y
	inx
	dec operand_count
	bne .copyparam
	iny
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
	jsr debug_print
	!text "* End session *",13,0
	jmp *

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

	; operand+0 contains object number; return obj_mid, obj_ptr pointing at object
get_object_addr
	; compute objIndex * 9
	lda operands_lo+0
	bne +
	jsr fatal_error
	!text "get_object_addr 0 called",13,0
+	sta obj_ptr+0
	lda operands_hi+0
	sta obj_ptr+1

	; objIndex * 8
	asl obj_ptr+0
	rol obj_ptr+1
	asl obj_ptr+0
	rol obj_ptr+1
	asl obj_ptr+0
	rol obj_ptr+1

	; finish objIndex * 9 computation (carry is always clear)
	lda obj_ptr+0
	adc operands_lo+0
	sta obj_ptr+0
	lda obj_ptr+1
	adc operands_hi+0
	sta obj_ptr+1

	; convert to final memory address
	lda obj_ptr+0
	adc obj_base
	sta obj_ptr+0

	lda obj_ptr+1
	adc obj_base+1
	sta obj_ptr+1
	sec
	sbc #>HEADER
	sta obj_mid
	rts

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
	ora #$30
	jsr print_char
.noprint
}

z_print_num
	jsr print_num 
	jmp next_insn

print_num
	lda #0
	sta mulTemp
	cmp operands_hi+0
	beq ++
	bpl +
	lda #'-'
	jsr print_char
	sec
	lda #0
	sbc operands_lo+0
	sta operands_lo+0
	lda #0
	sbc operands_hi+0
	sta operands_hi+0
+	+process_digit 10000
	+process_digit 1000
++	+process_digit 100	
;	+process_digit 10
;	lda operands_lo+0
;	ora #$30
;	jmp print_char
	ldy operands_lo+0
	lda dec2hex,Y
	cmp #10
	bcs print_hex_byte
	ldy mulTemp
	beq print_hex_digit
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
	ora #$30
	cmp #$3A
	bcc +
	adc #$6	; carry is always set
+	jmp print_char

z_new_line
	lda #13
	+skip_imm
z_print_char
	lda operands_lo+0
	jsr print_char
	jmp next_insn

z_show_status
	jsr show_status
	jmp next_insn

show_status
	lda #<print_char_upper
	sta print_char+1
	lda #>print_char_upper
	sta print_char+2
	lda #0
	sta top_cursor_x

	lda globals_lo+16
!if ZVERSION=3 {
	cmp last_status_room
	beq .numbers_only
}
	sta last_status_room
	lda globals_lo+16
	sta operands_lo+0
	lda globals_hi+16
	sta operands_hi+0
	jsr print_obj
	lda top_cursor_x
	pha
	sec
	sbc prev_top_cursor_x
	bcs .longer_or_same
	sta prev_top_cursor_x
-	lda #32
	jsr print_char_upper
	inc prev_top_cursor_x
	bne -
.longer_or_same
	pla
	sta prev_top_cursor_x

.numbers_only
	lda #(COLUMNS-7)
	sta top_cursor_x

	; global 1 is score
	lda globals_lo+17
	sta operands_lo+0
	lda globals_hi+17
	sta operands_hi+0
	jsr print_num
	lda #'/'
	jsr print_char
	lda globals_lo+18
	sta operands_lo+0
	lda globals_hi+18
	sta operands_hi+0
	jsr print_num

-	lda top_cursor_x
	cmp #(COLUMNS)
	bcs default_print_char
	lda #32
	jsr print_char_upper
	jmp -

flush_main_window
	sty flush_restore_y+1
	ldy #0
-	cpy chars_stored
	beq +	
	lda char_buffer,Y
	jsr print_char_lower
	iny
	bne -
+	lda #0
	sta chars_stored
flush_restore_y
	ldy #$12
	rts

buffered_print_char
	cmp #$0D
	beq .break
	cmp #$20
	beq .break
	sty ysave
	ldy chars_stored
	sta char_buffer,Y
	inc chars_stored
	ldy ysave
	rts
.break
	pha
	lda cursor_x
	clc
	adc chars_stored
	cmp #(COLUMNS-1)
	bcc .fits
	lda #$0D
	jsr print_char_lower
.fits
	jsr flush_main_window
	pla
	jmp print_char_lower

default_print_char
	lda #<buffered_print_char
	sta print_char+1
	lda #>buffered_print_char
	sta print_char+2
	rts	
	
	; divide operands+0 by operands+1, quotient in operands+0, remainder in operands+2
divide
	lda #0
	sta operands_lo+2	; rem
	sta operands_hi+2	; rem+1
	ldx #16
-	asl operands_lo+0	; num1
	rol operands_hi+0	; num1+1
	rol operands_lo+2	; rem
	rol operands_hi+2	; rem+1
	lda operands_lo+2	; rem
	sec
	sbc operands_lo+1	; num2
	tay
	lda operands_hi+2	; rem+1
	sbc operands_hi+1	; num2+1
	bcc +
	sta operands_hi+2	; rem+1
	sty operands_lo+2	; rem
	inc operands_lo+0	; num1	
+	dex
	bne -
	rts

z_store
	lda operands_hi+1
	sta store_hi
	ldx operands_lo+1
	lda operands_lo+0
	jsr store_result_2
	jmp next_insn

store_common
	jsr store_result
	jmp next_insn

	; incoming: x is low byte, a is high byte of result to store
store_result
	sta store_hi
	+zeroy
	+next_insn_byte_y0
store_result_2
	cmp #$00
	beq .store_tos
!ifndef FRAME_USES_GLOBALS {
	cmp #$10
	bcs .store_global
	; store local
	adc frameptr
	tay
	lda store_hi
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
}
	tay
	lda store_hi
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
	lda store_hi
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
	!text " to TOS",0
}
	rts
+ 	jsr fatal_error
	!text "stack overflow",13,0

fatal_error
	lda zpc_hi
	jsr print_hex_byte
	lda zpc_mid
	jsr print_hex_byte
	lda zptr
	jsr print_hex_byte
	lda #':'
	jsr print_char
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

;!ifdef DEBUG_TRACE {
	; destroys A
debug_print
	pla
	sta stringptr
	pla
	sta stringptr+1
	sty .debug_print_restore+1
	ldy #1
-	lda (stringptr),y
	beq +
	jsr print_char
	iny
	bne -
+	tya
	clc
	adc stringptr
	sta stringptr
	bcc +
	inc stringptr+1
+	lda stringptr+1
	pha
	lda stringptr
	pha
.debug_print_restore
	ldy #$12
	rts
;}

	!align 255, 512 - 100 - (26*3) - 96
dec2hex 
	!byte $00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24
	!byte $25,$26,$27,$28,$29,$30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$40,$41,$42,$43,$44,$45,$46,$47,$48,$49
	!byte $50,$51,$52,$53,$54,$55,$56,$57,$58,$59,$60,$61,$62,$63,$64,$65,$66,$67,$68,$69,$70,$71,$72,$73,$74
	!byte $75,$76,$77,$78,$79,$80,$81,$82,$83,$84,$85,$86,$87,$88,$89,$90,$91,$92,$93,$94,$95,$96,$97,$98,$99

	; maps ascii to encoded zscii (+(4<<5) or (5<<5) if it needs a shift first). if 255, needs four-byte encoding 5,6,N>>5,N.
zencode
	;  !"#$%&'()*+,-./0123456789:;<=>?
    ; @ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_
    ; 'abcdefghijklmnopqrstuvwxyz{!}~ 
	!byte 0
	!fill 95,255

	; on V5 the version in the story is copied over this
	; the first two entries in the last row are never replaced. The first is always a newline,
	; and the second is reserved for "character not in table" and must always be zero.
zalphabet
	!text "abcdefghijklmnopqrstuvwxyz"
	!text "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	!text 0,13,"0123456789.,!?_#'",34,"/",92,"-:()"
	; 0=8, .=18, ,=19, !=20, ?=21, _=22, #=23, '=24, "=25, /=26, \=27, -=28, :=29 (=30, )=31

	!align 255, 0
dispatch +table16 _2op_s_s,_2op_s_s,_2op_s_v,_2op_s_v,_2op_v_s,_2op_v_s,_2op_v_v,_2op_v_v,_1op_large,_1op_small,_1op_variable,_0op,_2op_var,_2op_var,_vop,_vop

_2opTbl +table32 z_ill,z_je,z_jl,z_jg,z_dec_chk,z_inc_chk,z_jin,z_test,z_or,z_and,z_test_attr,z_set_attr,z_clear_attr,z_store,z_insert_obj,z_loadw,z_loadb,z_get_prop,z_get_prop_addr,z_get_next_prop,z_add,z_sub,z_mul,z_div,z_mod,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill

_1opTbl +table16 z_jz,z_get_sibling,z_get_child,z_get_parent,z_get_prop_len,z_inc,z_dec,z_print_addr,z_ill,z_remove_obj,z_print_obj,z_ret,z_jump,z_print_paddr,z_load,z_not

_0opTbl +table16 z_rtrue,z_rfalse,z_print,z_print_ret,next_insn,z_save,z_restore,z_restart,z_ret_popped,z_pop,z_quit,z_new_line,z_show_status,z_ill,z_ill,z_ill

_varTbl +table32 z_call_vs,z_storew,z_storeb,z_put_prop,z_sread,z_print_char,z_print_num,z_random,z_push,z_pull,z_split_window,z_set_window,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_output_stream,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill

char_buffer !fill 32

	; resist temptation to move these to $800 because that's banked RAM on apple 2e.
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
