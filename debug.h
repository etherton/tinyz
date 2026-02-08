#include "header.h"

#include <map>
#include <string>

namespace debug {

// file header is 0xDE, 0xBF
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
					// then one string for each local, terminated by a zero byte
	ARRAY_DBR,	// byte_address: word, name: string
	MAP_DBR,	// string/address pairs, terminated by a zero byte
	ROUTINE_END_DBR,// routine_number: word, defn_end: line, next_pc_value: address
};

struct line {
	uint8_t file_number;	// 1-based
	word line_number;
	uint8_t column;
};

struct address {
	uint8_t h,m,l;
};

struct routine_info {
	std::string name;
	uint32_t start, end;
	std::vector<std::string> locals;
};
	
struct debug_info {
	std::map<uint8_t,std::string> files;
	std::map<uint8_t,std::string> attributes;
	std::map<uint8_t,std::string> properties;
	std::map<uint8_t,std::string> globals;
	std::map<uint16_t,std::string> objects;
	std::map<uint16_t,routine_info> routines;
	std::map<uint32_t,uint16_t> addressMappings;	// maps an address to a routine number
	uint8_t header[64];

	bool read(const char*);
	bool write(const char*);
	void dump();
	void resolveAddress(char *dest,size_t destSize,uint32_t address);
	void clear() {
		files.clear();
		attributes.clear();
		properties.clear();
		globals.clear();
		objects.clear();
		routines.clear();
		addressMappings.clear();
		memset(header,0,sizeof(header));
	}
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

} // namespace debug