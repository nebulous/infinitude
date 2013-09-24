#!/usr/bin/perl
package CarrierDevice;
use Moo;
has 'name' => (is=>'rw');
has 'type' => (is=>'rw');
has 'index' => (is=>'rw');

sub BUILD {
  my $self = shift;
  my $msb_h = sprintf("%02x",$self->type);
  $self->name(sprintf("Device: %02x%02x", $self->type, $self->index));
  $self->name("Thermostat".$self->index) if $msb_h =~ /^2/;
  $self->name("Air Handler".$self->index) if $msb_h =~ /^4/;
  $self->name("Outdoor Unit-".$self->index) if $msb_h =~ /^5/;
}

sub address {
  my $self = shift;
  return chr($self->type).chr($self->index);
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
  #use Data::Dumper; print Dumper([$dst_type, $dst_index, $src_type, $src_index, $length, $reserved, $function]);
  $self->dst(new CarrierDevice({type=>$dst_type, index=>$dst_index}));
  $self->src(new CarrierDevice({type=>$src_type, index=>$src_index}));
  $self->options($options);
  $self->length($length);
  $self->function($function);
}

package CarrierFrame;
use Moo;
use Digest::CRC qw/crc16/;

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

#class method to pull the next valid frame from a string
#does not appear to recognize broadcast frames.
sub get_frame {
  my $class = shift;
  my ($input) = @_;
  $input = $class unless $class eq 'CarrierFrame';
  my $offset=0;
  while ($offset<length($$input)) {
    return 0 if length($$input)<($offset+4);
    my $len = 10+ord(substr($$input,$offset+4,1));
    return 0 if length($$input)<=(10+$len);
    my $tf = substr($$input,$offset, 10+ord(substr($$input,$offset+4,1)));
    if (crc16($tf) == 0) {
      print "Found frame at offset $offset\n";
      substr($$input,0,$offset+$len,'');
      return new CarrierFrame($tf);
    }
    $offset++;
  }

  return 0;
}


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
my $tries=0;
my $input = '';
while (<>) {
  $input.=$_;
  my $frame = CarrierFrame->get_frame(\$input);
  print "Tries: $tries frames: $frame_count length".length($input)."\n";
  $tries++;
  next if $frame == 0;
  print "--------------------- Frame $frame_count -------------------------\n";
  $frame_count++;
  print join(" ", "Message type", $frame->header->function == 11 ? 'request' : $frame->header->function == 6 ? 'reply' : $frame->header->function,"from", $frame->header->src->name, "to", $frame->header->dst->name)."\n";
  print &hexdump($frame->data)."\n";
  print &asciidump($frame->data)."\n";
  #exit if $frame_count>3;
}

