#!/bin/sh

#path to the casperjs bin
CASPERPATH="$HOME/src/casperjs/bin/casperjs"

#output json to this file
JSONPATH="infinity_status.txt"

#add any phantomJS command line options here
OPT="--cookies-file=carriercookies.txt"

#Your carrier username
USERNAME=''

#Your carrier password
PASSWORD=''

$CASPERPATH $OPT scrape_infinity.js $USERNAME $PASSWORD >> $JSONPATH
