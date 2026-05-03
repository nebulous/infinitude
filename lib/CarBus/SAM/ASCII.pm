package CarBus::SAM::ASCII;
use strict;
use warnings;
use feature ':5.10';
use Moo;
use IO::Termios;

has device => (is => 'ro', default => '/dev/cu.usbserial-21120');
has baud => (is => 'ro', default => '9600,8,n,1');
has system => (is => 'rw', default => 1);
has zone => (is => 'rw');
has fh => (is => 'rw');

# Command definitions with their response parsers
# Note: Commands marked "Touch: NAK" return NAK on Infinity Touch systems
my %commands = (
    # System status
    MODE     => { desc => 'System mode', type => 'system', parse => \&parse_mode },
    OAT      => { desc => 'Outdoor temperature', type => 'system', parse => \&parse_temp },
    HUMID    => { desc => 'Humidifier state', type => 'system', parse => \&parse_onoff },
    DAY      => { desc => 'Day of week', type => 'system', parse => \&parse_day },
    TIME     => { desc => 'Time of day', type => 'system', parse => \&parse_time },
    ZONE     => { desc => 'Displayed zone', type => 'system', parse => \&parse_number },
    PER      => { desc => 'Program period (Touch: NAK)', type => 'system', parse => \&parse_string },

    # Configuration
    BLIGHT   => { desc => 'Backlight', type => 'system', parse => \&parse_onoff },
    CFGEM    => { desc => 'Units (F/C)', type => 'system', parse => \&parse_units },
    CFGAUTO  => { desc => 'Auto mode enabled (Touch set: NAK)', type => 'system', parse => \&parse_onoff },
    CFGTYPE  => { desc => 'System type', type => 'system', parse => \&parse_string },
    CFGDEAD  => { desc => 'Deadband (Touch set: NAK)', type => 'system', parse => \&parse_number },
    CFGCPH   => { desc => 'Cycles per hour (Touch set: NAK)', type => 'system', parse => \&parse_number },
    CFGFAN   => { desc => 'Programmable fan (Touch: always ON, set NAK)', type => 'system', parse => \&parse_onoff },
    CFGPER   => { desc => 'Periods per day (Touch: NAK)', type => 'system', parse => \&parse_number },
    CFGPGM   => { desc => 'Programming enabled (Touch set: NAK)', type => 'system', parse => \&parse_onoff },

    # Accessories
    FILTRLVL => { desc => 'Filter life %', type => 'system', parse => \&parse_percent },
    UVLVL    => { desc => 'UV lamp life %', type => 'system', parse => \&parse_percent },
    HUMLVL   => { desc => 'Humidifier pad life %', type => 'system', parse => \&parse_percent },
    VENTLVL  => { desc => 'Ventilator filter life %', type => 'system', parse => \&parse_percent },
    FILTRRMD => { desc => 'Filter reminder', type => 'system', parse => \&parse_onoff },
    UVRMD    => { desc => 'UV lamp reminder', type => 'system', parse => \&parse_onoff },
    HUMRMD   => { desc => 'Humidifier reminder', type => 'system', parse => \&parse_onoff },
    VENTRMD  => { desc => 'Ventilator reminder', type => 'system', parse => \&parse_onoff },

    # Vacation
    VACAT    => { desc => 'Vacation state', type => 'system', parse => \&parse_onoff },
    VACDAYS  => { desc => 'Vacation days (max 365)', type => 'system', parse => \&parse_number },
    VACMINT  => { desc => 'Vacation min temp', type => 'system', parse => \&parse_temp },
    VACMAXT  => { desc => 'Vacation max temp', type => 'system', parse => \&parse_temp },
    VACMINH  => { desc => 'Vacation min humidity', type => 'system', parse => \&parse_percent },
    VACMAXH  => { desc => 'Vacation max humidity', type => 'system', parse => \&parse_percent },
    VACFAN   => { desc => 'Vacation fan', type => 'system', parse => \&parse_fan },

    # Dealer (Touch set: NAK - set via online/USB only)
    DEALER   => { desc => 'Dealer name (18 char max, Touch set: NAK)', type => 'system', parse => \&parse_string },
    DEALERPH => { desc => 'Dealer phone (18 char max, Touch set: NAK)', type => 'system', parse => \&parse_string },

    # Zone commands
    RT       => { desc => 'Room temperature', type => 'zone', parse => \&parse_temp },
    RH       => { desc => 'Room humidity (max 99%)', type => 'zone', parse => \&parse_percent },
    FAN      => { desc => 'Fan setting (Touch: AUTO=continuous off)', type => 'zone', parse => \&parse_fan },
    HOLD     => { desc => 'Hold status (Touch: "hold permanent")', type => 'zone', parse => \&parse_onoff },
    UNOCC    => { desc => 'Unoccupied (Touch: AWAY in hold permanent)', type => 'zone', parse => \&parse_onoff },
    HTSP     => { desc => 'Heat setpoint', type => 'zone', parse => \&parse_temp },
    CLSP     => { desc => 'Cool setpoint', type => 'zone', parse => \&parse_temp },
    RHTG     => { desc => 'Humidification target (max 99%)', type => 'zone', parse => \&parse_percent },
    OVR      => { desc => 'Override state ("hold until" active)', type => 'zone', parse => \&parse_onoff },
    OTMR     => { desc => 'Override timer (Touch: truncated to 15min)', type => 'zone', parse => \&parse_time },
    NAME     => { desc => 'Zone name (11 char max)', type => 'zone', parse => \&parse_string },
);

sub BUILD {
    my $self = shift;
    $self->connect() unless $self->fh;
}

sub connect {
    my $self = shift;
    my $fh = IO::Termios->open($self->device, $self->baud)
        or die "Cannot open " . $self->device . ": $!";
    $self->fh($fh);
}

sub disconnect {
    my $self = shift;
    if ($self->fh) {
        close($self->fh);
        $self->fh(undef);
    }
}

# Send raw command and get response (single attempt)
sub send {
    my ($self, $cmd) = @_;

    my $fh = $self->fh;
    $fh->blocking(0);

    # Flush any pending data
    while (1) {
        my $junk;
        my $n = sysread($fh, $junk, 4096);
        last unless $n && $n > 0;
    }

    # SAM RS-232 is extremely timing-sensitive:
    # - Need settling delay before write (100ms works, 50ms too short, 200ms too long)
    # - The SAM must have an active ABCD bus sync with the thermostat
    # - Without sync, commands return NAK (plain -- CCN timeout)
    # - Sync requires 10+ successful read/reply cycles with thermostat
    # - Commands should be sent during gaps in ABCD bus activity
    select(undef, undef, undef, 0.1);
    syswrite($fh, $cmd . "\r\n");

    # Read response with extended timeout
    # SAM may query the thermostat via ABCD bus before responding, which takes time
    my $response = '';
    my $timeout = 8;  # Match samterm/samser timeout
    my $start = time;

    while (time - $start < $timeout) {
        my $chunk;
        my $n = sysread($fh, $chunk, 256);
        if ($n && $n > 0) {
            $response .= $chunk;
            last if $response =~ /\n/;
        }
        select(undef, undef, undef, 0.01);
    }

    $response =~ s/[\r\n]+$//;
    return $response;
}

# Send command with retries (recommended for all SAM communication)
# SAM ASCII is unreliable - commands often need multiple attempts
sub send_with_retries {
    my ($self, $cmd, $max_retries) = @_;
    $max_retries //= 15;

    for my $attempt (1..$max_retries) {
        my $response = $self->send($cmd);

        # Success: got a non-NAK, non-empty response
        return $response if defined $response && $response ne '' && $response !~ /NAK/;

        # Wait before retry (300-500ms random)
        select(undef, undef, undef, 0.3 + rand(0.2));
    }

    return undef;  # All retries exhausted
}

# Build and send a command with retries
sub query {
    my ($self, $command, $zone) = @_;
    $zone //= $self->zone;

    my $cmd_str = $self->_build_command($command, '?', undef, $zone);
    return $self->send_with_retries($cmd_str);
}

sub set {
    my ($self, $command, $value, $zone) = @_;
    $zone //= $self->zone;

    my $cmd_str = $self->_build_command($command, '!', $value, $zone);
    return $self->send_with_retries($cmd_str);
}

sub _build_command {
    my ($self, $command, $op, $value, $zone) = @_;

    my $cmd = $command;

    # Check if zone is needed
    if (exists $commands{$command} && $commands{$command}{type} eq 'zone') {
        die "Zone required for command $command" unless defined $zone;
        $cmd = "Z${zone}${command}";
    }

    # Add value if set operation
    $cmd .= $op;
    $cmd .= $value if defined $value;

    # Add system prefix
    $cmd = "S" . $self->system . $cmd;

    return $cmd;
}

# Parse response into structured data
# Error types from Carrier spec:
#   NAK CMD - Invalid command or not supported
#   NAK VAL - Invalid parameter value
#   NAK     - CCN error or response timeout
sub parse_response {
    my ($self, $command, $response) = @_;

    return { error => 'No response' } unless defined $response && $response ne '';

    # Check for NAK with reason
    if ($response =~ /NAK\s+(CMD|VAL)/) {
        return { error => $1, raw => $response };
    }

    # Check for plain NAK (CCN error or timeout)
    if ($response =~ /NAK\b/) {
        return { error => 'CCN', raw => $response };
    }

    # Check for ACK
    if ($response =~ /ACK/) {
        return { success => 1, raw => $response };
    }

    # Extract value from response
    if ($response =~ /:\s*(.+)$/i) {
        my $value = $1;

        # Use command-specific parser if available
        if (exists $commands{$command} && $commands{$commands{$command}}) {
            my $parser = $commands{$command}{parse};
            return { value => $parser->($value), raw => $response };
        }

        return { value => $value, raw => $response };
    }

    return { raw => $response };
}

# Parser functions
sub parse_temp {
    my ($val) = @_;
    if ($val =~ /(-?\d+)\s*°?([FC])/i) {
        return { temp => $1 + 0, unit => uc($2) };
    }
    return $val;
}

sub parse_percent {
    my ($val) = @_;
    if ($val =~ /(\d+)\s*%?/) {
        return $1 + 0;
    }
    return $val;
}

sub parse_onoff {
    my ($val) = @_;
    return uc($val) eq 'ON' ? 1 : 0;
}

sub parse_mode {
    my ($val) = @_;
    # Mode format: MODE or MODE# where # is active demand stages
    # EHEAT can be commanded but always returns NAK on Touch
    if ($val =~ /^(HEAT|COOL|AUTO|OFF|EHEAT)(\d*)$/i) {
        return { mode => uc($1), stages => $2 || 0 };
    }
    return $val;
}

sub parse_fan {
    my ($val) = @_;
    return uc($val);  # AUTO, LOW, MED, HIGH
}

sub parse_day {
    my ($val) = @_;
    my %days = (
        SUNDAY => 0, MONDAY => 1, TUESDAY => 2, WEDNESDAY => 3,
        THURSDAY => 4, FRIDAY => 5, SATURDAY => 6
    );
    my %num_to_day = reverse %days;
    return $days{uc($val)} // $val;
}

sub parse_time {
    my ($val) = @_;
    if ($val =~ /(\d{1,2}):(\d{2})\s*([AP])/i) {
        return { hour => $1, minute => $2, period => uc($3) };
    }
    return $val;
}

sub parse_units {
    my ($val) = @_;
    return $val =~ /^[FC]$/ ? $val : $val;
}

sub parse_number {
    my ($val) = @_;
    return $val =~ /(\d+)/ ? $1 + 0 : $val;
}

sub parse_string {
    my ($val) = @_;
    return $val;
}

# Convenience methods for common operations
sub get_mode { shift->query('MODE') }
sub set_mode { shift->set('MODE', $_[0]) }

sub get_temp { my $self = shift; $self->query('RT', $_[0] // $self->zone) }
sub get_humidity { my $self = shift; $self->query('RH', $_[0] // $self->zone) }
sub get_heat_setpoint { my $self = shift; $self->query('HTSP', $_[0] // $self->zone) }
sub get_cool_setpoint { my $self = shift; $self->query('CLSP', $_[0] // $self->zone) }
sub set_heat_setpoint {
    my $self = shift;
    my ($zone, $temp, $duration);
    if (@_ == 3) {
        ($zone, $temp, $duration) = @_;
    } elsif (@_ == 2) {
        ($temp, $duration) = @_;
        $zone = $self->zone;
    } else {
        ($temp) = @_;
        $zone = $self->zone;
    }
    my $value = defined $duration ? "$temp,$duration" : $temp;
    $self->set('HTSP', $value, $zone);
}
sub set_cool_setpoint {
    my $self = shift;
    my ($zone, $temp, $duration);
    if (@_ == 3) {
        ($zone, $temp, $duration) = @_;
    } elsif (@_ == 2) {
        ($temp, $duration) = @_;
        $zone = $self->zone;
    } else {
        ($temp) = @_;
        $zone = $self->zone;
    }
    my $value = defined $duration ? "$temp,$duration" : $temp;
    $self->set('CLSP', $value, $zone);
}

sub get_fan { my $self = shift; $self->query('FAN', $_[0] // $self->zone) }
sub set_fan { my $self = shift; $self->set('FAN', $_[1], $_[0] // $self->zone) }

sub get_outdoor_temp { shift->query('OAT') }
sub get_time { shift->query('TIME') }
sub set_time { shift->set('TIME', $_[0]) }
sub get_day { shift->query('DAY') }
sub set_day { shift->set('DAY', $_[0]) }

sub get_hold { my $self = shift; $self->query('HOLD', $_[0] // $self->zone) }
sub set_hold { my $self = shift; $self->set('HOLD', $_[1], $_[0] // $self->zone) }

sub get_unoccupied { my $self = shift; $self->query('UNOCC', $_[0] // $self->zone) }
sub set_unoccupied { my $self = shift; $self->set('UNOCC', $_[1], $_[0] // $self->zone) }

sub get_override_state { my $self = shift; $self->query('OVR', $_[0] // $self->zone) }
sub get_override_timer { my $self = shift; $self->query('OTMR', $_[0] // $self->zone) }
sub set_override_timer { my $self = shift; $self->set('OTMR', $_[1], $_[0] // $self->zone) }

sub get_zone_name { my $self = shift; $self->query('NAME', $_[0] // $self->zone) }
sub set_zone_name { my $self = shift; $self->set('NAME', $_[1], $_[0] // $self->zone) }

# Accessory methods
sub get_filter_life { shift->query('FILTRLVL') }
sub reset_filter_life { shift->set('FILTRLVL', '0') }
sub get_uv_life { shift->query('UVLVL') }
sub reset_uv_life { shift->set('UVLVL', '0') }
sub get_humidifier_life { shift->query('HUMLVL') }
sub reset_humidifier_life { shift->set('HUMLVL', '0') }
sub get_ventilator_life { shift->query('VENTLVL') }
sub reset_ventilator_life { shift->set('VENTLVL', '0') }

# Vacation methods
sub get_vacation { shift->query('VACAT') }
sub set_vacation_days { shift->set('VACDAYS', sprintf('%03d', $_[0])) }  # Leading zeros for <100
sub get_vacation_days { shift->query('VACDAYS') }
sub end_vacation { shift->set('VACDAYS', '000') }
sub get_vacation_status {
    my $self = shift;
    return {
        active    => $self->query('VACAT'),
        days      => $self->query('VACDAYS'),
        min_temp  => $self->query('VACMINT'),
        max_temp  => $self->query('VACMAXT'),
        min_humidity => $self->query('VACMINH'),
        max_humidity => $self->query('VACMAXH'),
        fan       => $self->query('VACFAN'),
    };
}

# Units methods
sub get_units { shift->query('CFGEM') }
sub set_units { shift->set('CFGEM', $_[0]) }  # Use 'E' for English, 'M' for Metric

# Get all status for a zone
sub get_zone_status {
    my ($self, $zone) = @_;
    $zone //= $self->zone;
    die "Zone required" unless defined $zone;

    return {
        name           => $self->query('NAME', $zone),
        temperature    => $self->query('RT', $zone),
        humidity       => $self->query('RH', $zone),
        fan            => $self->query('FAN', $zone),
        heat_setpoint  => $self->query('HTSP', $zone),
        cool_setpoint  => $self->query('CLSP', $zone),
        hold           => $self->query('HOLD', $zone),
        unoccupied     => $self->query('UNOCC', $zone),
        override_state => $self->query('OVR', $zone),
        override_timer => $self->query('OTMR', $zone),
        humidification => $self->query('RHTG', $zone),
    };
}

# Get system status
sub get_system_status {
    my $self = shift;

    return {
        mode           => $self->query('MODE'),
        outdoor_temp   => $self->query('OAT'),
        humidifier     => $self->query('HUMID'),
        time           => $self->query('TIME'),
        day            => $self->query('DAY'),
        displayed_zone => $self->query('ZONE'),
        vacation       => $self->query('VACAT'),
        filter_life    => $self->query('FILTRLVL'),
        uv_life        => $self->query('UVLVL'),
        humidifier_life=> $self->query('HUMLVL'),
        ventilator_life=> $self->query('VENTLVL'),
        units          => $self->query('CFGEM'),
    };
}

1;

__END__

=head1 NAME

CarBus::SAM::ASCII - Carrier SAM ASCII Serial Protocol Interface

=head1 SYNOPSIS

    use CarBus::SAM::ASCII;

    my $sam = CarBus::SAM::ASCII->new(
        device => '/dev/cu.usbserial-21120',
        system => 1,
        zone   => 1,
    );

    # Get system mode
    my $mode = $sam->get_mode();
    print "Mode: $mode\n";

    # Get room temperature for zone 1
    my $temp = $sam->get_temp();
    print "Temperature: $temp\n";

    # Set heat setpoint (optionally with override timer)
    $sam->set_heat_setpoint(70);
    $sam->set_heat_setpoint(70, '01:30');  # With 1h30m override

    # Get full zone status
    my $status = $sam->get_zone_status(1);

=head1 DESCRIPTION

Interface to the Carrier SYSTXCCSAM01 System Access Module ASCII serial protocol.
Provides programmatic access to thermostat status and control via the SAM's
RS-232 serial port at 9600 baud.

=head1 COMPATIBILITY

Compatible SAM devices: SYSTXCCSAM01, SYSTXCCRCT01, SYSTXNNRCT01, SYSTXCCRWF01

B<Legacy UID/UIZ Controls:> Firmware 14+

B<Infinity Touch Controls:> Firmware 08+

Note: The SAM is designed for legacy UID/UIZ wall controls. When used with
Infinity Touch systems, some commands return NAK or behave differently.
See method documentation for Touch-specific behavior.

=head1 METHODS

=head2 Query Methods

=over 4

=item get_mode() - Get system mode (HEAT, COOL, AUTO, OFF, EHEAT)

=item get_temp([$zone]) - Get room temperature

=item get_humidity([$zone]) - Get room humidity (max 99%)

=item get_heat_setpoint([$zone]) - Get heat setpoint

=item get_cool_setpoint([$zone]) - Get cool setpoint

=item get_fan([$zone]) - Get fan setting (AUTO, LOW, MED, HIGH)
Touch: AUTO indicates continuous fan is OFF

=item get_outdoor_temp() - Get outdoor temperature

=item get_time() - Get time of day

=item get_day() - Get day of week

=item get_hold([$zone]) - Get hold status
Touch: Returns "hold permanent" status

=item get_unoccupied([$zone]) - Get unoccupied status
Touch: Maps to AWAY state in "hold permanent"

=item get_override_state([$zone]) - Get "hold until" timer active state

=item get_override_timer([$zone]) - Get "hold until" remaining time (HH:MM)
Touch: Values truncated to 15-minute intervals

=item get_zone_name([$zone]) - Get zone name (11 char max)

=item get_units() - Get temperature units (F or C)

=item get_filter_life() - Get filter consumption %

=item get_uv_life() - Get UV lamp consumption %

=item get_humidifier_life() - Get humidifier pad consumption %

=item get_ventilator_life() - Get ventilator filter consumption %

=back

=head2 Set Methods

=over 4

=item set_mode($mode) - Set mode (HEAT, COOL, AUTO, OFF, EHEAT)
Touch: EHEAT always returns NAK

=item set_heat_setpoint([$zone], $temp, [$duration]) - Set heat setpoint
Legacy: Default override 3 hours
Touch: Issues "hold until" in MANUAL if duration, else "hold permanent"
Example: set_heat_setpoint(1, 70, '01:30') for zone 1, 70 degrees, 1h30m

=item set_cool_setpoint([$zone], $temp, [$duration]) - Set cool setpoint
Legacy: Default override 2 hours
Touch: Same behavior as heat setpoint

=item set_fan([$zone], $setting) - Set fan (AUTO, LOW, MED, HIGH)
Touch: AUTO sets continuous fan to OFF

=item set_time($time) - Set time (HH:MM A/P format, leading zeros required)

=item set_day($day) - Set day (0-6, 0=Sunday)
Touch: Returns NAK

=item set_hold([$zone], $onoff) - Set hold (ON/OFF)
Touch: Issues/cancels "hold permanent"

=item set_unoccupied([$zone], $onoff) - Set unoccupied (ON/OFF)
Touch: ON sets AWAY in "hold permanent", OFF sets HOME in "hold permanent"

=item set_override_timer([$zone], $time) - Set override timer (HH:MM)
Send 00:00 to cancel. Touch: truncated to 15-min intervals.

=item set_zone_name([$zone], $name) - Set zone name (11 char max)

=item set_units($units) - Set units. Use 'E' for English (F), 'M' for Metric (C)

=item set_vacation_days($days) - Set vacation days (max 365, leading zeros for <100)

=item end_vacation() - End vacation (sets days to 0)

=item reset_filter_life() - Reset filter life to 0%

=item reset_uv_life() - Reset UV lamp life to 0%

=item reset_humidifier_life() - Reset humidifier pad life to 0%

=item reset_ventilator_life() - Reset ventilator filter life to 0%

=back

=head2 Bulk Methods

=over 4

=item get_zone_status([$zone]) - Get all status for a zone

=item get_system_status() - Get system-level status

=item get_vacation_status() - Get all vacation settings

=back

=head1 ERROR RESPONSES

The SAM returns NAK responses for errors:

=over 4

=item NAK CMD - Command not recognized or not supported

=item NAK VAL - Invalid parameter value

=item NAK - CCN error or response timeout

=back

=head1 AUTHOR

Infinitude Project

=cut
