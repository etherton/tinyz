#include <stdio.h>

int main(int,char**) {
	for (int i=1; i<=255; i++) {
		int c = 26 + 27*i + 5*i*i;
		float f = 0.98f * c;
		printf("a=%d, %d cycles, %f usec\n",i,c,f);
	}

	return 0;
}
 