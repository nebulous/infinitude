CFLAGS=-std=c99 -I.

all: cardump

cardump: buffy.o crc.o cardump.o
	$(CC) -o cardump buffy.o crc.o cardump.o 

clean:
	rm *.o cardump

