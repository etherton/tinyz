all: tinyzc tinyzcd tinyzterp tinyzterpd zdis cloak.z3 cloak.z4 cloak.z5 demogame.z3 advent.do advent.po demogame.do bunkerblues.z3 \
	sieve_2p.do sieve_2e.do sieve_2ee.do cloak.do hibernated.do czech_z3.do czech_z5.do minimal.do minimal.hdv \
	applez_2e.bin applez_2e40_0.bin applez_2e40_1.bin applez_2e40_2.bin \
	applez_2e_v3_46k.bin applez_2e_v3_92k.bin applez_2e_v3_128k.bin  \
	applez_2e_v5_46k.bin applez_2e_v5_92k.bin applez_2e_v5_256k.bin \
	czech.z3 czech.z5 applez_2e_v4.bin applez_2e_v8.bin

# these require story files not included
optional: zork.do hibernated.do loh.do

tinyzcd: opcodes.h header.h tinyz.y debug.h debug.cpp Makefile
	bison --debug tinyz.y -v -o tinyz.debug.tab.cpp && clang++ -DDEBUG_MEM=1 -g -std=c++17 tinyz.debug.tab.cpp debug.cpp -o tinyzcd

tinyzc: opcodes.h header.h tinyz.y debug.h debug.cpp Makefile
	bison tinyz.y -v -o tinyz.tab.cpp && clang++ -std=c++17 -O2 tinyz.tab.cpp debug.cpp -o tinyzc

tinyzterpd: opcodes.h header.h machine.h machine.cpp interface_macos.cpp debug.h debug.cpp Makefile
	clang++ -std=c++17 -g -DENABLE_DEBUG=1 machine.cpp interface_macos.cpp debug.cpp -o tinyzterpd

tinyzterp: opcodes.h header.h machine.h machine.cpp interface_macos.cpp debug.h debug.cpp Makefile
	clang++ -std=c++17 machine.cpp interface_macos.cpp debug.cpp -O2 -o tinyzterp

zdis: opcodes.h header.h zdis.cpp debug.h debug.cpp Makefile
	clang++ -std=c++17 zdis.cpp debug.cpp -o zdis

makedsk: makedsk.cpp
	clang++ makedsk.cpp -o makedsk

cloak.z3: cloak.tz tinyzc Makefile
	./tinyzc -z3 -agametext.txt -Acloak.abbrev -g -r cloak.tz > cloak.z3.txt

cloak.z4: cloak.tz tinyzc Makefile
	./tinyzc -z4 -Acloak.abbrev -g -r cloak.tz > cloak.z4.txt

cloak.z5: cloak.tz tinyzc Makefile
	./tinyzc -z5 -Acloak.abbrev -g -r cloak.tz > cloak.z5.txt

demogame.z3: demogame.tz core.tzh tinyzc Makefile
	./tinyzc -z3 demogame.tz

bunkerblues.z3: bunkerblues.tz core.tzh tinyzc Makefile
	./tinyzc -z3 bunkerblues.tz

debug3: cloak.z3 Makefile tinyzterpd
	./tinyzterpd cloak.z3 -debug -di cloak.z3.dbg

debug4: cloak.z4 Makefile tinyzterpd
	./tinyzterpd cloak.z4 -debug -di cloak.z4.dbg

debug5: cloak.z5 Makefile tinyzterpd
	./tinyzterpd cloak.z5 -debug -di cloak.z5.dbg
	
run3: cloak.z3 Makefile tinyzterp
	./tinyzterp cloak.z3 cloak.z3.dbg

run4: cloak.z4 Makefile tinyzterp
	./tinyzterp cloak.z4 cloak.z4.dbg

run5: cloak.z5 Makefile tinyzterp
	./tinyzterp cloak.z5 cloak.z5.dbg
	
check:
	./tinyzcd demogame.tz

sieve.z3: sieve.tz
	./tinyzc sieve.tz

applez_2p.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=40 -DTARGET_APPLE2PLUS=1 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=1 -r applez_2p.lst -o applez_2p.bin applez.asm

applez_2e.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=1 -r applez_2e.lst -o applez_2e.bin applez.asm

applez_2e_v4.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=4 -DMEM_MODEL=3 -DLOAD_FROM_DISK_II=0 -r applez_2e_v4.lst -o applez_2e_v4.bin applez.asm

applez_2e_v5_46k.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=5 -DMEM_MODEL=0 -DLOAD_FROM_DISK_II=1 -r applez_2e_v5_46k.lst -o applez_2e_v5_46k.bin applez.asm

applez_2e_v5_92k.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=5 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=1 -r applez_2e_v5_92k.lst -o applez_2e_v5_92k.bin applez.asm

applez_2e_v5_256k.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=5 -DMEM_MODEL=3 -DLOAD_FROM_DISK_II=0 -r applez_2e_v5_256k.lst -o applez_2e_v5_256k.bin applez.asm

applez_2e_v8.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=8 -DMEM_MODEL=3 -DLOAD_FROM_DISK_II=0 -r applez_2e_v8.lst -o applez_2e_v8.bin applez.asm

applez_2e40_0.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=40 -DZVERSION=3 -DMEM_MODEL=0 -DLOAD_FROM_DISK_II=0  -r applez_2e40_0.lst -o applez_2e40_0.bin applez.asm

applez_2e40_1.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=40 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=0 -r applez_2e40_1.lst -o applez_2e40_1.bin applez.asm

applez_2e40_2.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=40 -DZVERSION=3 -DMEM_MODEL=2 -DLOAD_FROM_DISK_II=0 -r applez_2e40_2.lst -o applez_2e40_2.bin applez.asm

applez_2e_v3_46k.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=3 -DMEM_MODEL=0 -DLOAD_FROM_DISK_II=0 -r applez_2e_v3_46k.lst -o applez_2e_v3_46k.bin applez.asm

applez_2e_v3_92k.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=0 -r applez_2e_v3_92k.lst -o applez_2e_v3_92k.bin applez.asm

applez_2e_v3_128k.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DZVERSION=3 -DMEM_MODEL=2 -DLOAD_FROM_DISK_II=0 -r applez_2e_v3_128k.lst -o applez_2e_v3_128k.bin applez.asm

applez_2ee.bin: applez.asm Makefile
	acme -f plain --cpu 65c02 -DCOLUMNS=80 -DTARGET_65C02=1 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=1 -r applez_2ee.lst -o applez_2ee.bin applez.asm

sieve_2p.do: sieve.z3 applez_2p.bin makedsk
	./makedsk applez_2p.bin sieve.z3 -o sieve_2p.do

sieve_2e.do: sieve.z3 applez_2e.bin makedsk
	./makedsk applez_2e.bin sieve.z3 -o sieve_2e.do

sieve_2ee.do: sieve.z3 applez_2ee.bin makedsk
	./makedsk applez_2ee.bin sieve.z3 -o sieve_2ee.do

sieve.hdv: sieve.z3 applez_2e40_0.bin makedsk
	./makedsk applez_2e40_0.bin sieve.z3 -o sieve.hdv

cloak.do: cloak.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin cloak.z3 -o cloak.do

advent.do: advent.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin advent.z3 -o advent.do

advent.po: advent.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin advent.z3 -o advent.po

zork.do: zork1-r88-s840726.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin zork1-r88-s840726.z3 -o zork.do

demogame.do: demogame.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin demogame.z3 -o demogame.do

hibernated.do: hibernated1.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin hibernated1.z3 -o hibernated.do

minimal.z3: minimal.tz tinyzc
	./tinyzc -z3 minimal.tz

minimal.z4: minimal.tz tinyzc
	./tinyzc -z4 minimal.tz

minimal.do: minimal.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin minimal.z3 -o minimal.do

minimal.hdv: minimal.z4 applez_2e_v4.bin Makefile makedsk
	./makedsk applez_2e_v4.bin minimal.z4 -o minimal.hdv

czech.z3: czech.inf
	inform -v3 czech.inf

czech_z3.do: czech.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin czech.z3 -o czech_z3.do

czech.z5: czech.inf
	inform -v5 czech.inf

czech_z5.do: czech.z3 applez_2e_v5_256k.bin Makefile makedsk
	./makedsk applez_2e_v5_256k.bin czech.z5 -o czech_z5.do

loh.do: library_of_horror.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin library_of_horror.z3 -o loh.do

maketable: maketable.cpp Makefile
	clang++ maketable.cpp -o maketable

table_2op.inc: maketable
	./maketable x00 je jl jg dec_chk inc_chk jin test or and test_attr set_attr clear_attr store insert_obj loadw loadb \
get_prop get_prop_addr get_next_prop add sub mul div mod call_2s call_2n set_colour throw x1d x1e x1f > table_2op.inc

table_1op_v3.inc: maketable
	./maketable jz get_sibling get_child get_parent get_prop_len inc dec print_addr call_1s remove_obj print_obj ret jump print_paddr load not > table_1op_v3.inc

table_1op_v5.inc: maketable
	./maketable jz get_sibling get_child get_parent get_prop_len inc dec print_addr call_1s remove_obj print_obj ret jump print_paddr load call_1n > table_1op_v5.inc

table_0op.inc: maketable
	./maketable rtrue rfalse print print_ret nop save restore restart ret_popped pop quit new_line show_status verify extended piracy > table_0op.inc

table_varop.inc: maketable
	./maketable call_vs storew storeb put_prop sread print_char print_num random push pull split_wnd set_wnd call_vs2 era_wnd \
era_ln set_curs get_curs set_txt_style buffer_mode out_strm inp_strm sfx read_char scan_table not call_vn call_vn2 tokenise \
encode_text copy_table print_table chk_arg_ct > table_varop.inc

applez.asm: maketable table_0op.inc table_1op_v3.inc table_1op_v5.inc table_2op.inc table_varop.inc

