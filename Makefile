all: tinyzc tinyzterp zdis cloak.z3

tinyzc: opcodes.h header.h tinyz.y
	bison --debug tinyz.y -v -o tinyz.tab.cpp && clang++ -g -std=c++17 tinyz.tab.cpp -o tinyzc

tinyzterp: opcodes.h header.h machine.h machine.cpp interface_macos.cpp
	clang++ -std=c++17 -DENABLE_DEBUG=1 machine.cpp interface_macos.cpp -o tinyzterp

zdis: opcodes.h header.h zdis.cpp
	clang++ -std=c++17 zdis.cpp -o zdis

cloak.z3: cloak.tz tinyzc
	./tinyzc cloak.tz

run: cloak.z3
	./tinyzterp cloak.z3
	
