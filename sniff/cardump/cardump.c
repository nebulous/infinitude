#include <termios.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <time.h>

#include "buffy.h"
#include "crc.h"

/* Set terminal (tty) into "raw" mode: no line or other processing done
   Terminal handling documentation:
       curses(3X)  - screen handling library.
       tput(1)     - shell based terminal handling.
       terminfo(4) - SYS V terminal database.
       termcap     - BSD terminal database. Obsoleted by above.
       termio(7I)  - terminal interface (ioctl(2) - I/O control).
       termios(3)  - preferred terminal interface (tc* - terminal control).
*/

void tty_atexit(void);
int tty_reset(void);
void tty_raw(void);
int screenio(void);
void fatal(char *mess);

static struct termios orig_termios;  /* TERMinal I/O Structure */
static int ttyfd = STDIN_FILENO;     /* STDIN_FILENO is 0 by default */

int main(int argc, char **argv) {
    /* check that input is from a tty */
    if (isatty(ttyfd)) {
			/* store current tty settings in orig_termios */
			if (tcgetattr(ttyfd,&orig_termios) < 0) fatal("can't get tty settings");
			/* register the tty reset with the exit handler */
			if (atexit(tty_atexit) != 0) fatal("atexit: can't register tty reset");
			tty_raw();      /* put tty in raw mode */
		} else {
			fprintf(stderr,"Not a tty. Reading from file...\n");
		}

    screenio();     /* run application code */
    return 0;       /* tty_atexit will restore terminal */
}


/* exit handler for tty reset */
void tty_atexit(void)  /* NOTE: If the program terminates due to a signal   */
{                      /* this code will not run.  This is for exit()'s     */
	printf("Exit. Reset tty to initial settings.\n");
	tty_reset();        /* only.  For resetting the terminal after a signal, */
}                      /* a signal handler which calls tty_reset is needed. */

/* reset tty - useful also for restoring the terminal when this process
   wishes to temporarily relinquish the tty
*/
int tty_reset(void) {
	/* flush and reset */
	if (tcsetattr(ttyfd,TCSAFLUSH,&orig_termios) < 0) return -1;
	return 0;
}


void tty_raw() {
	struct termios raw;

	raw = orig_termios;  /* copy original and then modify below */

	/* input modes - clear indicated ones giving: no break, no CR to NL, 
		 no parity check, no strip char, no start/stop output (sic) control */
	raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);

	/* output modes - clear giving: no post processing such as NL to CR+NL */
	raw.c_oflag &= ~(OPOST);

	/* control modes - set 8 bit chars */
	raw.c_cflag |= (CS8);

	/* local modes - clear giving: echoing off, canonical off (no erase with 
		 backspace, ^U,...),  no extended functions, no signal chars (^Z,^C) */
	raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);

	/* control chars - set return condition: min number of bytes and timer */
	raw.c_cc[VMIN] = 5; raw.c_cc[VTIME] = 8; /* after 5 bytes or .8 seconds
																							after first byte seen      */
	raw.c_cc[VMIN] = 0; raw.c_cc[VTIME] = 0; /* immediate - anything       */

	raw.c_cc[VMIN] = 2; raw.c_cc[VTIME] = 0; /* after two bytes, no timer  */
	raw.c_cc[VMIN] = 0; raw.c_cc[VTIME] = 8; /* after a byte or .8 seconds */

	/* put terminal in raw mode after flushing */
	if (tcsetattr(ttyfd,TCSAFLUSH,&raw) < 0) fatal("can't set raw mode");

	printf("input speed was %d\n",cfgetispeed(&orig_termios));
	cfsetispeed(&orig_termios, B38400); //Set 38.4k
	cfsetospeed(&orig_termios, B38400); //Set 38.4k
	printf("input speed set to %d\n",cfgetispeed(&orig_termios));
}

typedef struct {
	uint8_t dst;
	uint8_t dst_idx;
	uint8_t src;
	uint8_t src_idx;
	uint8_t len;
	uint16_t reserved;
	uint8_t type;
} carhead;

typedef struct {
	carhead head;
	char payload[256];
	uint16_t crc;
} carframe;


int screenio(void) {
	int bytes;

	buffy framebuf;
	framebuf.len = 0;
	carhead header;
	crcInit();

	char buffer[32]; //serial reads tend to have less than 32 bytes

	uint8_t tries = 0;
	printf("Time\tFrom\tTo\tType\tLength\tHex Content\n");
	for (;;) {
		bytes = read(ttyfd, buffer, 32);
		if (bytes < 0) fatal("Read error");
		if (bytes == 0) { tries+=1; } else { tries = 0; }
		if (tries>9) fatal("Not trying again");

		bufadd(&framebuf, buffer, bytes);

		int datalen = framebuf.data[4];
		int framelen = 10+datalen;
		fprintf(stderr, "added %d bytes. Looking for %d byte frame in %d byte buffer\n", bytes, datalen, framebuf.len);

		if (framebuf.len>=framelen) { 
			if (crcFast(framebuf.data, framelen) == 0) {
				memcpy(&header, framebuf.data,8);
				printf("%d\t%x\t%x\t%x\t%x", (int)time(NULL),header.src, header.dst, header.type, header.len);
				for (int i=0;i<header.len;i++) {
					printf("%02x ", framebuf.data[8+i]);
				}
				printf("\n");
				bufshift(&framebuf, framelen);
			} else {
				bufshift(&framebuf, 1);
			}
		}
	}
}

void fatal(char *message) {
	fprintf(stderr,"fatal error: %s\n",message);
	exit(1);
}
