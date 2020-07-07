FROM debian:latest

COPY . /infinitude
WORKDIR /infinitude

RUN apt-get update \
&& apt-get install -y jq locales cpanminus libchi-perl libmojolicious-perl libdatetime-perl libxml-simple-perl libtry-tiny-perl libmoo-perl libjson-perl libjson-maybexs-perl libhash-asobject-perl libdata-parsebinary-perl libdigest-crc-perl libcache-perl libtest-longstring-perl libio-pty-perl libpath-tiny-perl \
&& cpanm -n IO::Termios \ 
&& localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 \
&& apt-get -y --purge remove cpanminus \ 
&& apt autoremove -y \
&& apt-get clean \
&& rm -rf /var/lib/apt/lists/* 

ENV LANG en_US.UTF-8  
ENV LANGUAGE en_US:en  
ENV LC_ALL en_US.UTF-8
ENV APP_SECRET="Pogotudinal"
ENV PASS_REQS="1020"
ENV MODE="Production"
ENV SERIAL_TTY=""
ENV SERIAL_SOCKET=""

EXPOSE 3000

CMD ["bash", "/infinitude/entrypoint.sh"]