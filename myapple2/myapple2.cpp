#include "impl_6502.h"

#include <algorithm>
#include <unistd.h>
#include <stdarg.h>

struct myapple2: public generic_6502 {
	void cpu_cycle() final;
	u8 read_byte(u16) const final;
	void write_byte(u16,u8) final;
	const char *xstate() final;
    const char *resolve_symbol(u16) const final;
	u8 *read_file(const char *fname,size_t *sizePtr);
	void init();
    bool init_sdl();
    void init_vic_ii(u16 addr);
    unsigned draw_char(unsigned x,unsigned y,u32 fore,u32 back,u8 c);
    unsigned draw_text(unsigned x,unsigned y,u32 fore,u32 back,const char *fmt,...);
    u8 *ram, *rom;
    u8 writeprotect;
    mutable u8 keylatch;
    union {
        u8 ssw[32];
        struct {
            u8 padding[17];
            u8 ssw_bsrbank2;
            u8 ssw_bsreadram;
            u8 ssw_ramrd;
            u8 ssw_ramwrt;
            u8 ssw_intxcrom;
            u8 ssw_altzp;
            u8 ssw_slotc3rom;
            u8 ssw_80store;
            u8 ssw_vblank;
            u8 ssw_text;
            u8 ssw_mixed;
            u8 ssw_page2;
            u8 ssw_hires;
            u8 ssw_altcharset;
            u8 ssw_80col;
        };
    };
};


const char *myapple2::resolve_symbol(u16 addr) const {
    switch(addr) {
    case 0x43: return "zpc_mid_low";
    case 0x44: return "call_storage";
    case 0x45: return "mulSign";
    case 0x46: return "mulTemp";
    case 0x47: return "attr_bit";
    case 0x48: return "ztype";
    case 0x49: return "zinsn";
    case 0x4a: return "zpc_hi";
    case 0x4b: return "zpc_mid";
    case 0x4c: return "zptr";
    case 0x4e: return "store_hi";
    case 0x4f: return "operand_count";
    case 0x50: return "operands_hi";
    case 0x51: return "operands_hi+1";
    case 0x52: return "operands_hi+2";
    case 0x53: return "operands_hi+3";
    case 0x54: return "operands_hi+4";
    case 0x58: return "operands_lo";
    case 0x59: return "operands_lo+1";
    case 0x5a: return "operands_lo+2";
    case 0x5b: return "operands_lo+3";
    case 0x5c: return "operands_lo+4";
    case 0x60: return "stringptr";
    case 0x62: return "obj_ptr_alt";
    case 0x6a: return "obj_hi";
    case 0x6b: return "obj_mid";
    case 0x6c: return "obj_ptr";
    case 0x6e: return "obj_base";
    case 0x70: return "obj_prev_offset";
    case 0x71: return "window_current";
    case 0x72: return "output_table";
    case 0x73: return "output_enables";
    case 0x74: return "shift";
    case 0x75: return "abbrev";
    case 0x76: return "extended";
    case 0x78: return "stackptr";
    case 0x79: return "frameptr";
    case 0x7c: return "default_props_ptr";
    case 0x7e: return "dict_ptr";
    case 0x80: return "parse_ptr";
    case 0x82: return "text_offset";
    case 0x83: return "parse_offset";
    case 0x84: return "entry_ptr";
    case 0x86: return "low_index";
    case 0x88: return "high_index";
    case 0x8A: return "entry_size";
    case 0x8B: return "char_index";
    case 0x8C: return "chars_stored";
    case 0x8D: return "last_status_room";
    case 0x8E: return "zchar_hi";
    case 0x8F: return "zchar_lo";
    case 0x90: return "desired_page";
    case 0x92: return "oldest_page_index";
    case 0x94: return "oldest_page_value";
    case 0x96: return "vm_ptr";

    case 0xC000: return "_80STOREOFF";
    case 0xC001: return "_80STOREON";
    case 0xC002: return "RAMRDOFF";
    case 0xC003: return "RAMRDON";
    case 0xC004: return "RAMWRTOFF";
    case 0xC005: return "RAMWRTON";
    case 0xC006: return "INTCXROMOFF";
    case 0xC007: return "INTCXROMON";
    case 0xC008: return "ALTZPOFF";
    case 0xC009: return "ALTZPON";
    case 0xC00A: return "SLOTC3ROMOFF";
    case 0xC00B: return "SLOTC3ROMON";
    case 0xC00C: return "80COLOFF";
    case 0xC00D: return "80COLON";
    case 0xC00E: return "ALTCHARSETOFF";
    case 0xC00F: return "ALTCHARSETON";
    case 0xC010: return "AKD";
    case 0xC011: return "BSRBANK2";
    case 0xC012: return "BSREADRAM";
    case 0xC013: return "RAMRD";
    case 0xC014: return "RAMWRT";
    case 0xC015: return "INTCXROM";
    case 0xC016: return "ALTZP";
    case 0xC017: return "SLOTC3ROM";
    case 0xC018: return "80STORE";
    case 0xC019: return "VERTBLANK";
    case 0xC01A: return "TEXT";
    case 0xC01B: return "MIXED";
    case 0xC01C: return "PAGE2";
    case 0xC01D: return "HIRES";
    case 0xC01E: return "ALTCHARSET";
    case 0xC01F: return "80COL";
    case 0xC050: return "TEXTOFF";
    case 0xC051: return "TEXTON";
    case 0xC052: return "MIXEDOFF";
    case 0xC053: return "MIXEDON";
    case 0xC054: return "PAGE2OFF";
    case 0xC055: return "PAGE2ON";
    case 0xC056: return "HIRESOFF";
    case 0xC057: return "HIRESON";
    default: return nullptr;
    }
}

void myapple2::cpu_cycle() {
    ++cpu_cycles;
    ssw_vblank = (cpu_cycles % 17030 < 12480) << 7;
}

u8 *interpreter, *story;
size_t interpreterSize, storySize;

u8 myapple2::read_byte(u16 addr) const {
    if (ssw_80store && addr >= 0x400 && addr < 0x800) {
        return ram[ssw_page2? 0x10000 + addr : addr];
    }
    else if ((ssw_ramrd && addr >= 0x200 && addr < 0xc000) ||
        (ssw_altzp && addr >= 0x000 && addr < 0x200)) {
        return ram[0x10000 + addr];
    }
    else if (addr >= 0xc000 && addr < 0xd000) {
        if (addr == 0xc000) {
            if (!keylatch) {
                keylatch = fgetc(stdin) | 0x80;
                if (keylatch == 0x8A)
                    keylatch = 0x8D;
            }
            return keylatch;
        }
        else if (addr == 0xc010)
            keylatch = 0;
        else if (addr < 0xc020)
            return ssw[addr & 31];
        // detect SmartPort call (normal reads to rom area return 0, so C503 + ($C5FF) is 3.
        else if (addr == 0xc503 || addr == 0xc603) {
            myapple2 *that = const_cast<myapple2*>(this);
            // get return address
            u16 rv = read_word(0x101+s);
            u8 cmd = read_byte(rv+1);
            if (cmd!=1) {
                fprintf(stderr,"only smartport reads supported, not %d\n",cmd);
                that->p |= 1;
            }
            else {
                u16 pb = read_word(rv+2);
                u16 dest = read_word(pb+2);
                u16 block = read_word(pb+4);
                u8 *base = (block < 24)? interpreter + block * 512 : story + (block-24) * 512;
                fprintf(stdout,"{read from block %04x (z addr %06x) to address %04x}\n",block,
			block < 24? 0 : (block-24) * 512,dest);
                for (int i=0; i<512; i++)
                    that->write_byte(dest+i,base[i]);
                that-> p &= ~1; // clear carry
            }
            that->write_word(0x101+s,rv+3); // fix return address
            return 0x60;        // rts
        }
        return 0;
    }
    else if (addr >= 0xd000) {
        if (ssw_bsreadram) {
            u8 *base = ssw_altzp? ram + 0x10000 : ram;
            if (addr < 0xe000)
                return base[(addr & 0xfff) | (ssw_bsrbank2? 0xc000: 0xd000)];
            else
                return base[addr];
        }
        else
            return rom[addr - 0xd000];
    }
    else
        return ram[addr];
}

const char *myapple2::xstate() {
	static char buf[32];
	buf[0] = 32;
	buf[1] = ssw_ramrd? 'R' : ' ';
	buf[2] = ssw_ramwrt? 'W' : ' ';
	buf[3] = ssw_altzp? 'Z' : ' ';
	return buf;
}

void myapple2::write_byte(u16 addr,u8 value) {
    if (ssw_80store && addr >= 0x400 && addr < 0x800) {
        ram[ssw_page2? 0x10000 + addr : addr] = value;
    }
    else if (addr >= 0xc000 && addr < 0xc100) {
        switch (addr) {
            case 0xC000: ssw_80store = 0x00; break;
            case 0xC001: ssw_80store = 0x80; break;
            case 0xC002: ssw_ramrd = 0x00; break;
            case 0xC003: ssw_ramrd = 0x80; break;
            case 0xC004: ssw_ramwrt = 0x00; break;
            case 0xC005: ssw_ramwrt = 0x80; break;
            case 0xC006: ssw_intxcrom = 0x00; break;
            case 0xC007: ssw_intxcrom = 0x80; break;
            case 0xC008: ssw_altzp = 0x00; break;
            case 0xC009: ssw_altzp = 0x80; break;
            case 0xC00A: ssw_slotc3rom = 0x00; break;
            case 0xC00B: ssw_slotc3rom = 0x80; break;
            case 0xC080: writeprotect = 2;                  ssw_bsreadram = 0x80; ssw_bsrbank2 = 0x00; break;
            case 0xC081: if (writeprotect) --writeprotect;  ssw_bsreadram = 0x00; ssw_bsrbank2 = 0x00; break;
            case 0xC082: writeprotect = 2;                  ssw_bsreadram = 0x00; ssw_bsrbank2 = 0x00; break;
            case 0xC083: if (writeprotect) --writeprotect;  ssw_bsreadram = 0x80; ssw_bsrbank2 = 0x00; break;
            case 0xC088: writeprotect = 2;                  ssw_bsreadram = 0x80; ssw_bsrbank2 = 0x80; break;
            case 0xC089: if (writeprotect) --writeprotect;  ssw_bsreadram = 0x00; ssw_bsrbank2 = 0x80; break;
            case 0xC08A: writeprotect = 2;                  ssw_bsreadram = 0x00; ssw_bsrbank2 = 0x80; break;
            case 0xC08B: if (writeprotect) --writeprotect;  ssw_bsreadram = 0x80; ssw_bsrbank2 = 0x80; break;
            case 0xC0FE: trace = !!value; break;
            case 0xC0FF: if (!value) { printf("%u cycles\n",cpu_cycles); exit(1); } putchar(value==13?10:value); break;
        }
    }
    else if ((ssw_ramwrt && addr >= 0x200 && addr < 0xc000) ||
        (ssw_altzp && addr >= 0x000 && addr < 0x200)) {
        ram[0x10000 + addr] = value;
    }
    else if (addr >= 0xD000) {
        if (!writeprotect && ssw_bsreadram) {
            u8 *base = ssw_altzp? ram + 0x10000 : ram;
            if (addr < 0xE000)
                base[(addr & 0xFFF) | (ssw_bsrbank2? 0xc000 : 0xd000)] = value;
            else
                base[addr] = value;
        }
    }
    else
        ram[addr] = value;
}


u8* myapple2::read_file(const char *name,size_t *sizePtr) {
    /* char buf[256];
    getcwd(buf,sizeof(buf));
    puts(buf); */
	FILE *f = fopen(name,"rb");
	if (!f)
		return nullptr;
	fseek(f,0,SEEK_END);
	size_t s = ftell(f);
    if (sizePtr)
        *sizePtr =  s;
	fseek(f,0,SEEK_SET);
	u8 *buffer = new u8[s];
    printf("%zu bytes loaded from %s\n",s,name);
	fread(buffer,1,s,f);
	fclose(f);
	return buffer;
}

inline u8 *znew(size_t s) {
    u8 *result = new u8[s];
    memset(result,0,s);
    return result;
}
    
void myapple2::init() {
    ram = znew(65536);
    memset(ssw,0,sizeof(ssw));
    writeprotect = 2;
    keylatch = 0;
}

bool myapple2::init_sdl() {
#if USE_SDL
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_JOYSTICK)  < 0) {
        fprintf(stderr, "Unable to init SDL: %s\n", SDL_GetError());
        return false;
    }
    atexit(SDL_Quit);
    
    if (SDL_VideoInit(nullptr) < 0) {
        fprintf(stderr, "Unable to init video: %s\n", SDL_GetError());
        return false;
    }
    atexit(SDL_VideoQuit);
    
    window = SDL_CreateWindow("myapple2",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,screen_width*2,screen_height*2,SDL_WINDOW_RESIZABLE);
    renderer = SDL_CreateRenderer(window,-1,SDL_RENDERER_PRESENTVSYNC);
    texture = SDL_CreateTexture(renderer,SDL_PIXELFORMAT_ARGB8888,SDL_TEXTUREACCESS_STREAMING,screen_width,screen_height);
    screen = new u32[screen_width*screen_height];
    
    static u16 codes[64] = {
        SDL_SCANCODE_BACKSPACE,SDL_SCANCODE_RETURN,SDL_SCANCODE_LEFT,SDL_SCANCODE_F7,
        SDL_SCANCODE_F1,SDL_SCANCODE_F3,SDL_SCANCODE_F5,SDL_SCANCODE_UP,
        SDL_SCANCODE_3,SDL_SCANCODE_W,SDL_SCANCODE_A,SDL_SCANCODE_4,
        SDL_SCANCODE_Z,SDL_SCANCODE_S,SDL_SCANCODE_E,SDL_SCANCODE_LSHIFT,
        SDL_SCANCODE_5,SDL_SCANCODE_R,SDL_SCANCODE_D,SDL_SCANCODE_6,
        SDL_SCANCODE_C,SDL_SCANCODE_F,SDL_SCANCODE_T,SDL_SCANCODE_X,
        SDL_SCANCODE_7,SDL_SCANCODE_Y,SDL_SCANCODE_G,SDL_SCANCODE_8,
        SDL_SCANCODE_B,SDL_SCANCODE_H,SDL_SCANCODE_U,SDL_SCANCODE_V,
        SDL_SCANCODE_9,SDL_SCANCODE_I,SDL_SCANCODE_J,SDL_SCANCODE_0,
        SDL_SCANCODE_M,SDL_SCANCODE_K,SDL_SCANCODE_O,SDL_SCANCODE_N,
        SDL_SCANCODE_F7,SDL_SCANCODE_P,SDL_SCANCODE_L,SDL_SCANCODE_MINUS,
        SDL_SCANCODE_PERIOD,SDL_SCANCODE_SEMICOLON,SDL_SCANCODE_LEFTBRACKET,SDL_SCANCODE_COMMA,
        SDL_SCANCODE_TAB,SDL_SCANCODE_RIGHTBRACKET,SDL_SCANCODE_APOSTROPHE,SDL_SCANCODE_RALT,
        SDL_SCANCODE_RSHIFT,SDL_SCANCODE_EQUALS,SDL_SCANCODE_BACKSLASH,SDL_SCANCODE_SLASH,
        SDL_SCANCODE_1,SDL_SCANCODE_ESCAPE,SDL_SCANCODE_LCTRL,SDL_SCANCODE_2,
        SDL_SCANCODE_SPACE,SDL_SCANCODE_LALT,SDL_SCANCODE_Q,SDL_SCANCODE_GRAVE
    };
    // mark all codes as unknown
    memset(sdl_to_c64,0xFF,sizeof(sdl_to_c64));
    // fill in the ones we map back to real keys
    for (unsigned i=0; i<64; i++)
        sdl_to_c64[codes[i]] = i;
    memset(keystate,0xFF,sizeof(keystate));
    joystick1 = joystick2 = joystick_state = 0xFF;

    // Check for joystick
    joystick = SDL_NumJoysticks() > 0? SDL_JoystickOpen(0) : nullptr;
    joystick_emulation = !joystick;
#endif
    return true;
}

int main(int argc,char **argv) {
	myapple2 computer;
	while (--argc&&**++argv=='-')
		switch (argv[0][1]) {
			case 't': computer.trace = true; break;
		}
		
    if (!computer.init_sdl())
        return 1;
    computer.init();
    // first parameter is emulator image, which loads at 0xD000
    // second parameter is story file, which loads at 0x1000 (and wraps back at 0xBFFF if longer)
    interpreter = computer.read_file(argv[0],&interpreterSize);
    if (!interpreter || interpreterSize != 12 * 1024) {
        fprintf(stderr,"interpreter must be 12k\n");
        return 1;
    }

    story = computer.read_file(argv[1],&storySize);
    if (!story) {
        fprintf(stderr,"story not found\n");
        return 1;
    }

    // The Disk][ paths load at $1000, ProDOS loads at $0800.
    uint16_t header = interpreter[0]==3? 0x1000 : 0x0800;
    uint16_t ramtop = 0xc000;
    uint16_t ramsize = ramtop - header;

    // for now hack appropriate initial state and jump to zentry
    // are we emulating a disk drive load?
    if (interpreter[0]==3) {
        memcpy(computer.ram + 0xD000, interpreter, 12 * 1024);
        size_t lowPart = storySize > ramsize ? (ramtop-header) : storySize;
        size_t highPart = storySize - lowPart;
        printf("loading story into %zu bytes of main memory and %zu bytes of aux memory\n",lowPart,highPart);
        memcpy(computer.ram + header, story, lowPart);
        memcpy(computer.ram + 0x1'0000 + header, story + lowPart, highPart);
        computer.pc = 0xD300;
        computer.writeprotect = 0;
        computer.ssw_bsreadram = 0x80;
    }
    else {  // nope, smartport boot
        memcpy(computer.ram + 0x800, interpreter, 1024);
        computer.pc = 0x801;
        computer.a = 0x01;
        computer.x = 0x50;
        computer.y = 0x00;
    }
    srand(time(0));
    // init 'rover' to random value
    computer.ram[0x3A] = rand();
    computer.ram[0x3B] = rand();

	computer.exec();
}
