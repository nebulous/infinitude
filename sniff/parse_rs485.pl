#!/usr/bin/perl
package CarrierDevice;
use Moo;
has 'name' => (is=>'rw');
has 'type' => (is=>'rw');
has 'index' => (is=>'rw');

sub BUILD {
  my $self = shift;
  my $msb_h = sprintf("%02x",$self->type);
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

sub BUILDARGS {
  my ( $class, @args ) = @_;
  unshift @args, "raw" if @args % 2 == 1;
  return { @args };
}

sub BUILD {
  my $self = shift;
  my ($dst_type, $dst_index, $src_type, $src_index, $length, $reserved, $function) = unpack("CCCCCnC", $self->raw);
  #use Data::Dumper; print Dumper([$dst_type, $dst_index, $src_type, $src_index, $length, $reserved, $function]);
  $self->dst(new CarrierDevice({type=>$dst_type, index=>$dst_index}));
  $self->src(new CarrierDevice({type=>$src_type, index=>$src_index}));
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

sub valid {
  my $self = shift;
  #this doesn't work. Will probably need to pack data, add the header, and check endienness
  return $self->checksum eq crc16(substr($self->raw,0,-2)) ? 'valid' : 'invalid';
}

1;


my $input = join('',<>);

my $devices = [
  chr(0x20).chr(0x01),
  chr(0x42).chr(0x01),
  chr(0x50).chr(0x01)
];

#hacky way to find first frame.
my $frame_offset = length($input);
foreach my $dst (@$devices) {
  foreach my $src (@$devices) {
    my $offset = index($input, $dst.$src);
    $frame_offset = $offset if ($offset>0 and $offset<$frame_offset);
  }
}

print "found frame at: $frame_offset\n";
substr($input,0,$frame_offset,'');


sub get_frame {
  my ($string) = @_;
  my $len = 10+ord(substr($$string, 4,1)); #10 = header+checksum
  return substr($$string,0,$len,'');
}

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

while (my $framestring = &get_frame(\$input)) {
  my $frame = new CarrierFrame($framestring);
  print join(" ", $frame->valid,"Message type",$frame->header->function == 11 ? 'request' : $frame->header->function == 6 ? 'reply' : 'unknown',"from", $frame->header->src->name, "to", $frame->header->dst->name)."\n";
  print &hexdump($frame->data)."\n";
  print &asciidump($frame->data)."\n";
}

