# CLAUDE.md

## Project Overview

Infinitude is an alternative web service for Carrier Infinity Touch and compatible thermostats. It provides local control bypassing Carrier's cloud services, allowing direct web-based control of:

- Temperature setpoints
- Schedules
- Dealer information

Infinitude also optionally monitors the Carrier/Bryant RS485 (ABCD) bus to obtain higher resolution access to thermostat, air handler, heat pump, and other device registers. Serial data can be monitored via an attached serial port or networked serial bridge.

**Important:** Infinitude is not compatible with thermostat firmware versions newer than 4.05.

## Architecture

### Backend
- **Language:** Perl
- **Framework:** Mojolicious::Lite
- **Object System:** Moo
- **Caching:** CHI (file-based)
- **Protocol:** Custom CarBus RS485 implementation

### Frontend
- **Framework:** AngularJS 1.x
- **UI:** Bootstrap
- **Build:** Grunt + Bower

### Key Components
- Main web application with RESTish API
- CarBus protocol handler for RS485 communication
- XML parsing and processing
- Serial monitoring with real-time register tracking

## Directory Structure

```
infinitude          # Main application entry point (Perl Mojolicious app)
lib/
  CarBus.pm         # RS485 bus protocol handler
  CarBus/Frame.pm   # Frame parsing and validation
  CarBus/SAM.pm     # SAM emulation and register definitions
  CarBus/SAM/ASCII.pm # SAM ASCII serial protocol interface
  samterm           # Interactive SAM ASCII terminal
  cbt.pl            # CarBus test/bridge script
  XML/Simple/Minded.pm  # Custom XML parser
docs/
  SAM-ASCII-Protocol.md # SAM RS-232 ASCII protocol specification
public/
  app/              # AngularJS frontend source
  dist/             # Built frontend assets
defs/               # XML configuration schemas for systems
state/              # Runtime data and cache (gitignored)
t/                  # Test suite
contrib/
  cardump/          # C-based RS485 packet dumper utility
climate             # Command-line utility for RS485 communication
```

## Commands

### Running with Docker (Recommended)
```bash
# Basic run
docker run --rm -v $PWD/state:/infinitude/state -p 3000:3000 nebulous/infinitude

# With environment variables
docker run --rm -v $PWD/state:/infinitude/state \
  -e APP_SECRET='YOUR_SECRET_HERE' \
  -e PASS_REQS='1020' \
  -p 3000:3000 \
  nebulous/infinitude

# Using docker-compose
docker-compose up
```

### Running from Source
```bash
# Install dependencies
cpanm --installdeps .

# Development mode (port 3000)
./infinitude daemon

# Production mode (port 80)
./infinitude daemon -l http://:80
```

### Building Frontend
```bash
cd public/
./build-dist.sh
```

### Testing
```bash
# Run all tests
prove -t t/

# Run specific test
prove t/01-xml-simple-minded.t
```

## Configuration

Configuration is stored in `infinitude.json` and can be overridden via environment variables:

| Variable | Description |
|----------|-------------|
| `APP_SECRET` | Cookie signature string |
| `PASS_REQS` | Min seconds between Carrier server requests (0 = never) |
| `MODE` | `production` (default) or `development` |
| `SERIAL_TTY` | RS485 device (e.g., `/dev/ttyUSB0`) |
| `SERIAL_SOCKET` | TCP/RS485 bridge (e.g., `192.168.1.42:23`) |
| `LOGLEVEL` | Minimum log severity |
| `SCAN_THERMOSTAT` | Enable continuous thermostat table scanning |
| `EMULATE_SAM` | Enable SAM emulation on RS485 bus (1 = enabled) |

## Code Conventions

- **Perl Library Path:** All Perl commands must include `-I ~/perl5/lib/perl5 -I lib` to find local modules
- **Boilerplate:** All Perl files use `use strict`, `use warnings`, `use feature ':5.10'`
- **OOP:** Use Moo for object-oriented programming
- **Error Handling:** Use Try::Tiny for exceptions
- **Web Framework:** Mojolicious::Lite with hooks and routes
- **File Operations:** Path::Tiny for file handling

## Key Files

| File | Purpose |
|------|---------|
| `infinitude` | Main application - routes, API endpoints, business logic |
| `lib/CarBus.pm` | RS485 protocol implementation |
| `lib/CarBus/Frame.pm` | Binary frame parsing for bus messages |
| `lib/XML/Simple/Minded.pm` | Custom XML parser for thermostat data |
| `cpanfile` | Perl dependency declarations |
| `Dockerfile` | Alpine-based container build |
| `docker-compose.yaml` | Container orchestration |

## API Structure

The application provides a RESTish API that intercepts requests normally destined for Carrier's servers. Key patterns:

- Requests matching `(bryant|carrier|ioncomfort|infinitude)` hosts are intercepted
- XML data is parsed and stored in the CHI cache
- Responses are cached and can be served without contacting Carrier servers
- API endpoints return XML or JSON depending on content type

## Development Notes

### RS485 Serial Communication
- Read-only by default
- Requires IO::Termios for serial port access
- Can use network serial bridges via IO::Socket::IP
- CarBus module handles protocol parsing

### Frontend Development
- AngularJS app located in `public/app/`
- Built assets go to `public/dist/`
- Development mode serves from `public/app/`, production from `public/dist/`

### Security
- HTTP only (no HTTPS) - run on trusted networks only
- Cookie signing via APP_SECRET
- Traffic between thermostat and Infinitude is unencrypted

### SAM (System Access Module)
- SAM has two serial interfaces:
  - **ABCD bus side** (38400 baud, binary CarBus protocol) - connects to thermostat network
  - **RS-232 side** (9600 baud, ASCII protocol) - for home automation integration
- ASCII protocol documented in `docs/SAM-ASCII-Protocol.md`
- Use `lib/samterm` for interactive SAM ASCII terminal

## Related Projects

- [Infinitude Home Assistant Integration](https://github.com/MizterB/homeassistant-infinitude-beyond)
- [Infinitive](https://github.com/acd/infinitive) - RS485 control for non-touch thermostats
- [Protocol Wiki](https://github.com/nebulous/infinitude/wiki)
