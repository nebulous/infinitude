cardump opens a serial tty and dumps any valid Carrier/Bryant serial frames found.

It's a simple and fast utility to monitor or log RS485 traffic. It does not write to the bus.

My C skills are quite rusty, but cardump is known to compile on x86/MIPS/ARM processors and under uClinux

A C compiler and basic build tools are required.
To build:

    make

Pipe from a serial tty(see <a target="_blank" href="http://www.amazon.com/Infinitude-hardware/lm/R2G4T8HWC1AQDK/?_encoding=UTF8&camp=1789&creative=390957&linkCode=ur2&tag=sbec-20&linkId=THB3EP6RU76EIXOA">Infinitude Hardware</a><img src="https://ir-na.amazon-adsystem.com/e/ir?t=sbec-20&l=ur2&o=1" width="1" height="1" border="0" alt="" style="border:none !important; margin:0px !important;" /> for inexpensive rs485 interfaces.) for best results:

    ./cardump < /dev/ttyS0

Or on a log file, but the timestamps won't be very useful:

    ./cardump < aLogFile 


TSV of valid frames dumps to STDOUT and human readable output goes to STDERR.
So, to create a TSV logfile and simultaneously monitor activity, one might run:

    ./cardump < /dev/ttyUSB0 > frames.tsv
    
