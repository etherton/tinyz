all: tinyzc tinyzcd tinyzterp tinyzterpd zdis cloak.z3 cloak.z4 cloak.z5

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

cloak.z3: cloak.tz tinyzc Makefile
	./tinyzc -z3 -g -r cloak.tz > cloak.z3.txt

cloak.z4: cloak.tz tinyzc Makefile
	./tinyzc -z4 -g -r cloak.tz > cloak.z4.txt

cloak.z5: cloak.tz tinyzc Makefile
	./tinyzc -z5 -g -r cloak.tz > cloak.z5.txt

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
	
