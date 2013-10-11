#include <string.h>
#include "buffy.h"

void bufadd(buffy *thebuf, char *toadd, int len) {
	if (thebuf->len+len>BUFMAX) {
		bufshift(thebuf, len);
	}
	memcpy(thebuf->data+thebuf->len, toadd, len);
	thebuf->len = thebuf->len + len;
}

void bufshift(buffy *thebuf, int bytes) {
	memmove(thebuf->data, thebuf->data+bytes, thebuf->len-bytes);
	thebuf->len = thebuf->len - bytes;
}
