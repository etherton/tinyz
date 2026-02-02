#include <stdio.h>
#include <stdint.h>
// shift groups 1-3, 26 per group. 0 is a space, 1-3 are abbrevations, 
// 4=shift1, 5=shift2, shift2 code 6 means "next 10 bits are a zscii code"
#define DEFAULT_ZSCII_ALPHABET \
	"abcdefghijklmnopqrstuvwxyz" \
	"ABCDEFGHIJKLMNOPQRSTUVWXYZ" \
	"\033\r0123456789.,!?_#'\"/\\-:()"

static const uint8_t opTypes[16+2] = {
	0b0101'1111, // 0x00-0x3F
	0b0101'1111,
	0b0110'1111,
	0b0110'1111,

	0b1001'1111, // 0x40-0x7F
	0b1001'1111,
	0b1010'1111,
	0b1010'1111,

	0b0011'1111, // 0x80-0xBF
	0b0111'1111,
	0b1011'1111,
	0b1111'1111,

	// Remaining entries are all zero to indicate types follow
	0,
	0,
	0,
	0,

	0,
	0
};

// Bits 0-1 are for V1-3, 2-3 are for V4, 4-5 for V5/7/8, 6-7 for V6
const uint8_t St=0b01010101, Br=0b10101010, StBr=0b11111111;
static const uint8_t version_shift[9] = { 0,0,0,0, 2,4,6,4,4 };

static const uint8_t decode[256+32] = {
	// 2OP x 4 (0-0x7F)
	0,Br,Br,Br,Br,Br,Br,Br, St,St,Br,0,0,0,0,St, St,St,St,St,St,St,St,St, St,St,0,0,0,0,0,0,
	0,Br,Br,Br,Br,Br,Br,Br, St,St,Br,0,0,0,0,St, St,St,St,St,St,St,St,St, St,St,0,0,0,0,0,0,
	0,Br,Br,Br,Br,Br,Br,Br, St,St,Br,0,0,0,0,St, St,St,St,St,St,St,St,St, St,St,0,0,0,0,0,0,
	0,Br,Br,Br,Br,Br,Br,Br, St,St,Br,0,0,0,0,St, St,St,St,St,St,St,St,St, St,St,0,0,0,0,0,0,

	// 1OP x 3 (0xF is special; it's St on V1-4, 0 on V5+) (080-0xAF)
	Br,StBr,StBr,St,St,0,0,0, St,0,0,0,0,0,St,0b00000101,
	Br,StBr,StBr,St,St,0,0,0, St,0,0,0,0,0,St,0b00000101,
	Br,StBr,StBr,St,St,0,0,0, St,0,0,0,0,0,St,0b00000101,

	// 0OP (0xB0-0xBF), 0xBE is translated to 0x100 | XOP
	0,0,0,0,0,0b00000110,0b00000110,0, 0,0b01010000,0,0,0,Br,0,Br,
	
	// 2OP, VAR form 0xC0
	0,Br,Br,Br,Br,Br,Br,Br, St,St,Br,0,0,0,0,St, St,St,St,St,St,St,St,St, St,St,0,0,0,0,0,0,

	// VAR misc 0xE0
	St,0,0,0,0b01010000,0,0,St, 0,0b01000000,0,0,St,0,0,0, 0,0,0,0,0,0,St,StBr, St,0,0,0,0,0,0,Br,

	// EXT
	St,St,St,St,St,0,Br,0, 0,St,St,0,St,0,0,0, 0,0,0,St,0,0,0,0, Br,0,0,Br,0,0,0,0
};

/* From the standard:
  $00 -- $1f  long      2OP     small constant, small constant
  $20 -- $3f  long      2OP     small constant, variable
  $40 -- $5f  long      2OP     variable, small constant
  $60 -- $7f  long      2OP     variable, variable
  $80 -- $8f  short     1OP     large constant
  $90 -- $9f  short     1OP     small constant
  $a0 -- $af  short     1OP     variable
  $b0 -- $bf  short     0OP
  except $be  extended opcode given in next byte
  $c0 -- $df  variable  2OP     (operand types in next byte)
  $e0 -- $ff  variable  VAR     (operand types in next byte(s))
  */
 
enum class optype: uint8_t {
	large_constant,		// 2 bytes
	small_constant,		// 1 byte
	variable,			// 1 byte
	omitted
};

enum class _2op: uint8_t { // 0x00 - 0x7F, 0xC0-0xDF
	je=1, jl, jg, dec_chk, inc_chk, jin, test, 
	or_, and_, test_attr, set_attr, clear_attr, store, insert_obj, loadw,
	loadb, get_prop, get_prop_addr, get_next_prop, add, sub, mul, div,
	mod, call_2s, call_2n, set_colour, throw_,
};

enum class _1op: uint8_t { // 0x80 - 0xAF
	jz, get_sibling, get_child, get_parent, get_prop_len, inc, dec, print_addr,
	call_1s, remove_obj, print_obj, ret, jump, print_paddr, load, not_, call_1n=not_
};

enum class _0op: uint8_t { // 0xB0 - 0xBF
	rtrue, rfalse, print, print_ret, nop, save, restore, restart,
	ret_popped, pop, catch_=pop, quit, new_line, show_status, verify, extended, piracy,
	je=17 // Not really a 0op but in the same range.
};

enum class _var: uint8_t { // 0xC0 - 0xDF are VAR forms of 2OP; rest start at 0xE0
	call_vs, storew, storeb, put_prop, sread, print_char, print_num, random,
	push, pull, split_window, set_window, call_vs2, erase_window, erase_line, set_cursor,
	get_cursor, set_text_style, buffer_mode, output_stream, input_stream, sound_effect, read_char, scan_table,
	not_, call_vn, call_vn2, tokenise, encode_text, copy_table, print_table, check_arg_count
};

enum class _ext: uint8_t { // these follow _0op::extended (0xBE)
	save, restore, log_shift, art_shift, set_font, draw_picture, picture_data, erase_picture,
	set_margins, save_undo, restore_undo, print_unicode, check_unicode, set_true_color,
	move_window=16, window_size, window_style, get_wind_prop, scroll_window, pop_stack, read_mouse, mouse_window,
	push_stack, put_wind_prop, print_form, make_menu, picture_table, buffer_screen
};

#if ENABLE_DEBUG
static const char *opcode_names[256+32] = {
	// 00-0x7F
	"?00", "je", "jl", "jg", "dec_chk", "inc_chk", "jin $o $o", "test", "or", "and", "test_attr $o $a", "set_attr $o $a", "clear_attr $o $a", "store", "insert_obj $o $o", "loadw", "loadb", "get_prop $o $p", "get_prop_addr $o $p", "get_next_prop $o $p", "add", "sub", "mul", "div", "mod", "call_2s", "call_2n", "set_colour", "throw", "?1D", "?1E", "?1F",
	"?20", "je", "jl", "jg", "dec_chk", "inc_chk", "jin $o $o", "test", "or", "and", "test_attr $o $a", "set_attr $o $a", "clear_attr $o $a", "store", "insert_obj $o $o", "loadw", "loadb", "get_prop $o $p", "get_prop_addr $o $p", "get_next_prop $o $p", "add", "sub", "mul", "div", "mod", "call_2s", "call_2n", "set_colour", "throw", "?3D", "?3E", "31F",
	"?40", "je", "jl", "jg", "dec_chk", "inc_chk", "jin $o $o", "test", "or", "and", "test_attr $o $a", "set_attr $o $a", "clear_attr $o $a", "store", "insert_obj $o $o", "loadw", "loadb", "get_prop $o $p", "get_prop_addr $o $p", "get_next_prop $o $p", "add", "sub", "mul", "div", "mod", "call_2s", "call_2n", "set_colour", "throw", "?5D", "?5E", "?5F",
	"?60", "je", "jl", "jg", "dec_chk", "inc_chk", "jin $o $o", "test", "or", "and", "test_attr $o $a", "set_attr $o $a", "clear_attr $o $a", "store", "insert_obj $o $o", "loadw", "loadb", "get_prop $o $p", "get_prop_addr $o $p", "get_next_prop $o $p", "add", "sub", "mul", "div", "mod", "call_2s", "call_2n", "set_colour", "throw", "?7D", "?7E", "?7F",

	// 0x80-0xAF
	"jz", "get_sibling $o","get_child $o","get_parent $o","get_prop_len","inc","dec","print_addr","call_1s","remove_obj $o","print_obj $o","ret","jump","print_paddr","load","not/call1n",
	"jz", "get_sibling $o","get_child $o","get_parent $o","get_prop_len","inc","dec","print_addr","call_1s","remove_obj $o","print_obj $o","ret","jump","print_paddr","load","not/call1n",
	"jz", "get_sibling $o","get_child $o","get_parent $o","get_prop_len","inc","dec","print_addr","call_1s","remove_obj $o","print_obj $o","ret","jump","print_paddr","load","not/call1n",

	// 0xB0-0xBF
	"rtrue","rfalse","print","print_ret","nop","save","restore","restart","ret_popped","pop/catch","quit","new_line","show_status","verify","EXT_BE","piracy",

	// 0xC0-0xDF
	"?C0", "je", "jl", "jg", "dec_chk", "inc_chk", "jin $o $o", "test", "or", "and", "test_attr $o $a", "set_attr $o $a", "clear_attr $o $a", "store", "insert_obj $o $o", "loadw", "loadb", "get_prop $o $p", "get_prop_addr $o $p", "get_next_prop$o $p", "add", "sub", "mul", "div", "mod", "call_2s", "call_2n", "set_colour", "throw", "?DD", "?DE", "?DF",

	//0xE0-0xFF
	"call_vs","storew","storeb","put_prop $o $p","sread","print_char","print_num","random","push","pull","split_window","set_window","call_vs2","erase_window","erase_line","set_cursor",
	"get_cursor","set_text_style","buffer_mode","output_stream","input_stream","sound_effect","read_char","scan_table","not","call_vn","call_vn2","tokenise","encode_text","copy_table","print_table","check_arg_count",

	// 0x100-0x1F
	"save","restore","log_shift","art_shift","set_font","draw_picture","picture_data","erase_picture","set_margins","save_undo","restore_undo","print_unicode","check_unicode","ext0D","ext0E","ext0F",
	"move_window","window_size","window_style","get_wind_prop","scroll_window","pop_stack","read_mouse","mouse_window","push_stack","put_wind_prop","print_form","make_menu","picture_table","ext1D","ext1E","ext1F"
};
#endif
