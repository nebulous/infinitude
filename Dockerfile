ARG BASE_IMAGE=alpine:latest
FROM ${BASE_IMAGE}

COPY . /infinitude
WORKDIR /infinitude

RUN apk add --no-cache make perl-app-cpanminus perl-mojolicious perl-chi perl-datetime perl-path-tiny perl-json perl-xml-simple perl-moo perl-io-tty
RUN cpanm -n Data::ParseBinary Digest::CRC Hash::AsObject IO::Termios
RUN apk --purge del apk-tools make perl-app-cpanminus

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV APP_SECRET="Pogotudinal"
ENV PASS_REQS="1020"
ENV MODE="Production"
ENV SERIAL_TTY=""
ENV SERIAL_SOCKET=""

EXPOSE 3000

ENTRYPOINT ["/infinitude/entrypoint.sh"]
