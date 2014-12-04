#Infinitude
###Documentation and information on protocol available on the [Wiki](https://github.com/nebulous/infinitude/wiki). Please contribute!

#### Infinitude is an alternative web service for [Carrier Infinity Touch*](https://github.com/nebulous/infinitude/wiki/Infinity-touch) thermostats.

*and presumably other Carrier/Bryant network thermostats as well

Screenshot of recent version:
<a href="http://imgur.com/s2BrXXt"><img src="http://i.imgur.com/s2BrXXt.png" title="Hosted by imgur.com"/></a>

#### Requirements

 * Basic hardware capable of running Linux. See author's <a target="_blank" href="http://www.amazon.com/Infinitude-hardware/lm/R2G4T8HWC1AQDK/?_encoding=UTF8&camp=1789&creative=390957&linkCode=ur2&tag=sbec-20&linkId=THB3EP6RU76EIXOA">Infinitude Hardware</a><img src="https://ir-na.amazon-adsystem.com/e/ir?t=sbec-20&l=ur2&o=1" width="1" height="1" border="0" alt="" style="border:none !important; margin:0px !important;" /> for recommended devices around $20 USD

 * Perl/[Plack](https://github.com/miyagawa/Plack) and friends
 * [Web::Simple](https://metacpan.org/module/Web::Simple)
 * DateTime
 * [WWW::Wunderground::API](https://metacpan.org/module/WWW::Wunderground::API)  - 0.05 or newer. Github has lastest (https://github.com/nebulous/WWW-Wunderground-API)

####Usage 
 * Set your proxy server/port in the advanced wireless settings on the thermostat itself. 
 * Start Infinitude. Remember this is not encrypted, so use locally or over a VPN.
 *   The author runs the web service and serial monitor on a [Pogoplug v4](http://www.amazon.com/Pogoplug-Series-4-Backup-Device/dp/B006I5MKZY/ref=sr_1_1?ie=UTF8&tag=sbhq-20&qid=1415825203&sr=8-1&keywords=pogoplug) which sits on top of the air handler. 


    plackup -l _yourProxyIP:yourProxyPort_ -a Infinitude.pm --no-default-middleware


With any luck, Carrier will allow the owners of these devices and data direct access rather
than this ridiculous work around. If you have one of these thermostats, tell
Carrier you'd like direct network access to your thermostat, or at the very
least, access to a public API!
