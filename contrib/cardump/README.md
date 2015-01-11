cardump opens a serial tty and dumps any valid Carrier/Bryant serial frames found.

It's a simple and fast utility to monitor or log RS485 traffic. It does not write to the bus.

My C skills are quite rusty, but cardump is known to compile on x86/MIPS/ARM processors and under uClinux

A C compiler and basic build tools are required.
To build:

    make

Pipe from a serial tty for best results:

    ./cardump < /dev/ttyS0

Or on a log file, but the timestamps won't be very useful:

    ./cardump < aLogFile 


TSV of valid frames dumps to STDOUT and human readable output goes to STDERR.
So, to create a TSV logfile and simultaneously monitor activity, one might run:

    ./cardump < /dev/ttyUSB0 > frames.tsv
    
