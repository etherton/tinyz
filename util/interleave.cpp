#include <stdio.h>

int main(int,char**) {
	for (int i=0; i<64; i++) {
		int a = ((i & 2) >> 1) | ((i & 1) << 1);
		int b = ((i & 8) >> 3) | ((i & 4) >> 1);
		int c = ((i & 32) >> 5) | ((i & 16) >> 3);
		printf("\t!byte %d,%d,%d,%d\n",a,b,c,0);
	}
}
