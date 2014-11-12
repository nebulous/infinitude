Opens a tty and dumps valid frames.
Simple and fast, cross compiles and runs nicely in uClinux without interpreter overhead
My C skills are _very_ rusty, but this does the job for now

Use on a serial tty for best results:

    ./cardump < /dev/ttyS0

Or on a log file, but the timestamps won't be very useful:

    ./cardump < aLogFile 


TSV of valid frames dumps to STDOUT and human readable output goes to STDERR.
So to log TSV and watch activity one might:

    ./cardump < /dev/ttyUSB0 > frames.tsv
    
    
