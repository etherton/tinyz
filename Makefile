all: tinyzc tinyzcd tinyzterp tinyzterpd zdis cloak.z3

tinyzcd: opcodes.h header.h tinyz.y debug.h debug.cpp Makefile
	bison --debug tinyz.y -v -o tinyz.debug.tab.cpp && clang++ -g -std=c++17 tinyz.debug.tab.cpp debug.cpp -o tinyzcd

tinyzc: opcodes.h header.h tinyz.y debug.h debug.cpp Makefile
	bison tinyz.y -v -o tinyz.tab.cpp && clang++ -std=c++17 -O2 tinyz.tab.cpp debug.cpp -o tinyzc

tinyzterpd: opcodes.h header.h machine.h machine.cpp interface_macos.cpp debug.h debug.cpp Makefile
	clang++ -std=c++17 -g -DENABLE_DEBUG=1 machine.cpp interface_macos.cpp debug.cpp -o tinyzterpd

tinyzterp: opcodes.h header.h machine.h machine.cpp interface_macos.cpp debug.h debug.cpp Makefile
	clang++ -std=c++17 machine.cpp interface_macos.cpp debug.cpp -O2 -o tinyzterp

zdis: opcodes.h header.h zdis.cpp debug.h debug.cpp Makefile
	clang++ -std=c++17 zdis.cpp debug.cpp -o zdis

cloak.z3: cloak.tz tinyzc Makefile
	./tinyzc -z3 -g cloak.tz

run: cloak.z3 Makefile
	./tinyzterp cloak.z3
	
