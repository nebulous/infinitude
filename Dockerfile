FROM ubuntu:xenial

ADD . /infinitude

RUN apt-get update && apt-get -y upgrade \
	&& apt-get install -y git jq build-essential cpanminus libchi-perl libmojolicious-perl libdatetime-perl libxml-simple-perl libmoo-perl libjson-maybexs-perl libhash-asobject-perl libdata-parsebinary-perl libdigest-crc-perl libcache-perl libtest-longstring-perl libio-pty-perl \
    && chmod +x /infinitude/infinitude \
    && cd /infinitude \
    && cpanm -n Mojolicious::Lite CHI DateTime Try::Tiny Path::Tiny JSON IO::Termios
EXPOSE 3000
ENTRYPOINT /infinitude/docker/entrypoint.sh
