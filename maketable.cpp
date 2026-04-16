#include <stdio.h>
#include <string.h>
#include <assert.h>

int main(int argc,char **argv) {
	--argc,++argv;
	if (argc != 16 && argc != 32) {
		fprintf(stderr,"expected either 16 or 32 entries\n");
		return 1;
	}
	printf("    !byte %d,",argc+2);
	int offset = 0;
	for (int i=0; i<argc; i++) {
		printf("%d,",offset);
		offset += strlen(argv[i]);
	}
	printf("%d\n",offset);
	if (offset > 255) {
		fprintf(stderr,"table too large by %d bytes\n",offset-255);
		return 1;
	}
#if 1
	printf("    !text \"");
	for (int i=0; i<argc; i++)
		printf("%s",argv[i]);
	printf("\"\n");
#else
	int accum = 0, bits = 0, first = 1;
	printf("    !byte");
	for (int i=0; i<argc; i++) {
		for (int j=0; j<strlen(argv[i]); j++) {
			int ch = argv[i][j];
			if (ch>='_'&&ch<='z')
				ch -= '_';
			else if (ch>='0'&&ch<='3')
				ch = 28 + (ch-'0');
			else
				fprintf(stderr,"invalid character %c\n",ch);
			assert(ch>=0 && ch<32);
			accum |= ch << bits;
			bits += 5;
			if (bits >= 8) {
				printf("%c%d",first?' ':',',accum&255);
				first = 0;
				bits -= 8;
				accum >>= 8;
			}
		}
	}
	if (bits)
		printf(",%d\n",accum);
	else
		printf("\n");
#endif
	return 0;	
}
