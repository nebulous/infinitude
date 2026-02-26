package CarBus::SAM;
use strict;
use warnings;
use feature ':5.10';
use Moo;
use Data::ParseBinary;
use CarBus::Frame;

has bus => (is => 'ro', required => 1);
has registers => (is => 'rw', default => sub { {} });
has handlers => (is => 'ro', default => sub { {} });

# Register definitions - metadata about SAM registers
my %register_defs = (
    '3B02' => { name => 'sam_state',     access => 'r' },
    '3B03' => { name => 'sam_zones',     access => 'rw' },
    '3B04' => { name => 'sam_vacation',  access => 'rw' },
    '3B05' => { name => 'sam_accessories', access => 'r' },
    '3B06' => { name => 'sam_dealer',    access => 'rw' },
);

# Register SAM parsers with Frame.pm on module load
CarBus::Frame->register_parser('3B02', Struct('sam_state',
    Byte('active_zones'),
    Padding(2),
    Array(8, Byte('temperature')),
    Array(8, Byte('humidity')),
    Padding(1),
    Byte('oat'),
    BitStruct('zones_unoccupied',
        Flag('z8'), Flag('z7'), Flag('z6'), Flag('z5'),
        Flag('z4'), Flag('z3'), Flag('z2'), Flag('z1'),
    ),
    BitStruct('stagmode',
        Nibble('stage'),
        Enum(Nibble('mode'), heat=>0, cool=>1, auto=>2, eheat=>3, off=>4)
    ),
    Array(2, Byte('unknown')),
    Enum(Byte('weekday'), Sunday=>0, Monday=>1, Tuesday=>2, Wednesday=>3, Thursday=>4, Friday=>5, Saturday=>6),
    UBInt16('minutes_since_midnight'),
    Byte('displayed_zone')
));

CarBus::Frame->register_parser('3B03', Struct('sam_zones',
    Byte('active_zones'),
    Padding(2),
    Array(8, Enum(Byte('fan_mode'), high=>3, medium=>2, low=>1, auto=>0 )),
    BitStruct('zones_holding',
        Flag('z8'), Flag('z7'), Flag('z6'), Flag('z5'),
        Flag('z4'), Flag('z3'), Flag('z2'), Flag('z1'),
    ),
    Array(8, Byte('heat_setpoint')),
    Array(8, Byte('cool_setpoint')),
    Array(8, Byte('humidity_setpoint')),
    Byte('speed_controlled_fan'),
    Byte('hold_timer'),
    Array(8, UBInt16('hold_duration')),
    Array(8, Field('zone_name', 12))
));

CarBus::Frame->register_parser('3B04', Struct('sam_vacation',
    Byte('active'),
    UBInt16('hours'),
    Byte('min_temp'),
    Byte('max_temp'),
    Byte('min_humidity'),
    Byte('max_humidity'),
    Byte('fan_mode')
));

CarBus::Frame->register_parser('3B05', Struct('sam_accessories',
    Padding(3),
    Byte('filter_consumption'),
    Byte('uv_consumption'),
    Byte('humidifier_consumption'),
    Enum(Byte('filter_reminders'), off=>0, on=>1),
    Enum(Byte('uv_reminders'), off=>0, on=>1),
    Enum(Byte('humidifier_reminders'), off=>0, on=>1),
));

CarBus::Frame->register_parser('3B06', Struct('sam_dealer',
    Byte('backlight'),
    Byte('auto_mode'),
    Padding(1),
    Byte('deadband'),
    Byte('cycles_per_hour'),
    Byte('schedule_periods'),
    Byte('programs_enabled'),
    Byte('temp_units'),
    Pointer(15,CString('dealer_name')),
    Pointer(35,CString('dealer_phone')),
));

sub register_defs {
    return \%register_defs;
}

# Set up callback handlers for emulation
sub on_read {
    my ($self, $reg, $handler) = @_;
    $self->handlers->{$reg}->{read} = $handler;
}

sub on_write {
    my ($self, $reg, $handler) = @_;
    $self->handlers->{$reg}->{write} = $handler;
}

# Handle incoming frame addressed to SAM
sub handle_frame {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;

    return unless $fs->{dst} eq 'SAM' || $fs->{dst} eq 'FakeSAM';

    if ($fs->{cmd} eq 'read') {
        return $self->_handle_read($frame);
    }
    elsif ($fs->{cmd} eq 'write') {
        return $self->_handle_write($frame);
    }
    return;
}

sub _handle_read {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $reg_key = sprintf("%02X%02X", $table, $row);

    my $handler = $self->handlers->{$reg_key}->{read};
    my $data = $handler ? $handler->() : $self->registers->{$reg_key};

    return unless defined $data;

    # Build reply frame
    return CarBus::Frame->new(
        src     => 'FakeSAM',
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => pack("C*", 0, $table, $row) . $data,
    );
}

sub _handle_write {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $value = substr($fs->{payload_raw}, 3);
    my $reg_key = sprintf("%02X%02X", $table, $row);

    my $handler = $self->handlers->{$reg_key}->{write};
    if ($handler) {
        $handler->($value);
    } else {
        $self->registers->{$reg_key} = $value;
    }

    # Send ack reply
    return CarBus::Frame->new(
        src     => 'FakeSAM',
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => $fs->{payload_raw},
    );
}

# Convenience: read from thermostat
sub read_thermostat {
    my ($self, $table, $row) = @_;
    return $self->bus->read_register('Thermostat', $table, $row);
}

# Convenience: write to thermostat
sub write_thermostat {
    my ($self, $table, $row, $value) = @_;
    return $self->bus->write_register('Thermostat', $table, $row, $value);
}

1;
