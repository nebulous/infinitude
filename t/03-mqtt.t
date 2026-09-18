use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Mojo::JSON qw/decode_json encode_json/;

BEGIN {
    package Net::MQTT::Simple;

    sub new {
        my ($class, $broker) = @_;
        return bless {
            broker        => $broker,
            retained      => {},
            subscriptions => {},
        }, $class;
    }

    sub login {
        my ($self, @credentials) = @_;
        $self->{credentials} = \@credentials;
    }

    sub last_will {
        my ($self, @last_will) = @_;
        $self->{last_will} = \@last_will;
    }

    sub retain {
        my ($self, $topic, $message) = @_;
        $self->{retained}{$topic} = $message;
    }

    sub subscribe {
        my ($self, %subscriptions) = @_;
        $self->{subscriptions} = \%subscriptions;
    }

    sub tick { }

    $INC{'Net/MQTT/Simple.pm'} = 1;
}

use Infinitude::MQTT;

package MockStore {
    sub new { bless { values => $_[1] }, $_[0] }
    sub get { $_[0]{values}{$_[1]} }
}

package main;

sub make_store {
    return MockStore->new({
        'status.json' => encode_json({
            status => [{
                cfgem => ['F'],
                oat   => ['72'],
                zones => [{
                    zone => [{
                        enabled          => ['on'],
                        name             => ['Zone 1'],
                        rt               => ['70'],
                        rh               => ['45'],
                        zoneconditioning => ['idle'],
                        currentActivity  => ['home'],
                    }],
                }],
            }],
        }),
        'systems.json' => encode_json({
            system => [{
                config => [{
                    mode  => ['heat'],
                    zones => [{
                        zone => [{
                            hold         => ['off'],
                            holdActivity => [''],
                            otmr          => [''],
                            activities   => [{
                                activity => [{
                                    id   => ['home'],
                                    htsp => ['68'],
                                    clsp => ['74'],
                                    fan  => ['off'],
                                }],
                            }],
                        }],
                    }],
                }],
            }],
        }),
    });
}

sub make_mqtt {
    my (%config) = @_;
    return Infinitude::MQTT->new(
        store  => make_store(),
        config => { mqtt_broker => 'broker:1883', %config },
    );
}

subtest 'default discovery identity remains backward compatible' => sub {
    my $mqtt = make_mqtt();
    $mqtt->publish_discovery;

    is_deeply(
        $mqtt->{mqtt}{last_will},
        ['infinitude/status', 'offline', 1],
        'default availability topic unchanged',
    );

    my $topic = 'homeassistant/climate/infinitude_zone_1/config';
    ok(exists $mqtt->{mqtt}{retained}{$topic}, 'default discovery topic unchanged');

    my $payload = decode_json($mqtt->{mqtt}{retained}{$topic});
    is($payload->{unique_id}, 'infinitude_zone_1', 'default unique ID unchanged');
    is_deeply($payload->{device}{identifiers}, ['infinitude'], 'default device identifier unchanged');
    is($payload->{device}{name}, 'Infinitude', 'default device name unchanged');
};

subtest 'instances use disjoint discovery identities and MQTT topics' => sub {
    my $main = make_mqtt(
        mqtt_instance_id => 'infinitude_main',
        mqtt_device_name => 'Infinitude Main Level',
        mqtt_topic       => 'infinitude/main',
    );
    my $upstairs = make_mqtt(
        mqtt_instance_id => 'infinitude_upstairs',
        mqtt_device_name => 'Infinitude Upstairs',
        mqtt_topic       => 'infinitude/upstairs',
    );

    $main->publish_discovery;
    $upstairs->publish_discovery;
    $main->subscribe_commands;
    $upstairs->subscribe_commands;

    my $main_topic = 'homeassistant/climate/infinitude_main_zone_1/config';
    my $upstairs_topic = 'homeassistant/climate/infinitude_upstairs_zone_1/config';
    ok(exists $main->{mqtt}{retained}{$main_topic}, 'main discovery topic is namespaced');
    ok(exists $upstairs->{mqtt}{retained}{$upstairs_topic}, 'upstairs discovery topic is namespaced');

    my $main_payload = decode_json($main->{mqtt}{retained}{$main_topic});
    my $upstairs_payload = decode_json($upstairs->{mqtt}{retained}{$upstairs_topic});

    is($main_payload->{unique_id}, 'infinitude_main_zone_1', 'main unique ID is namespaced');
    is($upstairs_payload->{unique_id}, 'infinitude_upstairs_zone_1', 'upstairs unique ID is namespaced');
    is_deeply($main_payload->{device}{identifiers}, ['infinitude_main'], 'main device identifier is namespaced');
    is_deeply($upstairs_payload->{device}{identifiers}, ['infinitude_upstairs'], 'upstairs device identifier is namespaced');
    is($main_payload->{device}{name}, 'Infinitude Main Level', 'main device name is configurable');
    is($upstairs_payload->{device}{name}, 'Infinitude Upstairs', 'upstairs device name is configurable');

    isnt($main_payload->{availability_topic}, $upstairs_payload->{availability_topic}, 'availability topics do not overlap');
    isnt($main_payload->{mode_state_topic}, $upstairs_payload->{mode_state_topic}, 'state topics do not overlap');
    isnt($main_payload->{mode_command_topic}, $upstairs_payload->{mode_command_topic}, 'command topics do not overlap');

    my @main_subscriptions = sort keys %{$main->{mqtt}{subscriptions}};
    my @upstairs_subscriptions = sort keys %{$upstairs->{mqtt}{subscriptions}};
    is(scalar(grep { /^infinitude\/main\/zone\/\+\// } @main_subscriptions), 6, 'main command subscriptions use its base topic');
    is(scalar(grep { /^infinitude\/upstairs\/zone\/\+\// } @upstairs_subscriptions), 6, 'upstairs command subscriptions use its base topic');

    my $main_sensor_topic = 'homeassistant/sensor/infinitude_main_oat/config';
    my $upstairs_sensor_topic = 'homeassistant/sensor/infinitude_upstairs_oat/config';
    my $main_sensor = decode_json($main->{mqtt}{retained}{$main_sensor_topic});
    my $upstairs_sensor = decode_json($upstairs->{mqtt}{retained}{$upstairs_sensor_topic});
    is($main_sensor->{unique_id}, 'infinitude_main_oat', 'main sensor unique ID is namespaced');
    is($upstairs_sensor->{unique_id}, 'infinitude_upstairs_oat', 'upstairs sensor unique ID is namespaced');
};

subtest 'invalid instance IDs are rejected' => sub {
    for my $instance_id ('', 'main floor', 'main/floor') {
        my $mqtt = eval { make_mqtt(mqtt_instance_id => $instance_id) };
        ok(!$mqtt, "invalid instance ID '$instance_id' is rejected");
        like($@, qr/mqtt_instance_id must contain only/, 'configuration error explains the constraint');
    }
};

done_testing();
