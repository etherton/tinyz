		// Copyright 2010, David Etherton.  All rights reserved.
		// 41 means 4 plus 1 if crossing page boundary
		// 51 means 5 plus 1 if crossing page boundary
		// 234 means 2 if not taken, 3 if taken on same page, 4 if take on adjacent page

		// LDA:
		case 0xA5: OPC(LDA,3,zero_page_direct); break;
		case 0xA9: OPC(LDA,2,immediate); break;
		case 0xB5: OPC(LDA,4,zero_page_indexed_x); break;
		case 0xA1: OPC(LDA,6,preindexed_indirect_x); break;
		case 0xB1: OPC(LDA,51,postindexed_indirect_y); break;
		case 0xAD: OPC(LDA,4,extended_direct); break;
		case 0xB9: OPC(LDA,41,absolute_indexed_y); break;
		case 0xBD: OPC(LDA,41,absolute_indexed_x); break;
		// STA:
		case 0x85: OPC(STA,3,zero_page_direct); break;
		case 0x95: OPC(STA,4,zero_page_indexed_x); break;
		case 0x81: OPC(STA,6,preindexed_indirect_x); break;
		case 0x91: OPC(STA,6,postindexed_indirect_y); break;
		case 0x8D: OPC(STA,4,extended_direct); break;
		case 0x99: OPC(STA,5,absolute_indexed_y); break;
		case 0x9D: OPC(STA,5,absolute_indexed_x); break;
		// LDX:
		case 0xA2: OPC(LDX,2,immediate); break;
		case 0xA6: OPC(LDX,3,zero_page_direct); break;
		case 0xB6: OPC(LDX,4,zero_page_indexed_y); break;
		case 0xAE: OPC(LDX,4,extended_direct) ; break;
		case 0xBE: OPC(LDX,41,absolute_indexed_y); break;
		// STX:
		case 0x86: OPC(STX,3,zero_page_direct); break;
		case 0x96: OPC(STX,4,zero_page_indexed_y); break;
		case 0x8E: OPC(STX,4,extended_direct); break;
		// LDY:
		case 0xA0: OPC(LDY,2,immediate); break;
		case 0xA4: OPC(LDY,3,zero_page_direct); break;
		case 0xB4: OPC(LDY,4,zero_page_indexed_x); break;
		case 0xAC: OPC(LDY,4,extended_direct); break;
		case 0xBC: OPC(LDY,41,absolute_indexed_x); break;
		// STY:
		case 0x84: OPC(STY,3,zero_page_direct); break;
		case 0x94: OPC(STY,4,zero_page_indexed_x); break;
		case 0x8C: OPC(STY,4,extended_direct); break;
		// ADC:
		case 0x65: OPC(ADC,3,zero_page_direct); break;
		case 0x69: OPC(ADC,2,immediate); break;
		case 0x75: OPC(ADC,4,zero_page_indexed_x); break;
		case 0x61: OPC(ADC,6,preindexed_indirect_x); break;
		case 0x71: OPC(ADC,51,postindexed_indirect_y); break;
		case 0x6D: OPC(ADC,4,extended_direct); break;
		case 0x79: OPC(ADC,41,absolute_indexed_y); break;
		case 0x7D: OPC(ADC,41,absolute_indexed_x); break;
		// AND:
		case 0x25: OPC(AND,3,zero_page_direct); break;
		case 0x29: OPC(AND,2,immediate); break;
		case 0x35: OPC(AND,4,zero_page_indexed_x); break;
		case 0x21: OPC(AND,6,preindexed_indirect_x); break;
		case 0x31: OPC(AND,51,postindexed_indirect_y); break;
		case 0x2D: OPC(AND,4,extended_direct); break;
		case 0x39: OPC(AND,41,absolute_indexed_y); break;
		case 0x3D: OPC(AND,41,absolute_indexed_x); break;
		// BIT:
		case 0x24: OPC(BIT,3,zero_page_direct); break;
		case 0x2C: OPC(BIT,4,extended_direct); break;
		// CMP:
		case 0xC5: OPC(CMP,3,zero_page_direct); break;
		case 0xC9: OPC(CMP,2,immediate); break;
		case 0xD5: OPC(CMP,4,zero_page_indexed_x); break;
		case 0xC1: OPC(CMP,6,preindexed_indirect_x); break;
		case 0xD1: OPC(CMP,51,postindexed_indirect_y); break;
		case 0xCD: OPC(CMP,4,extended_direct); break;
		case 0xD9: OPC(CMP,41,absolute_indexed_y); break;
		case 0xDD: OPC(CMP,41,absolute_indexed_x); break;
		// EOR:
		case 0x45: OPC(EOR,3,zero_page_direct); break;
		case 0x49: OPC(EOR,2,immediate); break;
		case 0x55: OPC(EOR,4,zero_page_indexed_x); break;
		case 0x41: OPC(EOR,6,preindexed_indirect_x); break;
		case 0x51: OPC(EOR,51,postindexed_indirect_y); break;
		case 0x4D: OPC(EOR,4,extended_direct); break;
		case 0x59: OPC(EOR,41,absolute_indexed_y); break;
		case 0x5D: OPC(EOR,41,absolute_indexed_x); break;
		// ORA:
		case 0x05: OPC(ORA,3,zero_page_direct); break;
		case 0x09: OPC(ORA,2,immediate); break;
		case 0x15: OPC(ORA,4,zero_page_indexed_x); break;
		case 0x01: OPC(ORA,6,preindexed_indirect_x); break;
		case 0x11: OPC(ORA,51,postindexed_indirect_y); break;
		case 0x0D: OPC(ORA,4,extended_direct); break;
		case 0x19: OPC(ORA,41,absolute_indexed_y); break;
		case 0x1D: OPC(ORA,41,absolute_indexed_x); break;
		// SBC:
		case 0xE5: OPC(SBC,3,zero_page_direct); break;
		case 0xE9: OPC(SBC,2,immediate); break;
		case 0xF5: OPC(SBC,4,zero_page_indexed_x); break;
		case 0xE1: OPC(SBC,6,preindexed_indirect_x); break;
		case 0xF1: OPC(SBC,51,postindexed_indirect_y); break;
		case 0xED: OPC(SBC,4,extended_direct); break;
		case 0xF9: OPC(SBC,41,absolute_indexed_y); break;
		case 0xFD: OPC(SBC,41,absolute_indexed_x); break;
		// INC
		case 0xE6: OPC(INC,5,zero_page_direct); break;
		case 0xF6: OPC(INC,6,zero_page_indexed_x); break;
		case 0xEE: OPC(INC,6,extended_direct); break;
		case 0xFE: OPC(INC,7,absolute_indexed_x); break;
		// DEC
		case 0xC6: OPC(DEC,5,zero_page_direct); break;
		case 0xD6: OPC(DEC,6,zero_page_indexed_x); break;
		case 0xCE: OPC(DEC,6,extended_direct); break;
		case 0xDE: OPC(DEC,7,absolute_indexed_x); break;
		// CPX
		case 0xE0: OPC(CPX,2,immediate); break;
		case 0xE4: OPC(CPX,3,zero_page_direct); break;
		case 0xEC: OPC(CPX,4,extended_direct); break;
		// CPY
		case 0xC0: OPC(CPY,2,immediate); break;
		case 0xC4: OPC(CPY,3,zero_page_direct); break;
		case 0xCC: OPC(CPY,4,extended_direct); break;
		// ROL
		case 0x26: OPC(ROL,5,zero_page_direct); break;
		case 0x2A: OPC(ROL,2,accumulator); break;
		case 0x36: OPC(ROL,6,zero_page_indexed_x); break;
		case 0x2E: OPC(ROL,6,extended_direct); break;
		case 0x3E: OPC(ROL,7,absolute_indexed_x); break;
		// ROR
		case 0x66: OPC(ROR,5,zero_page_direct); break;
		case 0x6A: OPC(ROR,2,accumulator); break;
		case 0x76: OPC(ROR,6,zero_page_indexed_x); break;
		case 0x6E: OPC(ROR,6,extended_direct); break;
		case 0x7E: OPC(ROR,7,absolute_indexed_x); break;
		// ASL
		case 0x06: OPC(ASL,5,zero_page_direct); break;
		case 0x0A: OPC(ASL,2,accumulator); break;
		case 0x16: OPC(ASL,6,zero_page_indexed_x); break;
		case 0x0E: OPC(ASL,6,extended_direct); break;
		case 0x1E: OPC(ASL,7,absolute_indexed_x); break;
		// LSR
		case 0x46: OPC(LSR,5,zero_page_direct); break;
		case 0x4A: OPC(LSR,2,accumulator); break;
		case 0x56: OPC(LSR,6,zero_page_indexed_x); break;
		case 0x4E: OPC(LSR,6,extended_direct); break;
		case 0x5E: OPC(LSR,7,absolute_indexed_x); break;
		// JMP
		case 0x4C: IMPL(JMP,3,extended_direct,pc = fetch_absolute()); break;	// 3 cycles
		case 0x6C: IMPL(JMP,5,indirect,t16 = fetch_absolute(); pc = read(t16); pc |= read((t16 & 0xFF00) | u8(t16 + 1)) << 8); break;	// 5 cycles
		// Branches
		case 0x10: BRANCH_0(BPL,234,SF); break;
		case 0x30: BRANCH_1(BMI,234,SF); break;
		case 0x50: BRANCH_0(BVC,234,VF); break;
		case 0x70: BRANCH_1(BVS,234,VF); break;
		case 0x90: BRANCH_0(BCC,234,CF); break;
		case 0xB0: BRANCH_1(BCS,234,CF); break;
		case 0xD0: BRANCH_0(BNE,234,ZF); break;
		case 0xF0: BRANCH_1(BEQ,234,ZF); break;
		// JSR
		case 0x20: IMPL(JSR,6,extended_direct,t16 = fetch_absolute(); --pc; cpu_cycle(); push(pc>>8); push(pc & 255); pc = t16); break;	// 6 cycles
		// RTS:
		case 0x60: IMPL(RTS,6,implicit,pc=pull(); pc|=pull()<<8; pc++; cpu_cycle(); cpu_cycle(); cpu_cycle()); break;	// 6 cycles
		// Register transfers:
		case 0xAA: IMPL(TAX,2,implicit,x = a; UPDATE_SZ(x); cpu_cycle()); break;		// TAX, 2 cycles
		case 0x8A: IMPL(TXA,2,implicit,a = x; UPDATE_SZ(a); cpu_cycle()); break;		// TXA, 2 cycles
		case 0xA8: IMPL(TAY,2,implicit,y = a; UPDATE_SZ(y); cpu_cycle()); break;		// TAY, 2 cycles
		case 0x98: IMPL(TYA,2,implicit,a = y; UPDATE_SZ(a); cpu_cycle()); break;		// TYA, 2 cycles
		case 0xBA: IMPL(TSX,2,implicit,x = s; UPDATE_SZ(x); cpu_cycle()); break;		// TSX, 2 cycles
		case 0x9A: IMPL(TXS,2,implicit,s = x; cpu_cycle()); break;					// TXS, 2 cycles (special case, doesn't affect flags)
		// Increment/decrement
		case 0xCA: IMPL(DEX,2,implicit,--x; UPDATE_SZ(x); cpu_cycle()); break;		// DEX, 2 cycles
		case 0x88: IMPL(DEY,2,implicit,--y; UPDATE_SZ(y); cpu_cycle()); break;		// DEY, 2 cycles
		case 0xE8: IMPL(INX,2,implicit,++x; UPDATE_SZ(x); cpu_cycle()); break;		// INX, 2 cycles
		case 0xC8: IMPL(INY,2,implicit,++y; UPDATE_SZ(y); cpu_cycle()); break;		// INY, 2 cycles
		// Stack manipulation
		case 0x48: IMPL(PHA,3,implicit,push(a); cpu_cycle()); break;					// PHA, 3 cycles
		case 0x68: IMPL(PLA,4,implicit,a=pull(); UPDATE_SZ(a); cpu_cycle(); cpu_cycle()); break;	// PLA, 4 cycles
		case 0x08: IMPL(PHP,3,implicit,push(p); cpu_cycle()); break;					// PHP, 3 cycles
		case 0x28: IMPL(PLP,4,implicit,p=pull(); cpu_cycle(); cpu_cycle()); break;	// PLP, 4 cycles
		// Interrupts
		case 0x58: IMPL(CLI,2,implicit,p &= ~IF; cpu_cycle()); break;		// CLI - enable interrupts, 2 cycles
		case 0x78: IMPL(SEI,2,implicit,p |= IF; cpu_cycle()); break;		// SEI - disable interrupts, 2 cycles
		case 0x40: IMPL(RTI,6,implicit,p=pull();pc=pull();pc|=pull()<<8;cpu_cycle();cpu_cycle()); break;			// RTI
		case 0x00: IMPL(BRK,7,implicit,++pc; push(pc>>8); push(pc); push(p|16); pc=read(0xFFFE); pc|=(read(0xFFFF)<<8); cpu_cycle()); break;			// BRK
		// Flag manipulation
		case 0x18: IMPL(CLC,2,implicit,p &= ~CF; cpu_cycle()); break;		// CLC, 2 cycles
		case 0x38: IMPL(SEC,2,implicit,p |= CF; cpu_cycle()); break;		// SEC, 2 cycles
		case 0xB8: IMPL(CLV,2,implicit,p &= ~VF; cpu_cycle()); break;		// CLV, 2 cycles
		case 0xD8: IMPL(CLD,2,implicit,p &= ~DF; cpu_cycle()); break;		// CLD, 2 cycles
		case 0xF8: IMPL(SED,2,implicit,p |= DF; cpu_cycle()); break;		// SED, 2 cycles

		// http://www.xmission.com/~trevin/atari/6502_opcodes.html
		// case 0x1A: case 0x3A: case 0x5A: case 0x7A: case 0xDA: case 0xFA:	// unofficial
		case 0xEA: IMPL(NOP,2,implicit,cpu_cycle()); break;				// NOP, 2 cycles

		// "Illegal" instructions
		case 0x04: IMPL(NOP,3,zero_page_direct,EA_RD_zero_page_direct(); READ_zero_page_direct()); break; // NOP, 3 cycles
		case 0x0C: IMPL(NOP,4,extended_direct,EA_RD_extended_direct(); READ_extended_direct()); break; // NOP, 3 bytes, 4 cycles
		case 0x80: IMPL(NOP,2,immediate,EA_RD_immediate(); READ_immediate()); break; // NOP, 2 bytes, 2 cycles

		// LAX (load both A and X, affect flags)
		case 0xA7: OPC(LAX,3,zero_page_direct); break;
		case 0xB7: OPC(LAX,4,zero_page_indexed_y); break;
		case 0xA3: OPC(LAX,6,preindexed_indirect_x); break;
		case 0xB3: OPC(LAX,51,postindexed_indirect_y); break;
		case 0xAF: OPC(LAX,41,extended_direct); break;
		case 0xBF: OPC(LAX,41,absolute_indexed_y); break;
		// SAX (store A&X to destination, do not affect flags)
		case 0x87: OPC(SAX,3,zero_page_direct); break;
		case 0x97: OPC(SAX,4,zero_page_indexed_y); break;
		case 0x83: OPC(SAX,6,preindexed_indirect_x); break;
		case 0x8F: OPC(SAX,4,extended_direct); break;
		// DCP (decrement target address, then do CMP)
		case 0xC7: OPC(DCP,5,zero_page_direct); break;
		case 0xD7: OPC(DCP,6,zero_page_indexed_x); break;
		// case 0xC3: DCP(preindexed_indirect_x); break;
		// case 0xD3: DCP(postindexed_indirect_y); break;
		case 0xCF: OPC(DCP,6,extended_direct); break;
		case 0xDF: OPC(DCP,7,absolute_indexed_x); break;
		// case 0xDB: DCP(absolute_indexed_y); break;
		// TODO: SBX
		// http://www.oxyron.de/html/opcodes02.html
		case 0x4B: OPC(ALR,2,immediate); break;
		case 0xCB: OPC(AXS,2,immediate); break;
