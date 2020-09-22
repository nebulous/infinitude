# Infinitude

![Docker image Build Status](https://github.com/nebulous/infinitude/workflows/Multi-architecture%20Build%20Status/badge.svg?branch=master)
![Docker Hub documentation](https://github.com/nebulous/infinitude/workflows/Push%20Description%20&%20README%20to%20Docker%20Hub/badge.svg?branch=master)

## Documentation and [information on protocol(s) available on the Wiki](https://github.com/nebulous/infinitude/wiki). Please contribute!

### Infinitude is an alternative web service for [Carrier Infinity Touch](https://github.com/nebulous/infinitude/wiki/Infinity-touch) and compatible thermostats.

Infinitude allows direct web-based control of
  * Temperature setpoints
  * Schedules
  * Dealer information

As well as providing an open RESTish API 

<img src="http://i.imgur.com/1LhLKbp.png" />

Infinitude can also optionally monitor the Carrier/Bryant RS485(ABCD) bus for higher resolution access to your thermostat, air handler, heat pump, and other devices.
Infinitude provides a serial monitor to keeps track of the current state of registers on the serial bus, and highlights changing bytes to aid in protocol analysis.
Serial monitoring can be done via an attached serial port or via a networked serial bridge.


<img src="http://i.imgur.com/5Ge1zEM.png" />

RS485 stream monitoring example video:

[![Real time RS485 monitoring](http://img.youtube.com/vi/ybjCumDG_d8/0.jpg)](https://www.youtube.com/watch?v=ybjCumDG_d8)


Infinitude does **not** control thermostats via the RS485 bus at this time. RS485 communication is optional, and _read only_. 
Serial-based control of some older _non-touch_ thermostats is provided by the [Infinitive project](https://github.com/acd/infinitive)


#### Docker
Prebuilt Docker containers are available on [DockerHub](https://hub.docker.com/r/nebulous/infinitude) or you can build one manually with the included Dockerfile.
Special thanks go to @scyto for instrumental contributions to the Infinitude containers in general, and multiarch builds in particular.

Infinitude configuration parameters can be passed through environment variables into the container.  Support is included for:

| Variable | Description |
| --- | --- |
| APP_SECRET | Cookie signature string. Matters to almost nobody | 
| PASS_REQS | Minimum amount of time to wait(in seconds) between requests to Carrier/Bryant servers. `0` means never. |
| MODE | `production`(default) or `development`(more logging) |
| SERIAL_TTY | optional rs485 device string eg `/dev/ttyUSB0` |
| SERIAL_SOCKET | optional tcp/rs485 bridge string eg `192.168.1.42:23` | 


the published container can be run as

`docker run --rm -v $PWD/state:/infinitude/state -p 3000:3000 nebulous/infinitude`

with additional config items as ENV vars

```
docker run --rm -v $PWD/state:/infinitude/state \
-e APP_SECRET='YOUR_SECRET_HERE' \
-e PASS_REQS='1020' \
-e MODE='Production' \
-p 3000:3000 \
nebulous/infinitude
```

or via the included [docker-compose file](https://github.com/nebulous/infinitude/blob/master/docker-compose.yaml).
`docker-compose up`


#### Manual installation Requirements

The easiest way to run Infinitude is by running a published Docker image, but if you'd like to install manually, these are the basic requirements

##### Software
 * Some flavor of UNIX. Both Linux and OSX are known to work and some have even used Strawberry Perl in Windows.
 * Perl with the following modules
   * Mojolicious
   * DateTime
   * [IO::Termios](https://metacpan.org/module/IO::Termios) optional for RS485 serial monitoring
   * Path::Tiny
   * Try::Tiny
   * JSON
   
##### Dependency Installation
  * a cpanfile is provided which lists Infinitude's minimum dependencies.
  * use your distribution's packaging system, your favorite cpan installer, or `sudo cpanm --installdeps .` to install

###### Raspbian-specific
Many users opt to run Infinitude on a Raspberry Pi. This is also most easily accomplished using a Docker image, but
[More specific manual installation instructions are available on the wiki](https://github.com/nebulous/infinitude/wiki/Installing-Infinitude-on-Raspberry-PI-(raspbian))


##### Hardware

Basic hardware capable of running docker or a unix/posix system. This could be a desktop machine, many people use a [Raspberry Pi](https://amzn.to/2StGo8z), or any embedded device with sufficient memory and storage. The author runs Infinitude in a Docker container on an [Atomic PI](https://amzn.to/3bgufMV), but has also used a Pandaboard and first ran it on the very limited [Pogoplug v4](http://www.amazon.com/Pogoplug-Series-4-Backup-Device/dp/B006I5MKZY/ref=sr_1_1?ie=UTF8&tag=sbhq-20&qid=1415825203&sr=8-1&keywords=pogoplug) hardware, which at the time(2014) cost less than $10 USD and sat on top of the air handler and allowed for a USB RS485 dongle to interface with it.

See <a target="_blank" href="https://www.amazon.com/ideas/amzn1.account.AEFBGWAOB3IGADYQPGQRC566Z2FA/19DKMPAQCZX12?type=explore&ref=idea_cp_vl_ov_d&tag=sbec-20" width="1" height="1" border="0" alt="" style="border:none !important; margin:0px !important;">a list of hardware others have used.</a>


#### Usage
 * Set your proxy server/port in the advanced wireless settings on the thermostat to point to your infinitude host/port. 
 * Edit the $conf section of the infinitude file to set your optional RS485 serial tty device.
 * Start Infinitude. This traffic is _not encrypted_, so only run on a trusted network.

Infinitude is a Mojolicious application, so the simplest way to run it is via:

    ./infinitude daemon

which starts a server in development mode on port 3000.

Or to listen on port 80:

    ./infinitude daemon -l http://:80

See ./infinitude <command> --help for additional options

With any luck, Carrier will allow the owners of these devices and data direct access rather
than this ridiculous work around. If you have one of these thermostats, tell
Carrier you'd like direct network access to your thermostat, or at the very
least, access to a public API!
