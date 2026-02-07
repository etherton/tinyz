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
probably also be done for the Windows console. The tools produce and can use Inform DEBF
binary debug information files.

The Language
============
The compiler is written using Bison and a hand-crafted parser. It runs two passes over the code.
Only objects at global scope are checked (we ignore anything in braces except dictionary words
at this point).  The first pass identifies objects, action names, globals, and dictionary words. 

Between passes we construct the dictionary, assigning each word an ordinal index. This allows 
us to use a smaller instruction format and avoid many extra relocations. 

On the second pass we perform parsing and code generation. Each routine generates a tree of
statements and expressions and generates code directly. We estimate block sizes so that
forward jumps can be small whenever possible. Also, we dead strip code from branches so simple version
checks can elide code here (for example, to hide differences in the text parsing between versions).

After the second pass is done, we assign final addresses to everything and build the Z machine
header. We do some basic routine-level dead stripping here (although dictionary words in dead code will
still exist in the dictionary). A routine with no references is removed, and any functions it called
have their reference counts lowered, which may in turn make them dead code as well. The process
repeats until no new dead code is uncovered.

The language looks a lot like C, mostly because while I admire languges like FORTH and Lisp,
I simply cannot read or write code in anything except standard imperative languages.

Perhaps the most unusual thing about TinyZ is the hard distinction between boolean tests and
expressions. A boolean test can only appear in if or while statements, and always maps directly
to a Z machine branch instruction. I also got tired of spelling hasn't without the apostrophe
so the lexer allows apostrophes in any symbol. Go crazy. A symbol can start with # or $ or
an alphabetic character or underscore, and can contain any alphanumeric character, underscore,
or apostrophe.

Here's a basic routine that demonstrates several things:

```
routine Look [; i r f] {
	if (room hasn't lit)
		print_ret "It's too dark to see anything.";
	r = call room.description();
	if (room has child -> i) {
		repeat {
			if (i isn't Player and i has $is_object and i hasn't scenery) {
				if (once f)
					print "You can also see:^";
				PrintAObj(i); crlf;
			}
		} while (i has sibling -> i);
	}
	return r;
}
```

It accepts no parameters, and declares three locals, all initialized to zero. 'room' is
a global that contains the player's current location and is reflected in the v3 status line.
If the room doesn't have the lit attribute, we print a generic message and return. Otherwise
we query the room's description (which is always a routine, but simple strings resolve to
a print_ret). 

Next, we see if the room has any children; since the get_child instruction can both do a
branch and a store, we leverage that to put the entire test in a single instruction.
For each child, we verify it is not the player, and it's an object and not a location (that
attribute is set by the compiler so that some attributes and properties can overlap).

The `once` construct maps to the inc_chk instruction internally and efficiently tests and
sets a flag in one instruction (relying on the fact that all locals are zero). PrintAObj
uses stream 3 to capture object output to identify whether the object name starts with
a vowel or not.

Then we check for a sibling, store the result, and branch all in one instruction.

Here's the resulting assembly:

```
000ae9 test_attr global0 31 ?b04 [ 4a 10 1f d9 ]
000aed print_ret "It's too dark to see anything." [ b3 11 d9 17 18 03 34 50 09 1a f0 03 34 03 0a 28 06 4f d9 35 d3 b0 b2 ]
000b04 get_prop global0 31 -> TOS [ 51 10 1f 00 ]
000b08 call_vs TOS -> local1 [ e0 bf 00 02 ]
000b0c get_child global0 -> local0 ?~b3b [ a2 10 01 6d ]
000b10 je local0 1 ?b36 [ 41 01 01 e4 ]
000b14 test_attr local0 0 ?~b36 [ 4a 01 00 60 ]
000b18 test_attr local0 3 ?b36 [ 4a 01 03 dc ]
000b1c inc_chk 3 1 ?b2f [ 05 03 01 d1 ]
000b20 print "You can also see:
" [ b2 13 d4 68 08 1a 60 1a 38 50 18 29 45 f4 a7 ]
000b2f call_vs 0xaac local0 -> global3 [ e0 2f 05 56 01 13 ]
000b35 new_line [ bb ]
000b36 get_sibling local0 -> local0 ?b10 [ a1 01 01 bf d7 ]
000b3b ret local1 [ ab 02 ]
000b3d nop [ b4 ]
```

The trailing nop is to align the routine to the story alignment boundary (2 for V3)

The other really different thing about the language is how arrays work. I didn't
care for the "slightly longer arrow" syntax of Inform so I use more traditional
array syntax but put my own irritating spin on it.

To treat any variable as the base address of a byte array, use square brackets.

	j = text_buffer[2];

To treat any variable as the base address of a word array, use double square brackets.

	t = parse_buffer[[3]];

I'm considering adding ways to mark up a variable as being intended as a byte or word
array since getting this wrong is a common source of bugs.

For equality tests you can use == or <>, or `is` or `isnt` or `isn't`.

Builtins that take a zero/one parameter don't require parentheses. Builtins that take
more than one parameter do require parentheses. All routine calls require parentheses.
This is necessary to avoid ambiguities in the Bison grammar.

Z-Machine Instructions to Code
==============================

Statements
----------
@print			`print`\
@print_ret		`print_ret` (which has an implicit rtrue)\
@print_ret		`print_retf` This expands to `print`, new_line, and an rfalse.\
@inc			++var\
@dec			--var\
@set_attr		obj `gains` attribute (or `set_attr`)\
@clear_attr		obj `loses` attribute (or `clear_attr`)\
@insert_obj		`move` obj `into` obj (or `insert_obj`)\
@restart		`restart`\
@quit			`quit`\
@new_line		`crlf`\
@show_status	`show_status`\
@print_addr		`print_addr`\
@print_paddr	`print_paddr`\
@remove_obj		`remove_obj`\
@print_obj		`print_obj`\
@print_num		`print_num`\
@output_stream	`output_stream` or `output_stream2` depending on parameter count\
@read_char		`read_char`

Expressions
-----------
@add			`+`\
@sub			`-`\
@mul			`*`\
@div			`/`\
@mod			`%`\
@not			`~`\
@and			`&`\
@or				`|`\
@get_prop		obj `.` property\
@get_prop_addr	`addrof` `(` obj `.` property_name `)`\
@get_prop_len	`sizeof` `(` expr `)`\

Boolean Expressions
-------------------
@jl				`<` (or `>=` negated)\
@jg				`>` (or `<=` negated)\
@je				`is` or `==` (or `isn't` or `<>` negated)\
@test			`&=` (this one is great to replace & and isn't zero)\
@je				expr `in` {a,b,c} (can test up to three values at once)\
@jz				`isfalse` expr (or `iszero` or `isz`; or `istruth`, `isnonzero`, or `isnz` negated)\
@test_attr		obj `has` (or `hasn't`) attribute\
@get_child		obj `has` (or `hasn't`) `child` `->` dest (store is optional and goes to scratch otherwise)\
@get_sibling	obj `has` (or `hasn't`) `child` `->` dest (store is optional and goes to scratch otherwise)\
@jin			obj `holds` obj\
@inc_chk		`once` var

Note that expr `is` 0 and expr `isn't` 0 (where the right hand size is a constant zero) are already
turned into @jz instead of @je, so `isfalse` etc is just syntactic sugar. Also not that `istruth`
specifically means 'is non zero' and not any particular true value (which is exactly 1).


