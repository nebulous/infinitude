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


###Device information and protocol discussion available on the [Wiki](https://github.com/nebulous/infinitude/wiki)
