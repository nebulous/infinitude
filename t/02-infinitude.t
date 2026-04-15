use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw/tempdir/;
use CHI;
use Mojo::JSON qw/decode_json/;
use XML::Simple::Minded;

BEGIN { use_ok('Infinitude') }

# --- Mock objects ---

package MockMQTT {
    sub new { bless { published => 0 }, shift }
    sub publish_state { shift->{published}++ }
    sub published { shift->{published} }
}

package MockSAM {
    sub new { bless { calls => [] }, shift }
    sub set_system_mode { my $s = shift; push @{$s->{calls}}, ['set_system_mode', @_] }
    sub set_zone_setpoint { my $s = shift; push @{$s->{calls}}, ['set_zone_setpoint', @_] }
    sub set_zone_fan { my $s = shift; push @{$s->{calls}}, ['set_zone_fan', @_] }
    sub calls { shift->{calls} }
}

package main;

# --- Fixtures ---

my $fixture_xml;
{
    my $live_store = CHI->new(driver => 'File', root_dir => 'state', depth => 0, max_key_length => 256, namespace => '');
    $fixture_xml = $live_store->get('systems.xml');
    plan skip_all => "No systems.xml in state/ - run infinitude first" unless $fixture_xml;
}

sub make_inf {
    my ($mqtt, $sam) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $store = CHI->new(driver => 'File', root_dir => $dir, depth => 0, max_key_length => 256, namespace => '');
    $store->set('systems.xml', $fixture_xml);
    $store->set('systems.json', XML::Simple::Minded->new($fixture_xml)->_as_json());
    return Infinitude->new(store => $store, mqtt => $mqtt, sam => $sam), $store;
}

# --- Tests ---

subtest 'modify_system saves xml/json/changes' => sub {
    my $mqtt = MockMQTT->new;
    my ($inf, $store) = make_inf($mqtt);

    $inf->modify_system(sub {
        my $xml = shift;
        $xml->system->config->mode(['cool']);
    });

    is($store->get('changes'), 'true', 'changes flag set');
    is($mqtt->published, 1, 'MQTT publish_state called');

    my $xml = XML::Simple::Minded->new($store->get('systems.xml'));
    is($xml->system->config->mode, 'cool', 'XML updated');

    my $json = decode_json($store->get('systems.json'));
    ok($json, 'JSON updated');
};

subtest 'set_system_mode' => sub {
    my $mqtt = MockMQTT->new;
    my $sam = MockSAM->new;
    my ($inf, $store) = make_inf($mqtt, $sam);

    $inf->set_system_mode('heat');

    my $xml = XML::Simple::Minded->new($store->get('systems.xml'));
    is($xml->system->config->mode, 'heat', 'mode set to heat');
    is_deeply($sam->calls, [['set_system_mode', 'heat']], 'RS485 called');
    is($mqtt->published, 1, 'MQTT published');
};

subtest 'set_system_mode without sam' => sub {
    my $mqtt = MockMQTT->new;
    my ($inf, $store) = make_inf($mqtt);

    $inf->set_system_mode('off');

    my $xml = XML::Simple::Minded->new($store->get('systems.xml'));
    is($xml->system->config->mode, 'off', 'mode set to off');
};

subtest 'set_zone_setpoint sets manual activity and hold' => sub {
    my $mqtt = MockMQTT->new;
    my $sam = MockSAM->new;
    my ($inf, $store) = make_inf($mqtt, $sam);

    $inf->set_zone_setpoint(1, 70, 74);

    my $xml = XML::Simple::Minded->new($store->get('systems.xml'));
    my $zone = $xml->system->config->zones->zone->[0];
    is($zone->hold, 'on', 'hold activated');

    for my $act (@{$zone->activities->activity}) {
        if ($act->id eq 'manual') {
            is($act->htsp, '70', 'htsp set');
            is($act->clsp, '74', 'clsp set');
        }
    }

    is_deeply($sam->calls, [['set_zone_setpoint', 1, 70, 74]], 'RS485 setpoint called');
    is($mqtt->published, 1, 'MQTT published');
};

subtest 'set_zone_setpoint partial - heat only' => sub {
    my $sam = MockSAM->new;
    my ($inf, $store) = make_inf(MockMQTT->new, $sam);

    $inf->set_zone_setpoint(1, 65, undef);

    my $xml = XML::Simple::Minded->new($store->get('systems.xml'));
    my $zone = $xml->system->config->zones->zone->[0];
    for my $act (@{$zone->activities->activity}) {
        if ($act->id eq 'manual') {
            is($act->htsp, '65', 'htsp changed');
            is($act->clsp, '72', 'clsp unchanged');
        }
    }
    # RS485 gets actual values: htsp=65 (changed), clsp=72 (original)
    is_deeply($sam->calls, [['set_zone_setpoint', 1, 65, 72]], 'RS485 got actual values');
};

subtest 'set_zone_fan sets manual activity fan' => sub {
    my $sam = MockSAM->new;
    my ($inf, $store) = make_inf(MockMQTT->new, $sam);

    $inf->set_zone_fan(1, 'high');

    my $xml = XML::Simple::Minded->new($store->get('systems.xml'));
    my $zone = $xml->system->config->zones->zone->[0];
    for my $act (@{$zone->activities->activity}) {
        if ($act->id eq 'manual') {
            is($act->fan, 'high', 'fan set on manual activity');
        }
    }
    is_deeply($sam->calls, [['set_zone_fan', 1, 'high']], 'RS485 fan called');
};

subtest 'set_zone_hold' => sub {
    my ($inf, $store) = make_inf(MockMQTT->new);

    $inf->set_zone_hold(1, 'on', 'away', '14:00');

    my $xml = XML::Simple::Minded->new($store->get('systems.xml'));
    my $zone = $xml->system->config->zones->zone->[0];
    is($zone->hold, 'on', 'hold set');
    is($zone->holdActivity, 'away', 'activity set');
    is($zone->otmr, '14:00', 'timer set');
};

subtest 'set_zone_hold wholeHouse' => sub {
    my ($inf, $store) = make_inf(MockMQTT->new);

    $inf->set_zone_hold('wholeHouse', 'off', '', {});

    my $xml = XML::Simple::Minded->new($store->get('systems.xml'));
    my $wh = $xml->system->config->wholeHouse;
    is($wh->hold, 'off', 'wholeHouse hold set');
};

subtest '_qtr_hr rounding' => sub {
    my $inf = Infinitude->new(store => CHI->new(driver => 'File', root_dir => tempdir(CLEANUP => 1), depth => 0, max_key_length => 256, namespace => ''));

    is($inf->_qtr_hr(10, 7),  '10:00', 'rounds down to :00');
    is($inf->_qtr_hr(10, 8),  '10:15', 'rounds up to :15');
    is($inf->_qtr_hr(10, 22), '10:15', 'rounds down to :15');
    is($inf->_qtr_hr(10, 23), '10:30', 'rounds up to :30');
    is($inf->_qtr_hr(10, 52), '10:45', 'rounds down to :45');
    is($inf->_qtr_hr(10, 53), '11:00', 'rounds up to next hour');
    is($inf->_qtr_hr('14:37'), '14:30', 'parses HH:MM string');
};

done_testing();
