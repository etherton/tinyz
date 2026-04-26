
DEBUG_TRACE = 0
DEBUG_PROP_COMMON = 0
DEBUG_TOKENISE = 0
DEBUG_TOKENISE_VERBOSE = 0
DEBUG_VM = 0

!macro bp {
	bit $c00e
}

!macro skip_1b {
	!byte $24 ; bit ZP causes next byte to be skipped
}

!macro skip_2b {
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
RAMWRT		= $C014

PAGE1		= $C054
PAGE2		= $C055

!if MEM_MODEL=0 {
!macro save_ram_state {
}
!macro restore_ram_state {
}
!macro begin_dynamic {
}
!macro end_dynamic {
}
} else {
; begin dynamic memory reference; remember if we were using alt memory, then switch to main
; modifies N/Z/V flags
!macro save_ram_state {
	bit RAMRD
	php
}
!macro restore_ram_state {
	plp
	bpl +
	sta RAMRDON
	;sta RAMWRTON
+
}

!macro begin_dynamic {
	+save_ram_state
	sta RAMRDOFF
	;sta RAMWRTOFF
}
; remember old setting and if it was active, re-enable it. destroys flags.
!macro end_dynamic {
	+restore_ram_state
}
}


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
unit_number = $2E

!if LOAD_FROM_DISK_II {
data_page = $30
track = $31
trackbit = $32
sector = $33
tracks_remaining = $34
sector_map_lo = $35
sector_map_hi = $36
} else {
blocks_remaining = $34
}
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

char_buffer = $100

LOAD_ADDR = $D000

	*=LOAD_ADDR		; actually loads at $800 hence the magic numbers in .copy below

!if LOAD_FROM_DISK_II {
	!byte 3		; this is the sector to stop loading at (rest of our code and lookup tables)

	sta BANKA_RAMRD_WE	; +1
	sta BANKA_RAMRD_WE	; +4

	; We load the first 4k track at $800, and immediately relocate everything to LOAD_ADDR
	; y is zero
.copy
	lda $800,Y			; +7 (9)
	sta LOAD_ADDR,Y		; +10 (12)
	iny
	bne .copy
	inc $809
	inc $80C
	dec $800
	bne .copy
	jmp stage1

} else {
	!byte 1		; this has to be 1 for whatever reason

	sta BANKA_RAMRD_WE	; +1
	sta BANKA_RAMRD_WE	; +4
	sta unit_number		; +7
	stx slot_index		; +9
	ldx #4				; +11

	; We load the first 4k track at $800, and immediately relocate everything to LOAD_ADDR
	; y is zero
.copy
	lda $800,Y			; +13 (15)
	sta LOAD_ADDR,Y		; +16 (18)
	iny
	bne .copy
	inc $80F
	inc $812
	dex
	bne .copy
	jmp stage1
}

!if LOAD_FROM_DISK_II {

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
	lda #>LOAD_ADDR
	sta data_page
	lda #$F8				; already read first three sectors
	sta sector_map_lo

	jsr read_rest_track_1

	; read rest of interpreter
	jsr read_next_track
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

} else {		; !LOAD_FROM_DISK_II

stage1
	lda slot_index
	lsr
	lsr
	lsr
	lsr
	ora temp+2
	sta temp+2
	sta smart_port_jsr+2
temp
	ldx $C0FF
	inx
	inx
	inx
	stx smart_port_jsr+1
	lda unit_number
	sta read_params+1

-	jsr do_read
	inc read_block
	inc read_dest+1
	inc read_dest+1
	bne -			; keep going until we wrap

	lda #>HEADER
	sta read_dest+1
	jsr do_read

	; round story size (which is half its actual value) up to next 512b multiple
	; for V3 it's (size + $ff) >> 8
	; for V4/5 it's (size + $7f) >> 7
	; for V8 it's (size + $3f) >> 6
	lda HEADER+27
	clc
!if ZVERSION=8 {
	adc #$3F
	ldx #6
} else if (ZVERSION>3) {
	adc #$7F
	ldx #7
} else {
	adc #$FF
	ldx #8
}
	sta blocks_remaining
	lda HEADER+26
	adc #0
	sta blocks_remaining+1

-	lsr blocks_remaining+1
	ror blocks_remaining
	dex
	bne -

	; story size in 512b blocks (including the one we already read)
	; for higher memory models, we fill aux memory too so vm is "full"
	; note $B0 here is 88k (512b blocks)
!if MEM_MODEL > 1 {
	lda blocks_remaining+1
	bne clamp_story_size
	lda blocks_remaining
	cmp #$B0
	bcc +
clamp_story_size
	lda #$B0
	sta blocks_remaining
+
} 

read_story
	dec blocks_remaining	
	beq ++
	inc read_dest+1
	inc read_dest+1
	lda read_dest+1
	; for memory model 1, which supports stories up to 88k, we fill banked memory too.
!if MEM_MODEL > 0 {
	cmp #$C0
	bne +
	; switch to aux memory
	lda #>HEADER
	sta read_dest+1
	sta RAMRDON
	sta RAMWRTON
+	
}
	inc read_block
	bne +
	inc read_block+1
+	jsr do_read
	jmp read_story
++	jmp endboot

do_read
	lda #$5D
	sta $400+39
smart_port_jsr
	jsr $C000		; patched to hold SmartPort handler
	!byte 1			; READ
	!word read_params	; pointer to parameter buffered_print_char
	lda #$20
	sta $400+39
	rts
read_params
	!byte 3			; parameter count
	!byte 1			; device index
read_dest
	!word $D400		; destination address (start past what is already loaded by bootstrap)
read_block
	!word $0002		; block number to read (start past what is already loaded by bootstrap)
	!byte $00

}

endboot ; 0x?300
	; these are part of boot code but we're tight on space there.
+	sta RAMWRTOFF
	sta RAMRDOFF


!if COLUMNS=80 {
	sta _80COLON
	sta _80STOREON	; make sure this is on if story is small
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

debug_print_char
	sta $c0ff
	rts

	; destroys A
print_char_lower
	sta $c0ff
	+save_ram_state
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
	+restore_ram_state
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
	; on V3, first byte is maximum length, and input is 0-terminated
	; on V5+, first byte is maximum length, and second byte is previous input count, and first byte is actual stored
read_line
!ifdef TARGET_65C02 {
	lda (text_ptr)
} else {
	ldy #0
	lda (text_ptr),Y
}
	sta .max_length+1
!if ZVERSION>=5 {
	; skip any previous input (which game should have displayed)
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
	cpy #99			; this is overwritten above
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
	+begin_dynamic
	sta (text_ptr),y
	+end_dynamic
	jmp .update_cursor
.backsp
!if ZVERSION>=5 {
	cpy #1
} else {
	cpy #0
}
	beq .next_char
	dec cursor_x
	dey
	jmp .update_cursor
.return
	lda #$20
	jsr print_char
	lda #$0D
	jsr print_char

	+begin_dynamic
!if ZVERSION>=5 {
	dey
	tya
	ldy #1
	sta (text_ptr),Y
	tay
	iny
}
	lda #0
	iny
	sta (text_ptr),y
	+end_dynamic
	rts

; Portable code ZP use starts at $40
zpc_mid_low = $43
call_storage = $44
mulSign = $45
mulTemp = $46
attr_bit = $47
ztype2 = $47
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
obj_base = $6E		; 9/14 bytes before first object slot
obj_prev_offset = $70
window_current = $71
output_table = $72
output_enables = $73
shift = $74			; if nonzero, shifts next character
abbrev = $75		; 0 if not halfway through abbreviation, else 32/64/96
extended = $76
stackptr = $78		; one past top of stack
frameptr = $79		; one before first local (since locals are one-based)
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
desired_page = $90
oldest_page_index = $92
oldest_page_value = $94
!if MEM_MODEL>1 {
vm_ptr = $96
}

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


; We support four memory models
; MEM_MODEL=0: Stories are limited to 44k total. No banking.
; MEM_MODEL=1: Stories are limited to 88k total, dynamic+static limited to 44k.
; MEM_MODEL=2: Stories are limited to 128k total, dynamic+static limited to 44k. All alt ram is VM backed by disk.
; MEM_MODEL=3: Stories have normal Z5/Z8 liimits. Dynamic limited to 44k. Static and high backed by disk.
; The difference between 2 and 3 is that in model 3, static memory can be paged, which affects loadb, loadw,
; and tokenisation.
; For any memory model past 1, we implement virtual memory. All virtual memory is kept in the aux 44k memory.
; We adopt a page size to limit the size of our data structures. This is particularly important for static memory,
; which is often accessed consecutively. For V3, the page size is 512 bytes. V5 is 1024, and V8 is 2048.
; One table maps a (Z address >> 9) (for V3) to which page in aux memory ($10-$BE), or $00 if it's not resident.
; For V3 stories, max size is 128k, of which 44k is permanent, so 84k is paged at 512 bytes each, or 168 slots.
; On the other side, each of those 88 possible pages needs to maintain an age so that old pages can be evicted.
; By happy coincidence, 168+88 is exactly 256, so it fits up against our other "large" data structures.
; For V5, 256k-44k is 212k, with 1k pages, or 212 slots, and 44 pages of aux memory.
; For V8, 256-44k is 468k, with 2k pages, or 234 slots, and 22 pages of aux memory. They all add up to 256.
; It works because the amount of banked memory happens to exactly match the amount of the story that is
; kept permanently resident.
; If the page is already resident, reset its age to 0. Done.
; If the page is not already resident, find an oldest page to replace, reset its age to 1, and then age all OTHER pages by 1

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
!if MEM_MODEL > 0 {
	jsr increment_zpc_mid
} else {
	inc zpc_mid
	inc zptr+1
}
+
}

!macro zeroy {
}

!macro next_insn_byte_y0 {
	lda (zptr)
	inc zptr
	bne +
!if MEM_MODEL > 0 {
	jsr increment_zpc_mid
} else {
	inc zpc_mid
	inc zptr+1
}
+
}

} else {

!macro skip_insn_byte {
	inc zptr
	bne +
!if MEM_MODEL > 0 {
	jsr increment_zpc_mid
} else {
	inc zpc_mid
	inc zptr+1
}
+
}

!macro zeroy {
	ldy #0
}

!macro next_insn_byte_y0 {
	lda (zptr),y
	inc zptr
	bne +
!if MEM_MODEL > 0 {
	jsr increment_zpc_mid
} else {
	inc zpc_mid
	inc zptr+1
}
+
}
}

!if MEM_MODEL=0 {

update_zptr
	lda zpc_mid
	clc
	adc #>HEADER	; carry clear
	sta zptr+1
	rts

} else if MEM_MODEL > 0 {

	; preserves A/X/Y
	; if high byte of zptr is $C0, we need to update the TLB
increment_zpc_mid
	inc zpc_mid
	bne +
	inc zpc_hi

!if MEM_MODEL = 1 {
+	inc zptr+1
	pha
	lda zptr+1
	cmp #$C0
	bne +
	jsr update_zptr
+	pla
} else {
+	pha
	jsr update_zptr
	pla
}
	rts

	; destroys A; uses current values of zpc_hi/zpc_mid
	; to enable correct ram page and set zptr+1 pointing at it
!if MEM_MODEL=1 {
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
	rts
	; 100->60, 110->70, 120->80 etc 
.update_zptr_hi
	clc
	lda zpc_mid
	adc #$60
	sta zptr+1
	sta RAMRDON
	rts
} else if MEM_MODEL>=2 {

; idea - include a one-element TLB to handle the case of a loop
; spanning page boundary
update_zptr
	; convert zpc_mid/hi to an eight-bit page (Z3)
	lda zpc_hi
	bne update_vmem_hi
	sta zpc_mid_low ; zero zpc_mid_low
	lda zpc_mid
	lsr				; get even/odd block
	rol zpc_mid_low ; put carry bit (even/odd page) in LSB
	sec
	sbc #88				; now value beteen 0-167
	bcs update_vmem		; in virtual memory?
	sta RAMRDOFF		; nope, it's in dynamic (resident) memory.
	lda zpc_mid
	adc #>HEADER		; carry already clear
	sta zptr+1
	rts
update_vmem_hi
!if DEBUG_VM {
	jsr debug_print
	!text "zpc=",0
	jsr print_hex_byte
	pha
	lda zpc_mid
	jsr print_hex_byte
	jsr space
	pla
}
	;sta $c0fe ;; enable trace
	; desired_page is between 0-2047
	lsr
	sta desired_page+1
	lda zpc_mid
	ror
	sta desired_page
	lda #0
	adc #0
	sta zpc_mid_low		; pull out carry for even/odd
	lda desired_page
	sec
	sbc #88
	sta desired_page
	lda desired_page+1
	sbc #0
	sta desired_page+1
!if DEBUG_VM {
	jsr debug_print
	!text "vm hi ",0
	pha
	jsr print_hex_byte
	lda desired_page
	jsr print_hex_byte
	pla
}
	clc				; todo: carry probably known here, could adjust adc and eliminate clc
	adc #>vm_map
	sta vm_ptr+1
	sty .y_recover+1
	;lda #0
	;sta $c0fe
	ldy desired_page
!if DEBUG_VM>1 {
	jsr space
	lda vm_ptr+1
	jsr print_hex_byte
	lda vm_ptr
	jsr print_hex_byte
	jsr space
	lda #>vm_map
	jsr print_hex_byte
	lda #<vm_map
	jsr print_hex_byte
	jsr space
}
	lda (vm_ptr),Y
	bne page_hit
	beq page_miss_2
update_vmem
	; desired page is in A, 0-167 (or more for Z4+)
	sty .y_recover+1
	tay
!if DEBUG_VM {
	jsr debug_print
	!text "vm lo ",0
	jsr print_hex_byte
}
	lda vm_map,Y
	beq page_miss
page_hit
	ora zpc_mid_low
	sta zptr+1
	lsr			; divide upper byte of address by two to get page index
	tay			; get page index (biased by HEADER)
!if DEBUG_VM {
	jsr debug_print
	!text " page hit ",0
	jsr print_hex_byte
	jsr space
	lda zpc_mid_low
	jsr print_hex_byte
	jsr newline
}
	lda #0
	sta page_ages-(>HEADER/2),y		; account for HEADER offset
	sta RAMRDON						; it's in virtual (aux) memory
.y_recover
	ldy #$12
	;lda #0
	;sta $c0fe
	rts
page_miss
	; y contains page (512b block, starting from 88 in story) we want to make resident
	sty desired_page
!if ZVERSION>3 {
	lda #>vm_map
	sta vm_ptr+1		; make sure this is still correct
}
page_miss_2
	sty RAMRDON
	sty RAMWRTON		; enable aux memory for both read and write so we can fill it (smartport needs checksums)

	; sty $c0fe ;; enable trace

	; find oldest page (and age all pages once)
	ldy #87
	lda page_ages,Y
	clc
	adc #1
	sta oldest_page_value
	sta page_ages,y
	sty oldest_page_index
-	dey
	bmi +
	lda page_ages,Y
	clc
	adc #1
	sta page_ages,y
	cmp oldest_page_value
	bcc -
	beq -
	sta oldest_page_value
	sty oldest_page_index
	bcs -

	; mark this page not resident
+	ldy oldest_page_index
!if DEBUG_VM {
	jsr debug_print
	!text " oldest ",0
	tya
	jsr print_hex_byte
	jsr space
}
!if ZVERSION=3 {
	lda page_owners_lo,Y		; this is index into vm_map that owns us
!if DEBUG_VM {
	jsr debug_print
	!text " owned by ",0
	jsr print_hex_byte
	jsr space
}
	tay
	lda #0
	sta vm_map,Y
} else {
!if DEBUG_VM {
	jsr debug_print
	!text " owned by ",0
	lda page_owners_hi,Y
	jsr print_hex_byte
	lda page_owners_lo,Y
	jsr print_hex_byte
}
	lda page_owners_hi,Y
	clc
	adc #>vm_map
	sta .vm_store+2
	lda page_owners_lo,Y
	tay
	lda #0
.vm_store
	sta vm_map,y
}

	; change owner of this vm page to new page, reset age to 1
	ldy oldest_page_index
	lda desired_page			; 0-167
	sta page_owners_lo,y		; that page owns this slot (0-87)
!if ZVERSION>3 {
	lda desired_page+1
	sta page_owners_hi,Y
}

	lda #1
	sta page_ages,y				; update the page age

	; remember where to find this page in the future
	tya
	asl							; double page index to get high byte of address
	adc #>HEADER				; account for header base address (carry always clear)
	ldy desired_page
!if ZVERSION>3 {
	sta (vm_ptr),Y				; this was set up above near end of update_vmem_hi
} else {
	sta vm_map,y
}
!if DEBUG_VM {
	jsr debug_print
	!text " store to page ",0
	jsr print_hex_byte
	jsr newline
}
	; set destination for read
	sta read_dest+1

	; update zptr+1 now, remembering whether original address was even or odd
	ora zpc_mid_low
	sta zptr+1

	; figure out block to read
	lda desired_page
	adc #(24+88)		; interpreter is 24 blocks, resident is 88 blocks (carry still clear)
	sta read_block
!if ZVERSION>3 {
	lda desired_page+1
} else {
	lda #0
}
	adc #0
	sta read_block+1
	stx .x_recover+1
	jsr do_read
.x_recover
	ldx #$12
	sta RAMWRTOFF
	jmp .y_recover
} 
}

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

	; get default property table minus 2 (since objects are 1-based)
	clc
	lda HEADER+11
	adc #$FE
	sta default_props_ptr

	lda HEADER+10
	adc #$FF
	clc
	adc #>HEADER
	sta default_props_ptr+1

	; now compute the 1-based pointer to the object array
	clc
	lda HEADER+11
!if ZVERSION>3 {
	adc #(126 - 14)
} else {
	adc #(62 - 9)		; skip defaults, and objects are 1-based
}
	sta obj_base

	lda HEADER+10
	adc #>HEADER
	sta obj_base+1		; carry clear after this

	lda HEADER+9
	sta dict_ptr
	lda HEADER+8
	adc #>HEADER
	sta dict_ptr+1
	ldy #0
	lda (dict_ptr),y	; get number of separators
	tay
	iny					; +1
	lda (dict_ptr),Y
	sta entry_size
	tya					; get number of separators + 1 back in
	clc
	adc #3 				; skip to first word (this will never carry)
	adc dict_ptr
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
!if ZVERSION>=5 {
	sta HEADER+$23
}
	lda #24
	sta HEADER+$20
!if ZVERSION>=5 {
	sta HEADER+$25
	lda #1
	sta HEADER+$26
	sta HEADER+$27
}

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

	; set apple2e interpreter
	lda #2
	sta HEADER+30
	lda #'Z'
	sta HEADER+31

!if MEM_MODEL>1 {
	lda #<vm_map
	sta vm_ptr
	; upper word is always rewritten
}

	; finish setting up initial pc - this needs to be last because it might set up aux memory
	jsr update_zptr
	jmp next_insn

; opcode
; (type byte) (type byte for call_vs2) (00=large, 01=small, 10=var, 11=omit)
; (operands)
; (store destination)
; (branch offset)
; (text to print)

!if DEBUG_TRACE {
; obj_ptr points at table, zinsn contains instruction, destroys A, X/Y is zero
print_opcode_data
	ldy #0
	lda (obj_ptr),Y			; get table size (also insn mask+3)
	sec
	sbc #3
	and zinsn
	tay
	iny
	iny
	lda (obj_ptr),y			; get offset of next string
	sec
	dey
	sbc (obj_ptr),Y
	tax						; x contains length
	lda (obj_ptr),Y			; get offset of this string again
	pha
	ldy #0
	lda (obj_ptr),Y
	clc
	adc obj_ptr
	sta obj_ptr
	bcc +
	inc obj_ptr+1
+	pla
	tay
-	lda (obj_ptr),Y
	jsr debug_print_char
	iny
	dex
	bne -
	jsr space
	ldy #0
	rts

!macro print_opcode tblName {
	ldy #<tblName
	sty obj_ptr
	ldy #>tblName
	sty obj_ptr+1
	jsr print_opcode_data
}
}

; if an instruction would cross a non-contiguous 4k boundary (rare), we copy the entire instruction into a temporary
; location and execute it from there. (eventually)
	; !align 255,0
next_insn
!ifdef BENCHMARK {
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
!if DEBUG_TRACE {
	jsr newline
	lda zpc_hi
	jsr print_hex_byte
	lda zpc_mid
	jsr print_hex_byte
	lda zptr
	jsr print_hex_byte
	jsr space
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
!if DEBUG_TRACE {
	+print_opcode _2opNames
}
	ldx #0
	jsr operand_small
	jsr operand_small
	bne ._2op_common ; always taken
_2op_s_v
!if DEBUG_TRACE {
	+print_opcode _2opNames
}
	ldx #0
	jsr operand_small
	jsr operand_variable
	bne ._2op_common ; always taken
_2op_v_s
!if DEBUG_TRACE {
	+print_opcode _2opNames
}
	ldx #0
	jsr operand_variable
	jsr operand_small
	bne ._2op_common ; always taken
_2op_v_v
!if DEBUG_TRACE {
	+print_opcode _2opNames
}
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
!if DEBUG_TRACE {
	+print_opcode _2opNames
}
	jsr decode_types
	jmp ._2op_common_2
_vop
!if DEBUG_TRACE {
	+print_opcode _varNames
}
!if ZVERSION>3 {
	lda zinsn
	cmp #$EC
	beq .extra_types
	cmp #$FA 
	bne .no_extra_types
.extra_types
	jsr decode_xtypes
	lda zinsn
	bne +
.no_extra_types
}
	jsr decode_types
	lda zinsn
+	and #$1F
	+dispatch32 _varTbl

_1op_large
!if DEBUG_TRACE {
	+print_opcode _1opNames
}
	ldx #0
	jsr operand_large

	bne ._1op_common ; always taken
_1op_small
!if DEBUG_TRACE {
	+print_opcode _1opNames
}
	ldx #0
	jsr operand_small
	bne ._1op_common ; always taken
_1op_variable
!if DEBUG_TRACE {
	+print_opcode _1opNames
}
	ldx #0
	jsr operand_variable
._1op_common
	lda zinsn
	and #$f
	+dispatch16 _1opTbl

_0op
!if DEBUG_TRACE {
	+print_opcode _0opNames
}
	lda zinsn
	and #$f
	+dispatch16 _0opTbl

!if >_2op_s_s != >_0op {
	!error "initial dispatches not on same page"
}

!if ZVERSION>3 {
decode_xtypes
	+next_insn_byte_y0
	sta ztype
	+next_insn_byte_y0
	sta ztype2
	ldx #0
	beq decode_type_byte
}
decode_types
!if ZVERSION>3 {
	ldx #$FF
	stx ztype2
	inx
} else {
	ldx #0
}
	+next_insn_byte_y0
	sta ztype
decode_type_byte
	bit ztype
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
	bne decode_type_byte			; always taken
.decode_done
	stx operand_count ; je and call_vs need arg count
!if ZVERSION>3 {
	lda ztype2
	cmp #$FF
	beq +
	sta ztype
	lda #$FF
	sta ztype2
	bne decode_type_byte ; always taken
+
}
	rts

	; all operand handlers inx before return and so the zero flag is always clear.
operand_large
	+next_insn_byte_y0
!if DEBUG_TRACE {
	jsr print_hex_byte
}
	+skip_2b
	; zero flag clear on return (x never zero)
operand_small
	lda #$0
	sta operands_hi,x
	+next_insn_byte_y0
	sta operands_lo,x
!if DEBUG_TRACE {
	jsr print_hex_byte
	jsr space
}
	inx
	rts

	; operand_variable destroys y so it needs to be reloaded from znext
	; if there are more types to decode
operand_variable	
	+next_insn_byte_y0
	cmp #$00
	beq .read_tos
!ifndef FRAME_USES_GLOBALS {
	cmp #$10
	bcs .read_global
	; read local
!if DEBUG_TRACE {
	pha
	lda #'L'
	jsr debug_print_char
	pla
	pha
	sec
	sbc #1
	jsr print_hex_byte
	lda #'='
	jsr debug_print_char
	pla
	clc
}
	adc frameptr
	tay
	lda stack_hi,Y
!if DEBUG_TRACE {
	jsr print_hex_byte
}
	sta operands_hi,x
	lda stack_lo,Y
!if DEBUG_TRACE {
	jsr print_hex_byte
	jsr space
}
	sta operands_lo,x
	+zeroy
	inx
	rts
.read_global
}
	tay
!if DEBUG_TRACE {
	lda #'G'
	jsr debug_print_char
	tya
	sec
	sbc #$10
	jsr print_hex_byte
	lda #'='
	jsr debug_print_char
}
	lda globals_hi,Y
!if DEBUG_TRACE {
	jsr print_hex_byte
}
	sta operands_hi,X
	lda globals_lo,Y
!if DEBUG_TRACE {
	jsr print_hex_byte
	jsr space
}
	sta operands_lo,x
	+zeroy
	inx
	rts

.read_tos
!if DEBUG_TRACE {
	jsr debug_print
	!text "--(sp)=",0
}
	dec stackptr
	ldy stackptr
	lda stack_hi,Y
!if DEBUG_TRACE {
	jsr print_hex_byte
}
	sta operands_hi,x
	lda stack_lo,Y
!if DEBUG_TRACE {
	jsr print_hex_byte
	jsr space
}
	sta operands_lo,X
	+zeroy
	inx
	rts

z_ill
	lda zinsn
	jsr print_hex_byte
	jsr space
	jsr fatal_error
	!text "unimplemented insn",13,0

; branch(var(operands[0].getS()).dec() < operands[1].getS()); break;
z_dec_chk
	lda operands_lo+0
	beq .dec_chk_tos
!ifndef FRAME_USES_GLOBALS {
	cmp #$10
	bcs .dec_chk_global
	; carry is clear here
	adc frameptr
	tax
	lda stack_lo,X
	sec
	sbc #1
	sta stack_lo,x
	sta operands_lo+0
	lda stack_hi,X
	sbc #0
	sta stack_hi,X
	sta operands_hi+0
	jmp z_jl
.dec_chk_global
}
	tax
	lda globals_lo,X
	sec
	sbc #1
	sta globals_lo,X
	sta operands_lo+0
	lda globals_hi,X
	sbc #0
	sta globals_hi,X
	sta operands_hi+0
	jmp z_jl
.dec_chk_tos
	ldx stackptr
	lda stack_lo-1,X
	sec
	sbc #1
	sta stack_lo-1,X
	sta operands_lo+0
	lda stack_hi-1,X
	sbc #0
	sta stack_hi-1,X
	sta operands_hi+0
	jmp z_jl

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

	; is operand+0's parent operand+1?
z_jin
	jsr get_object_addr
	ldy #PARENT
	lda (obj_ptr),Y
	cmp operands_lo+1
	bne +
!if ZVERSION>3 {
	dey
	lda (obj_ptr),Y
	cmp operands_hi+1
	bne +
}
	jmp branch_passed
+	jmp branch_failed

z_print_ret
	jsr z_print_inline_common
	lda #$0D
	jsr print_char
z_rtrue
	ldx #1
	+skip_2b
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

	lda stack_lo,Y
	sta zptr
	lda stack_hi,Y
	sta zpc_mid
	lda stack_lo+1,Y
	sta zpc_hi
	lda stack_hi+1,Y
	sta frameptr
	
	jsr update_zptr

!if ZVERSION>3 {
	lda stack_hi+2,Y
	bmi +
}
	lda stack_lo+2,Y

	jsr store_result_2
+	jmp next_insn

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
	bne +
	jmp z_rfalse
+	cmp #$1
	bne +
	jmp z_rtrue
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
	+skip_2b
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

	; for branches, MSB set indicates take the branch if true; clear means take it if false;
	; next, 0x40 encodes a short forward branch (0=rfalse,1=rtrue,2+=forward). Otherwise,
	; 0x20 indicates the sign of the branch, remaining bits are upper bits of sign, next byte is lower part.
branch_failed
	+zeroy
!if DEBUG_TRACE {
	jsr print_offset
}
	+next_insn_byte_y0
	cmp #$80
	bcc .take_branch	; if byte < 0x80, invert sense of the branch
.skip_branch
	and #$40
	bne .skip_short_branch
	+skip_insn_byte
.skip_short_branch
	jmp next_insn
branch_passed
	+zeroy
!if DEBUG_TRACE {
	jsr print_offset
}
	+next_insn_byte_y0
	cmp #$80
	bcc .skip_branch	; if byte < 0x80, invert sense of the branch
.take_branch
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

; same as above but with operands reversed (jl a,b == jg b,a)
z_jg
	sec
	lda operands_hi+1
	sbc operands_hi+0
	bvc +
	eor #$80
+	bmi branch_passed ; op1_h < op0_h? (op0_h > op1_h)
	bvc +
	eor #$80
+	bne branch_failed	; if op1_h != op0_h then op1 > op0
	lda operands_lo+1
	sbc operands_lo+0
	bcc branch_passed
	jmp branch_failed	; always taken

!if DEBUG_TRACE {
print_offset
	lda #'?'
	jsr debug_print_char
	lda (zptr),Y
	bmi +
	lda #'~'
	jsr debug_print_char
+	jsr space
	lda #'('
	jsr debug_print_char
	lda (zptr),y
	and #$40
	bne +
	lda (zptr),Y
	and #$3F
	jsr print_hex_byte
	iny
	lda (zptr),Y
	jsr print_hex_byte
	dey
-	lda #')'
	jmp debug_print_char
+	lda (zptr),Y
	and #$3F
	cmp #$00
	beq print_rfalse
	cmp #$01
	beq print_rtrue
	pha
	lda #0
	jsr print_hex_byte
	pla
	jsr print_hex_byte
	jmp -
print_rfalse
	jsr debug_print
	!text "rfalse",0
	jmp -
print_rtrue
	jsr debug_print
	!text "rtrue",0
	jmp -
}

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
	ldx #1
	stx mulSign
	ldx #0
	lda operands_hi+0
	bpl +
	jsr negate_operand
	dec mulSign
+	inx
	lda operands_hi+1
	bpl +
	jsr negate_operand
	dec mulSign
+	jsr .z_mul_16x16u
	lda mulSign
	bne +
	ldx #2
	jsr negate_operand
+	lda operands_hi+2
	ldx operands_lo+2
	jmp store_common

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

negate_operand
	lda #0
	sec
	sbc operands_lo,x
	sta operands_lo,X
	lda #0
	sbc operands_hi,x
	sta operands_hi,X
	rts

z_random
	lda operands_hi+0
	bmi .seed_random
	bpl .random_range
	ldx operands_lo+0
	bne .random_range
	; random(0) should seed based on system randomness.
	eor #$FF
.seed_random
	sta seed+1
	ldx operands_lo+0
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
	lda operands_hi+2
	ldx operands_lo+2
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

!if ZVERSION=3 {
PARENT = 4
SIBLING = 5
CHILD = 6
PROP_ADDR = 8
MAX_PROP = 31
} else {
PARENT = 7
SIBLING = 9
CHILD = 11
PROP_ADDR = 13
MAX_PROP = 63
}

z_get_child
	+begin_dynamic
	lda operands_lo+0
!if ZVERSION>3 {
	ora operands_hi+0
}
	beq .child_sibling_zero
	jsr get_object_addr
	ldy #CHILD
	bne +		; always taken
z_get_sibling
	+begin_dynamic
	jsr get_object_addr
	ldy #SIBLING
+	
!if ZVERSION>3 {
	lda (obj_ptr),Y
	tax
	dey
	lda (obj_ptr),Y
} else {
	lda (obj_ptr),Y
	tax
	lda #0
}
	+end_dynamic
!if ZVERSION>3 {
	cmp #0
	bne .child_sibling_nonzero
}
	cpx #0
	bne .child_sibling_nonzero
.child_sibling_zero
	tax
	jsr store_result
	jmp branch_failed
.child_sibling_nonzero
	jsr store_result
	jmp branch_passed

	; get_parent doesn't branch
z_get_parent
	; get_parent(0) is always 0.
	lda operands_lo+0
!if ZVERSION>3 {
	ora operands_hi+0
}
	beq +
	; otherwise get object address
	+begin_dynamic
	jsr get_object_addr
	ldy #PARENT
!if ZVERSION>3 {
	lda (obj_ptr),Y
	tax
	dey
	lda (obj_ptr),y
} else {
	lda (obj_ptr),Y
	tax
	lda #0
}
	+end_dynamic
+	jmp store_common

z_remove_obj
	jsr remove_obj
	jmp next_insn
	; operands_lo+4 is previous operands_lo+0
	; operands_lo+0 is overwritten
	; obj_ptr_alt is the object being removed 
	; obj_ptr is the parent or previous sibling
remove_obj
	lda operands_lo+0
	sta operands_lo+4
!if ZVERSION>3 {
	lda operands_hi+0
	sta operands_hi+4
}
	+begin_dynamic
	jsr get_object_addr
	lda obj_ptr
	sta obj_ptr_alt
	lda obj_ptr+1
	sta obj_ptr_alt+1
	ldy #PARENT
	lda (obj_ptr),Y
!if ZVERSION > 3 {
	sta operands_lo+0
	dey
	lda (obj_ptr),y
	sta operands_hi+0
	ora operands_lo+0
	beq .remove_obj_no_parent
} else {
	beq .remove_obj_no_parent
	sta operands_lo+0
}
	jsr get_object_addr
	ldy #CHILD
.remove_obj_check_prev
	lda (obj_ptr),Y
!if ZVERSION>3 {
	dey
}
	cmp operands_lo+4
	bne .remove_obj_not_direct	; Z4+: y points at hi byte
!if ZVERSION>3 {
	lda (obj_ptr),Y
	cmp operands_hi+4
	bne .remove_obj_not_direct
}
	sty obj_prev_offset
	ldy #SIBLING
	lda (obj_ptr_alt),Y	
	ldy obj_prev_offset
	; parent's child is our sibling (or our predecessor's sibling is our sibling)
!if ZVERSION>3 {
	iny
	sta (obj_ptr),y
	ldy #SIBLING-1
	lda (obj_ptr_alt),Y
	ldy obj_prev_offset
	sta (obj_ptr),Y
} else {
	sta (obj_ptr),Y
}
	ldy #SIBLING	; sibling
	lda #0
	sta (obj_ptr_alt),Y	; zero out our sibling
	dey
!if ZVERSION>3 {
	sta (obj_ptr_alt),Y
	dey
}
	sta (obj_ptr_alt),y ; zero out our parent
!if ZVERSION>3 {
	sta (obj_ptr_alt),Y
	dey
}
.remove_obj_no_parent
	+end_dynamic
	rts
	; walk next sibling in the list instead
.remove_obj_not_direct
!if ZVERSION>3 {
	lda (obj_ptr),Y
	sta operands_hi+0
	iny
	lda (obj_ptr),y
	sta operands_lo+0
} else {
	sta operands_lo+0
}
	jsr get_object_addr
	ldy #SIBLING
	bne .remove_obj_check_prev	; always taken

z_insert_obj
	jsr remove_obj	; obj_ptr_alt is now the object we're inserting
	; set our new parent
	+begin_dynamic
	ldy #PARENT		; parent
	lda operands_lo+1
	sta (obj_ptr_alt),y
	sta operands_lo+0

!if ZVERSION > 3 {
	dey
	lda operands_hi+1
	sta (obj_ptr_alt),Y
	sta operands_hi+0
}
	; our sibling is parent's child
	; first, get the parent's child and put it aside in X
	jsr get_object_addr
	ldy #CHILD
	lda (obj_ptr),y
!if ZVERSION>3 {
	sta operands_lo+5
	lda operands_lo+4
	sta (obj_ptr),Y
	dey
	lda (obj_ptr),Y
	sta operands_hi+5
	lda operands_hi+4
	sta (obj_ptr),Y

	; update parent's child to us while we're here
	iny
	lda operands_lo+4
	sta (obj_ptr),Y
	dey
	lda operands_hi+4
	sta (obj_ptr),Y

	; write parent's child to our sibling
	dey
	lda operands_lo+5
	sta (obj_ptr_alt),Y
	dey
	lda operands_hi+5
	sta (obj_ptr_alt),y
} else {
	tax
	; update parent's child to us while we're here
	lda operands_lo+4
	sta (obj_ptr),Y
	; write parent's child to our sibling
	dey			; sibling
	txa
	sta (obj_ptr_alt),Y
}
	+end_dynamic
	jmp next_insn

z_get_prop_addr
	+begin_dynamic
	jsr prop_common
	jsr find_property
	+end_dynamic
	ldx obj_ptr
	lda obj_mid
	jmp store_common

	; on input, operands+0 is object number; returns with obj_ptr pointing at first property
prop_common
!if DEBUG_PROP_COMMON {
	lda operands_lo+0
	jsr print_hex_byte
	lda #','
	jsr debug_print_char
	lda operands_lo+1
	jsr print_hex_byte
	jsr debug_print
	!text ": prop_common object",13,0
}
	jsr get_object_addr
	ldy #PROP_ADDR		; property addr
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

!if DEBUG_PROP_COMMON {
	lda obj_ptr+1
	jsr print_hex_byte
	lda obj_ptr
	jsr print_hex_byte
	jsr debug_print
	!text ": object table addr",13,0
}
	; get object length byte
	ldy #0
	lda (obj_ptr),y
	sty mulTemp	
	asl
	rol mulTemp			; damn you czech testing really long object names!
	adc obj_ptr
	sta obj_ptr
	lda obj_ptr+1
	adc mulTemp
	sta obj_ptr+1
	inc obj_ptr
	bne +
	inc obj_ptr+1
+	lda obj_ptr+1
	sec
	sbc #>HEADER
	sta obj_mid
	rts

	; on input, prop_common must have been called (obj_ptr valid), and operands+1 is property index
	; on return, y is property length or zero if not found; obj_ptr points at the property payload.
	; now we're at the first property; they are in descending order, terminated with zero
	; on V3, upper 3 bits are size-1, lower 5 bits are property index, 1-31
	; on V4+, lower 6 bits are property index, 1-63. If MSB is set, size is 6 LSB's of next byte (0 is 64) (and MSB there is set too)
	; if MSB is clear, bit 6 is set for a size of 2, else clear for a size of 1.
find_property
!if DEBUG_PROP_COMMON {
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
	; get property in A, length in Y, and obj_ptr points at paload
!if ZVERSION=3 {
	inc obj_ptr
	bne +
	inc obj_ptr+1
+	pha
	+lsr5
	tay
	iny
	pla
} else {
	bmi .twobyte	; length in second byte
	ldy #1
	cmp #$40
	bcc .havelen
	iny
	bne .havelen	; always taken
.twobyte
	pha
	inc obj_ptr
	bne +
	inc obj_ptr+1
+	
!ifdef TARGET_65C02 {
	lda (obj_ptr)
} else {
	lda (obj_ptr),y
}
	and #$3F
	bne +
	ldy #$40
	+skip_1b
+	tay
	pla
.havelen
	inc obj_ptr
	bne +
	inc obj_ptr+1
+	
}
	and #MAX_PROP
	beq .property_not_found

!if DEBUG_PROP_COMMON {
	pha
	jsr print_hex_byte
	lda #'='
	jsr debug_print_char
	lda operands_lo+1
	jsr print_hex_byte
	jsr debug_print
	!text "?",13,0
	pla
}
	cmp operands_lo+1
	beq .matched_property
	; if current propery < operands_lo+1, it's not here
	bcc .property_not_found
	tya		; get length so we can skip this payload
	clc
	adc obj_ptr
	sta obj_ptr
	bcc find_property
	inc obj_ptr+1
	bne find_property	; always taken (object can't be in high memory)
	; obj_ptr points at length byte; return value is length in bytes
.matched_property
	lda obj_ptr+1
	sec
	sbc #>HEADER
	sta obj_mid
	rts			; zero flag clear (obj_ptr can't be in zero page)
.property_not_found
	ldy #0
	sty obj_ptr
	sty obj_mid
	rts			; zero flag set

z_get_prop
	+begin_dynamic
	jsr prop_common
	jsr find_property
	beq .default_prop
	dey
	lda (obj_ptr),Y
	tax
	dey
	bmi +
	lda (obj_ptr),y
	+skip_2b
+	lda #0
	+end_dynamic
	jmp store_common

	; get the property index again (properties are between 1-31 or 1-63)
.default_prop
	lda operands_lo+1
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
	jsr find_property
	beq invalid_property
	dey
	lda operands_lo+2
	sta (obj_ptr),Y
	dey
	bmi +
	lda operands_hi+2
	sta (obj_ptr),Y
+	+end_dynamic
	jmp next_insn
invalid_property
	lda operands_lo+1
	jsr print_hex_byte
	jsr fatal_error
	!text ":invalid property for operation:",0

z_get_next_prop
	+begin_dynamic
	jsr prop_common
	; obj_ptr points at propery table now
	; operands+1 is property index to match
	lda operands_lo+1
	beq +		; if zero, obj_ptr is already correct.
	jsr find_property	; otherwise find this property
	tya					; and skip past it
	clc
	adc obj_ptr
	sta obj_ptr
	bcc +
	inc obj_ptr+1
+	
!ifdef TARGET_65C02 {
	lda (obj_ptr)
} else {
	ldy #0
	lda (obj_ptr),Y
}	
	and #MAX_PROP
	tax
	lda #0
	+end_dynamic
	jmp store_common

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
!if ZVERSION=3 {
	+lsr5
	clc
	adc #1
	tax
} else {
	cmp #$80
	bcs ++		; length is in second byte
	ldx #1
	cmp #$40
	bcc +
	inx
	bne +		; always taken
++	and #$3f
	bne	+++
	ldx #$40
	+skip_1b
+++ tax
}
+	lda #0
	jmp store_common

z_print_obj
	jsr print_obj
	jmp next_insn

print_obj
	+begin_dynamic
	jsr get_object_addr
	ldy #PROP_ADDR-1
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
	+end_dynamic

	; obj_ptr points at string to display. destroys A.
	; this function needs to be re-entrant
print_obj_ptr
	lda #0
	sta shift
	sta abbrev
	sta extended
	tya
	pha
	ldy #0
	+begin_dynamic
-	lda (obj_ptr),y
	php
	and #$7C
	lsr
	lsr
	jsr printz
	lda (obj_ptr),y
	and #$3
	; xsave is only used locally before we call printz again
	sta xsave
	inc obj_ptr
	bne +
	inc obj_ptr+1
+	lda (obj_ptr),y
	asl
	rol xsave
	asl
	rol xsave
	asl
	rol xsave
	lda xsave
	jsr printz
	lda (obj_ptr),Y
	inc obj_ptr
	bne +
	inc obj_ptr+1
+	and #$1F
	jsr printz
	plp
	bpl -
	+end_dynamic
	pla
	tay
	rts

z_print_addr
	lda operands_lo+0
	sta obj_ptr
	lda operands_hi+0
	clc
	adc #>HEADER
	sta obj_ptr+1
	; obj_ptr contains address in dynamic/static memory
	jsr print_obj_ptr
	jmp next_insn

operand_zero_to_zpc
	lda operands_lo+0
	sta zptr
	lda operands_hi+0
	sta zpc_mid
	lda #0
	sta zpc_hi
	asl zptr
	rol zpc_mid
	rol zpc_hi
!if ZVERSION>3 {
	asl zptr
	rol zpc_mid
	rol zpc_hi
!if ZVERSION=8 {
	asl zptr
	rol zpc_mid
	rol zpc_hi
}
}
	jsr update_zptr
	rts

z_print_paddr
	lda zpc_hi
	pha
	lda zpc_mid
	pha
	lda zptr
	pha
	jsr operand_zero_to_zpc
	jsr z_print_inline_common
	pla
	sta zptr
	pla
	sta zpc_mid
	pla
	sta zpc_hi
	jsr update_zptr
	jmp next_insn

	; destroys A,X
	; 5, 6, N>>4, N encodes any character not in dictionary
	; this function needs to be re-entrant for abbreviations to work.
printz
	ldx abbrev
	bne .print_abbrev
	ldx extended
	beq +
	cpx #$FF
	php
	asl extended
	asl extended
	asl extended
	asl extended
	asl extended
	ora extended
	sta extended
	plp
	beq .print_shift_ret
	ldx #0
	stx extended
	jmp print_char
+	cmp #0
	bne +
	lda #32
	jmp print_char
+	cmp #6
	bcs .print_tabled
	cmp #5
	beq .print_shift_2
	cmp #4
	beq .print_shift_1
	; what remains must be an abbreviation. carry is clear.
	asl
	asl
	asl
	asl
	asl
	sta abbrev	; 32/64/96
	rts
.print_tabled
	clc
	adc shift
	tax
	lda #0
	sta shift
	lda zalphabet-6,x
	beq .begin_extended

	jmp print_char
.print_shift_1
	lda #26
	+skip_2b
.print_shift_2
	lda #52
	sta shift
.print_shift_ret
	rts
.begin_extended
	lda #$FF
	sta extended
	rts
.print_abbrev
	clc
	adc abbrev
	sbc #31
	asl				; double to get word index
	tax
	lda obj_ptr+1
	pha
	lda obj_ptr
	pha
	+begin_dynamic
abbrev_load
	lda $1234,x
	sta obj_ptr+1
	inx
abbrev_load2
	lda $1234,x
	sta obj_ptr
	+end_dynamic

	; abbreviations are word addresses
	asl obj_ptr
	rol obj_ptr+1	; carry always clear
	lda obj_ptr+1
	adc #>HEADER
	sta obj_ptr+1
	jsr print_obj_ptr
	lda #0
	sta shift	; abbreviation might have had padding character
	pla
	sta obj_ptr
	pla
	sta obj_ptr+1
	rts

	; loads must be in contiguous dynamic+static memory
	; stores must be in contiguous dynamic memory
z_loadb
	jsr loadb
	tax
	lda #0
	jmp store_common
	; returns byte at operands+0 + operands+1 (dynamic or static memory) in A register
loadb
	clc
	lda operands_lo+0
	adc operands_lo+1
	sta load_addr+1
	lda operands_hi+0
	adc operands_hi+1
!if MEM_MODEL>=3 {
	; memory beyond 44k will be paged.
	cmp #$B0
	bcc +
	jsr fatal_error
	!text "paged static memory not implemented yet",13,0
}
+	clc
	adc #>HEADER
	sta load_addr+2
	+begin_dynamic
load_addr
	lda $1234
	+end_dynamic
	rts

z_storeb
	ldx operands_lo+2
	jsr storeb
	jmp next_insn
storeb
	clc
	lda operands_lo+0
	adc operands_lo+1
	sta store_addr+1
	lda operands_hi+0
	adc operands_hi+1
	clc
	adc #>HEADER
	sta store_addr+2
	+begin_dynamic
store_addr
	stx $1234
	+end_dynamic
	rts

	; return word of memory at operands[0] + operands[1]*2
z_loadw
	asl operands_lo+1
	rol operands_hi+1
!if MEM_MODEL>=3 {
	; in full memory models, implement word load as two byte
	; loads so crossing a VM boundary works.
	jsr loadb
	tay
	inc operands_lo+1
	bne +
	inc operands_hi+1
+	jsr loadb
	tax
	tya
} else {
	clc
	lda operands_lo+0
	adc operands_lo+1
	sta obj_ptr
	lda operands_hi+0
	adc operands_hi+1
	clc
	adc #>HEADER
	sta obj_ptr+1
	+begin_dynamic
	ldy #1
	lda (obj_ptr),Y
	tax
	dey
	lda (obj_ptr),y
	+end_dynamic
}
	jmp store_common

z_storew
	asl operands_lo+1
	rol operands_hi+1
	clc
	lda operands_lo+0
	adc operands_lo+1
	sta obj_ptr
	lda operands_hi+0
	adc operands_hi+1
	clc
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
-	jmp next_insn

operands_to_text_and_parse_ptr
	lda operands_lo+0
	sta text_ptr
	lda operands_hi+0
	clc
	adc #>HEADER
	sta text_ptr+1
	lda operands_lo+1
	sta parse_ptr
	lda operands_hi+1
	beq +				; make sure parse_ptr of zero stays zero.
	clc
	adc #>HEADER
+	sta parse_ptr+1
	rts

z_sread
	jsr operands_to_text_and_parse_ptr
!if ZVERSION=3 {
	; this destroys operands+0 through operands+2 (with print_num size optimizations)
	jsr show_status
}
	+begin_dynamic
	jsr read_line
	+end_dynamic
!if ZVERSION>=5 {
	lda parse_ptr
	ora parse_ptr+1
	beq  +
	jsr tokenise
+	ldx #13
	lda #0
	jmp store_common
} else {
	jsr tokenise
	jmp next_insn
}

z_tokenise
	jsr operands_to_text_and_parse_ptr
+	jsr tokenise
	jmp next_insn
tokenise
	+begin_dynamic

!if ZVERSION>=5 {
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
!if DEBUG_TOKENISE {
	jsr debug_print
	!text "text_offset = ",0
	lda text_offset
	jsr print_hex_byte
	jsr debug_print
	!text ", parse_offset = ",0
	lda parse_offset
	jsr print_hex_byte
	jsr newline
}
	; skip all spaces and stop at EOL (zero)
	; note that to keep the code simpler, we zero terminate even on Z5+
	ldy text_offset
	lda (text_ptr),Y
	bne +
!if DEBUG_TOKENISE {
	jsr debug_print
	!text "max parsed=",0
	ldy #0
	lda (parse_ptr),y
	jsr print_hex_byte
	jsr debug_print
	!text ", actual parsed=",0
	iny
	lda (parse_ptr),y
	jsr print_hex_byte
	lda #$d
	jsr debug_print_char
	iny
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
	jsr newline
	iny
	cpy parse_offset
	bcc .print_parsed_data
}
	+end_dynamic
	rts
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
!if DEBUG_TOKENISE {
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
!if DEBUG_TOKENISE_VERBOSE {
	jsr debug_print
	!text "low_index = ",0
	lda low_index+1
	jsr print_hex_byte
	lda low_index
	jsr print_hex_byte
	jsr debug_print
	!text ", high_index = ",0
	lda high_index+1
	jsr print_hex_byte
	lda high_index
	jsr print_hex_byte
	jsr newline
}
	; while (low_index <= high_index)
	; equivalently, if high_index - low_index isn't negative
	lda high_index
	sec
	sbc low_index
	lda high_index+1
	sbc low_index+1
	bmi .search_failed
	; mid_index = (low_index + high_index)>>1
	lda low_index
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
	; encode_buffer contains string to test against
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
	+skip_2b
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
	lda operands_lo+0
	beq .load_tos
!ifndef FRAME_USES_GLOBALS {
	cmp #$10
	bcs .load_global
	; carry is clear here
	adc frameptr
	tay
	lda stack_lo,y
	tax
	lda stack_hi,y
	jmp store_common
.load_global
}
	tay
	lda globals_lo,y
	tax
	lda globals_hi,y
	jmp store_common
.load_tos
	ldy stackptr
	lda stack_lo-1,y
	tax
	lda stack_hi-1,Y
	jmp store_common

z_print
	jsr z_print_inline_common
	jmp next_insn

z_print_inline_common
	lda #0
	sta shift
	sta abbrev
	sta extended
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

!if ZVERSION>4 {
z_call_1n
	ldx #1
	stx operand_count
z_call_2n
z_call_vn
z_call_vn2
	lda operands_lo+0
	ora operands_hi+0
	bne +
	; call to zero does nothing
	jmp next_insn
+	+zeroy
	lda #$80
	sta call_storage
	ora operand_count
	sta operand_count
	bne .no_store_result	; always taken
}

	; all call instructions route through here, x=1..7
	; the current frame's locals are kept in globals array to simplify decode logic
	; this means that when making a call, we need to copy as many variables as the
	; caller uses onto the stack before resetting them for the caller. likewise, on
	; return we need to copy the caller's variables back from the stack to the
	; current frame. this increases the cost of call_vs / ret slightly in favor
	; of improving the access speed of any local or global variable.
	; since all calls are variable typed (for now, not on V5) the arg count is in xsave
z_call_1s
	ldx #1
	stx operand_count
z_call_vs
z_call_vs2
z_call_2s
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
	sta call_storage		; set it aside for now

.no_store_result
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
!if ZVERSION>4 {
	lda operand_count
	sta stack_hi,x
	and #$7F
	sta operand_count
}
	lda call_storage
	sta stack_lo,x

	stx frameptr
	inx

!if DEBUG_TRACE {
!if ZVERSION>4 {
	ldy stack_hi-1,X
	bmi +
}
	cmp #0
	beq .call_st_tos
	cmp #$10
	bcs .call_st_global
	jsr debug_print
	!text " -> L",0
	sec
	sbc #1 ; carry clear
	jsr print_hex_byte
	jmp +
.call_st_global
	jsr debug_print
	!text " -> G",0
	sec
	sbc #$10
	jsr print_hex_byte
	jmp +
.call_st_tos
	jsr debug_print
	!text " -> (sp)++",0
+
}

	jsr operand_zero_to_zpc
	+zeroy
	+next_insn_byte_y0
	; get local count in A
	sta mulTemp
	cmp #0
	beq +
!if ZVERSION>4 {
	; zero out the locals
	lda #0
-	sta stack_hi,X
	sta stack_lo,X

} else {
	; copy local values

-	+next_insn_byte_y0	; local high byte
	sta stack_hi,x
	+next_insn_byte_y0	; local low byte
	sta stack_lo,x

}
	inx
	dec mulTemp
	bne -
+	stx stackptr

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

	; var(operands[0].getS()) = pop() (stack[--stackptr])
	; so if operands[0] is TOS, we use its current value *prior* to popping it
	; this translates to stack[stackptr-1] = stack[--stackptr],
	; which ultimately, turns into just --stackptr (leaving contents of stack untouched)
z_pull
	dec stackptr
	lda operands_lo+0
	beq +
	ldy stackptr
	lda stack_lo,Y
	tax
	lda stack_hi,Y
	sta store_hi
	lda operands_lo+0
	jsr store_result_3
+	jmp next_insn

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
	lda #0
	sta $c0ff
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
	; compute objIndex * 9 (*14 on V4+)
	; 9x is 8x + x.  14x is 16x-2x or 2(8x-x)
!if ZVERSION>3 {
	lda operands_hi+0
	bne +
}
	lda operands_lo+0
	bne ++
	jsr fatal_error
	!text "get_object_addr 0 called",13,0
+	lda operands_lo+0
++	sta obj_ptr+0
	lda operands_hi+0
	sta obj_ptr+1

	; objIndex * 8
	asl obj_ptr+0
	rol obj_ptr+1
	asl obj_ptr+0
	rol obj_ptr+1
	asl obj_ptr+0
	rol obj_ptr+1

!if ZVERSION=3 {
	; finish objIndex * 9 computation (carry is always clear)
	lda obj_ptr+0
	adc operands_lo+0
	sta obj_ptr+0
	lda obj_ptr+1
	adc operands_hi+0
	sta obj_ptr+1
} else {
	; 14x = 2(8x - x); compute 8x-x:
	lda obj_ptr+0
	sec
	sbc operands_lo+0
	sta obj_ptr+0
	lda obj_ptr+1
	sbc operands_hi+0
	sta obj_ptr+1
	; now double it
	asl obj_ptr+0
	rol obj_ptr+1
}
	; convert to final memory address (carry is always clear)
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

; FAST_PRINT_NUM = 1

print_num
!ifdef FAST_PRINT_NUM {
	lda #0
	sta mulTemp
	lda operands_hi+0
	beq ++
} else {
	lda operands_hi+0
}
	bpl +
	lda #'-'
	jsr print_char
	ldx #0
	jsr negate_operand
!ifdef FAST_PRINT_NUM {
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
} else {
+	lda #10
	sta operands_lo+1
	lda #0
	sta operands_hi+1
	pha					; mark terminator
-	jsr divide			; quotient in +0, remainder in +2
	lda operands_lo+2
	ora #$30			; don't care about carry
	pha
	lda operands_lo+0
	ora operands_hi+0
	bne -

-	pla
	beq +
	jsr print_char
	jmp -
+	rts
}
	; preserves A
print_hex_byte
	pha
	lsr
	lsr
	lsr
	lsr
	jsr print_hex_digit
	pla
	pha
	and #$f
	jsr print_hex_digit
	pla
	rts
print_hex_digit
	ora #$30
	cmp #$3A
	bcc +
	adc #$6	; carry is always set
+	jmp debug_print_char

z_new_line
	lda #13
	+skip_2b
z_print_char
	lda operands_lo+0
	jsr print_char
	jmp next_insn

z_show_status
!if ZVERSION=3 {
	jsr show_status
}
	jmp next_insn

!if ZVERSION=3 {
show_status
	jsr flush_main_window

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
}

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
	cmp #','
	beq .break
	sty .buffered_y_restore+1
	ldy chars_stored
	sta char_buffer,Y
	inc chars_stored
.buffered_y_restore
	ldy #$12
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
	; if signs are different, quotient is negative. remainder always has sign of the quotient.
	; destroys A, X, Y
divide
	lda #0
	sta mulSign
	lda operands_hi+0
	bpl +
	inc mulSign			; quotient is negative
	ldx #0
	jsr negate_operand
+	lda operands_hi+1
	bpl +
	inc mulSign			; dividend is negative
	inc mulSign
	ldx #1
	jsr negate_operand
+	lda #0
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
	lda mulSign
	; dividend is negative if signs were different (mulSign is 1 or 2)
	beq +
	cmp #3
	beq +
	ldx #0
	jsr negate_operand
	; remainder takes the original sign of the quotient
+	lda mulSign
	and #1
	beq +
	ldx #2
	jsr negate_operand
+	rts



	; var(operands[0].getS()) = operands[1];
	; meaning, stack pointer doesn't (further) change if operands[0] is 0.
z_store
	lda operands_hi+1
	sta store_hi
	ldx operands_lo+1
	lda operands_lo+0
	beq store_to_tos_no_change
	jsr store_result_3
	jmp next_insn
store_to_tos_no_change
	ldy stackptr
	lda store_hi
	sta stack_hi-1,Y
	txa
	sta stack_lo-1,y
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
store_result_3
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

!if DEBUG_TRACE {
	;lda stack_hi,y
	;jsr print_hex_byte
	;lda stack_lo,Y
	;jsr print_hex_byte
	jsr debug_print
	!text "-> L",0
	tya
	clc	; need to subtract an additional 1 to get local index back
	sbc frameptr
	jsr print_hex_byte
}
	rts
.store_global
}
	tay
	lda store_hi
	sta globals_hi,y
	txa
	sta globals_lo,y

!if DEBUG_TRACE {
	;lda globals_hi,y
	;jsr print_hex_byte
	;lda globals_lo,Y
	;jsr print_hex_byte
	jsr debug_print
	!text "-> G",0
	tya
	sec
	sbc #$10
	jsr print_hex_byte
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

!if DEBUG_TRACE {
	;lda stack_hi,y
	;jsr print_hex_byte
	;lda stack_lo,Y
	;jsr print_hex_byte
	jsr debug_print
	!text "-> (sp)++",0
}
	rts
+ 	jsr fatal_error
	!text "stack overflow",13,0

z_input_stream
	jmp next_insn

!if ZVERSION>4 {

;	!align 255, 0
z_xsave
z_xrestore
	jmp z_ill

z_log_shift
	lda operands_lo+1
	bmi .log_shift_right
	beq .shift_done
.shift_left_common
	asl operands_lo+0
	rol operands_hi+0
	dec operands_lo+1
	bne .shift_left_common
.shift_done
	ldx operands_lo+0
	lda operands_hi+0
	jmp store_common
.log_shift_right
	lsr operands_hi+0
	ror operands_lo+0
	inc operands_lo+1
	bne .log_shift_right
	beq .shift_done

z_art_shift
	lda operands_lo+1
	beq .shift_done
	bpl .shift_left_common
	lda operands_hi+0
	bpl .log_shift_right
.art_shift_right
	sec
	ror operands_hi+0
	ror operands_lo+0
	inc operands_lo+1
	bne .art_shift_right
	beq .shift_done

z_save_undo
	lda #$ff
	tax
	jmp store_common	; mark not supported

z_restore_undo
	lda #0
	tax
	jmp store_common	; mark failed operation

z_extended
	+zeroy
	+next_insn_byte_y0
!if DEBUG_TRACE {
	jsr print_hex_byte
}
	tay
	lda _extTblLo,Y
	sta .extDispatch+1
	lda _extTblHi,Y
	sta .extDispatch+2
	+zeroy
	jsr decode_types
.extDispatch
	jmp z_xsave

z_set_colour ; we could support normal and Inverse
	jmp next_insn


z_throw
	jmp z_ill ; todo, needs to restore stack
}

!if ZVERSION>3 {

z_set_text_style ; we could support normal and Inverse
	jmp next_insn

z_buffer_mode
	lda operands_lo+0
	bne .enable_buffering
	; disable buffering 
	jsr flush_main_window
	lda #<print_char_lower
	sta print_char+1
	lda #>print_char_lower
	sta print_char+2
	jmp next_insn
.enable_buffering
	jsr default_print_char
	jmp next_insn

z_erase_window
	jmp next_insn

z_erase_line
	jmp next_insn

z_set_cursor
	jmp next_insn

z_get_cursor
	jmp next_insn

z_read_char
	jsr flush_main_window
	jsr read_char
	tax
	lda #0
	jmp store_common

z_scan_table
	; match table count [form]
	; move 'table' to slot 0 for loadb/loadw use
	lda operands_lo+2
	ora operands_hi+2
	beq .scan_failed
	lda operands_lo+0
	sta operands_lo+4
	lda operands_hi+0
	sta operands_hi+4
	lda operands_lo+1
	sta operands_lo+0
	lda operands_hi+1
	sta operands_hi+0
	lda #0
	sta operands_lo+1
	sta operands_hi+1
	ldx operand_count
	cpx #4
	beq +
	lda #$82
	sta operands_lo+3
+	lda operands_lo+3
	bmi .scan_word
-	jsr loadb
	cmp operands_lo+4
	beq .scan_found
	lda operands_lo+0
	clc
	adc operands_lo+3
	sta operands_lo+0
	bcc +
	inc operands_hi+0
+	dec operands_lo+2
	bne -
	dec operands_hi+2
	bpl -
.scan_failed
	lda #0
	tax
	jsr store_result
	jmp branch_failed
.scan_found
	ldx operands_lo+0
	lda operands_hi+0
	jsr store_result
	jmp branch_passed
.scan_word
	and #$7f
	sta operands_lo+3
-	jsr loadb
	cmp operands_hi+4
	bne +				; didn't match
	inc operands_lo+1
	jsr loadb
	dec operands_lo+1
	cmp operands_lo+4
	beq .scan_found
+	lda operands_lo+0
	clc
	adc operands_lo+3
	sta operands_lo+0
	bcc +
	inc operands_hi+0
+	dec operands_lo+2
	bne -
	dec operands_hi+2
	bpl -
	bmi .scan_failed ; always taken

z_encode_text
	jmp z_ill


z_copy_table
	; first, second, count.
	; if second is zero, memset first to zero	
	+begin_dynamic
	lda operands_lo+0
	sta obj_ptr
	lda operands_hi+0
	clc
	adc #>HEADER
	sta obj_ptr+1

	ldy #0
	lda operands_lo+1
	sta obj_ptr_alt
	ora operands_hi+1
	beq .copy_table_zero
	lda operands_hi+1
	clc
	adc #>HEADER
	sta obj_ptr_alt+1

	sty operands_lo+1
	sty operands_hi+1
-	jsr loadb
	sta (obj_ptr_alt),Y
	inc obj_ptr_alt
	bne +
	inc obj_ptr_alt+1
+	inc operands_lo+1
	bne +
	inc operands_hi+1
+	lda operands_lo+1
	cmp operands_lo+2
	bne -
	lda operands_hi+1
	cmp operands_hi+2
	bne -
	beq .copy_table_zero_done	; always taken
.copy_table_zero
	sta (obj_ptr),Y
	inc obj_ptr
	bne +
	inc obj_ptr+1
+	dec operands_lo+2
	bne .copy_table_zero
	dec operands_hi+2
	bpl .copy_table_zero
.copy_table_zero_done
	+end_dynamic
	jmp next_insn

	; text_addr width height [skip]
z_print_table
	ldx operand_count
	cpx #4
	bcs +
	ldx #0
	stx operands_lo+3
+	lda operands_lo+1
	sta operands_lo+4
	lda #0
	sta operands_lo+1
	sta operands_hi+1
.print_row
	ldx operands_lo+4
.print_row_loop
	jsr loadb
	jsr print_char
	inc operands_lo+1
	bne +
	inc operands_hi+1
+	dex
	bne .print_row_loop
	lda operands_lo+3
	clc
	adc operands_lo+1
	sta operands_lo+1
	bcc +
	inc operands_hi+1
+	lda #13
	jsr print_char
	dec operands_lo+2
	bne .print_row
	jmp next_insn

z_check_arg_count
	; examine arg count in current stack frame
	ldy frameptr
	lda stack_hi,Y
	and #$F
	cmp operands_lo+0
	bcc +
	beq +
	jmp branch_passed
+	jmp branch_failed
}


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
	beq dead		; hang forever
	jsr print_char
	iny
	bne -		; always taken
dead
	sta $c0ff
	beq dead

;!if DEBUG_TRACE {
space
	pha
	lda #32
	jsr debug_print_char
	pla
	rts

newline
	pha
	lda #13
	jsr debug_print_char
	pla
	rts

	; preserves A/X/Y
debug_print
	sta .debug_print_restore+1
	pla
	sta stringptr
	pla
	sta stringptr+1
	sty .debug_print_restore+3
	ldy #1
-	lda (stringptr),y
	beq +
	jsr debug_print_char
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
	lda #$12
	ldy #$12
	rts
;}

!if DEBUG_TRACE {
_2opNames
	!source "table_2op.inc"
	
_1opNames
!if ZVERSION>3 {
	!source "table_1op_v5.inc"
} else {
	!source "table_1op_v3.inc"
}

_0opNames
	!source "table_0op.inc"

_varNames
	!source "table_varop.inc"
}
!ifdef FAST_PRINT_NUM {
	!align 255, 512 - 100 - (26*3) - 96
dec2hex 
	!byte $00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24
	!byte $25,$26,$27,$28,$29,$30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$40,$41,$42,$43,$44,$45,$46,$47,$48,$49
	!byte $50,$51,$52,$53,$54,$55,$56,$57,$58,$59,$60,$61,$62,$63,$64,$65,$66,$67,$68,$69,$70,$71,$72,$73,$74
	!byte $75,$76,$77,$78,$79,$80,$81,$82,$83,$84,$85,$86,$87,$88,$89,$90,$91,$92,$93,$94,$95,$96,$97,$98,$99
} else {
	!align 255, 256 - (26*3) - 96
}
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

!if ZVERSION>4 {
_2opTbl +table32 z_ill,z_je,z_jl,z_jg,z_dec_chk,z_inc_chk,z_jin,z_test,z_or,z_and,z_test_attr,z_set_attr,z_clear_attr,z_store,z_insert_obj,z_loadw,z_loadb,z_get_prop,z_get_prop_addr,z_get_next_prop,z_add,z_sub,z_mul,z_div,z_mod,z_call_2s,z_call_2n,z_set_colour,z_throw,z_ill,z_ill,z_ill
} else if ZVERSION>3 {
_2opTbl +table32 z_ill,z_je,z_jl,z_jg,z_dec_chk,z_inc_chk,z_jin,z_test,z_or,z_and,z_test_attr,z_set_attr,z_clear_attr,z_store,z_insert_obj,z_loadw,z_loadb,z_get_prop,z_get_prop_addr,z_get_next_prop,z_add,z_sub,z_mul,z_div,z_mod,z_call_2s,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill
} else {
_2opTbl +table32 z_ill,z_je,z_jl,z_jg,z_dec_chk,z_inc_chk,z_jin,z_test,z_or,z_and,z_test_attr,z_set_attr,z_clear_attr,z_store,z_insert_obj,z_loadw,z_loadb,z_get_prop,z_get_prop_addr,z_get_next_prop,z_add,z_sub,z_mul,z_div,z_mod,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill
}

!if ZVERSION>4 {
_1opTbl +table16 z_jz,z_get_sibling,z_get_child,z_get_parent,z_get_prop_len,z_inc,z_dec,z_print_addr,z_call_1s,z_remove_obj,z_print_obj,z_ret,z_jump,z_print_paddr,z_load,z_call_1n
} else if ZVERSION>3 {
_1opTbl +table16 z_jz,z_get_sibling,z_get_child,z_get_parent,z_get_prop_len,z_inc,z_dec,z_print_addr,z_call_1s,z_remove_obj,z_print_obj,z_ret,z_jump,z_print_paddr,z_load,z_not
} else {
_1opTbl +table16 z_jz,z_get_sibling,z_get_child,z_get_parent,z_get_prop_len,z_inc,z_dec,z_print_addr,z_ill,z_remove_obj,z_print_obj,z_ret,z_jump,z_print_paddr,z_load,z_not
}

!if ZVERSION>4 {
_0opTbl +table16 z_rtrue,z_rfalse,z_print,z_print_ret,next_insn,z_save,z_restore,z_restart,z_ret_popped,z_pop,z_quit,z_new_line,z_show_status,branch_passed,z_extended,branch_passed
} else {
_0opTbl +table16 z_rtrue,z_rfalse,z_print,z_print_ret,next_insn,z_save,z_restore,z_restart,z_ret_popped,z_pop,z_quit,z_new_line,z_show_status,branch_passed,z_ill,z_ill
}

!if ZVERSION>4 {
_varTbl +table32 z_call_vs,z_storew,z_storeb,z_put_prop,z_sread,z_print_char,z_print_num,z_random,z_push,z_pull,z_split_window,z_set_window,z_call_vs2,z_erase_window,z_erase_line,z_set_cursor,z_get_cursor,z_set_text_style,z_buffer_mode,z_output_stream,z_input_stream,next_insn,z_read_char,z_scan_table,z_not,z_call_vn,z_call_vn2,z_tokenise,z_encode_text,z_copy_table,z_print_table,z_check_arg_count
} else if ZVERSION>3 {
_varTbl +table32 z_call_vs,z_storew,z_storeb,z_put_prop,z_sread,z_print_char,z_print_num,z_random,z_push,z_pull,z_split_window,z_set_window,z_call_vs2,z_erase_window,z_erase_line,z_set_cursor,z_get_cursor,z_set_text_style,z_buffer_mode,z_output_stream,z_input_stream,next_insn,z_read_char,z_scan_table,z_not,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill
} else {
_varTbl +table32 z_call_vs,z_storew,z_storeb,z_put_prop,z_sread,z_print_char,z_print_num,z_random,z_push,z_pull,z_split_window,z_set_window,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_output_stream,z_input_stream,next_insn,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill,z_ill
}	

!if ZVERSION>4 {
_extTblLo
	!byte <z_xsave,<z_xrestore,<z_log_shift,<z_art_shift,<next_insn,<z_ill,<z_ill,<z_ill,<z_ill,<z_save_undo,<z_restore_undo
_extTblHi
	!byte >z_xsave,>z_xrestore,>z_log_shift,>z_art_shift,>next_insn,>z_ill,>z_ill,>z_ill,>z_ill,>z_save_undo,>z_restore_undo
}

	; resist temptation to move these to $800 because that's banked RAM on apple 2e.
	; stack is split into lower and upper bytes so we can treat the Y register as a stack pointer.
	!align 255, 0
stack_lo	!fill 256
stack_hi	!fill 256

	; we could have the current frame's locals here as well, but then we have to copy out to the
	; stack on any call or return. first 16 bytes of each could be used for something else
globals_lo	!fill 256
globals_hi	!fill 256



; the initial vm_map is always the next 44k of the story. we always use 512b blocks,
; since that is the minimum read size for smartport. this allows us to determine if
; a page is already resident in O(1) time. 
vm_map		!byte $10,$12,$14,$16,$18,$1A,$1C,$1E
			!byte $20,$22,$24,$26,$28,$2A,$2C,$2E
			!byte $30,$32,$34,$36,$38,$3A,$3C,$3E
			!byte $40,$42,$44,$46,$48,$4A,$4C,$4E
			!byte $50,$52,$54,$56,$58,$5A,$5C,$5E
			!byte $60,$62,$64,$66,$68,$6A,$6C,$6E
			!byte $70,$72,$74,$76,$78,$7A,$7C,$7E
			!byte $80,$82,$84,$86,$88,$8A,$8C,$8E
			!byte $90,$92,$94,$96,$98,$9A,$9C,$9E
			!byte $A0,$A2,$A4,$A6,$A8,$AA,$AC,$AE
			!byte $B0,$B2,$B4,$B6,$B8,$BA,$BC,$BE
!if ZVERSION=3 {
			; story size in kilobytes minus 44k dynamic and 44k initial vram, at two 512b blocks per kilobyte.
			!fill (128-88)*2,0
} else if (ZVERSION<=5) {
			!fill (256-88)*2,0
} else {
			!fill (512-88)*2,0
}

!if MEM_MODEL > 1 {
; this contains the age of each 512b page
; it's tempting to use larger pages on V5 and V8 but that will likely
; lead to a lot more disk thrashing.
page_ages	!fill 88,1			; 0 is freshly used
page_owners_lo
			!byte  0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15
			!byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
			!byte 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
			!byte 48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63
			!byte 64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79
			!byte 80,81,82,83,84,85,86,87
!if ZVERSION>3 {
page_owners_hi
			!fill 88
}
} ; MEM_MODEL>1

	; round interpreter up to next 8k boundary for alignment (we start at 4k)
	; the non-debug version of the interpreter fits in 8k though.
	!align 8191, 0
