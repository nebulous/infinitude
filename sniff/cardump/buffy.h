#define BUFMAX 2048

typedef struct {
	int len;
	char data[BUFMAX];
} buffy;

void bufadd(buffy *thebuf, char *toadd, int len);
void bufshift(buffy *thebuf, int bytes);
