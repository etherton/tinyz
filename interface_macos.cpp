#include "machine.h"

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
	}
}

static int window;

void interface::putchar(int ch) {
	if (!window || !nostatus)
    	putc(ch==13?10:ch, stdout);
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


void interface::setTextStyle(uint8_t style) {
	if (nostatus)
		;
	else if (style == 1)
		printf("\033[7m");
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
		m->init(story,argc>2&&!strcmp(argv[2],"-debug"));
	}	
}