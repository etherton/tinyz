#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// maps sector 0-15 to correct offset in .dsk file
const unsigned char xlat[] = { 0, 13, 11, 9, 7, 5, 3, 1, 14, 12, 10, 8, 6, 4, 2, 15 };

int main(int argc,char **argv) {
	char *in = new char[35*16*256];
	memset(in,0,35*16*256);
	int offset = 0;
	for (int i=1; i<argc; i++) {
		if (!strcmp(argv[i],"-o")) {
			FILE *o = fopen(argv[i+1],"wb");
			if (!o)
				return 2;
			for (int track=0; track<35; track++) {
				for (int sector=0; sector<16; sector++) {
					fwrite(in + track * 4096 + xlat[sector] * 256,1,256,o);
				}
			}
			fclose(o);
			printf("Wrote '%s'\n",argv[i+1]);
			return 0;
		}
		else {
			FILE *f = fopen(argv[i],"rb");
			if (!f)
				return 1;
			fseek(f,0,SEEK_END);
			int size = ftell(f);
			fseek(f,0,SEEK_SET);
			if (fread(in + offset,1,size,f) != size) {
				fprintf(stderr,"short read\n");
				return 1;
			}
			printf("Section '%s' offset %d size %d\n",argv[i],offset,size);
			offset += size;
			fclose(f);
		}
	}
	return 1;
}
