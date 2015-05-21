#Infinitude
###Documentation and [information on protocol(s) available on the Wiki](https://github.com/nebulous/infinitude/wiki). Please contribute!

#### Infinitude is an alternative web service for [Carrier Infinity Touch](https://github.com/nebulous/infinitude/wiki/Infinity-touch) and compatible thermostats.

It allows direct web-based control of
  * Temperature setpoints
  * Schedules
  * Dealer information

As well as monitoring of weather and any other sensors you may want to integrate.

<img src="http://i.imgur.com/1LhLKbp.png" />


Infinitude can also optionally monitor the Carrier/Bryant RS485 bus for higher resolution access to your thermostat, air handler, heat pump, and other devices. The serial monitor keeps track of the current state, and highlights changing bytes to aid in protocol analysis.

<img src="http://i.imgur.com/5Ge1zEM.png" />

Demonstrated in the video below:

[![Real time RS485 monitoring](http://img.youtube.com/vi/ybjCumDG_d8/0.jpg)](https://www.youtube.com/watch?v=ybjCumDG_d8)

#### Requirements

##### Software
 * Some flavor of UNIX. Both Linux and OSX are known to work.
 * Perl
   * Mojolicious
   * DateTime
   * [WWW::Wunderground::API](https://metacpan.org/module/WWW::Wunderground::API)
   * [IO::Termios](https://metacpan.org/module/IO::Termios) optional for RS485 serial monitoring
   * Try::Tiny
   * Cache::FileCache
   * JSON

##### Hardware
 * Basic hardware capable of running Linux. This could be a desktop machine, a Raspberry Pi, or an embedded device. The author runs Infinitude on ArchLinux using a [Pogoplug v4](http://www.amazon.com/Pogoplug-Series-4-Backup-Device/dp/B006I5MKZY/ref=sr_1_1?ie=UTF8&tag=sbhq-20&qid=1415825203&sr=8-1&keywords=pogoplug) which can be obtained for less than $20 USD and sits on top of the air handler like so:

<a href="http://imgur.com/a/bkcHX#1"><img src="http://i.imgur.com/IESJCCw.jpg" title="source: imgur.com" /></a>

See <a target="_blank" href="http://www.amazon.com/Infinitude-hardware/lm/R2G4T8HWC1AQDK/?_encoding=UTF8&camp=1789&creative=390957&linkCode=ur2&tag=sbec-20&linkId=THB3EP6RU76EIXOA">Infinitude Hardware</a><img src="https://ir-na.amazon-adsystem.com/e/ir?t=sbec-20&l=ur2&o=1" width="1" height="1" border="0" alt="" style="border:none !important; margin:0px !important;" /> for recommended devices.

####Usage
 * Set your proxy server/port in the advanced wireless settings on the thermostat to point to your infinitude host/port. 
 * Edit the $conf section of the infinitude file to set your optional Wunderground API key or RS485 serial tty device.
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
