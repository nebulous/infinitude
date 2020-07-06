FROM ubuntu:xenial

ADD . /infinitude
WORKDIR /infinitude

RUN apt-get update

RUN apt-get install -y git jq cpanminus libchi-perl libmojolicious-perl libdatetime-perl libxml-simple-perl libtry-tiny-perl libmoo-perl libjson-perl libjson-maybexs-perl libhash-asobject-perl libdata-parsebinary-perl libdigest-crc-perl libcache-perl libtest-longstring-perl libio-pty-perl libpath-tiny-perl

RUN cpanm -n IO::Termios 

RUN apt autoremove -y
RUN apt-get clean

EXPOSE 3000
ENTRYPOINT ./entrypoint.sh
