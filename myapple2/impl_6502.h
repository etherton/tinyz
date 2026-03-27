#define ASSEMBLER 0
#define DEBUGGER 1

#include <assert.h>
#include <ctype.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

typedef signed char s8;
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long u64;

struct generic_6502 {
    generic_6502(): cpu_cycles(0), pc(0), a(0), x(0), y(0), s(0xff), p(0) {
#if DEBUGGER
        singlestep = trace = false;
        bpaddr = bpraddr = bpwaddr = ~0U;
#endif
        interrupt = false;
        non_maskable_interrupt = false;
    }
	u32 cpu_cycles;
	u16 pc;
	u8 a, x, y, s, p;
    bool interrupt, non_maskable_interrupt;
	// enum { C, Z, I, D, B, X, V, S };
	enum { CF = 0x01, ZF = 0x02, IF = 0x04, DF = 0x08, VF = 0x40, SF = 0x80 };
#if ASSEMBLER || DEBUGGER
	void disassemble(u16 pc,int len,bool verbose);
	u16 disassemble_insn(char *dest,size_t destSize,u16 pc,bool mem) const;
#if USE_SDL
    SDL_Window *window;
#endif
    u32 bpaddr, bpraddr, bpwaddr;
    mutable bool singlestep, trace;
#endif
	void add_with_carry(u8 v) {
		int sum;
		if (p & DF)
		{
			sum = (a & 0xF) + (v & 0xF) + (p & CF);
			if (sum > 0x09)
				sum += 0x06;
			sum += (a & 0xF0) + (v & 0xF0);
			if (sum > 0x99)
				sum += 0x60;
			// carry will be set correctly by the common epilogue below.
		}
		else
			sum = a + v + (p & CF);
		p = (p & ~(SF|VF|ZF|CF)) | ((sum >> 8) & CF) |
			((sum & 255)? 0 : ZF) | (sum & SF) | 
			(((a ^ sum) & (v ^ sum) & SF) >> 1);	// if the sign of the sum is opposite both inputs, we had overflow
		a = sum & 255;
	}
	void subtract_with_carry(u8 v) {
		int diff;
		if (p & DF)
		{
			diff = (a & 0xF) - (v & 0xF) - 1 + (p & CF);
			int halfCarry = 0;
			if (diff < 0)
			{
				diff += 10;
				halfCarry = 0x10;
			}
			diff += (a & 0xF0) - (v & 0xF0) - halfCarry;
			if (diff < 0)
				diff += 0x1A0;		// underflow, no carry
			// carry will be set correctly by the common epilogue below.
			// printf("[%d] %02x - %02x = %03x\n",p&CF,a,v,diff);
		}
		else
			diff = a - v - 1 + (p & CF);
		p = (p & ~(SF|VF|ZF|CF)) | (((diff >> 8) & CF) ^ CF) |
			((diff & 255)? 0 : ZF) | (diff & SF) | 
			(((a ^ diff) & (v ^ diff) & SF) >> 1);	// if the sign of the sum is opposite both inputs, we had overflow
		a = diff & 255;
	}

	void fault();

	virtual u8 read_byte(u16 addr) const = 0; // like read, but with no cycle counts or bankswitching
	virtual void write_byte(u16 addr,u8 value) = 0;
    virtual const char *resolve_symbol(u16 addr) const = 0;

	u16 read_word(u16 addr) const {
		return read_byte(addr) | (read_byte(addr+1)<<8);
	}
	virtual void cpu_cycle() = 0;
	u8 read(u16 addr) {
		cpu_cycle();
		return read_byte(addr);
	}
	u8 readzp(u8 addr) { 
		return read(addr); 
	}
	void write(u16 addr,u8 value) {
		cpu_cycle();	// TODO - should it be here or at the end of the function?
#if DEBUGGER && 0
		if (addr == bwaddr && (bwval == -1 || value == bwval)) {
			printf("breakpoint on write to %x, value %x\n",bwaddr,value);
			singlestep = true;
		}
#endif
		write_byte(addr,value);
	}

	u8 fetch() { 
		return read(pc++); 
	}	// one cycle
	u8 fetch_add(u8 val) {	// two cycles
		u8 result = fetch() + val;		
		cpu_cycle();
		return result;
	}
	u16 fetch_absolute() { // two cycles
		u16 r = fetch(); 
		return r | (fetch() << 8); 
	}
	u16 fetch_indirect(u8 zpaddr) {	 // two cycles
		u16 r = readzp(zpaddr); 
		return r | (readzp(zpaddr+1)<<8); 
	}
	void add_index_with_page_crossing_penalty(u16 &ea,u8 xy) {
		if ((ea & 0xFF00) != ((ea + xy) & 0xFF00))
			cpu_cycle();
		ea += xy;
	}
	void add_index_for_write(u16 &ea,u8 xy) {
		cpu_cycle();
		ea += xy;
	}

	void push(u8 v) { 
		write(0x100|s,v); 
		--s; 
	}	// 1 cycle
	u8 pull() { 
		++s; 
		return read(0x100|s); 
	}	// 1 cycle

	u8 rotate_right(u8 cin,u8 value) {
		p = (p & ~CF) | (value & CF);
		return (cin << 7) | (value >> 1);
	}
	u8 rotate_left(u8 value,u8 cin) {
		p = (p & ~CF) | ((value >> 7) & CF);
		return cin | (value << 1);
	}

	void exec();
};

// reset vector is at 0xFFFC

#define UPDATE_SZ(v) (p = (p & ~(SF|ZF)) | ((v) & SF) | ((v)? 0 : ZF))		// set S and Z
#define UPDATE_CMP(reg,val)	\
	(p = (p & ~(CF|ZF|SF)) | ((reg>=val)?CF:0) | ((reg==val)?ZF:0) | ((reg-val)&SF))

inline int different_page(u16 pa,u16 pb) { return (pa>>8)!=(pb>>8); }

// all instructions have a base of two cycles (from the insn fetch and the final read done later)
// fetch +1; fetch_add +2; fetch_indirect +2; fetch_absolute +2.
// add_index_with_page_crossing_penalty +0/+1.
// READ's that cross a page boundary (addr),y or addr16,[xy] take an extra cycle.
#define EA_RD_zero_page_direct()		ea=fetch()						// 3 cycles
#define EA_RD_immediate()												// 2 cycles
#define EA_RD_accumulator()												// 2 cycles
#define EA_RD_zero_page_indexed_x()		ea=fetch_add(x)					// 4 cycles
#define EA_RD_zero_page_indexed_y()		ea=fetch_add(y)					// 4 cycles
#define EA_RD_preindexed_indirect_x()	ea=fetch_indirect(fetch_add(x))		// 6 cycles
#define EA_RD_postindexed_indirect_y()	ea=fetch_indirect(fetch()),add_index_with_page_crossing_penalty(ea,y)	// 5+1 cycles
#define EA_RD_extended_direct()			ea=fetch_absolute()					// 4 cycles
#define EA_RD_absolute_indexed_x()		(ea=fetch_absolute(),add_index_with_page_crossing_penalty(ea,x))		// 4+1 cycles
#define EA_RD_absolute_indexed_y()		(ea=fetch_absolute(),add_index_with_page_crossing_penalty(ea,y))		// 4+1 cycles

// No page crossing penalty here.  Base of two cycles (for the insn fetch and final write done later)
// fetch +1; fetch_add +2; indirect +2; absolute +2.
// add_index_for_write +1
#define EA_WR_zero_page_direct()		ea=fetch()			// 3 cycles
// #define EA_WR_immediate()								// 2 cycles
#define EA_WR_accumulator()									// 2 cycles
#define EA_WR_zero_page_indexed_x()		ea=fetch_add(x)		// 4 cycles
#define EA_WR_zero_page_indexed_y()		ea=fetch_add(y)		// 4 cycles
#define EA_WR_preindexed_indirect_x()	ea=fetch_indirect(fetch_add(x))	// 6 cycles
#define EA_WR_postindexed_indirect_y()	ea=fetch_indirect(fetch()),add_index_for_write(ea,y)	// 6 cycles
#define EA_WR_extended_direct()			ea=fetch_absolute()								// 4 cycles
#define EA_WR_absolute_indexed_x()		ea=fetch_absolute(),add_index_for_write(ea,x)		// 5 cycles
#define EA_WR_absolute_indexed_y()		ea=fetch_absolute(),add_index_for_write(ea,y)		// 5 cycles

// No page crossing penalty here; base of three cycles (insn fetch, initial read, and final write)
#define EA_RW_zero_page_direct()		ea=fetch(),cpu_cycle()			// 5 cycles
#define EA_RW_accumulator()												// 2 cycles (READ_accumulator costs no cycles)
#define EA_RW_zero_page_indexed_x()		ea=fetch_add(x),cpu_cycle()		// 6 cycles
#define EA_RW_extended_direct()			ea=fetch_absolute(),cpu_cycle()		// 6 cycles
#define EA_RW_absolute_indexed_x()		ea=fetch_absolute(),add_index_for_write(ea,x),cpu_cycle()		// 7 cycles

// Note that all reads here consume a cycle (except for accumulator) by virtue of calling read or fetch.
#define READ_zero_page_direct()			(read(ea))
#define READ_immediate()				(fetch())
#define READ_accumulator()				(a)
#define READ_zero_page_indexed_x()		(read(ea))
#define READ_zero_page_indexed_y()		(read(ea))
#define READ_preindexed_indirect_x()	(read(ea))
#define READ_postindexed_indirect_y()	(read(ea))
#define READ_extended_direct()			(read(ea))
#define READ_absolute_indexed_x()		(read(ea))
#define READ_absolute_indexed_y()		(read(ea))

// All writes here consume a cycle (everything but accumulator)
#define WRITE_zero_page_direct(v)		(write(ea,(v)))
#define WRITE_accumulator(v)			(cpu_cycle(),(a = (v)))
#define WRITE_zero_page_indexed_x(v)	(write(ea,(v)))
#define WRITE_zero_page_indexed_y(v)	(write(ea,(v)))
#define WRITE_preindexed_indirect_x(v)	(write(ea,(v)))
#define WRITE_postindexed_indirect_y(v)	(write(ea,(v)))
#define WRITE_extended_direct(v)		(write(ea,(v)))
#define WRITE_absolute_indexed_x(v)		(write(ea,(v)))
#define WRITE_absolute_indexed_y(v)		(write(ea,(v)))

#define I_LDA(am) EA_RD_##am(); a = READ_##am(); UPDATE_SZ(a)
#define I_STA(am) EA_WR_##am(); WRITE_##am(a)
#define I_LDX(am) EA_RD_##am(); x = READ_##am(); UPDATE_SZ(x)
#define I_STX(am) EA_WR_##am(); WRITE_##am(x)
#define I_LDY(am) EA_RD_##am(); y = READ_##am(); UPDATE_SZ(y)
#define I_STY(am) EA_WR_##am(); WRITE_##am(y)
#define I_ADC(am) EA_RD_##am(); t8 = READ_##am(); add_with_carry(t8)
#define I_AND(am) EA_RD_##am(); a &= READ_##am(); UPDATE_SZ(a)
#define I_BIT(am) EA_RD_##am(); t8 = READ_##am(); p = (p & ~(SF|VF|ZF)) | (t8 & (SF|VF)) | ((t8&a)? 0 : ZF)
#define I_CMP(am) EA_RD_##am(); t8 = READ_##am(); UPDATE_CMP(a,t8)
#define I_EOR(am) EA_RD_##am(); a ^= READ_##am(); UPDATE_SZ(a)
#define I_ORA(am) EA_RD_##am(); a |= READ_##am(); UPDATE_SZ(a)
#define I_SBC(am) EA_RD_##am(); t8 = READ_##am(); subtract_with_carry(t8)
#define I_INC(am) EA_RW_##am(); t8 = READ_##am() + 1; WRITE_##am(t8); UPDATE_SZ(t8)
#define I_DEC(am) EA_RW_##am(); t8 = READ_##am() - 1; WRITE_##am(t8); UPDATE_SZ(t8)
#define I_CPX(am) EA_RD_##am(); t8 = READ_##am(); UPDATE_CMP(x,t8)
#define I_CPY(am) EA_RD_##am(); t8 = READ_##am(); UPDATE_CMP(y,t8)
#define I_ROL(am) EA_RW_##am(); t8 = READ_##am(); t8 = rotate_left(t8,p & 1); WRITE_##am(t8); UPDATE_SZ(t8)
#define I_ROR(am) EA_RW_##am(); t8 = READ_##am(); t8 = rotate_right(p & 1,t8); WRITE_##am(t8); UPDATE_SZ(t8)
#define I_ASL(am) EA_RW_##am(); t8 = READ_##am(); t8 = rotate_left(t8,0); WRITE_##am(t8); UPDATE_SZ(t8)
#define I_LSR(am) EA_RW_##am(); t8 = READ_##am(); t8 = rotate_right(0,t8); WRITE_##am(t8); UPDATE_SZ(t8)
#define BRANCH_0(op,cyc,flag) r8 = (s8)fetch(); if (!(p & flag)) { if (different_page(pc,pc+r8)) cpu_cycle(); pc += r8; cpu_cycle(); }
#define BRANCH_1(op,cyc,flag) r8 = (s8)fetch(); if (p & flag) { if (different_page(pc,pc+r8)) cpu_cycle(); pc += r8; cpu_cycle(); }

#define I_LAX(am) EA_RD_##am(); a = x = READ_##am(); UPDATE_SZ(a)
#define I_SAX(am) EA_WR_##am(); WRITE_##am(a & x)
#define I_DCP(am) EA_RW_##am(); t8 = READ_##am() - 1; WRITE_##am(t8); UPDATE_CMP(a,t8)
#define I_ALR(am) EA_RD_##am(); t8 = a & READ_##am(); t8 = rotate_right(0,t8); UPDATE_SZ(a)
#define I_AXS(am) EA_RD_##am(); t8 = READ_##am(); x &= a; UPDATE_CMP(x,t8);  x -= t8;

#if DEBUGGER
#define OPC(opc,cyc,am)			I_##opc(am);expected_cycles=cyc
#define IMPL(opc,cyc,am,code)	code;expected_cycles=cyc
#else
#define OPC(opc,cyc,am)			I_##opc(am)
#define IMPL(opc,cyc,am,code)	code
#endif

void generic_6502::exec()
{
	for (;;)
	{
		u8 t8;
		s8 r8;
		u16 t16;
		u16 ea;

#if DEBUGGER
		unsigned expected_cycles = 0, start_cpu_cycles = cpu_cycles;
		u16 orig_pc = pc;
		if (pc == bpaddr)
		{
			singlestep = true;
#if USE_SDL
			SDL_SetWindowTitle(window, "BREAKPOINT");
#endif
		}
#endif
 		if (singlestep || trace)
		{
			char buf[256];
			disassemble_insn(buf,sizeof(buf),pc,true);

			printf("$%04X %-22s  A=%02X X=%02X Y=%02X S=%02X [%c%c%c%c%c%c] %04d\n",pc,buf,a,x,y,s,
				(p&SF)?'S':' ',(p&VF)?'V':' ',(p&DF)?'D':' ',
				(p&IF)?'I':' ',(p&ZF)?'Z':' ',(p&CF)?'C':' ',
				cpu_cycles%10000);
		}
#if USE_SDL
		if (singlestep)
		{
			SDL_Event event;
			while (SDL_WaitEvent(&event))
			{
				if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_F10)	// step
					break;
                if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_F9)    // step
                    bpaddr ^= 0x10000;
				else if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_F5)	// run
				{
					singlestep = false;
					SDL_SetWindowTitle(window,"RUNNING");
					break;
				}
			}
		}
#endif
		switch (fetch()) 
		{
		#include "decode_6502.h"
		default:
			--pc;
			printf("invalid insn %x\n",read(pc));
			singlestep = trace = true;
			break;
		}
#if DEBUGGER
        unsigned actual_cycles = cpu_cycles - start_cpu_cycles;
		if (expected_cycles && expected_cycles != actual_cycles)
		{
			if (expected_cycles == 41 && (actual_cycles == 4 || actual_cycles == 5))
				;
			else if (expected_cycles == 51 && (actual_cycles == 5 || actual_cycles == 6))
				;
			else
			{
				printf("insn at %4X (%2X) expected %d cycles, took %d\n",orig_pc,read_byte(orig_pc),expected_cycles,actual_cycles);
				assert(false);
			}
		}
#endif
        if (non_maskable_interrupt) {
            push(pc>>8);
            push(pc);
            push(p);
            p |= IF; // prevent further interrupts until this one is acknowledged
            pc = read_word(0xFFFA);
            non_maskable_interrupt = false;
        }
        else if (interrupt && !(p & IF)) {
            push(pc>>8);
            push(pc);
            push(p);
            p |= IF; // prevent further interrupts until this one is acknowledged
            pc = read_word(0xFFFE);
            interrupt = false;
            // singlestep = true;
        }

	}
}

#if ASSEMBLER || DEBUGGER

enum address_mode {
	invalid,
	implicit,				//  none
	accumulator=implicit,	//  implicit, or A
	immediate,				//  #$bb
	relative,				// for branches
	zero_page_direct,		//  $bb
	zero_page_indexed_x,	//  $bb,X
	zero_page_indexed_y,	//  $bb,Y
	preindexed_indirect_x,	// ($bb,X)
	postindexed_indirect_y,	// ($bb),Y
	indirect,				// ($wwww)
	extended_direct,		// $wwww
	absolute_indexed_x,		// $wwww,X
	absolute_indexed_y,		// $wwww,Y
	address_mode_count
};
const char *address_mode_strings[] =
{
	"invalid",
	"implicit",				//  none
	"immediate",			//  #$bb
	"relative",				// for branches
	"zero_page_direct",		//  $bb
	"zero_page_indexed_x",	//  $bb,X
	"zero_page_indexed_y",	//  $bb,Y
	"preindexed_indirect_x",// ($bb,X)
	"postindexed_indirect_y",// ($bb),Y
	"indirect",				// ($wwww)
	"extended_direct",		// $wwww
	"absolute_indexed_x",	// $wwww,X
	"absolute_indexed_y"	// $wwww,Y
};

#define INSN(name,am) opc=name, mode=am

#undef BRANCH_0
#undef BRANCH_1
#define BRANCH_0(op,c,code) opc=#op,mode=relative
#define BRANCH_1(op,c,code) opc=#op,mode=relative

#undef OPC
#undef IMPL

#define IMPL(o,c,am,code)	opc=#o, mode=am
#define OPC(o,c,am)			opc=#o, mode=am

char* insert_byte(char *d,int b)
{
	static char hex[] = "0123456789ABCDEF";
	d[0] = hex[(b>>4)&15];
	d[1] = hex[b&15];
	return d+2;
}

char* insert_word(char *d,int w)
{
	return insert_byte(insert_byte(d,w>>8),w);
}

#define isalpha_(c) (isalpha(c)||(c)=='_')
#define isalnum_(c) (isalnum(c)||(c)=='_')
#define WR 1
#define RD 2

u16 generic_6502::disassemble_insn(char *dest,size_t destSize,u16 pc,bool mem) const
{
	// special case for vectors.
	if (pc >= 0xFFFC)
	{
		snprintf(dest,destSize,".WORD %04X ; VECTOR",read_word(pc));
		return pc+2;
	}

	const char *opc = ".BYTE";	// default if not recognized
	address_mode mode = invalid;
	switch (read_byte(pc++)) 
	{
		#include "decode_6502.h"
	}
	// compute base effective address based on addressing mode
	int ea;
	if (mode < immediate)
		ea = 0;
	else if (mode < indirect)
		ea = read_byte(pc++);
	else {
		ea = read_word(pc);
		pc+=2;
	}
	if (mode == relative)
		ea = pc + s8(ea);
	// bool store = opc[0]=='S' && (opc[1]=='A'||opc[1]=='T');
	// int flags = store?WR:RD;
	static const char *formats[] = 
	{
		0,		// invalid
		"%s",		// implicit / accumulator
		"%s #%s",	// immediate
		"%s %s",	// relative
		"%s %s",	// zero_page_direct
		"%s %s,X",	// zero_page_indexed_x
		"%s %s,Y",	// zero_page_indexed_y
		"%s (%s,X)",// preindexed_indirect_x
		"%s (%s),Y",// postindexed_indirect_y
		"%s (%s)",	// indirect
		"%s %s",	// extended_direct
		"%s %s,X",		// absolute_indexed_x
		"%s %s,Y",		// absolute_indexed_y
	};
	
	if (mode == invalid)
		snprintf(dest,destSize,".BYTE $%02X",read_byte(pc-1));
	else
	{
		const char *sym = resolve_symbol(ea);
		if (sym)
		    snprintf(dest,destSize,formats[mode],opc,sym);
		else {
			char buf[6];
			buf[0]='$';
			if (mode < indirect && mode != relative)
				*insert_byte(buf+1,ea) = 0;
			else
				*insert_word(buf+1,ea) = 0;
			snprintf(dest,destSize,formats[mode],opc,buf);
		}
		if (mem) switch (mode)
		{
		case zero_page_direct: if (ea>127) snprintf(dest+strlen(dest),destSize-strlen(dest)," [%02X]", read_byte(ea)); break;
		case zero_page_indexed_x: ea += x; if (ea>127) snprintf(dest+strlen(dest),destSize-strlen(dest)," [%02X:%02X]", ea, read_byte(ea)); break;
		case zero_page_indexed_y: ea += y; if (ea>127) snprintf(dest+strlen(dest),destSize-strlen(dest)," [%02X:%02X]", ea, read_byte(ea)); break;
		case preindexed_indirect_x: ea += x; ea = read_word(ea); snprintf(dest+strlen(dest),destSize-strlen(dest)," [%04X:%02X]", ea, read_byte(ea)); break;
		case postindexed_indirect_y: ea = read_word(ea) + y; snprintf(dest+strlen(dest),destSize-strlen(dest)," [%04X:%02X]", ea, read_byte(ea)); break;
		case indirect: snprintf(dest+strlen(dest),destSize-strlen(dest)," [%04X]", read_word(ea)); break;
		case extended_direct: if (*opc!='J') snprintf(dest+strlen(dest),destSize-strlen(dest)," [%02X]", read_byte(ea)); break;
		case absolute_indexed_x: ea += x; snprintf(dest+strlen(dest),destSize-strlen(dest)," [%04X:%02X]", ea, read_byte(ea)); break;
		case absolute_indexed_y: ea += y; snprintf(dest+strlen(dest),destSize-strlen(dest)," [%04X:%02X]", ea, read_byte(ea)); break;
		default: break;
		}
	}
	return pc;
}

#if ASSEMBLER
#include "assembler.h"
#endif

void generic_6502::disassemble(u16 pc,int len,bool verbose)
{
	while (len > 0)
	{
		char buf[128];
		u16 newpc = disassemble_insn(buf,sizeof(buf),pc,false);
		if (newpc < pc)
			len = 0;
		else
			len -= (newpc - pc);
		if (!verbose)
			printf(" %s\n",buf);
		else if (newpc-pc==3)
			printf("$%04X %02X %02X %02X %s\n",pc,read_byte(pc),read_byte(pc+1),read_byte(pc+2),buf);
		else if (newpc-pc==2)
			printf("$%04X %02X %02X    %s\n",pc,read_byte(pc),read_byte(pc+1),buf);
		else
			printf("$%04X %02X       %s\n",pc,read_byte(pc),buf);
		pc = newpc;
	}
}

#endif

