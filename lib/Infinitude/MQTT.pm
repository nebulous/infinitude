package Infinitude::MQTT;

use strict;
use warnings;
use feature ':5.10';
use utf8;
use Mojo::JSON qw/encode_json decode_json/;

sub new {
    my ($class, %args) = @_;

    my $store  = $args{store}  or die "MQTT: store required";
    my $config = $args{config} or die "MQTT: config required";

    my $broker = $config->{mqtt_broker} or do {
        return bless { enabled => 0 }, $class;
    };

    require Net::MQTT::Simple;

    my $prefix = $config->{mqtt_prefix} // 'homeassistant';
    my $base   = $config->{mqtt_topic}  // 'infinitude';

    my $mqtt = Net::MQTT::Simple->new($broker);

    if ($config->{mqtt_user}) {
        $ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1 unless $broker =~ /^ssl:/i;
        $mqtt->login($config->{mqtt_user}, $config->{mqtt_pass} // '');
    }

    $mqtt->last_will("$base/status" => 'offline', 1);

    my $self = bless {
        enabled => 1,
        mqtt    => $mqtt,
        store   => $store,
        prefix  => $prefix,
        base    => $base,
        config  => $config,
        zc      => $args{zc},  # CarBus::ZoneController (optional)
    }, $class;

    return $self;
}

sub enabled { shift->{enabled} }

sub _topic { my $s = shift; join '/', $s->{base}, @_ }
sub _disc  { my $s = shift; join '/', $s->{prefix}, @_ }

# Unwrap single-element arrays from XML->JSON mapping
sub _v {
    my $val = shift;
    return '' unless defined $val;
    $val = $val->[0] if ref($val) eq 'ARRAY' && @$val == 1;
    return '' if ref($val) eq 'HASH' && !keys %$val;
    return $val // '';
}

# JSON encode for MQTT
sub _json { encode_json(shift) }

sub publish_discovery {
    my ($self) = @_;
    return unless $self->{enabled};

    my $status = decode_json($self->{store}->get('status.json') || '{}');
    my $sys    = $status->{status}[0] or return;
    my $zones  = $sys->{zones}[0]{zone} // [];
    my $cfgem  = _v($sys->{cfgem}) || 'f';

    my $device = {
        identifiers  => ['infinitude'],
        name         => 'Infinitude',
        manufacturer => 'Carrier',
        model        => 'Infinity',
    };

    my @topics;

    for my $i (0 .. $#$zones) {
        my $zone = $zones->[$i];
        my $zid  = $i + 1;
        my $disc = $self->_disc('climate', "infinitude_zone_${zid}", 'config');

        # Clear stale retained discovery for any zone that is not currently
        # enabled. A zero-byte retained message on the config topic tells Home
        # Assistant to delete the entity; without this, a zone that was ever
        # enabled (e.g. a now-disabled 4th zone) leaves a ghost climate device
        # forever, because retained messages never expire on their own.
        if (lc(_v($zone->{enabled})) ne 'on') {
            push @topics, $disc => '';
            next;
        }

        my $name  = _v($zone->{name}) || "Zone $zid";
        my $zbase = $self->_topic('zone', $zid);

        push @topics,
            $disc =>
            _json({
                unique_id              => "infinitude_zone_${zid}",
                name                   => $name,
                device                 => $device,
                modes                  => ['off', 'heat', 'cool', 'heat_cool'],
                fan_modes              => ['auto', 'low', 'medium', 'high'],
                preset_modes           => [qw(schedule home away sleep wake hold hold_until)],
                mode_state_topic       => "$zbase/mode/state",
                mode_command_topic     => "$zbase/mode/cmd",
                temperature_state_topic      => "$zbase/temp/state",
                temperature_command_topic    => "$zbase/temp/cmd",
                temperature_low_command_topic  => "$zbase/temp_low/cmd",
                temperature_high_command_topic => "$zbase/temp_high/cmd",
                temperature_low_state_topic  => "$zbase/temp_low/state",
                temperature_high_state_topic => "$zbase/temp_high/state",
                current_temperature_topic    => "$zbase/current_temp",
                current_humidity_topic       => "$zbase/humidity",
                fan_mode_state_topic         => "$zbase/fan/state",
                fan_mode_command_topic       => "$zbase/fan/cmd",
                preset_mode_state_topic      => "$zbase/preset/state",
                preset_mode_command_topic    => "$zbase/preset/cmd",
                action_topic                 => "$zbase/action",
                optimistic                   => 1,
                temp_step                    => 1,
                min_temp                     => 40,
                max_temp                     => 99,
                temperature_unit             => $cfgem =~ /c/i ? 'C' : 'F',
                availability_topic           => $self->_topic('status'),
                payload_available            => 'online',
                payload_not_available        => 'offline',
            });
    }

    # System sensors
    my $sbase = $self->_topic('system');
    my @sensors = (
        ['oat',        'Outdoor Temperature', '°F'],
        ['filtrlvl',   'Filter Level',        '%'],
        ['uvlvl',      'UV Lamp Level',       '%'],
        ['humlvl',     'Humidifier Level',    '%'],
        ['ventlvl',    'Ventilator Level',    '%'],
        ['humid',      'Humidifier State',    undef],
    );

    for my $s (@sensors) {
        my ($key, $name, $unit) = @$s;
        my $payload = {
            unique_id             => "infinitude_$key",
            name                  => $name,
            device                => $device,
            state_topic           => "$sbase/$key",
            availability_topic    => $self->_topic('status'),
            payload_available     => 'online',
            payload_not_available => 'offline',
        };
        $payload->{unit_of_measurement} = $unit if defined $unit;
        push @topics,
            $self->_disc('sensor', "infinitude_$key", 'config') =>
            _json($payload);
    }

    while (@topics) {
        my $topic = shift @topics;
        my $msg   = shift @topics;
        $self->{mqtt}->retain($topic => $msg);
    }

    $self->{mqtt}->retain($self->_topic('status') => 'online');
}

sub publish_state {
    my ($self) = @_;
    return unless $self->{enabled};

    my $status = decode_json($self->{store}->get('status.json') || '{}');
    my $sys    = $status->{status}[0] or return;
    my $zones  = $sys->{zones}[0]{zone} // [];

    my %fan_map = (
        'off'  => 'auto',
        'low'  => 'low',
        'med'  => 'medium',
        'high' => 'high',
    );

    my %action_map = (
        'active_heat' => 'heating',
        'active_cool' => 'cooling',
        'prep_heat'   => 'preheating',
        'prep_cool'   => 'cooling',
        'idle'        => 'idle',
    );

    my $systems = decode_json($self->{store}->get('systems.json') || '{}');
    my $cfg     = eval { $systems->{system}[0]{config}[0] } // {};

    for my $i (0 .. $#$zones) {
        my $zone = $zones->[$i];
        next unless lc(_v($zone->{enabled})) eq 'on';

        my $zid   = $i + 1;
        my $zbase = $self->_topic('zone', $zid);
        my $mqtt  = $self->{mqtt};

        # Runtime values from status
        $mqtt->retain("$zbase/current_temp"    => _v($zone->{rt}));
        $mqtt->retain("$zbase/humidity"        => _v($zone->{rh}));

        # Config values from systems.json
        my $cfg_zone = $cfg->{zones}[0]{zone}[$i];
        my ($cfg_htsp, $cfg_clsp, $cfg_fan);
        if ($cfg_zone) {
            my $act_id = lc(_v($cfg_zone->{holdActivity})) eq 'manual' ? 'manual' : lc(_v($zone->{currentActivity}) || 'home');
            for my $a (@{$cfg_zone->{activities}[0]{activity} || []}) {
                my $aid = ref($a->{id}) eq 'ARRAY' ? $a->{id}[0] : $a->{id};
                if (lc($aid // '') eq $act_id) {
                    $cfg_htsp = _v($a->{htsp});
                    $cfg_clsp = _v($a->{clsp});
                    $cfg_fan  = _v($a->{fan});
                    last;
                }
            }
        }
        # Fallback to status values if config not found
        $cfg_htsp //= _v($zone->{htsp});
        $cfg_clsp //= _v($zone->{clsp});
        $cfg_fan  //= _v($zone->{fan});

        $mqtt->retain("$zbase/temp_low/state"  => $cfg_htsp);
        $mqtt->retain("$zbase/temp_high/state" => $cfg_clsp);

        my $cfg_mode = lc(_v($cfg->{mode}) || _v($sys->{mode}) || 'off');
        my $mode = $cfg_mode;
        if ($mode eq 'heat') {
            $mqtt->retain("$zbase/temp/state" => $cfg_htsp);
        } elsif ($mode eq 'cool') {
            $mqtt->retain("$zbase/temp/state" => $cfg_clsp);
        } else {
            $mqtt->retain("$zbase/temp/state" => 'None');
        }

        my $ha_mode = $mode eq 'auto' ? 'heat_cool' : $mode;
        $mqtt->retain("$zbase/mode/state" => $ha_mode);

        my $fan = lc($cfg_fan || 'off');
        $mqtt->retain("$zbase/fan/state" => ($fan_map{$fan} // 'auto'));

        my $zc = lc(_v($zone->{zoneconditioning}) || 'idle');
        $mqtt->retain("$zbase/action" => ($action_map{$zc} // 'idle'));

        # Preset mode — read hold state from config (systems.json), not runtime (status.json)
        my $preset = 'schedule';
        my $cfg_hold = $cfg_zone ? lc(_v($cfg_zone->{hold})) : '';
        my $cfg_hold_act = $cfg_zone ? _v($cfg_zone->{holdActivity}) : '';
        my $cfg_otmr = $cfg_zone ? _v($cfg_zone->{otmr}) : '';
        if ($cfg_hold eq 'on') {
            my $act = lc($cfg_hold_act || 'manual');
            if ($cfg_otmr ne '' && $cfg_otmr ne 'forever') {
                $preset = ($act eq 'manual') ? 'hold_until' : $act;
            } else {
                $preset = ($act eq 'manual') ? 'hold' : $act;
            }
        } else {
            my $act = lc(_v($zone->{currentActivity}) || 'home');
            $preset = $act if grep { $_ eq $act } qw(home away sleep wake);
        }
        $mqtt->retain("$zbase/preset/state" => $preset);
    }

    # System sensors
    my $sbase = $self->_topic('system');
    for my $key (qw(oat filtrlvl uvlvl humlvl ventlvl humid)) {
        my $val = _v($sys->{$key});
        $self->{mqtt}->retain("$sbase/$key" => $val) if $val ne '';
    }
}

sub subscribe_commands {
    my ($self, %cbs) = @_;
    return unless $self->{enabled};

    $self->{on_set_mode}        = $cbs{on_set_mode};
    $self->{on_set_temperature} = $cbs{on_set_temperature};
    $self->{on_set_temp_low}    = $cbs{on_set_temp_low};
    $self->{on_set_temp_high}   = $cbs{on_set_temp_high};
    $self->{on_set_fan}         = $cbs{on_set_fan};
    $self->{on_set_preset}      = $cbs{on_set_preset};

    my $base = $self->{base};
    $self->{mqtt}->subscribe(
        "$base/zone/+/mode/cmd"      => sub { $self->_handle_mode(@_) },
        "$base/zone/+/temp/cmd"      => sub { $self->_handle_temp(@_) },
        "$base/zone/+/temp_low/cmd"  => sub { $self->_handle_temp_low(@_) },
        "$base/zone/+/temp_high/cmd" => sub { $self->_handle_temp_high(@_) },
        "$base/zone/+/fan/cmd"       => sub { $self->_handle_fan(@_) },
        "$base/zone/+/preset/cmd"    => sub { $self->_handle_preset(@_) },
    );
}

sub _extract_zone {
    my ($self, $topic) = @_;
    my $base = quotemeta($self->{base});
    if ($topic =~ m{^$base/zone/(\d+)/}) {
        return $1;
    }
    return;
}

sub _handle_mode {
    my ($self, $topic, $msg) = @_;
    $self->_extract_zone($topic) or return;
    my %map = (off => 'off', heat => 'heat', cool => 'cool', heat_cool => 'auto', auto => 'auto');
    my $mode = $map{lc($msg)} or return;
    $self->{on_set_mode}->($mode) if $self->{on_set_mode};
}

sub _handle_temp {
    my ($self, $topic, $msg) = @_;
    my $zone = $self->_extract_zone($topic) or return;
    return unless $msg =~ /^[\d.]+$/;
    $self->{on_set_temperature}->($zone, $msg + 0) if $self->{on_set_temperature};
}

sub _handle_temp_low {
    my ($self, $topic, $msg) = @_;
    my $zone = $self->_extract_zone($topic) or return;
    return unless $msg =~ /^[\d.]+$/;
    $self->{on_set_temp_low}->($zone, $msg + 0) if $self->{on_set_temp_low};
}

sub _handle_temp_high {
    my ($self, $topic, $msg) = @_;
    my $zone = $self->_extract_zone($topic) or return;
    return unless $msg =~ /^[\d.]+$/;
    $self->{on_set_temp_high}->($zone, $msg + 0) if $self->{on_set_temp_high};
}

sub _handle_fan {
    my ($self, $topic, $msg) = @_;
    my $zone = $self->_extract_zone($topic) or return;
    my %map = (auto => 'off', low => 'low', medium => 'med', high => 'high');
    my $fan = $map{lc($msg)} or return;
    $self->{on_set_fan}->($zone, $fan) if $self->{on_set_fan};
}

sub _handle_preset {
    my ($self, $topic, $msg) = @_;
    my $zone = $self->_extract_zone($topic) or return;
    $self->{on_set_preset}->($zone, lc($msg)) if $self->{on_set_preset};
}

sub tick {
    my ($self) = @_;
    return unless $self->{enabled};
    $self->{mqtt}->tick(0);
}

my @STATUS_WATCH = qw(rt rh zoneconditioning fan currentActivity hold holdActivity otmr);

sub publish_if_status_changed {
    my ($self) = @_;
    return unless $self->{enabled};
    return if ($self->{store}->get('changes') || '') eq 'true';

    my $status = decode_json($self->{store}->get('status.json') || '{}');
    my $sys    = $status->{status}[0] or return;
    my $zones  = $sys->{zones}[0]{zone} // [];

    my %cur;
    $cur{mode} = _v($sys->{mode});
    for my $i (0 .. $#$zones) {
        my $zone = $zones->[$i];
        next unless lc(_v($zone->{enabled})) eq 'on';
        my $zid = $i + 1;
        $cur{"z${zid}$_"} = _v($zone->{$_}) for @STATUS_WATCH;
    }

    my $prev = $self->{_last_status} // {};
    my $changed;
    for my $k (keys %cur) {
        if (($cur{$k} // '') ne ($prev->{$k} // '')) {
            $changed = 1;
            last;
        }
    }

    if ($changed) {
        $self->{_last_status} = \%cur;
        $self->publish_state;
    }
}

1;
