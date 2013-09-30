#!/usr/bin/perl
package CarrierDevice;
use Moo;
has 'name' => (is=>'rw');
has 'type' => (is=>'rw');
has 'index' => (is=>'rw');
has 'attrs' => (is=>'rw', lazy=>1, default=>sub{{}});

sub BUILDARGS {
  my ( $class, @args ) = @_;
  if (@args % 2 == 1) {
    my ($type,$index) = split(/\./, shift(@args));
    return { type=>$type, index=>$index };
  }
  return @args ;
}

sub BUILD {
  my $self = shift;

  my $msb_h = sprintf("%02x",$self->type);
  $self->name(sprintf("Device: %02x%02x", $self->type, $self->index));
  $self->name("Thermostat".$self->index) if $msb_h =~ /^2/;
  $self->name("Air Handler".$self->index) if $msb_h =~ /^4/;
  $self->name("Outdoor Unit-".$self->index) if $msb_h =~ /^5/;
  $self->name("Master-".$self->index) if $msb_h =~ /^1F/i;
}

sub address {
  my $self = shift;
  my ($add) = @_;
  if ($add) {
    my ($type,$index) = split(/\./,$add);
    $self->type($type);
    $self->index($index);
  }
  return $self->type.'.'.$self->index;
}


package CarrierFrame::Header;
use Moo;
has raw=>(is=>'ro');
has dst=>(is=>'rw');
has src=>(is=>'rw');
has length=>(is=>'rw');
has function=>(is=>'rw');
has options=>(is=>'rw');

sub BUILDARGS {
  my ( $class, @args ) = @_;
  unshift @args, "raw" if @args % 2 == 1;
  return { @args };
}

sub BUILD {
  my $self = shift;
  my ($dst_type, $dst_index, $src_type, $src_index, $length, $options, $function) = unpack("CCCCCnC", $self->raw);

  $self->dst("$dst_type.$dst_index");
  $self->src("$src_type.$src_index");

  $self->options($options);
  $self->length($length);
  $self->function($function);
}

package CarrierFrame;
use Moo;

has 'raw'=>(is=>'ro');
has 'header'=>(is=>'rw');
has 'data'=>(is=>'rw');
has 'checksum'=>(is=>'rw');

sub BUILDARGS {
  my ( $class, @args ) = @_;
  unshift @args, "raw" if @args % 2 == 1;
  return { @args };
}

sub BUILD {
  my $self = shift;
  my $len = length($self->raw);
  $self->header(new CarrierFrame::Header(substr($self->raw,0,8)));
  $self->data(substr($self->raw,8,$len-8-2));
  $self->checksum(unpack("n",substr($self->raw,-2)));
}

sub type {
  my $self = shift;
  my $types = {
    6 => 'reply',
    11 => 'request',
    12 => 'announce',
  };
  return $types->{$self->header->function} || 'type-'.$self->header->function;
}

sub register {
  my $self = shift;
  join(':',unpack("ccc",substr($self->data,0,3)));
}


package CarrierStream;
use Moo;
use Digest::CRC qw/crc16/;

has data=>(is=>'rw', default=>sub{''});
has devices=>(is=>'rw', default=>sub{{}});

sub add {
  my $self = shift;
  my ($data) = @_;
  $data||='';
  $self->data($self->data.$data);
}

sub remove {
  my $self = shift;
  my ($start,$length) = @_;
  unless ($length) {
    $length=$start;
    $start = 0;
  }
  my $sl =length($self->data);
  my $dc = $self->data;
  substr($dc,$start,$length,'');
  $self->data($dc);
}

#pull the next valid frame from stream
my $frame_log = {};
sub get_frame {
  my $self = shift;
  my $offset=0;
  my $data_len = length($self->data());

  while ($offset<$data_len) {
    return 0 if $data_len<($offset+4);
    my $len = 10+ord(substr($self->data,$offset+4,1));
    return 0 if $data_len<$len;
    my $tf = substr($self->data,$offset, $len);
    if (crc16($tf) == 0) {
      print "Found frame at offset $offset\n" if $offset;
      $self->remove($offset+$len);
      $frame_log->{$tf}||=0;
      $frame_log->{$tf}++;
      my $frame = new CarrierFrame($tf);

      my $device_addr = $frame->header->src;
      my $device = $self->devices->{$device_addr} ||= new CarrierDevice($device_addr);
      $device->attrs->{$frame->register}||={};
      $device->attrs->{$frame->register}{$frame->data}||=0;
      $device->attrs->{$frame->register}{$frame->data}++;

      return $frame;
    }
    $offset++;
  }

  return 0;
}

sub gl { return $frame_log };


1;

sub hexdump {
  my $ret ='';
  foreach my $byte (split(//,$_[0])) { $ret.=sprintf("%02x ",ord($byte)); };
  return $ret;
}

sub asciidump {
  my $ret ='';
  foreach my $byte (split(//,$_[0])) {
    if (ord($byte)>=32 and ord($byte)<=127) {
      $ret.="$byte  ";
    } else {
      $ret.="   ";
    }
  };
  return $ret;
}

no warnings 'uninitialized';

my $frame_count=0;
my $stream = new CarrierStream;
while (<>) {
  $stream->add($_);
  while(my $frame = $stream->get_frame) {
    print "(Frames: $frame_count buffer length:".length($stream->data).")\n";
    print "--------------------- Frame $frame_count -------------------------\n";
    my $srcname = $stream->devices->{$frame->header->src} ? $stream->devices->{$frame->header->src}->name : $frame->header->src;
    my $dstname = $stream->devices->{$frame->header->dst} ? $stream->devices->{$frame->header->dst}->name : $frame->header->dst;
    print join(" ", "Message type", $frame->type,"from", $srcname, "to", $dstname)."\n";
    print &hexdump($frame->data)."\n";
    print &asciidump($frame->data)."\n";
    $frame_count++;
  }
}

#Search for changing data in stream
=comment
foreach my $dev_id (keys %{$stream->devices}) {
  my $dev = $stream->devices->{$dev_id};
  print "\n".$dev->name."\n";
  foreach my $attr (keys %{$dev->attrs}) {
    print "\t$attr\n";
    foreach my $val (keys %{$dev->attrs->{$attr}}) {
      my $count = $dev->attrs->{$attr}{$val};
      print "\t(x$count)\n";
      print "\t\t".&hexdump($val)."\n";
      print "\t\t".&asciidump($val)."\n";
    }
  }
}
=end

=comment
my $log = $stream->gl;
foreach my $fr (sort{$log->{$b} <=> $log->{$a}} keys %$log) {
  print "Count ".$log->{$fr}."\n";
  print &hexdump($fr)."\n";
  print &asciidump($fr)."\n\n";
}
=cut

