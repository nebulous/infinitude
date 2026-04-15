package Infinitude;

use strict;
use warnings;
use feature ':5.10';
use Try::Tiny;
use XML::Simple::Minded;

sub new {
    my ($class, %args) = @_;
    die "Infinitude: store required" unless $args{store};
    bless {
        store => $args{store},
        mqtt  => $args{mqtt},
        sam   => $args{sam},
    }, $class;
}

sub modify_system {
    my ($self, $code) = @_;
    my $xml = XML::Simple::Minded->new($self->{store}->get('systems.xml'));
    $code->($xml);
    $self->{store}->set('systems.xml',  $xml . '');
    $self->{store}->set('systems.json', $xml->_as_json());
    $self->{store}->set(changes => 'true');
    $self->{mqtt}->publish_state if $self->{mqtt};
}

sub set_system_mode {
    my ($self, $mode) = @_;
    $self->modify_system(sub { $_[0]->system->config->mode([$mode]) });
    if ($self->{sam}) {
        try { $self->{sam}->set_system_mode($mode) }
        catch { warn "RS485 mode write failed: $_" };
    }
}

sub set_zone_setpoint {
    my ($self, $zone_id, $htsp, $clsp) = @_;
    my ($actual_htsp, $actual_clsp);
    $self->modify_system(sub {
        my $xml = shift;
        my $idx = $zone_id - 1;
        my $zone = $xml->system->config->zones->zone->[$idx];
        for my $activity (@{$zone->activities->activity}) {
            if ($activity->id eq 'manual') {
                $activity->htsp([$htsp]) if defined $htsp;
                $activity->clsp([$clsp]) if defined $clsp;
                $actual_htsp = (defined $htsp ? $htsp : $activity->htsp) + 0;
                $actual_clsp = (defined $clsp ? $clsp : $activity->clsp) + 0;
                $zone->hold(['on']);
                $zone->holdActivity(['manual']);
                $zone->otmr([$self->_qtr_hr((localtime)[2] + 1)]);
                last;
            }
        }
    });
    if ($self->{sam}) {
        try { $self->{sam}->set_zone_setpoint($zone_id, $actual_htsp, $actual_clsp) }
        catch { warn "RS485 setpoint write failed: $_" };
    }
}

sub set_zone_fan {
    my ($self, $zone_id, $fan) = @_;
    $self->modify_system(sub {
        my $xml = shift;
        my $idx = $zone_id - 1;
        my $zone = $xml->system->config->zones->zone->[$idx];
        for my $activity (@{$zone->activities->activity}) {
            if ($activity->id eq 'manual') {
                $activity->fan([$fan]);
                last;
            }
        }
    });
    if ($self->{sam}) {
        try { $self->{sam}->set_zone_fan($zone_id, $fan) }
        catch { warn "RS485 fan write failed: $_" };
    }
}

sub set_zone_hold {
    my ($self, $zone_id, $hold, $activity, $until) = @_;
    $self->modify_system(sub {
        my $xml = shift;
        my $zone;
        if ($zone_id eq 'wholeHouse') {
            $zone = $xml->system->config->wholeHouse;
        } else {
            $zone = $xml->system->config->zones->zone->[$zone_id - 1];
        }
        $zone->hold([$hold]);
        $zone->holdActivity([$activity]);
        $zone->otmr([$until]);
    });
}

sub _qtr_hr {
    my ($self, $hour, $minute) = @_;
    if ($hour =~ /\d:\d/) {
        ($hour, $minute) = $hour =~ /(\d+)\:(\d+)/;
    }
    $hour   ||= (localtime)[2];
    $minute ||= (localtime)[1];
    $minute  = 15 * int(0.5 + ($minute / 15));
    if ($minute == 60) {
        $hour++;
        $minute = 0;
    }
    return sprintf("%02d:%02d", $hour, $minute);
}

1;
