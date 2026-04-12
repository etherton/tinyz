#include <stdio.h>
#include <string.h>

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
	printf("    !text \"");
	for (int i=0; i<argc; i++)
		printf("%s",argv[i]);
	printf("\"\n");
	return 0;	
}
