# Infinitude

![Docker image Build Status](https://github.com/nebulous/infinitude/workflows/Multi-architecture%20Build%20Status/badge.svg?branch=master)
![Docker Hub documentation](https://github.com/nebulous/infinitude/workflows/Push%20Description%20&%20README%20to%20Docker%20Hub/badge.svg?branch=master)

## Documentation and [information on protocol(s) available on the Wiki](https://github.com/nebulous/infinitude/wiki). Please contribute!

### Infinitude is an alternative web service for [Carrier Infinity Touch](https://github.com/nebulous/infinitude/wiki/Infinity-touch) and compatible thermostats.

Infinitude allows direct web-based control of
  * Temperature setpoints (per zone)
  * Schedules (7-day, 5-period per zone)
  * System mode (heat/cool/auto/off)
  * Fan speed per zone
  * Hold modes and activity presets
  * Vacation scheduling

As well as providing an open RESTish API

<img width="1032" height="623" alt="image" src="https://github.com/user-attachments/assets/e638064a-26aa-43e5-9178-63973b3ab030" />

<img width="1119" height="300" alt="image" src="https://github.com/user-attachments/assets/dcdd8637-aaa4-45f1-b44a-daf34d2146e5" />

<img width="1015" height="592" alt="image" src="https://github.com/user-attachments/assets/0c19b9fd-d1b3-41fd-a140-fce1b85d35dc" />

### Serial monitoring / control 

Infinitude can also optionally monitor the Carrier/Bryant RS485(ABCD) bus to obtain higher resolution access to values within your thermostat, air handler, heat pump, and other devices.
Infinitude provides a serial monitor which keeps track of the current state of registers on the serial bus, and highlights changing bytes to aid in protocol analysis.
Serial data can be monitored via an attached serial port or via a networked serial bridge.

With SAM emulation enabled (`EMULATE_SAM=1`), Infinitude can also write setpoints, mode, fan speed, and hold settings directly to the RS485 bus. **SAM emulation is experimental. If Infinitude stops, the thermostat continues operating with a communication error.**

<img width="1121" height="665" alt="image" src="https://github.com/user-attachments/assets/b6634bda-af9d-4e2f-8fd2-036c31a2cbe7" />



### Home Assistant Integration via MQTT Discovery

Infinitude can register itself directly as climate entities in Home Assistant using MQTT Discovery. No separate integration is needed — Infinitude publishes discovery payloads, state, and accepts commands all via MQTT. Requires an MQTT broker (e.g., Mosquitto).

Each enabled zone appears as a climate entity with:
  * Current temperature and humidity
  * Target temperature (heat/cool/auto modes, including range control)
  * HVAC mode, fan mode, and preset modes (home, away, sleep, wake, hold)
  * HVAC action (heating/cooling/idle via `zoneconditioning`)

System-level sensors (outdoor temperature, filter levels, humidifier state) are also published.

<img src="http://i.imgur.com/5Ge1zEM.png" />

RS485 stream monitoring example video:

[![Real time RS485 monitoring](http://img.youtube.com/vi/ybjCumDG_d8/0.jpg)](https://www.youtube.com/watch?v=ybjCumDG_d8)

Serial-based control of some older _non-touch_ thermostats is provided by the [Infinitive project](https://github.com/acd/infinitive). Infinitude also provides experimental RS485 serial monitoring and SAM emulation for direct bus control — see the serial configuration options below.

## ⚠️ Safety Notice

**This software communicates with and may control HVAC equipment.** It is experimental and not a replacement for OEM hardware. Improper use could result in property damage, equipment damage, or hazardous conditions including frozen pipes, overheating, or loss of heating/cooling. Use is entirely at your own risk. See [NOTICE](NOTICE) for additional disclaimer.

Emulation features carry additional risk:

| Feature | Risk if Infinitude stops |
|---------|------------------------|
| SAM emulation | Low — thermostat continues with a communication error |
| ZC emulation | **High — conditioning may stop entirely** |

Zone Controller emulation should not be used in the critical HVAC control loop. It is provided for protocol development and testing. See [docs/ZC-Emulation-Roadmap.md](docs/ZC-Emulation-Roadmap.md) for details.

## Installation

### ⚠️ Firmware compatibility: Infinitude is not compatible with all thermostat firmware versions. See the [Compatibility Matrix](https://github.com/nebulous/infinitude/wiki/Infinitude-Compatibility-Matrix) for known-working combinations — and add yours if it works for you. If your thermostat has auto-updated past a supported version, see [issues/148](https://github.com/nebulous/infinitude/issues/148) for discussion.

#### Docker - Recommended
Prebuilt Docker containers are available for multiple architectures on [DockerHub](https://hub.docker.com/r/nebulous/infinitude), or you can build a container manually with the included Dockerfile.
Special thanks go to @scyto for instrumental contributions to the Infinitude containers in general, and multiarch builds in particular.

Infinitude configuration parameters can be passed through environment variables into the container.  Support is included for:

| Variable | Description |
| --- | --- |
| APP_SECRET | Cookie signature string. Matters to almost nobody | 
| PASS_REQS | Minimum amount of time to wait(in seconds) between requests to Carrier/Bryant servers. `0` means never. |
| MODE | `production`(default) or `development`(more logging) |
| SERIAL_TTY | optional rs485 device string eg `/dev/ttyUSB0` |
| SERIAL_SOCKET | optional tcp/rs485 bridge string eg `192.168.1.42:23` |
| LOGLEVEL | optional [minimum severity of log messages to print](https://docs.mojolicious.org/Mojo/Log#level) |
| SCAN_THERMOSTAT | truthy values on systems with serial connectivity cause Infinitude to continuously scan each Thermostat table |
| EMULATE_SAM | Enable SAM emulation for RS485 bus writes (1 = enabled) |
| EMULATE_ZC | Enable Zone Controller emulation (**⚠️ high risk, see Safety Notice**) |
| MQTT_BROKER | MQTT broker address (e.g., `192.168.1.3:1883`). Enables Home Assistant MQTT Discovery. |
| MQTT_USER | Optional MQTT broker username |
| MQTT_PASS | Optional MQTT broker password |
| MQTT_PREFIX | HA discovery prefix (default: `homeassistant`) |
| MQTT_TOPIC | MQTT base topic (default: `infinitude`) |


the published container can be run as

`docker run --rm -v $PWD/state:/infinitude/state -p 3000:3000 nebulous/infinitude`

with additional config items as ENV vars

```
docker run --rm -v $PWD/state:/infinitude/state \
-e APP_SECRET='YOUR_SECRET_HERE' \
-e PASS_REQS='1020' \
-e MODE='production' \
-p 3000:3000 \
nebulous/infinitude
```

or via the included [docker-compose file](https://github.com/nebulous/infinitude/blob/master/docker-compose.yaml).
`docker compose up`


#### Manual installation Requirements

The easiest way to run Infinitude is by running a published Docker image, but if you'd like to install manually, these are the basic requirements

##### Software
 * Some flavor of UNIX. Both Linux and OSX are known to work and some have even used Strawberry Perl in Windows.
 * Perl — dependencies are listed in the included `cpanfile`. Install them with `cpanm --installdeps .`
   * `IO::Termios` and `Net::MQTT::Simple` are optional (for RS485 serial and MQTT respectively)

###### Raspbian-specific
Many users opt to run Infinitude on a Raspberry Pi. This is also most easily accomplished using a Docker image, but
[More specific manual installation instructions are available on the wiki](https://github.com/nebulous/infinitude/wiki/Installing-Infinitude-on-Raspberry-PI-(raspbian))


##### Hardware

Basic hardware capable of running docker or a unix/posix system. This could be a desktop machine, many people use a [Raspberry Pi](https://amzn.to/2StGo8z), or any embedded device with sufficient memory and storage. The author runs Infinitude in a Docker container on an [Atomic PI](https://amzn.to/3bgufMV), but has also used a Pandaboard and first ran it on the very limited [Pogoplug v4](http://www.amazon.com/Pogoplug-Series-4-Backup-Device/dp/B006I5MKZY/ref=sr_1_1?ie=UTF8&tag=sbhq-20&qid=1415825203&sr=8-1&keywords=pogoplug) hardware, which at the time(2014) cost less than $10 USD and sat on top of the air handler and allowed for a USB RS485 dongle to interface with it.

See <a target="_blank" href="https://www.amazon.com/ideas/amzn1.account.AEFBGWAOB3IGADYQPGQRC566Z2FA/19DKMPAQCZX12?type=explore&ref=idea_cp_vl_ov_d&tag=sbec-20" width="1" height="1" border="0" alt="" style="border:none !important; margin:0px !important;">a list of hardware others have used.</a>


#### Usage / Thermostat configuration
 * Set your proxy server/port in the advanced wireless settings on the thermostat to point to your infinitude host/port.
 * Edit `infinitude.json` to configure optional settings (RS485 serial, MQTT, etc).
 * Start Infinitude. This traffic is _not encrypted_, so only run on a trusted network.

Infinitude is a Mojolicious application, so the simplest way to run it from source is via:

    ./infinitude daemon

which starts a server in development mode on port 3000.

Or to listen on port 80:

    ./infinitude daemon -l http://:80

See ./infinitude <command> --help for additional options

Infinitude exists because device owners like their Infinity systems and deserve local access
to their own equipment and data. We hope manufacturers will continue to expand official
local API options for these systems.


### See Also

- [InfinitESP hardware-based SAM emulator](https://github.com/nebulous/infinitesp)
- [Infinitude Home Assistant Integration](https://github.com/MizterB/homeassistant-infinitude-beyond)
- [Infinitive project for RS485 control of non-touch thermostats](https://github.com/acd/infinitive)
- [Anantha modifies thermostat firmware to intercept AWS IoT control traffic](https://github.com/anupcshan/anantha)
