all: tinyzc tinyzcd tinyzterp tinyzterpd zdis cloak.z3 cloak.z4 cloak.z5 demogame.z3 advent.do advent.po demogame.do \
	sieve_2p.do sieve_2e.do sieve_2ee.do cloak.do zork.do dejavu.do hibernated.do czech.do minimal.do loh.do \
	applez_2e.bin applez_2e40_0.bin applez_2e40_1.bin applez_2e40_2.bin

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
	acme -f plain --cpu 6502 -DCOLUMNS=40 -DTARGET_APPLE2PLUS=1 -DNDEBUG_TRACE=1 -DNDEBUG_PROP_COMMON=1 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=1 -r applez_2p.lst -o applez_2p.bin applez.asm

applez_2e.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=80 -DNDEBUG_TRACE=1 -DNDEBUG_PROP_COMMON=1 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=1 -r applez_2e.lst -o applez_2e.bin applez.asm

applez_2e40_0.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=40 -DNDEBUG_TRACE=1 -DNDEBUG_PROP_COMMON=1 -DZVERSION=3 -DMEM_MODEL=0 -DLOAD_FROM_DISK_II=0  -r applez_2e40_0.lst -o applez_2e40_0.bin applez.asm

applez_2e40_1.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=40 -DNDEBUG_TRACE=1 -DNDEBUG_PROP_COMMON=1 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=0 -r applez_2e40_1.lst -o applez_2e40_1.bin applez.asm

applez_2e40_2.bin: applez.asm Makefile
	acme -f plain --cpu 6502 -DCOLUMNS=40 -DNDEBUG_TRACE=1 -DNDEBUG_PROP_COMMON=1 -DZVERSION=3 -DMEM_MODEL=2 -DLOAD_FROM_DISK_II=0 -r applez_2e40_2.lst -o applez_2e40_2.bin applez.asm

applez_2ee.bin: applez.asm Makefile
	acme -f plain --cpu 65c02 -DCOLUMNS=80 -DNDEBUG_TRACE=1 -DNDEBUG_PROP_COMMON=1 -DTARGET_65C02=1 -DZVERSION=3 -DMEM_MODEL=1 -DLOAD_FROM_DISK_II=1 -r applez_2ee.lst -o applez_2ee.bin applez.asm

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

dejavu.do: dejavu.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin dejavu.z3 -o dejavu.do

hibernated.do: hibernated1.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin hibernated1.z3 -o hibernated.do

minimal.z3: minimal.tz tinyzc
	./tinyzc -Aadvent.abbrev minimal.tz

minimal.do: minimal.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin minimal.z3 -o minimal.do

czech.z3: czech.inf
	inform -v3 czech.inf

czech.do: czech.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin czech.z3 -o czech.do

loh.do: library_of_horror.z3 applez_2e.bin Makefile makedsk
	./makedsk applez_2e.bin library_of_horror.z3 -o loh.do

