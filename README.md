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

WiFi module is a MICROCHIP - MRF24WB0MA (<a href="http://ww1.microchip.com/downloads/en/DeviceDoc/70632C.pdf">datasheet</a>)

<a href="http://www.amazon.com/gp/product/B005T8M3U8/ref=as_li_ss_il?ie=UTF8&camp=1789&creative=390957&creativeASIN=B005T8M3U8&linkCode=as2&tag=sbhq-20">
  <img src="http://ws-na.amazon-adsystem.com/widgets/q?_encoding=UTF8&ASIN=B005T8M3U8&Format=_SL160_&ID=AsinImage&MarketPlace=US&ServiceVersion=20070822&WS=1&tag=sbhq-20" >
</a>

It appears to handle encryption on board and have a SPI bus interface, so as a last resort that can be sniffed.


It has a 14 pin H-UDI debug connector as well as at least one debug serial port broken out.
All control apps seem to be based on Adobe AIR. Does it run Linux? Can it be rooted? Any ideas or knowledge welcome.

Proprietary ABCD port is really just RS485 serial(AB) and 24VAC(CD). 

<table>
  <thead>
    <tr>
      <th>Port</th>
      <th>Suggested Color</th>
      <th>Function</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>A</td>
      <td>Green</td>
      <td>RS-485 D+</td>
    </tr>
    <tr>
      <td>B</td>
      <td>Yellow</td>
      <td>RS-485 D-</td>
    </tr>
    <tr>
      <td>C</td>
      <td>White</td>
      <td>24v AC Common</td>
    </tr>
    <tr>
      <td>D</td>
      <td>Red</td>
      <td>24v AC Hot</td>
    </tr>
  </tbody>
</table>
  

There has been [some discussion](http://cocoontech.com/forums/topic/11372-carrier-infinity/page-4) of reverse 
engineering the control protocol, but no success to my knowledge. I would love to
be proven wrong about that. 

Recently purchased a cheap ch341 based RS485 adapter like this one:

<a href="http://www.amazon.com/gp/product/B009SIDMNM/ref=as_li_ss_il?ie=UTF8&camp=1789&creative=390957&creativeASIN=B009SIDMNM&linkCode=as2&tag=sbhq-20"><img border="0" src="http://ws-na.amazon-adsystem.com/widgets/q?_encoding=UTF8&ASIN=B009SIDMNM&Format=_SL110_&ID=AsinImage&MarketPlace=US&ServiceVersion=20070822&WS=1&tag=sbhq-20" ></a><img src="http://ir-na.amazon-adsystem.com/e/ir?t=sbhq-20&l=as2&o=1&a=B009SIDMNM" width="1" height="1" border="0" alt="" style="border:none !important; margin:0px !important;" />

I have some logs and a parser that I'll post here RealSoonNow&reg; 
Serial data is 38400 8N1 and is mostly the thermostat sending requests for data and the air handler/outdoor units replying with it.
From the helpful thread above the frame format is:

<table>
  <tr>
    <th colspan="7">Frame</th>
  </tr>
  <tr>
    <th colspan="5">Header</th>
    <th rowspan="2">Data</th>
    <th rowspan="2">Checksum</th>
  </tr>
  <tr>
    <th>2 bytes</th>
    <th>2 bytes</th>
    <th>1 byte</th>
    <th>2 bytes</th>
    <th>1 byte</th>
  </tr>
  <tr>
    <td>Dest Address</td>
    <td>Source Address</td>
    <td>Length</td>
    <td>Reserved</td>
    <td>Function</td>
    <th>0-255 bytes</th>
    <th>2 bytes</th>
  </tr>
</table>

<a href="http://imgur.com/HoHzQqA"><img src="http://i.imgur.com/HoHzQqA.jpg" title="Hosted by imgur.com" alt="" /></a>
