#include "machine.h"
#include "debug.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

// https://github.com/sindresorhus/macos-terminal-size/blob/main/terminal-size.c
#include <fcntl.h>     // open(), O_EVTONLY, O_NONBLOCK
#include <unistd.h>    // close()
#include <sys/ioctl.h> // ioctl()

static struct termios orig_termios, raw_termios;

static char *script_text;
static long script_size, script_offset;
static bool nostatus;
static bool debug_enable, strict_enable;

extern debug::debug_info di;

// map 155-223 to unicode
static uint16_t unicode_mapping[223-155+1] = {
0x0e4, //	a-diaeresis	ä	ae
0x0f6, //	o-diaeresis	ö	oe
0x0fc, //	u-diaeresis	ü	ue
0x0c4, //	A-diaeresis	Ä	Ae
0x0d6, //	O-diaeresis	Ö	Oe
0x0dc, //	U-diaeresis	Ü	Ue
0x0df, //	sz-ligature	ß	ss
0x0bb, //	quotation	»	>> or "
0x0ab, //	marks	«	<< or "
0x0eb, //	e-diaeresis	ë	e
0x0ef, //	i-diaeresis	ï	i
0x0ff, //	y-diaeresis	ÿ	y
0x0cb, //	E-diaeresis	Ë	E
0x0cf, //	I-diaeresis	Ï	I
0x0e1, //	a-acute	á	a
0x0e9, //	e-acute	é	e
0x0ed, //	i-acute	í	i
0x0f3, //	o-acute	ó	o
0x0fa, //	u-acute	ú	u
0x0fd, //	y-acute	ý	y
0x0c1, //	A-acute	Á	A
0x0c9, //	E-acute	É	E
0x0cd, //	I-acute	Í	I
0x0d3, //	O-acute	Ó	O
0x0da, //	U-acute	Ú	U
0x0dd, //	Y-acute	Ý	Y
0x0e0, //	a-grave	à	a
0x0e8, //	e-grave	è	e
0x0ec, //	i-grave	ì	i
0x0f2, //	o-grave	ò	o
0x0f9, //	u-grave	ù	u
0x0c0, //	A-grave	À	A
0x0c8, //	E-grave	È	E
0x0cc, //	I-grave	Ì	I
0x0d2, //	O-grave	Ò	O
0x0d9, //	U-grave	Ù	U
0x0e2, //	a-circumflex	â	a
0x0ea, //	e-circumflex	ê	e
0x0ee, //	i-circumflex	î	i
0x0f4, //	o-circumflex	ô	o
0x0fb, //	u-circumflex	û	u
0x0c2, //	A-circumflex	Â	A
0x0ca, //	E-circumflex	Ê	E
0x0ce, //	I-circumflex	Î	I
0x0d4, //	O-circumflex	Ô	O
0x0db, //	U-circumflex	Û	U
0x0e5, //	a-ring	å	a
0x0c5, //	A-ring	Å	A
0x0f8, //	o-slash	ø	o
0x0d8, //	O-slash	Ø	O
0x0e3, //	a-tilde	ã	a
0x0f1, //	n-tilde	ñ	n
0x0f5, //	o-tilde	õ	o
0x0c3, //	A-tilde	Ã	A
0x0d1, //	N-tilde	Ñ	N
0x0d5, //	O-tilde	Õ	O
0x0e6, //	ae-ligature	æ	ae
0x0c6, //	AE-ligature	Æ	AE
0x0e7, //	c-cedilla	ç	c
0x0c7, //	C-cedilla	Ç	C
0x0fe, //	Icelandic thorn	þ	th
0x0f0, //	Icelandic eth	ð	th
0x0de, //	Icelandic Thorn	Þ	Th
0x0d0, //	Icelandic Eth	Ð	Th
0x0a3, //	pound symbol	£	L
0x153, //	oe-ligature	œ	oe
0x152, //	OE-ligature	Œ	OE
0x0a1, //	inverted !	¡	!
0x0bf, //	inverted ?	¿	?
};

static void standard_mode() {
	tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios);
}

static void raw_mode() {
	tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw_termios);
}

void interface::init(int argc,char **argv) {
	tcgetattr(STDIN_FILENO, &orig_termios);
	atexit(standard_mode);
	cfmakeraw(&raw_termios);

	for (int i=1; i<argc; i++) {
		if (!strcmp(argv[i],"-script") && i+1<argc) {
			script_text = readStory(argv[++i],&script_size);
			if (!script_text) {
					fprintf(stderr,"unable to open script file %s\n",argv[i]);
					exit(1);
			}
			else
				nostatus = true;
		}
		else if (!strcmp(argv[i],"-di") && i+1<argc) {
			if (!di.read(argv[++i]))
				exit(1);
			else
				puts("debug info read okay");
		}
		else if (!strcmp(argv[i],"-debug"))
			debug_enable = true;
		else if (!strcmp(argv[i],"-strict"))
			strict_enable = true;
	}
}

void interface::updateHeader(uint8_t *header) {
		header[1] |= 0x1C;	// support bold, italic, fixed
}

static int window;
static FILE *transcript_file;

void uputc(uint8_t ch,FILE *f) {
	if (ch==13)
		fputc(10, f);
	else if (ch >= 155 && ch <= 223) {
		uint16_t cp = unicode_mapping[ch - 155];
		fputc(0xC0 | (cp >> 6),f);
		fputc(0x80 | (cp & 63),f);
	}
	else
		fputc(ch, f);
}

void interface::putchar(int ch) {
	if (!window || !nostatus)
		uputc(ch, stdout);
	if (!window && transcript_file)
		uputc(ch, transcript_file);
}

void interface::readline(char *dest,unsigned destSize) {
	if (script_offset < script_size) {
		unsigned offset = 0;
		while (destSize--) {
			dest[offset] = script_text[script_offset++];
			if (dest[offset++] == '\n')
				break;
		}
		dest[offset] = 0;
		printf("%s",dest);
		if (script_offset >= script_size)
			printf("{end of script, resuming interactive input}\n");
		return;
	}

	fgets(dest,destSize,stdin);
	if (transcript_file)
		fputs(dest,transcript_file);
}

int interface::readchar() {
	if (nostatus)
		return 32;
    char result;
    raw_mode(); 
    read(STDIN_FILENO, &result, 1); 
    standard_mode();
    return result;
}

uint16_t interface::setFont(uint16_t /*newFont*/) {
	return 0;
}

void interface::setTextStyle(uint8_t style) {
	// 0 = standard, 1=reverse_video, 2=bold, 4=italic, 8=fixed_pitch
	if (nostatus)
		return;
	if (style == 1)
		printf("\033[7m");
	else if (style == 2)
		printf("\033[1m");	
	else if (style == 4)
		printf("\033[4m");
	else if (style == 0)
		printf("\033[0m");
	
}

void interface::setTextColor(uint8_t fore,uint8_t back) {
	// terminal colors are black, red, green, yellow, blue, magenta, cyan, white, (reserved), default
	// interpreter colors are current, default, black, red, green, yellow, blue, magenta, cyan, white
	if (nostatus)
		;
	else {
		if (fore != 0)
			printf("\033[3%cm"," 901234567"[fore]);
		if (back != 0)
			printf("\033[4%cm"," 901234567"[back]);
	}
}

void interface::setWindow(uint8_t w) {
	window = w;
	if (nostatus)
		;
    else if (window)
    	printf("\0337\033[H");
    else
    	printf("\0338");
    fflush(stdout);
}

void interface::eraseWindow(uint8_t cmd) {
	if (nostatus)
		;
    else if (cmd == 1)
		printf("\033[H\033[2K");
	else
		printf("\033[\033[2J");
}

void interface::setCursor(uint8_t x,uint8_t y) {
	if (nostatus)
		;
	else
		printf("\033[%d;%dH",y,x);
	fflush(stdout);
}

void interface::updateExtents(uint8_t &width,uint8_t &height) {
	int fd = open("/dev/tty",O_EVTONLY | O_NONBLOCK);
	if (fd != -1) {
		struct winsize ws;
		int result = ioctl(fd,TIOCGWINSZ, &ws);
		close(fd);
		if (result != -1) {
			height = ws.ws_row;
			width = ws.ws_col;
		}
	}
}

bool interface::writeSaveData(chunk *chunks,uint32_t count) {
	char buf[64];
	printf("Save as?");
	fgets(buf,sizeof(buf),stdin);
	buf[strlen(buf)-1] = 0;
	if (buf[0]==0)
		return false;
	FILE *f = fopen(buf,"wb");
	if (!f) {
		printf("{cannot create file}\n");
		return false;
	}
	for (uint32_t i=0; i<count; i++)
		fwrite(chunks[i].data,1,chunks[i].size,f);
	fclose(f);
	return true;
}

bool interface::readSaveData(chunk *chunks,uint32_t count) {
	char buf[64];
	printf("Load from?");
	fgets(buf,sizeof(buf),stdin);
	buf[strlen(buf)-1] = 0;
	if (buf[0]==0)
		return false;
	FILE *f = fopen(buf,"rb");
	if (!f) {
		printf("{file not found}\n");
		return false;
	}
	for (uint32_t i=0; i<count; i++)
		fread(chunks[i].data,1,chunks[i].size,f);
	fclose(f);
	return true;
}

bool interface::transcript(bool flag) {
	static char transcript_name[64];
	if (flag) {
		if (!transcript_file) {
			if (!transcript_name[0]) {
				printf("Save transcript to?");
				fgets(transcript_name,sizeof(transcript_name),stdin);
				transcript_name[strlen(transcript_name)-1] = 0;
			}
			transcript_file = transcript_name[0]? fopen(transcript_name,"a") : nullptr;
		}
		return transcript_file != nullptr;
	}
	else {
		if (transcript_file) {
			fclose(transcript_file);
			transcript_file = nullptr;
		}
		return true;
	}
}

char* interface::readStory(const char *name,long *sizePtr) {
	FILE *f = fopen(name,"rb");
    if (!f)
        return nullptr;
	fseek(f,0,SEEK_END);
	long size = ftell(f);
	rewind(f);
	char *story = new char[size];
	if (sizePtr)
		*sizePtr = size;
	fread(story,1,size,f);
	fclose(f);
    return story;
}

int main(int argc,char **argv) {
	interface::init(argc,argv);
	char *story = interface::readStory(argv[1]);
	if (story) {
		machine *m = new machine;
		m->init(story,debug_enable,strict_enable);
	}	
}
