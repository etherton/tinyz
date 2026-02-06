#include <stdint.h>

namespace debug {

// string is nul-terminated string
// word is 16 bit unsigned, high byte first
// line is four bytes: file number, word line number, character number
// address is three byte address high/med/low order
enum rectype: uint8_t {
	EOF_DBR,	// end of file
	FILE_DBR,	// file_number: byte (from 1), include_name: string, actual_name: string
	CLASS_DBR,	// class_name: string, defn_start: line, defn_end: line
	OBJECT_DBR,	// number: word, name: string, defn_start: line, defn_end: line
	GLOBAL_DBR,	// number: byte, name: string
	ATTR_DBR,	// number: word, name: string
	PROP_DBR,	// number: word, name: string
	FAKE_ACTION_DBR,// number: word, name: string
	ACTION_DBR,	// number: word, name: string
	HEADER_DBR,	// the_header: 64 bytes
	LINEREF_DBR,	// routine_number: word, num_seq_points: word (one line/word for each)
	ROUTINE_DBR,	// routine_number: word, defn_start: line, pc_start: address, name: string
			// then one string for each local
	ARRAY_DBR,	// byte_address: word, name: string
	MAP_DBR,	// string/location pairs, terminated by a zero byte
	ROUTINE_END_DBR,// routine_number: word, defn_end: line, next_pc_value: address
};

/* known structures
	"abbreviations table"
	"header extension"
	"alphabets table"
	"Unicode table"
	"property defaults"
	"object tree"
	"common properties"
	"class numbers"
	"individual properties"
	"global variables"
	"array space"
	"grammar table"
	"actions table"
	"parsing routines"
	"adjectives table"
	"dictionary"
	"code area"
	"strings area"
*/
