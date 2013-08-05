Scrape Infinity
==============

Uses [PhantomJS](https://github.com/ariya/phantomjs) and [CasperJS](https://github.com/n1k0/casperjs) to login and scrape thermostat data from https://www.myinfinitytouch.carrier.com/.

Only tested on my own single zone Carrier Infinity Touch thermostat, 
but I'd welcome patches from anyone with multiple zones or an original Infinity series.

With any luck, Carrier will allow the owners of this data direct access rather
than this ridiculous work around. If you have one of these thermostats, tell
Carrier you'd like direct network access to your thermostat, or at the very
least, access to a public API!

Can the Flash/Air application be scraped or controlled? Input welcomed. I miss my Proliphix.

####Usage
After setting your username and password:

    ./scrape_infinity.sh 


###Assorted device information
SOC used is a SuperH (SH2A) architecture 7267 running at 144Mhz
http://www.renesas.com/products/mpumcu/superh/sh7260/sh7266/device/R5S72670W144FP.jsp

It has a 14 pin H-UDI debug connector as well as at least one debug serial port broken out.
All control apps seem to be based on Adobe AIR. Does it run Linux? Can it be rooted?

Proprietary ABCD port is really just RS485 serial(AB) and 24VAC(CD). There has been [some discussion](http://cocoontech.com/forums/topic/11372-carrier-infinity/page-4) of reverse 
engineering the control protocol, but no success to my knowledge. I would love to
be proven wrong about that. Recently purchased a cheap RS485 adapter. If I can get any useful logs, will post them here.

<a href="http://imgur.com/HoHzQqA"><img src="http://i.imgur.com/HoHzQqA.jpg" title="Hosted by imgur.com" alt="" /></a>
