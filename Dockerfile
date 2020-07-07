FROM debian:latest

COPY . /infinitude
WORKDIR /infinitude

RUN apt-get update \
&& apt-get install -y jq cpanminus libchi-perl libmojolicious-perl libdatetime-perl libxml-simple-perl libtry-tiny-perl libmoo-perl libjson-perl libjson-maybexs-perl libhash-asobject-perl libdata-parsebinary-perl libdigest-crc-perl libcache-perl libtest-longstring-perl libio-pty-perl libpath-tiny-perl \
&& cpanm -n IO::Termios \ 
&& apt autoremove -y \
&& apt-get clean \
&& rm -rf /var/lib/apt/lists/* 

ENV APP_SECRET="Pogotudinal"
ENV PASS_REQS="1020"
ENV MODE="Production"
ENV LANG="en_US.UTF-8"
ENV SERIAL_TTY=""
ENV SERIAL_SOCKET=""

EXPOSE 3000
# ENTRYPOINT /infinitude/entrypoint.sh
CMD ["bash", "/infinitude/entrypoint.sh"]