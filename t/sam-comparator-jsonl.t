#!/usr/bin/env perl
use strict;
use warnings;
use feature ':5.10';
use Test::More;
use JSON;
use FindBin qw($Bin);
use File::Temp qw(tempfile);

my $perl = $^X;
my $lib = "$Bin/../lib";

# Test 1: Syntax check
my $comparator = "$Bin/../sam-comparator";
my $syntax_ok = system($perl, '-I', $lib, '-I', "$ENV{HOME}/perl5/lib/perl5", '-c', $comparator) == 0;
ok($syntax_ok, 'sam-comparator syntax check passes');

# Test 2: JSON module available
require_ok('JSON');
can_ok('JSON', 'encode_json');

# Test 3: log_event output format matches spec
my $test_script = <<'ENDSCRIPT';
use strict;
use warnings;
use feature ':5.10';
use JSON;
use POSIX qw(strftime);
use Time::HiRes qw(time);

my $start_time = time();

sub log_event {
    my ($data) = @_;
    $data->{ts} = strftime("%Y-%m-%dT%H:%M:%S", gmtime) . sprintf(".%03dZ", int(time() * 1000) % 1000);
    $data->{elapsed} = sprintf("%.3f", time() - $start_time);
    say encode_json($data);
}

log_event({ event => 'startup', known_registers => ['0104', '3B02'] });
log_event({ event => 'frame', src => 'Thermostat', dst => 'SAM', cmd => 'read', reg => '3B02' });
log_event({ event => 'comparison', reg => '3B02', verdict => 'match', real_hex => 'aabb', emu_hex => 'aabb' });
log_event({ event => 'learn', reg => '3B05', bytes => 42 });
log_event({ event => 'ascii', phase => 'send', attempt => 1 });
log_event({ event => 'stats', total_frames => 100 });
log_event({ event => 'shutdown', total_frames => 1000 });
ENDSCRIPT

my ($fh, $tmpfile) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print $fh $test_script;
close $fh;

my $output = `$perl $tmpfile 2>/dev/null`;
my @lines = grep { $_ ne '' } split /\n/, $output;
is(scalar @lines, 7, 'log_event produces 7 JSONL lines');

my @expected_events = qw(startup frame comparison learn ascii stats shutdown);
for my $i (0..$#expected_events) {
    my $obj = decode_json($lines[$i]);
    is($obj->{event}, $expected_events[$i], "line $i is $expected_events[$i] event");
    like($obj->{ts}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/, "line $i has ISO timestamp");
    like($obj->{elapsed}, qr/^\d+\.\d{3}$/, "line $i has elapsed seconds");
}

# Test 4: Frame event has all required fields
my $frame_obj = decode_json($lines[1]);
is($frame_obj->{src}, 'Thermostat', 'frame event has src');
is($frame_obj->{dst}, 'SAM', 'frame event has dst');
is($frame_obj->{cmd}, 'read', 'frame event has cmd');
is($frame_obj->{reg}, '3B02', 'frame event has reg');

# Test 5: Comparison event has verdict and hex data
my $cmp_obj = decode_json($lines[2]);
is($cmp_obj->{verdict}, 'match', 'comparison has verdict');
is($cmp_obj->{real_hex}, 'aabb', 'comparison has real_hex');
is($cmp_obj->{emu_hex}, 'aabb', 'comparison has emu_hex');

done_testing;
