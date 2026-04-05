#include "impl_6502.h"

#include <algorithm>
#include <unistd.h>
#include <stdarg.h>

struct myapple2: public generic_6502 {
	void cpu_cycle() final;
	u8 read_byte(u16) const final;
	void write_byte(u16,u8) final;
    const char *resolve_symbol(u16) const final;
	u8 *read_file(const char *fname,size_t *sizePtr);
	void init();
    bool init_sdl();
    void init_vic_ii(u16 addr);
    void init_symbol(u16 addr,const char *name) {
        symbols[addr] = name;
    }
    void init_indexed_symbol(u16 addr,const char *fmt,int x) {
        char buf[32];
        snprintf(buf,sizeof(buf),fmt,x);
        init_symbol(addr,strdup(buf));
    }
    void init_field_symbol(u16 addr,const char *name,const char *) {
        init_symbol(addr,name);
    }
    unsigned draw_char(unsigned x,unsigned y,u32 fore,u32 back,u8 c);
    unsigned draw_text(unsigned x,unsigned y,u32 fore,u32 back,const char *fmt,...);
    u8 *ram, *rom;
    const char **symbols;
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
    return symbols[addr];
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
    symbols = (const char**)memset(new const char*[65536],0,65536*sizeof(const char*));
    init_symbol(0xC000,"_80STOREOFF");
    init_symbol(0xC001,"_80STOREON");
    init_symbol(0xC002,"RAMRDOFF");
    init_symbol(0xC003,"RAMRDON");
    init_symbol(0xC004,"RAMWRTOFF");
    init_symbol(0xC005,"RAMWRTON");
    init_symbol(0xC006,"INTCXROMOFF");
    init_symbol(0xC007,"INTCXROMON");
    init_symbol(0xC008,"ALTZPOFF");
    init_symbol(0xC009,"ALTZPON");
    init_symbol(0xC00A,"SLOTC3ROMOFF");
    init_symbol(0xC00B,"SLOTC3ROMON");
    init_symbol(0xC00C,"80COLOFF");
    init_symbol(0xC00D,"80COLON");
    init_symbol(0xC00E,"ALTCHARSETOFF");
    init_symbol(0xC00F,"ALTCHARSETON");
    init_symbol(0xC010,"AKD");
    init_symbol(0xC011,"BSRBANK2");
    init_symbol(0xC012,"BSREADRAM");
    init_symbol(0xC013,"RAMRD");
    init_symbol(0xC014,"RAMWRT");
    init_symbol(0xC015,"INTCXROM");
    init_symbol(0xC016,"ALTZP");
    init_symbol(0xC017,"SLOTC3ROM");
    init_symbol(0xC018,"80STORE");
    init_symbol(0xC019,"VERTBLANK");
    init_symbol(0xC01A,"TEXT");
    init_symbol(0xC01B,"MIXED");
    init_symbol(0xC01C,"PAGE2");
    init_symbol(0xC01D,"HIRES");
    init_symbol(0xC01E,"ALTCHARSET");
    init_symbol(0xC01F,"80COL");
    init_symbol(0xC050,"TEXTOFF");
    init_symbol(0xC051,"TEXTON");
    init_symbol(0xC052,"MIXEDOFF");
    init_symbol(0xC053,"MIXEDON");
    init_symbol(0xC054,"PAGE2OFF");
    init_symbol(0xC055,"PAGE2ON");
    init_symbol(0xC056,"HIRESOFF");
    init_symbol(0xC057,"HIRESON");
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

    // for now hack appropriate initial state and jump to zentry
    // are we emulating a disk drive load?
    if (interpreter[0]==3) {
        memcpy(computer.ram + 0xD000, interpreter, 12 * 1024);
        size_t lowPart = storySize > 0xB000? 0xB000 : storySize;
        size_t highPart = storySize - lowPart;
        printf("loading story into %zu bytes of main memory and %zu bytes of aux memory\n",lowPart,highPart);
        memcpy(computer.ram + 0x1000, story, lowPart);
        memcpy(computer.ram + 0x11000, story + lowPart, highPart);
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

	computer.exec();
}
