#include <termios.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <time.h>

#include "buffy.h"
#include "crc.h"

/* raw tty code mostly from:
	http://www.cs.uleth.ca/~holzmann/C/system/ttyraw.c */

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



#define ACK02 0x02
#define ACK06 0x06
#define READ_TABLE_BLOCK 0x0b
#define WRITE_TABLE_BLOCK 0x0c
#define CHANGE_TABLE_NAME 0x10
#define NACK 0x15
#define ALARM_PACKET 0x1e
#define READ_OBJECT_DATA 0x22
#define READ_VARIABLE 0x62
#define WRITE_VARIABLE 0x63
#define AUTO_VARIABLE 0x64
#define READ_LIST 0x75

#pragma pack(push, 1)

typedef struct {
	uint8_t table;
	uint8_t row;
} careg;

typedef struct {
	uint8_t type;
	uint8_t idx;
} cardev;

typedef struct {
	 cardev dst;
	 cardev src;
	uint8_t len;
   uint16_t reserved;
	uint8_t type;
	   char payload[256];
   uint16_t crc;
} carframe;

typedef struct {
	   char pad;
      careg reg;
} caread;

typedef struct {
	   char pad;
	  careg reg;
       char payload[256];
} carwrite;

typedef struct {
	   char ack;
	  careg reg;
} careply;


#pragma pack(pop)


int screenio(void) {
	int bytes;

	buffy framebuf;
	framebuf.len = 0;
	carframe frame;
	crcInit();

	char buffer[32]; //serial reads tend to have less than 32 bytes

	uint8_t tries = 0;
	printf("Time\tFrom\tTo\tType\tLength\tHex Content\n");
	int shifts = 0;
	int syncs = 0;

	for (;;) {
		bytes = read(ttyfd, buffer, 32);
		if (bytes < 0) fatal("Read error");
		if (bytes == 0) { tries+=1; } else { tries = 0; }
		if (tries>9) fatal("Not trying again");

		bufadd(&framebuf, buffer, bytes);

		if (framebuf.len<4) continue;
		int datalen = framebuf.data[4];
		if (datalen == 0) {
			shifts++;
			bufshift(&framebuf, (int)(framebuf.len>>1));
			continue;
		}

		int framelen = 10+datalen;
		if (framebuf.len<framelen) continue;

		if (shifts>0) fprintf(stderr, "Looking for %d byte frame in %d byte buffer\n", datalen, framebuf.len);

		if (crcFast(framebuf.data, framelen) == 0) {
			if (shifts>0) {
				fprintf(stderr,"*** Synced stream after %d shifts ***\n", shifts);
				shifts=0;
				syncs++;
				if (syncs>100) fatal("Stream too noisy");
			}
			memcpy(&frame, framebuf.data, framelen);
			frame.crc=framebuf.data[framelen-2]<<8 | framebuf.data[framelen-1];

			if (READ_TABLE_BLOCK == frame.type) {
				fprintf(stderr, "--------------READ from %x ------------\n", frame.dst.type);
				caread req;
				memcpy(&req, frame.payload, 3);
				fprintf(stderr,"Request for table %d, row %d\n", req.reg.table, req.reg.row);
			}

			if (WRITE_TABLE_BLOCK == frame.type) {
				fprintf(stderr, "--------------WRITE to %x ------------\n", frame.dst.type);
				carwrite req;
				memcpy(&req, frame.payload, 256);
				fprintf(stderr,"Write to table %d, row %d\n", req.reg.table, req.reg.row);
				for (int i=0;i<frame.len;i++) fprintf(stderr, "%02x ", req.payload[i]);
				fprintf(stderr, "\n");
			}

			if (ACK06 == frame.type) {
				//Example of a known data point.
				if (frame.src.type == 0x50 && frame.payload[1] == 0x3E && frame.payload[2] == 0x01) {
					int16_t oat = (frame.payload[3]<<8) | frame.payload[4];
					int16_t t2 = (frame.payload[5]<<8) | frame.payload[6];
					fprintf(stderr, "Outside Temp: %df %04x\n", oat/16, oat);
					fprintf(stderr, "Outside Coil: %df %04x\n", t2/16, t2);
				}
			}

			if (frame.payload[1] == 0x02) {
				if (frame.payload[2] == 0x02) { //Time Frame
					fprintf(stderr,"Time is %d:%d\n", frame.payload[3], frame.payload[4]);
				}
				if (frame.payload[2] == 0x03) { //Date Frame
					fprintf(stderr,"Date is %d-%d-%d\n", frame.payload[5]+2000, frame.payload[4], frame.payload[3]);
				}
			}

			printf("%d\t%x\t%x\t%02x\t%d\t", (int)time(NULL),frame.src.type, frame.dst.type, frame.type, frame.len);
			for (int i=0;i<frame.len;i++) printf("%02x ", frame.payload[i]);
			printf("\n");

			bufshift(&framebuf, framelen);
		} else {
			shifts++;
			bufshift(&framebuf, 1);
		}
	}
}

void fatal(char *message) {
	fprintf(stderr,"fatal error: %s\n",message);
	exit(1);
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

	//printf("input speed was %d\n",cfgetispeed(&orig_termios));
	cfsetispeed(&orig_termios, B38400); //Set 38.4k
	cfsetospeed(&orig_termios, B38400); //Set 38.4k
	//printf("input speed set to %d\n",cfgetispeed(&orig_termios));
}

