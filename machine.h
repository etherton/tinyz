#include "header.h"

/*
	Example of a function that takes three parameters and has five locals total
	Stack grows upward to higher addresses (unlike most modern architectures)
	(Not sure this is strictly necessary but I want to behave similarly to other working interpreters)
	Higher addresses
	User stack area <- SP (localCount+3)
	local5
	local4
	local3/param3
	local2/param2
	local1/param1 (LP+3)
	Storage address (or -1 to discard result) (shifted left 4), or'd with number of parameters (0-15)
	Previous LP (lower 13 bits), and upper three bits of return address (upper 3 bits)
	return_address <- LP

	First, we set LP to SP, then push the return address, previous LP, and storage
	address onto the stack, followed by all locals and/or parameters

	When any sort of return is encountered (including a branch to offset 0/1), the result
	is recorded in an internal register. We then fetch the return address and restore LP.
	The return value is then written to the location specified by Storage Address in
	the context of the calling function.
*/

struct chunk { void *data; uint32_t size; };

class interface {
public:
	static char *readStory(const char*,long *sizePtr = nullptr);
	static void init(int,char**);
	static void putchar(int ch);
	static int readchar();
	static void readline(char*dest,unsigned destSize);
	static bool writeSaveData(chunk *chunks,unsigned count);
	static bool readSaveData(chunk *chunks,unsigned count);
	static void setTextStyle(uint8_t);
	static void setTextColor(uint8_t fore,uint8_t back);
	static void setCursor(uint8_t,uint8_t);
	static void setWindow(uint8_t);
	static void eraseWindow(uint8_t);
	static void updateExtents(uint8_t&,uint8_t&);
};

class machine {
public:
	void init(const void*,bool debug);
	void run(uint32_t pc);
	void showStatus();
	void updateExtents();
	void printObjTree();
private:
	// first attribute (zero) is MSB of lowest byte.
	struct object_small {	
		uint8_t attr[4], parent, sibling, child;
		word propAddr;
		bool testAttribute(uint16_t a) const {
			return (attr[a >> 3] & (0x80 >> (a & 7))) != 0;
		}
		void setAttribute(uint16_t a) {
			attr[a >> 3] |= (0x80 >> (a & 7));
		}
		void clearAttribute(uint16_t a) {
			attr[a >> 3] &= ~(0x80 >> (a & 7));
		}
	};
	struct object_large {
		uint8_t attr[6];
		word parent, sibling, child, propAddr;
		bool testAttribute(uint16_t a) const {
			return (attr[a >> 3] & (0x80 >> (a & 7))) != 0;
		}
		void setAttribute(uint16_t a) {
			attr[a >> 3] |= (0x80 >> (a & 7));
		}
		void clearAttribute(uint16_t a) {
			attr[a >> 3] &= ~(0x80 >> (a & 7));
		}
		/* Either both size bytes have bit 7 set (bits 0-5 of first byte are prop number, bits 0-5 of second
			byte are the prop size, in bytes, with 0 meaning 64 bytes) or there is a single size byte with bit
			7 clear, 0-5 contain the property number, and bit 6 clear means size=1, bit 6 set means size=2 */
	};
	struct object_header_small {
		word defaultProps[31];
		object_small objTable[0];
	};
	struct object_header_large {
		word defaultProps[63];
		object_large objTable[0];
	};
	uint32_t print_zscii(uint32_t addr);
	void printz(uint8_t ch);
	void print_char(uint8_t ch);
	void finishChar(uint8_t ch);
	void print_num(int16_t v);
	uint8_t m_abbrev, m_shift;
	uint16_t m_extended;
	bool objIsChildOf(uint16_t o1,uint16_t o2) const {
		if (!o1 || o1 > m_objCount)
			fault("jin first object %d out of range",o1);
		if (o2 > m_objCount)
			fault("jin second object %d out of range",o2);
		return o2 == (m_header->version<4
				? m_objectSmall->objTable[o1-1].parent 
				: m_objectLarge->objTable[o1-1].parent.getU());

	}
	bool objTestAttribute(uint16_t o,uint16_t attr) const {
		if (!o || o > m_objCount)
			fault("test_attr object %d out of range",o);
		if (attr >= (m_header->version<4? 32 : 48))
			fault("test_attr attribute %d out of range",attr);
		return m_header->version < 4
			? m_objectSmall->objTable[o-1].testAttribute(attr)
			: m_objectLarge->objTable[o-1].testAttribute(attr);
	}
	void objSetAttribute(uint16_t o,uint16_t attr) {
		if (!o || o > m_objCount)
			fault("set_attr object %d out of range",o);
		if (attr >= (m_header->version<4? 32 : 48))
			fault("set_attr attribute %d out of range",attr);
		return m_header->version < 4
			? m_objectSmall->objTable[o-1].setAttribute(attr)
			: m_objectLarge->objTable[o-1].setAttribute(attr);
	}
	void objClearAttribute(uint16_t o,uint16_t attr) {
		if (!o || o > m_objCount)
			fault("clear_attr object %d out of range",o);
		if (attr >= (m_header->version<4? 32 : 48))
			fault("clear_attr attribute %d out of range",attr);
		return m_header->version < 4
			? m_objectSmall->objTable[o-1].clearAttribute(attr)
			: m_objectLarge->objTable[o-1].clearAttribute(attr);
	}
	void objUnparent(uint16_t o) {
		if (!o || o>m_objCount)
			fault("remove_obj object %d out of range",o);
		if (m_header->version < 4) {
			uint8_t p = m_objectSmall->objTable[o-1].parent;
			uint8_t s = m_objectSmall->objTable[o-1].sibling;
			if (p && m_objectSmall->objTable[p-1].child == o)
				m_objectSmall->objTable[p-1].child = s;
			// scan entire object table to find dangling sibling reference (parent may be zero)
			else for (uint16_t i=1; i<=m_objCount; i++)
				if (m_objectSmall->objTable[i-1].sibling == o) {
					m_objectSmall->objTable[i-1].sibling = s;
					break;
				}
			m_objectSmall->objTable[o-1].parent = 0;
			m_objectSmall->objTable[o-1].sibling = 0;
		}
		else {
			word p = m_objectLarge->objTable[o-1].parent;
			word s = m_objectLarge->objTable[o-1].sibling;
			if (p.notZero() && m_objectLarge->objTable[p.getU()-1].child.getU() == o)
				m_objectLarge->objTable[p.getU()-1].child = s;
			// scan entire object table to find dangling sibling reference (parent may be zero)
			else for (uint16_t i=1; i<=m_objCount; i++)
				if (m_objectLarge->objTable[i-1].sibling.getU() == o) {
					m_objectLarge->objTable[i-1].sibling = s;
					break;
				}
			m_objectLarge->objTable[o-1].parent.setByte(0);
			m_objectLarge->objTable[o-1].sibling.setByte(0);
		}
	}
	void objMoveTo(uint16_t o1,uint16_t o2) {
		objUnparent(o1);
		if (!o2 || o2>m_objCount)
			fault("move_obj destination %d out of range",o2);
		if (m_header->version < 4) {
			m_objectSmall->objTable[o1-1].parent = o2;
			m_objectSmall->objTable[o1-1].sibling = m_objectSmall->objTable[o2-1].child;
			m_objectSmall->objTable[o2-1].child = o1;
		}
		else {
			m_objectLarge->objTable[o1-1].parent.set(o2);
			m_objectLarge->objTable[o1-1].sibling = m_objectLarge->objTable[o2-1].child;
			m_objectLarge->objTable[o2-1].child.set(o1);
		}
	}
	static uint8_t zeroIs64(uint8_t f) { return f? f : 64; }
	word objGetProperty(uint16_t o,uint16_t prop) const {
		if (!o || o>m_objCount)
			fault("get_prop object %d out of range",o);
		if (!prop || prop>(m_header->version<4? 31 : 63))
			fault("get_prop property index %d out of range",prop);
		// this is the only one that returns a default property if it's not present
		// properties are stored in descending order.
		if (m_header->version < 4) {
			uint16_t pa = m_objectSmall->objTable[o-1].propAddr.getU();
			// skip object description
			pa += 1 + (read_mem8(pa)<<1);
			for(;;) {
				uint8_t pv = read_mem8(pa++);
				if ((pv & 31) < prop)
					return m_objectSmall->defaultProps[prop-1];
				else if ((pv & 31) == prop) {
					if (!(pv >> 5))
						return byte2word(read_mem8(pa));
					else if ((pv>>5)==1)
						return read_mem16(pa);
					else
						fault("attempted to call get_prop on property that is %d bytes",(pv>>5)+1);
				}
				pa += 1 + (pv>>5);
			} 
		}
		else {
			uint16_t pa = m_objectLarge->objTable[o-1].propAddr.getU();
			// skip object description
			pa += 1 + (read_mem8(pa)<<1);
			for(;;) {
				uint8_t pv = read_mem8(pa++);
				uint8_t pn = (pv & 63);
				uint8_t ps = (pv & 128)? zeroIs64(read_mem8(pa++) & 63) : pv & 64? 2 : 1;
				if (pn < prop)
					return m_objectLarge->defaultProps[prop-1];
				else if (pn == prop) {
					if (ps==1)
						return byte2word(read_mem8(pa));
					else if (ps==2)
						return read_mem16(pa);
					else
						fault("attempted to call get_prop on property that is %d bytes",ps);
				}
				pa += ps;
			} 
		}
	}
	word objGetPropertyAddr(uint16_t o,uint16_t prop) const {
		if (!o || o>m_objCount)
			fault("get_prop_addr object %d out of range",o);
		if (!prop || prop>(m_header->version < 4? 31 : 63))
			fault("get_prop_addr property index %d out of range",prop);
		// properties are stored in descending order.
		if (m_header->version < 4) {
			uint16_t pa = m_objectSmall->objTable[o-1].propAddr.getU();
			// skip object description
			pa += 1 + (read_mem8(pa)<<1);
			for(;;) {
				uint8_t pv = read_mem8(pa++);
				if ((pv & 31) < prop)
					return byte2word(0);
				else if ((pv & 31) == prop)
					return word2word(pa);
				pa += 1 + (pv >> 5);
			}
		}
		else {
			uint16_t pa = m_objectLarge->objTable[o-1].propAddr.getU();
			// skip object description
			pa += 1 + (read_mem8(pa)<<1);
			for(;;) {
				uint8_t pv = read_mem8(pa++);
				uint8_t pn = (pv & 63);
				uint8_t ps = (pv & 128)? zeroIs64(read_mem8(pa++) & 63) : pv & 64? 2 : 1;
				if (pn < prop)
					return byte2word(0);
				else if (pn == prop)
					return word2word(pa);
				pa += ps;
			}
		}
	}
	void objSetProperty(uint16_t o,uint16_t prop,word value) {
		word pa = objGetPropertyAddr(o,prop);
		if (pa.notZero()) {
			uint8_t pl;
			if (m_header->version < 4)
				pl = (read_mem8(pa.getU()-1)>>5) + 1;
			else {
				uint8_t pv = read_mem8(pa.getU()-1);
				pl = (pv & 128)? zeroIs64(pv & 63) : pv & 64? 2 : 1;
			}
			if (pl==1)
				write_mem8(pa.getU(),value.lo);
			else if (pl==2)
				write_mem16(pa.getU(),value);
			else
				fault("attempted to put_prop a property of size %d",pl);
		}
		else
			fault("put_prop failed on missing property");
	}
	word objGetNextProperty(uint16_t o,uint16_t prop) const {
		// given a property number (or zero for first property) return the NEXT property number (or zero)
		// properties are in descending numerical order, so if we're searching for N and find something
		// less than N, it's not present.
		if (!o||o>m_objCount)
			fault("get_next_prop invalid object number %d",o);
		if (m_header->version < 4) {
			uint16_t pa = m_objectSmall->objTable[o-1].propAddr.getU();
			// skip object description
			pa += 1 + (read_mem8(pa)<<1);
			for(;;) {
				uint8_t pv = read_mem8(pa);
				if (!prop || (pv & 31) < prop)
					return byte2word(pv & 31);
				else if (!pv)
					return byte2word(0);
				pa += 2 + (pv>>5);
			}
		}
		else {
			uint16_t pa = m_objectLarge->objTable[o-1].propAddr.getU();
			// skip object description
			pa += 1 + (read_mem8(pa)<<1);
			for(;;) {
				uint8_t pv = read_mem8(pa++);
				uint8_t pn = pv & 63;
				uint8_t pl = (pv & 128)? zeroIs64(read_mem8(pa++) & 63) : pv & 64? 2 : 1;
				if (!prop || pn < prop)
					return byte2word(pn);
				else if (!pn)
					return byte2word(0);
				pa += pl;
			}
		}
	}
	word objGetPropertyLen(uint16_t propAddr) const {
		if (!propAddr)
			return byte2word(0);
		else if (m_header->version < 4)
			return byte2word((read_mem8(propAddr-1) >> 5)+1);
		else {
			uint8_t pv = read_mem8(propAddr-1);
			return byte2word((pv & 128)? zeroIs64(pv & 63) : pv & 64? 2 : 1);
		}
	}
	word objGetSibling(uint16_t o) const {
		if (!o || o>m_objCount)
			fault("get_sibling object %d out of range",o);
		return m_header->version < 4
			? byte2word(m_objectSmall->objTable[o-1].sibling)
			: m_objectLarge->objTable[o-1].sibling;				
	}
	word objGetChild(uint16_t o) const {
		// theatre.z5 might have a bug in it?
		if (!o)
			return byte2word(0);
		if (/*!o ||*/ o>m_objCount)
			fault("get_child object %d out of range",o);
		return m_header->version < 4
			? byte2word(m_objectSmall->objTable[o-1].child)
			: m_objectLarge->objTable[o-1].child;		
	}
	word objGetParent(uint16_t o) const {
		if (!o || o>m_objCount)
			fault("get_parent object %d out of range",o);
		return m_header->version < 4
			? byte2word(m_objectSmall->objTable[o-1].parent)
			: m_objectLarge->objTable[o-1].parent;
	}

	void objPrint(uint16_t o) {
		if (!o || o>m_objCount)
			fault("print_obj object %d out of range",o);	
		uint16_t pa = m_header->version<4? m_objectSmall->objTable[o-1].propAddr.getU() : m_objectLarge->objTable[o-1].propAddr.getU();
		if (read_mem8(pa))
			print_zscii(pa+1);	
	}

	uint8_t read_mem8(uint32_t addr) const {
		if (addr >= m_readOnlySize)
			memfault("out of range address %x (highest is %x)",addr,m_readOnlySize);
		return addr < m_dynamicSize? m_dynamic[addr] : m_readOnly[addr];
	}
	word read_mem16(uint32_t addr) const {
		if (addr >= m_readOnlySize)
			memfault("out of range address %x (highest is %x)",addr,m_readOnlySize);
		return addr+1 < m_dynamicSize? *(word*)(m_dynamic+addr) : *(word*)(m_readOnly+addr);
	}
	void write_mem8(uint32_t addr,uint8_t v) {
		if (addr>=m_dynamicSize)
			memfault("out of range write to %06x",addr);
		if (addr < 0x38 && addr != 0x10 && addr != 0x11)
			memfault("illegal write to header addr %02x",addr);
		m_dynamic[addr] = v;
	}
	void write_mem16(uint32_t addr,word v) {
		if (addr+1>=m_dynamicSize)
			memfault("out of range write to %06x",addr);
		if (addr < 0x38 && addr != 0x10)
			memfault("illegal write to header addr %02x",addr);
		m_dynamic[addr] = v.hi;
		m_dynamic[addr+1] = v.lo;
	}
	
	word &ref(int v,bool write) {
		if (v<0||v>255)
			fault("invalid reference %d",v);
		if (!v) {
			if (write)
				return m_stack[m_sp++];
			else
				return m_stack[--m_sp];
		}
		else if (v < 16)
			return m_stack[m_lp + v + 2];
		else
			return *(word*)(m_dynamic + m_globalsOffset + (v-16)*2);
	}
	word &var(int v) {
		if (v<0||v>255)
			fault("invalid variable %d",v);
		else if (!v) {
			if (!m_sp)
				fault("variable reference on empty stack");
			return m_stack[m_sp-1];
		}
		else if (v < 16)
			return m_stack[m_lp + v + 2];
		else
			return *(word*)(m_dynamic + m_globalsOffset + (v-16)*2);
	}
	bool scanTable(uint8_t dest,word x,uint16_t table,uint16_t len,uint8_t form) {
		if (form & 0x80) {
			form &= 0x7F;
			for (uint16_t i=0; i<len; i++,table+=form)
				if (read_mem16(table)==x) {
					ref(dest,true) = word2word(table);
					return true;
				}
		}
		else {
			for (uint16_t i=0; i<len; i++,table+=form)
				if (read_mem8(table)==x.lo) {
					ref(dest,true) = word2word(table);
					return true;
				}
		}
		return false;
	}
	void printTable(uint16_t zsciiAddr,uint16_t width,uint16_t height,uint16_t skip);
	void copyTable(uint16_t first,uint16_t second,int16_t count);
	void push(word w) {
		if (m_sp == kStackSize)
			fault("stack overflow in push");
		m_stack[m_sp++] = w;
	}
	word pop() {
		if (m_sp == 0)
			fault("stack underflow in pop");
		return m_stack[--m_sp];
	}
	// return value of both is new pc value.
	uint32_t call(uint32_t pc,int dest,word operands[],uint8_t opCount);
	uint32_t r_return(uint16_t v);
	[[noreturn]] void fault(const char*,...) const;
	[[noreturn]] void memfault(const char*,...) const;
	void setWindow(uint8_t w);
	void setCursor(uint8_t x,uint8_t y);
	void setOutput(int enable,uint16_t tableAddr);
	void flushMainWindow();
	bool saveGame(uint32_t&,int&);
	bool restoreGame(uint32_t&,int&);
	union {
		const uint8_t *m_readOnly; 	// can be in flash etc or memory mapped file
		const storyHeader *m_header;	
	};
	union {
		object_header_small *m_objectSmall;
		object_header_large *m_objectLarge;
	};
	void encode_text(word dest[],const char *src,uint8_t wordLen);
	uint8_t read_input(uint16_t textAddr,uint16_t parseAddr);
	uint8_t tokenise(uint16_t textAddr,uint16_t parseAddr,uint8_t offset = 2);
	uint16_t encodeDelta(uint32_t pc,uint8_t *buffer);
	uint32_t applyDelta(const uint8_t *buffer);
	uint8_t *m_dynamic;		// everything up to 'static' cutoff
	static const uint16_t kStackSize = 2048; // 1<<13 (8192) is largest possible value
	uint16_t m_sp, m_lp;
	word m_stack[kStackSize];
	uint8_t m_undoBuffer[4096];
	uint16_t m_undoTop;
	char m_zscii[26*3];
	char m_lineBuffer[256];
	uint16_t m_dynamicSize, m_globalsOffset, m_abbreviations, m_objCount;
	uint32_t m_readOnlySize;
	uint32_t m_faultpc;
	uint32_t m_routinesOffset, m_staticStringOffset;
	uint16_t m_outputBuffer;
	uint8_t m_storyShift;
	uint8_t m_debug;
	uint8_t m_printed;
	uint8_t m_stored;
	uint8_t m_windowSplit;
	uint8_t m_outputEnables;
	uint8_t m_cursorX, m_cursorY;
	uint8_t m_saveX, m_saveY;
	uint8_t m_currentWindow;
};
