#Infinitude
###Replacement programmable web service for Carrier Infinity* thermostats
*and presumably Bryant as well

#### Requirements

 * Perl/[Plack](https://github.com/miyagawa/Plack) and friends
 * [Web::Simple](https://metacpan.org/module/Web::Simple)
 * DateTime
 * [WWW::Wunderground::API](https://metacpan.org/module/WWW::Wunderground::API)  - 0.05 or newer. Github has lastest (https://github.com/nebulous/WWW-Wunderground-API)

####Usage 
 * Set your proxy server/port in the advanced wireless settings on the thermostat itself. 
 * Start Infinitude. Remember this is not encrypted, so use locally or over a VPN.


    plackup -l _yourProxyIP:yourProxyPort_ -a Infinitude.pm --no-default-middleware



With any luck, Carrier will allow the owners of these devices and data direct access rather
than this ridiculous work around. If you have one of these thermostats, tell
Carrier you'd like direct network access to your thermostat, or at the very
least, access to a public API!


###Assorted device information
SOC used is a SuperH (SH2A) architecture 7267 running at 144Mhz
http://www.renesas.com/products/mpumcu/superh/sh7260/sh7266/device/R5S72670W144FP.jsp

It has a 14 pin H-UDI debug connector as well as at least one debug serial port broken out.
All control apps seem to be based on Adobe AIR. Does it run Linux? Can it be rooted? Any ideas or knowledge welcome.

Proprietary ABCD port is really just RS485 serial(AB) and 24VAC(CD). There has been [some discussion](http://cocoontech.com/forums/topic/11372-carrier-infinity/page-4) of reverse 
engineering the control protocol, but no success to my knowledge. I would love to
be proven wrong about that. Recently purchased a cheap RS485 adapter. If I can get any useful logs, will post them here.

<a href="http://imgur.com/HoHzQqA"><img src="http://i.imgur.com/HoHzQqA.jpg" title="Hosted by imgur.com" alt="" /></a>
