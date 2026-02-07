all: tinyzc tinyzterp zdis cloak.z3

tinyzc: opcodes.h header.h tinyz.y debug.h debug.cpp
	bison --debug tinyz.y -v -o tinyz.tab.cpp && clang++ -g -std=c++17 tinyz.tab.cpp debug.cpp -o tinyzc

tinyzterp: opcodes.h header.h machine.h machine.cpp interface_macos.cpp debug.h debug.cpp
	clang++ -std=c++17 -DENABLE_DEBUG=1 machine.cpp interface_macos.cpp debug.cpp -o tinyzterp

zdis: opcodes.h header.h zdis.cpp debug.h debug.cpp
	clang++ -std=c++17 zdis.cpp debug.cpp -o zdis

cloak.z3: cloak.tz tinyzc
	./tinyzc -z3 cloak.tz

run: cloak.z3
	./tinyzterp cloak.z3
	
