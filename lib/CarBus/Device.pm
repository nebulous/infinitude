package CarBus::Device;
use strict;
use warnings;
use feature ':5.10';
use Moo;
use CarBus::Frame;
use CHI;

# --- Required ---
has bus => (is => 'ro', required => 1);

# --- Address & Identity ---
# Device class name as it appears in Frame.pm's Enum (e.g. 'ZoneControl', 'FakeSAM')
has src_name => (is => 'ro', required => 1);
has src_bus  => (is => 'ro', default => 1);

# --- Register Storage ---
has store => (is => 'ro', default => sub {
    my $self = shift;
    CHI->new(driver => 'File', root_dir => 'state', namespace => lc($self->src_name));
});
has handlers => (is => 'ro', default => sub { {} });

# --- Register cache (backed by CHI store) ---

sub registers {
    my $self = shift;
    return $self->store->get('registers') // {};
}

sub set_register {
    my ($self, $key, $value) = @_;
    my $regs = $self->registers;
    $regs->{$key} = $value;
    $self->store->set('registers', $regs);
}

sub get_register {
    my ($self, $key) = @_;
    return $self->registers->{$key};
}

# Learn a register value from observed real traffic
sub learn_register {
    my ($self, $reg_key, $raw_data) = @_;
    $reg_key = lc($reg_key);
    my $existing = $self->get_register($reg_key);
    if (!defined $existing) {
        $self->set_register($reg_key, $raw_data);
        return 1;  # Learned new register
    }
    return 0;  # Already known
}

# Return list of registers the emulator knows about
sub known_registers {
    my ($self) = @_;
    return [keys %{$self->registers}];
}

# --- Callback registration ---

sub on_read {
    my ($self, $reg, $handler) = @_;
    $self->handlers->{$reg}->{read} = $handler;
}

sub on_write {
    my ($self, $reg, $handler) = @_;
    $self->handlers->{$reg}->{write} = $handler;
}

# --- Frame dispatch ---

# Handle incoming frame addressed to this device.
# Returns a reply frame, or undef if the frame isn't for us.
sub handle_frame {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;

    return unless defined $fs->{dst} && $fs->{dst} eq $self->src_name;

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
    my $reg_key = lc(sprintf("%02X%02X", $table, $row));

    my $handler = $self->handlers->{$reg_key}->{read};
    my $data = $handler ? $handler->() : $self->get_register($reg_key);

    if (defined $data) {
        return $self->_reply($frame, pack("C*", 0, $table, $row) . $data);
    }

    return $self->_exception_reply($frame, 0x04);
}

sub _handle_write {
    my ($self, $frame) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    my $value = substr($fs->{payload_raw}, 3);
    my $reg_key = lc(sprintf("%02X%02X", $table, $row));

    my $handler = $self->handlers->{$reg_key}->{write};
    if ($handler) {
        $handler->($value);
    } else {
        $self->set_register($reg_key, $value);
    }

    # ACK: echo the payload back
    return $self->_reply($frame, $fs->{payload_raw});
}

sub _reply {
    my ($self, $frame, $payload) = @_;
    my $fs = $frame->struct;
    return CarBus::Frame->new(
        src     => $self->src_name,
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'reply',
        payload_raw => $payload,
    );
}

sub _exception_reply {
    my ($self, $frame, $code) = @_;
    my $fs = $frame->struct;
    my ($reserved, $table, $row) = unpack("C*", substr($fs->{payload_raw}, 0, 3));
    return CarBus::Frame->new(
        src     => $self->src_name,
        src_bus => $fs->{dst_bus},
        dst     => $fs->{src},
        dst_bus => $fs->{src_bus},
        cmd     => 'exception',
        payload_raw => pack("C*", 0, $table, $row, $code),
    );
}

# --- Bus I/O convenience ---

sub read_device {
    my ($self, $dst, $table, $row) = @_;
    return $self->bus->read_register($dst, $table, $row, {src => $self->src_name});
}

sub write_device {
    my ($self, $dst, $table, $row, $value) = @_;
    return $self->bus->write_register($dst, $table, $row, $value, {src => $self->src_name});
}

1;
