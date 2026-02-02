// clang++ -std=c++17 zdis.cpp -o zdis

#define ENABLE_DEBUG 1
#include "header.h"
#include <stdio.h>
#include <assert.h>

#include "opcodes.h"

const uint8_t storyScales[] = { 0,0,0,2,4,4,0,8,8 };

storyHeader *getStory(const char *storyName) {
	FILE *f = fopen(storyName,"rb");
	fseek(f,0,SEEK_END);
	long size = ftell(f);
	rewind(f);
	storyHeader *story = (storyHeader*) new char[size];
	fread(story,1,size,f);
	fclose(f);
	return story;
}

static const char zscii_default[] = 
	"abcdefghijklmnopqrstuvwxyz"
	"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	"\033\n0123456789.,!?_#'\"/\\-:()";
static const char *zscii = zscii_default;
static word *abbreviations;

void stdio_output_char(void*,uint8_t ch) { putchar(ch); }

static int print_zscii(const uint8_t *b,int addr,void *closure = nullptr,void (*output_char)(void*,uint8_t) = stdio_output_char) {
	uint8_t shift = 0, abbrev = 0;
	uint16_t extended = 0;
	auto printZ = [&](uint8_t ch) {
		assert(ch<32);
		if (abbrev) {
			int inner = abbrev-32+ch;
			abbrev = 0;
			print_zscii(b,abbreviations[inner].getU2(),closure,output_char);
			shift = 0;
		}
		else if (extended) {
			extended = (extended << 5) | ch;
			if (extended > 1023) {
				(*output_char)(closure,extended & 255);
				extended = 0;
			}
		}
		else if (ch==0)
			(*output_char)(closure,32);
		else if (ch<4)
			abbrev = ch * 32;
		else if (ch==4)
			shift = 1;
		else if (ch==5)
			shift = 2;
		else if (shift==2 && ch==6)
			shift = 0, extended = 1;
		else if (shift==2 && ch==7)
			(*output_char)(closure,10);
		else {
			(*output_char)(closure,zscii[shift*26+(ch-6)]);
			shift = 0;
		}
	};
	do {
		printZ((b[addr]>>2) & 31);
		printZ(((b[addr]&3)<<3) | (b[addr+1]>>5));
		printZ(b[addr+1]&31);
		addr+=2;
	} while (!(b[addr-2] & 0x80));
	return addr;
}

static int no_printf(const char*,...) {
	return 0;
}

typedef int (*pf)(const char*,...);

int dis(const storyHeader *h,int pc,pf xprintf = printf) {
	// keep track of the furthest forward branch we've seen.
	// if we encounter an unconditional return and we're at or beyond, we're done.
	// 0b00 - large constant (2 bytes)
	// 0b01 - small constant (1 byte)
	// 0b10 - variable (0=tos, 1-15=local, 16-255=global 1-240)
	// 0b11 - omitted altogether
	int highest = pc;
	int end = h->storyLength.getU() * storyScales[h->version];
	const uint8_t *b = (uint8_t*) h;

	auto varTypes = [](uint8_t t) {
		static char buf[8];
		if (!t)
			snprintf(buf,sizeof(buf),"(sp)");
		else if (t < 16)
			snprintf(buf,sizeof(buf),"L%d",t-1);
		else
			snprintf(buf,sizeof(buf),"G%d",t-16);
		return buf;
	};

	while (pc < end) {
		(*xprintf)("%06x: ",pc);
		uint16_t opcode = b[pc++];
		if (opcode == 0xBE && h->version>=5)
			opcode = 0x100 | b[pc++];
		if (opcode >= 0x120 || opcode_names[opcode][0]=='?') {
			(*xprintf)("[%03x] -- error in disassembly\n",opcode);
			return 0;
		}
		(*xprintf)("[%03x] %s ",opcode,opcode_names[opcode]);

		uint16_t types = opTypes[opcode >> 4] << 8;
		if (!types)
			types = b[pc++] << 8;
		if (opcode==236 || opcode==250)
			types |= b[pc++];
		else
			types |= 255;
		// remember the last op (used for jumps)
		int16_t op = 0;
		while (types != 0xFFFF) {
			op = b[pc++];
			switch (types & 0xC000) {
				case 0x0000: op = (op<<8) | b[pc++]; (*xprintf)("%d ",op); break;
				case 0x4000: (*xprintf)("%d ",op); break;
				case 0x8000: (*xprintf)("%s ",varTypes(op)); break;
			}
			types = (types << 2) | 0x3;
		}
		
		uint8_t decode_byte = decode[opcode] >> version_shift[h->version];
		if (decode_byte & 1)
			(*xprintf)("-> %s ",varTypes(b[pc++]));
		if (decode_byte & 2) {
			int16_t branch_offset = b[pc++];
			bool branch_cond = branch_offset >> 7;
			branch_offset &= 127;
			if (branch_offset & 64)
				branch_offset &= 63;
			else {
				
				if (branch_offset & 32)
					branch_offset |= 0xC0;
				branch_offset = (branch_offset << 8) | b[pc++];
			}
			if (branch_offset==0||branch_offset==1)
				(*xprintf)("?%s%s",branch_cond?"":"~",branch_offset?"rtrue":"rfalse");
			else {
				// track the furthest forward branch we've seen to detect end of routine.
				if (branch_offset > 0 && pc + branch_offset - 2 > highest)
					highest = pc + branch_offset - 2;
				(*xprintf)("?%s%x",branch_cond?"":"~",pc + branch_offset - 2);
			}
		}
		else if (opcode == 0x8C && op > 0 && pc + op - 2 > highest) {
			highest = pc + op - 2;
		}
		if (opcode == 0xB2 || opcode == 0xB3) {
			(*xprintf)("\"");
			pc = print_zscii(b,pc,(void*)xprintf,[](void* p,uint8_t x) { (*(pf)p)("%c",x); });
			(*xprintf)("\"");
		}
		// printf("  ;highest=%06x",highest);
		(*xprintf)("\n");

		// If pc is beyond furthest branch and it's a return/jump/quit, it's end of function
		// note jumps only count here if they're backward.
		if (pc > highest && ((opcode==0x8C&&op<0 /*jump*/) ||
			opcode==0x8B/*ret*/||opcode==0x9B/*ret*/||opcode==0xAB/*ret*/||
			opcode==0xB0/*rtrue*/||opcode==0xB1/*rfalse*/||opcode==0xB3/*print_ret*/||
			opcode==0xB8/*ret_popped*/||opcode==0xBA/*quit*/)) {
			if (opcode!=0xB0 || pc != 0x8497) // deal with orphaned code fragment in zork one
				break;
		}
	}
	return pc;
}

int routine(const storyHeader *h,int pc,pf xprintf = printf) {
	const uint8_t *b = (const uint8_t*) h;
	(*xprintf)("routine at %x, %d locals\n",pc,b[pc]);
	if (h->version < 5 && b[pc]) {
		const word *locals = (const word*)(b + pc + 1);
		(*xprintf)("initial values: ");
		for (int i=0; i<b[pc]; i++)
			(*xprintf)("[%d] ",locals[i].getS());
		(*xprintf)("\n");
		pc += 2 * b[pc];
	}
	return dis(h,pc+1,xprintf);
}

struct object_small {
	uint8_t attributes[4];
	uint8_t parent, sibling, child;
	word properties;
};

struct object_large {
	uint8_t attributes[6];
	word parent, sibling, child, properties;
};

int last_property;

void dump_properties(const storyHeader *h,int addr) {
	const uint8_t *b = (const uint8_t*) h;
	uint8_t tl = b[addr++];
	print_zscii(b,addr);
	printf("]:\n");
	addr += tl+tl;
	if (h->version < 4) {
		for (;;) {
			uint8_t sb = b[addr];
			if (!sb)
				break;
			printf("\tproperty %d is %d bytes\n",sb & 31,(sb >> 5)+1);
			addr = addr + 1 + (sb >> 5) + 1;
		}
	}
	else {
		for (;;) {
			if (!b[addr])
				break;
			uint8_t pn = b[addr++];
			uint8_t ps = pn&128? b[addr++] & 63 : (pn>>6)+1;
			pn &= 63;
			if (ps==0) ps=64; // why wasn't size-1 stored here?
			printf("\tproperty %d is %d bytes\n",pn,ps);
			addr = addr + ps;
		}
	}
	if (addr > last_property)
		last_property = addr;
}

void dump_objects(const storyHeader *h) {
	const word *default_properties = (const word*)((char*)h + h->objectTableAddr.getU());
	int oEnd = 0;
	if (h->version < 4) {
		for (int i=0; i<31; i++) {
			printf("default property %d at %x\n",i+1,default_properties[i].getU());
		}
		const object_small *o = (const object_small*)(default_properties + 31);
		int oEnd = o->properties.getU();
		int i = 1;
		while ((char*)o < (char*)h + oEnd) {
			printf("object %d parent %d, sibling %d, child %d named [",
				i,o->parent,o->sibling,o->child);
			dump_properties(h,o->properties.getU());
			++o,++i;
		}
	}
	else {
		for (int i=0; i<63; i++) {
			printf("default property %d at %x\n",i+1,default_properties[i].getU());
		}
		const object_large *o = (const object_large*)(default_properties + 63);
		int oEnd = o->properties.getU();
		int i = 1;
		while ((char*)o < (char*)h + oEnd) {
			printf("object %d parent %d, sibling %d, child %d named [",i,
				o->parent.getU(),o->sibling.getU(),o->child.getU());
			dump_properties(h,o->properties.getU());
			++o,++i;
		}
	}
}

void dump_dictionary(const storyHeader *h) {
	const uint8_t *b = (const uint8_t*) h;
	int addr = h->dictionaryAddr.getU();
	uint8_t numSep = b[addr++];
	printf("word separators: [");
	for (int i=0; i<numSep; i++)
		printf("%c",b[addr++]);
	printf("]\n");
	uint8_t entrySize = b[addr++];
	int numEntries = ((const word*)(b+addr))->getU();
	addr+=2;
	printf("dictionary has %d entries of %d bytes each:\n",numEntries,entrySize);
	while (numEntries--) {
		printf("\t[");
		print_zscii(b,addr);
		printf("] ");
		for (int i=h->version<4? 4 : 6; i<entrySize; i++)
			printf("%02x",b[addr+i]);
		addr += entrySize;
		printf("\n");
	}
}

int main(int argc,char **argv) {
	storyHeader *story = getStory(argv[1]);
	printf("version %d serial[%c%c%c%c%c%c]\n",story->version,
		story->serial[0],story->serial[1],story->serial[2],story->serial[3],story->serial[4],story->serial[5]);
	abbreviations = (word*)((char*)story + story->abbreviationsAddr.getU());
	if (story->version >= 5 && story->alphabetTableAddress.getU())
		zscii = (char*)story + story->alphabetTableAddress.getU();
	printf("high memory: %x\n",story->highMemoryAddr.getU());
	printf("initial pc: %x\n",story->initialPCAddr.getU());
	printf("dictionary: %x\n",story->dictionaryAddr.getU());
	// dump_dictionary(story);
	printf("globals: %x\n",story->globalVarsTableAddr.getU());
	printf("static memory: %x\n",story->staticMemoryAddr.getU());
	printf("abbreviations: %x\n",story->abbreviationsAddr.getU());
	/* for (int i=0; i<96; i++) {
		printf("[");
		print_zscii((uint8_t*)story,abbreviations[i].getU2());
		printf("]");
	} */
	printf("\nstory length: %x\n",story->storyLength.getU() * storyScales[story->version]);
	dump_objects(story);

	printf("last property at %x\n",last_property);
	auto roundUp = [&](int a) { return (a + storyScales[story->version] - 1) & -storyScales[story->version]; };
	int start = roundUp(story->highMemoryAddr.getU());
	if (start < last_property)
		start = roundUp(last_property);
	start = story->initialPCAddr.getU() - 1;
	int stop = story->storyLength.getU() * storyScales[story->version];
	const uint8_t *b = (const uint8_t*) story;

	int sn = 0;
	while (start < stop) {
		int test;
		if (b[start] > 15 || !(test = routine(story,start,no_printf))) {
			printf("S%d: ",++sn);
			start = roundUp(print_zscii(b,start));
		}
		else
			start = roundUp(routine(story,start));
		printf("\n");
	}
}
