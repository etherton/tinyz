#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// maps sector 0-15 to correct offset in .dsk file
// 0->0 7->1 14->2 6->3 13->4 5->5 12->6 4->7 11->8 3->9 10->10 2->11 9->12 1->13 8->14 15->15
const unsigned char xlat_do[] = { 0, 13, 11, 9, 7, 5, 3, 1, 14, 12, 10, 8, 6, 4, 2, 15 };

// 0->0 8->1 1->2 9->3 2->4 10->5 3->6 11->7 4->8 12->9 5->10 13->11 6->12 14->13 7->14 15->15
const unsigned char xlat_po[] = { 0, 2, 4, 6, 8, 10, 12, 14, 1, 3, 5, 7, 9, 11, 13, 15 };


// nib files are 6656 bytes per track. applewin writes 336 zero bytes between sectors
// since actual disk track length is closer to 6384 bytes.
//                          volume track sector checksum
// address field: $d5 $aa $96 XX YY XX YY XX YY XX YY $de $aa $ab
// XX = 1 d7 1 d5 1 d3 1 d1
// YY = 1 d6 1 d4 1 d2 1 d0
// data field : $d5 $aa $ad / 342 bytes of data / checksum / $de $aa $ab
// valid bytes have high bit set, no more than one run of two zero bits, and
// also there must be at least two adjacent bits set, not counting bit 7.

const unsigned char nibbles[] = {
	0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA6,
	0xA7, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB2, 0xB3,
	0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC,
	0xBD, 0xBE, 0xBF, 0xCB, 0xCD, 0xCE, 0xCF, 0xD3,
	0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE,
	0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC,
	0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6,
	0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF
};

int main(int argc,char **argv) {
	char *in = new char[35*16*256];
	memset(in,0,35*16*256);
	int offset = 0;
	for (int i=1; i<argc; i++) {
		if (!strcmp(argv[i],"-o")) {
			const char *ext = strrchr(argv[i+1],'.');
			if (!ext) {
				fprintf(stderr,"file '%s' needs extension\n",argv[i+1]);
				return 2;
			}
			FILE *o = fopen(argv[i+1],"wb");
			if (!o) {
				fprintf(stderr,"cannot create file '%s'\n",argv[i+1]);
				return 2;
			}
			if (!strcmp(ext,".dsk") || !strcmp(ext,".do")) {
				for (int track=0; track<35; track++) {
					for (int sector=0; sector<16; sector++) {
						fwrite(in + track * 4096 + xlat_do[sector] * 256,1,256,o);
					}
				}
			}
			else if (!strcmp(ext,".po")) {
				for (int track=0; track<35; track++) {
					for (int sector=0; sector<16; sector++) {
						fwrite(in + track * 4096 + xlat_po[sector] * 256,1,256,o);
					}
				}
			}
			else if (!strcmp(ext,".hdv")) {
				fwrite(in, 35*16, 256, o);
			}
			else if (!strcmp(ext,".nib")) {
				for (int track=0; track<35; track++) {
					for (int sector=0; sector<16; sector++) {
						fwrite(in + track * 4096 + xlat_po[sector] * 256,1,256,o);
					}
				}
			}
			else {
				fprintf(stderr,"unknown extension '%s'\n",ext);
				return 2;
			}
			fclose(o);
			printf("Wrote '%s'\n",argv[i+1]);
			return 0;
		}
		else {
			FILE *f = fopen(argv[i],"rb");
			if (!f) {
				fprintf(stderr,"cannot open '%s'\n",argv[i]);
				return 1;
			}
			fseek(f,0,SEEK_END);
			int size = ftell(f);
			fseek(f,0,SEEK_SET);
			if (fread(in + offset,1,size,f) != size) {
				fprintf(stderr,"short read on '%s'\n",argv[i]);
				return 1;
			}
			printf("Section '%s' offset %d size %d\n",argv[i],offset,size);
			offset += size;
			fclose(f);
		}
	}
	return 1;
}
