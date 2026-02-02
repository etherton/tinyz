What is TinyZ?
=============

It's a compiler for the Infocom Z-machine. The language is close to C but with random
bits of verbosity like in BASIC that you're mostly free to ignore. It's designed to map
very closely to the Z-machine instruction set, which means there is an unusual distinction
between arithmetic expressions and control flow expressions.

The compiler is designed to run on fairly small setups (modern 32 bit embedded systems,
not any 16 bit systems from the 80's) but the actual story output is designed to run
well on very old machines. While it supports v3/v4/v5/v8, its reason for existing is
to really push the limits of v3 stories.

Dictionary words have a single payload byte. The parser is based on a compact rule-based
system. The language is much closer to Zilch than Inform. It handles typical verb, direct
object, indirect object with disambiguation but doesn't support really complex manipulation
of multiple objects in one game command.

The major component is tinyzc, the compiler. It produces a story file directly. You can have
it generate a lot of diagnostic output including full disassembly. There is also a separate
story file disassembler, and a reasonably feature complete story interpreter as well. The only
supported platform for the latter is MacOS, but adding Linux support should be trivial, just
creating a new interface file with Linux-specific terminal access. Something similar could
probably also be done for the Windows console.
