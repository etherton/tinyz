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
system. The language is much closer to Zilch (Zilf) than Inform. It handles typical verb, direct
object, indirect object with disambiguation but doesn't support really complex manipulation
of multiple objects in one game command.

The major component is tinyzc, the compiler. It produces a story file directly. You can have
it generate a lot of diagnostic output including full disassembly. There is also a separate
story file disassembler, and a reasonably feature complete story interpreter as well. The only
supported platform for the latter is MacOS, but adding Linux support should be trivial, just
creating a new interface file with Linux-specific terminal access. Something similar could
probably also be done for the Windows console. The tools produce and can use Inform DEBF
binary debug information files.

There is also a work-in-progress interpreter that runs on an Apple 2+ or 2e. It requires the
latest version of ACME from SourceForce (https://sourceforge.net/projects/acme-crossass/).
The makefile currently references some external story files not included. The interpreter
uses a fast full-track loader modeled heavily on qboot (https://github.com/peterferrie/qboot).

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

There is also basic preprocessor support. The directives #if, #else, and #endif work anywhere in the
token stream, not necessarily at the line level. #if expects an integer literal, and tests against zero.
The symbols $v4, $v5, and $v8 are defined if the Z-machine version is at least that high. Anything `constant`
can appear here, or values can be passed in on the command line with the `-D` directive.

Language Syntax
---------------
Toplevel declarations include the following:

`constant symbol integer-expression;`\
Defines a symbol having the specified value, which
must evaluate to a compile-time constant.

`attribute {global|object|location} attribute-name;`\
Declares a named attribute. It can
be applied to either any object or location, an object, or a location. Internally all objects
have the $is_object attribute set on them; it is missing on locations.

`property {global|object|location} property-name [wordbit integer-literal];`\Declares a named
property, with scope like attributes. Additionally you can specify any word defined in that
property has the specified value or'd into its dictionary type byte.

`synonym word syn1 [syn2...];`\
Declares that syn1, etc are synonyms for the specified base word.
They are identical for all intents and purposes, and the substitution is done very early in
parsing. Synonyms always have a payload byte of 255, and their actual payload is taken from
the original room once it's been replaced. Synonyms cannot appear anywhere else in the story,
since they would never match.

`global symbol [= integer-expression];`\
Declares a standard integer global, defaults to zero unless an initializer is included.

`global symbol = byte_array(element-count) [{ intializers...}];`\
Declares a global that is initialized with the address of a sized byte array in dynamic memory. You can also declare a
`word_array` this way.

`routine symbol [ params.. ; locals.. ] { statements }`\
Defines a function. In version 3 games,
a routine can accept up to three parameters; others can accept up to seven. The total number
of parameters and locals is fifteen. There must be a single routine named `main` and it cannot
declare any parameters or locals. It defines the entry point for the game.

`action #symbol;`\
Defines an action symbol with no associated syntax. This is useful for fake
actions that are only passed into `before` or `after` handlers.

`action #symbol { phrases.. : routine-name-or-lambda }`\
`action #symbol { phrases.. routine-name : routine-name-or-lambda }`\
`action #symbol { phrases.. routine-name phrases.. routine-name : routine-name-or-lambda }`\
These define the parsing rules. They're searched in order and the first match stops processing.
All phrases that appear in the first part have bit 5 set (verbBit in game source, but the actual
value is hard-coded into the compiler). All words in the second part have bit 4 set (prepBit
in the game source). The phrases in the phrase list should be separated by slashes. Each phrase
can consist of either one or two dictionary words. Note that lexigraphically 'one two' and 'one' 'two'
are identical for all intents and purposes, but the former is clearer. Under the hood, the action
list is built as a large table; implementation details are in `ScanParseTable`.

`{object|location} symbol "short description" [(initial-location)] { decl.. }`\
Declares either an object or a location. The internal declarations can either be attributes, which appear on
their own with a semicolon, or properties, which are a property name, a colon, and its value.
The value of a property can either be an object name, an integer, a string, a lambda or routine name, or one or
more dictionary words (up to four in v3 games, sixteen in others). Internally, a property that
is a string is turned into a routine with a print_ret.

Routine Syntax
--------------
A routine consists of several statements. Statements can incorporate branch expressions and numeric
expressions. All variables declared by a routine are in the brackets at the beginning, both parameters
and locals, which are treated identically by the Z machine.

`if (branch-expr) stmt`\
`if (branch-expr) stmt else stmt`\
`while (branch-expr) stmt`\
`for (opt-initializer;opt-branch-expr;opt-continue) stmt`\
`repeat stmt while (branch-expr);`\
These all define basic flow control. `break` and `continue` can appear inside while, for, and repeat loops.

`{ stmt.. }` This is a block statement.

`varname = expr;`\
`varname[expr] = expr;`\
`varname[[expr]] = expr;`\
These are variable and array assignments. Note that single square brackets always
implies a byte access; double square brackets always implies a word access. This is a common source of errors,
be careful.

`return expr;`\
`rfalse;`\
`rtrue;`\
These all exit the current routine. A return with a constant value of zero or one is internally translated
to an `rfalse` or `rtrue` as appropriate. Note that all branches of any routine must explicitly return. There is
no default, intentionally, so that you have to think about whether you want to return zero or nonzero.

`routine-name (opt-parameter-list);`\
`call expr (opt-parameter-list);`\
These are routine calls. The second form allows indirect calls stored in
a variable and is how the Z machine implements an object-oriented design.

`{quit|restart|show_status|crlf};`\
These are zero-operand Z machine statements.

`{print_addr|print_paddr|remove_obj|print_obj|print_char} expr;`\
These are zero-operand Z machine statements. Note that parentheses are not required.

There are more, but I'm sick of typing.

`++variable;`\
`--variable;`\
These increment or decrement a variable.

`objref GAINS attribute-name;` is an alias for `set_attr`.

`objref LOSES attribute-name;` is an alias for `clear_attr`.

`move objref into objref;` is an alias for `insert_obj`.

`print`, `print_ret`, `print_retf` and `trace integer-literal`\
These all offer extended syntax for printing text. It can be a mixture of 
strings and variables and routine calls. Variables are printed
as numbers (via `print_num`), unless they are preceeded by the `object` keyword, in which case
`print_obj` is used. Routine calls are assumed to display output themselves, and their result
is ignored. If you want a routine call's result to be printed, enclose it in an extra pair
of parentheses. You can also include simple calls like `crlf`, `rfalse`, `rtrue`, `normal`,
`bold`, `italic`, and `reverse`. The latter four set the text style (or do nothing on v3 games).

Branch Expressions
------------------
`expr < expr`\
`expr <= expr`\
`expr > expr`\
`expr >= expr`\
`expr == expr` or `expr is expr`\
`expr <> expr` or `expr isn't expr` or `expr isnt expr`\
These are the standard relational operators.

`iszero expr` or `isfalse expr` or `isz expr`\
`istruth expr` or `isnonzero expr` or `isnz expr`\
These test an expression against zero or nonzero. They are equivalent to `expr is 0` or `expr isn't 0` but with less typing.

`expr &= expr`\
This succeeds if exactly the bits in the second expression are set in the first, and saves a few bytes over `expr & expr isn't 0`.

`expr in {expr[,expr[,expr]]]}`\
This tests whether the first expression is equal to up to three
more expressions (utilizing the VAR form of the @je instruction).

`not branch-expr`\
Negates the sense of the branch expression.

`branch-expr and branch-expr`\
Does a short-circuit logical and. The expression passes only if both
expressions pass. If the first expression fails, the second is not evauated.

`branch-expr or branch-expr`\
Does a short-circuit logical or. It passes immediate if the first expression
passes, without evaluating the second expression. Otherwise, the expression depends solely on the second expression.

`objref {has|hasn't|hasnt} attribute-name`\
Passes if the object has (or does not have) the specified attribute set.

`objref {has|hasn't|hasnt} {child|sibling} [-> variable]`\
Passes if the object has (or does not have) any children or siblings. If the optional variable is included, it will contain the child or sibling object number. Otherwise, the result is written to the scratch variable.

`objref HOLDS objref`\
Passes if the second object's parent is the first object (the @jin instruction).

`once variable`
Passes if variable was previously zero. The variable is incremented either way. This wraps the @inc_chk instruction.

`scan_table(expr,expr,expr[,expr]) -> variable`\
Passes the item is found in the table (and the address of the match
is stored in the variable). If you really don't need the result, just use `scratch` here explicitly.

`read_char`\
Reads a character (V4+ only) and returns its ZSCII value. May appear as a statement or an expression.

`random(expr)`\
Returns a random number from 1 to expr. If expr is negative, it seeds the RNG with the negation of that value.
If expr is zero, the interpreter should seed from a source of entropy (time of day etc). May appear as a
statement or expression, although it only makes sense as a statement if the input is negative or zero.

Numeric Expressions
-------------------
`expr + expr`\
`expr - expr`\
`expr * expr`\
`expr / expr`\
`expr % expr`\
Addition, subtraction, multiplication, division, and modulo. Note there is no unary negation, since the Z machine doesn't include that. Just
subtract from zero if you need that. Note that `a=a-1;` will not parse correctly because `-1` is seen as an 
integer literal. `a=a- 1;` or `a = a - 1;` will work

`expr & expr`\
`expr | expr`\
These are binary operations. There is no xor operation in the Z machine.

`~expr`\
Unary bitwise negation.

`expr << expr`\
`expr >> expr`\
These are logical shifts. They can appear in constant expressions in any Z-machine version, but are illegal at runtime in v3 and v4
targets because the instructions simply don't exist there. There isn't currently an arithmetic (sign preserving) shift.

`objref . property-name`\
This gets the value of a propery as an integer. The property name can be a fixed property name or a variable to indicate
it should use the property index contained in the variable. This wraps the `@get_prop` instruction.

`addrof(objref.property-name)`\
Returns the address of the property blob, or zero if it doesn't exist. This wraps the `@get_prop_addr` instruction.
Use `sizeof` below to determine the size of the property blob.

`sizeof(expr)`\
Returns the size of the property blob at the specified address (most often obtained with `addrof` just above). 
This wraps the `@get_prop_len` instruction.

`(expr)`\
Lets you change evaluation order. Note that since there is a distinct difference between branch expressions and numeric expression, precedence is
a bit different than you might be used to in C-based language. You'll find you need fewer parentheses than you do in C.

`'dictionary-word'`\
Evaluates the the index associated with a particular dictionary word. Up to two words are allowed in action statements, but you must use single words everywhere else.

`` `counted-string` ``\
The supplied string is stored in static memory. If the exact same counted string appears multiple times, it is
only stored once. A counted string evaluates to the address of its length byte, which is followed by the remaining
letters in the string, stored one byte per letter in standard Zscii.

You can also make routine calls (either by name, or indirectly with the `call` operator) and the syntax is identical to in statements.
