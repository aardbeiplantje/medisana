#!/usr/bin/perl
#
# medisana.pl - BLE controller for Medisana BS430 body composition scale
#
# Protocol reference:
#   Medisana BS430 uses standard GATT services and characteristics.
#
# GATT profile (BS430 body composition scale):
#   Service UUID:  181D  (Body Composition Service, standard GATT)
#   Weight char:   2A98  (Body Weight, read + notify)
#   BatLevel char: 2A19  (Battery Level, read + notify)
#
#   Additional characteristics may be available for body fat %, water %, etc.
#   depending on device firmware. This script reads available measurements.
#
# Measurement notifications:
#   Device sends ATT_HANDLE_VALUE_NOTIF when user steps on scale.
#   Weight is typically sent as a uint16 in 0.1 kg units (e.g., 0x0348 = 84.0 kg).
#   Battery level is sent as uint8 percentage (0-100).
#
# Usage:
#   ./medisana.pl -d AA:BB:CC:DD:EE:FF --measure
#   ./medisana.pl -d AA:BB:CC:DD:EE:FF --battery
#   ./medisana.pl -d AA:BB:CC:DD:EE:FF --measure --battery -v
#

use strict;
use warnings;
use bytes;
use Getopt::Long;

my %opts = (
    device            => undef,
    addr_type         => 'public',
    connect_timeout   => 5,
    debug             => 0,
    service_uuid      => '181d',
    weight_char_uuid  => '2a98',
    battery_char_uuid => '2a19',
    measure_timeout_s => 10,
);

my ($do_measure, $do_battery) = (0, 0);

GetOptions(
    'device|d=s'             => \$opts{device},
    'addr-type=s'            => \$opts{addr_type},
    'connect-timeout=f'       => \$opts{connect_timeout},
    'service-uuid=s'          => \$opts{service_uuid},
    'weight-char-uuid=s'      => \$opts{weight_char_uuid},
    'battery-char-uuid=s'     => \$opts{battery_char_uuid},
    'measure-timeout=f'       => \$opts{measure_timeout_s},
    'measure'                 => \$do_measure,
    'battery'                 => \$do_battery,
    'debug|v+'                => \$opts{debug},
    'help|h'                  => sub { print_usage(); exit 0; },
) or do { print_usage(); exit 1; };

unless ($opts{device}) {
    print STDERR "Error: -d / --device is required\n";
    print_usage();
    exit 1;
}
unless ($opts{device} =~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
    print STDERR "Error: Invalid Bluetooth address format\n";
    exit 1;
}
if ($opts{addr_type} !~ /^(?:public|random)$/i) {
    print STDERR "Error: --addr-type must be 'public' or 'random'\n";
    exit 1;
}

for my $k (qw(service_uuid weight_char_uuid battery_char_uuid)) {
    (my $u = lc $opts{$k}) =~ s/^0x//;
    unless ($u =~ /^[0-9a-f]{4}$/) {
        print STDERR "Error: --$k must be a 4-hex-digit UUID16 (e.g. 181d)\n";
        exit 1;
    }
    $opts{$k} = $u;
}

# Default: show measurement and battery
if (!$do_measure && !$do_battery) {
    $do_measure = $do_battery = 1;
}

my $scale = Medisana::BS430->new(%opts);
exit $scale->run(
    measure => $do_measure,
    battery => $do_battery,
);

# ============================================================================
# Medisana::BS430 class
# ============================================================================

package Medisana::BS430;

use Errno   qw(EAGAIN EINPROGRESS);
use Fcntl   qw(O_NONBLOCK F_SETFL F_GETFL);
use Socket  qw(SOCK_SEQPACKET SOL_SOCKET SO_ERROR);

use constant {
    AF_BLUETOOTH              => 31,
    BTPROTO_L2CAP             => 0,
    BDADDR_LE_PUBLIC          => 0x01,
    BDADDR_LE_RANDOM          => 0x02,

    ATT_FIND_BY_TYPE_REQ      => 0x06,
    ATT_FIND_BY_TYPE_RSP      => 0x07,
    ATT_READ_BY_TYPE_REQ      => 0x08,
    ATT_READ_BY_TYPE_RSP      => 0x09,
    ATT_READ_REQ              => 0x0A,
    ATT_READ_RSP              => 0x0B,
    ATT_WRITE_REQ             => 0x12,
    ATT_WRITE_RSP             => 0x13,
    ATT_HANDLE_VALUE_NOTIF    => 0x1B,
    ATT_EXCHANGE_MTU_REQ      => 0x02,
    ATT_EXCHANGE_MTU_RSP      => 0x03,
    ATT_ERROR_RSP             => 0x01,

    GATT_PRIMARY_SERVICE_UUID => 0x2800,
    GATT_CHARACTERISTIC_UUID  => 0x2803,
    GATT_CLIENT_CHAR_CONFIG   => 0x2902,
};

sub new {
    my ($class, %o) = @_;
    bless {
        device           => $o{device},
        addr_type        => lc($o{addr_type} // 'public'),
        connect_timeout  => $o{connect_timeout} // 5,
        debug            => $o{debug} // 0,

        service_uuid     => hex($o{service_uuid}),
        weight_uuid      => hex($o{weight_char_uuid}),
        battery_uuid     => hex($o{battery_char_uuid}),
        measure_timeout  => $o{measure_timeout_s} // 10,

        socket           => undef,
        handle_weight    => 0,
        handle_weight_cccd => 0,
        handle_battery   => 0,
        handle_battery_cccd => 0,
    }, $class;
}

# ============================================================================
# Top-level workflow
# ============================================================================

sub run {
    my ($self, %todo) = @_;

    print "Medisana BS430 BLE Scale Tool\n";
    print "=============================\n\n";
    print "Device: $self->{device}\n";

    unless ($self->ble_connect()) {
        print STDERR "ERROR: BLE connection failed\n";
        return 1;
    }
    unless ($self->discover_handles()) {
        print STDERR "ERROR: 181D service / measurement handles not found\n";
        $self->ble_disconnect();
        return 1;
    }

    # Request larger MTU for notification payloads.
    $self->exchange_mtu(160);

    # Subscribe to weight and battery notifications.
    $self->subscribe_notify();

    my $rc = 0;

    if ($todo{measure}) {
        my $m = $self->read_weight();
        if (defined $m) {
            printf "Weight:  %.1f kg\n", $m;
        } else {
            print STDERR "ERROR: Could not read weight (step on scale or check connection)\n";
            $rc = 1;
        }
    }

    if ($todo{battery}) {
        my $b = $self->read_battery();
        if (defined $b) {
            printf "Battery: %d%%\n", $b;
        } else {
            print STDERR "ERROR: Could not read battery level\n";
            $rc = 1;
        }
    }

    $self->ble_disconnect();
    return $rc;
}

# ============================================================================
# BLE connection / GATT discovery
# ============================================================================

sub ble_connect {
    my ($self) = @_;
    my @oct    = split(':', $self->{device});
    my $bdaddr = pack('C6', map { hex($_) } reverse @oct);
    my $atype  = ($self->{addr_type} eq 'random') ? BDADDR_LE_RANDOM : BDADDR_LE_PUBLIC;

    socket(my $sock, AF_BLUETOOTH, SOCK_SEQPACKET, BTPROTO_L2CAP) or return 0;

    # Bind local LE-public any-address, ATT fixed channel (CID 4)
    bind($sock, pack('S S a6 S S', AF_BLUETOOTH, 0, "\0" x 6, 4, BDADDR_LE_PUBLIC))
        or do { close($sock); return 0; };

    my $peer = pack('S S a6 S S', AF_BLUETOOTH, 0, $bdaddr, 4, $atype);
    fcntl($sock, F_SETFL, fcntl($sock, F_GETFL, 0) | O_NONBLOCK);

    my $connected = connect($sock, $peer);
    if (!$connected && !($! == EINPROGRESS || $! == EAGAIN)) {
        $self->debug("connect() immediate fail: $!");
        close($sock); return 0;
    }

    unless ($connected) {
        my $deadline = time() + ($self->{connect_timeout} > 0 ? $self->{connect_timeout} : 5);
        my $done     = 0;
        while (time() < $deadline) {
            my $fh   = fileno($sock);
            my $wvec = '';
            vec($wvec, $fh, 1) = 1;
            my $n = select(undef, $wvec, my $evec = $wvec, 0.5);
            next unless defined($n) && $n > 0;
            my $err = getsockopt($sock, SOL_SOCKET, SO_ERROR);
            my $eno = $err ? unpack('I', $err) : 0;
            if (!$eno)                                { $done = 1; last; }
            next if $eno == EINPROGRESS || $eno == EAGAIN;
            last;
        }
        unless ($done) { $self->debug('connect timeout'); close($sock); return 0; }
    }

    my $err = getsockopt($sock, SOL_SOCKET, SO_ERROR);
    if ($err && unpack('I', $err)) { close($sock); return 0; }

    fcntl($sock, F_SETFL, fcntl($sock, F_GETFL, 0) & ~O_NONBLOCK);
    $self->{socket} = $sock;
    return 1;
}

sub discover_handles {
    my ($self) = @_;

    my $rsp = $self->att_request(
        pack('C S< S< S<',
            ATT_FIND_BY_TYPE_REQ, 0x0001, 0xFFFF,
            GATT_PRIMARY_SERVICE_UUID, $self->{service_uuid}),
        3.0
    );
    return 0 unless defined $rsp && length($rsp) >= 5
                    && ord(substr($rsp, 0, 1)) == ATT_FIND_BY_TYPE_RSP;

    my ($svc_start, $svc_end) = unpack('S< S<', substr($rsp, 1, 4));
    $self->debug(sprintf('Service 0x%04X: 0x%04X-0x%04X',
        $self->{service_uuid}, $svc_start, $svc_end));

    my $start = $svc_start;
    while ($start <= $svc_end) {
        my $crsp = $self->att_request(
            pack('C S< S< S<', ATT_READ_BY_TYPE_REQ, $start, $svc_end, GATT_CHARACTERISTIC_UUID),
            2.0
        );
        last unless defined $crsp && length($crsp) >= 2;
        my $cop = ord(substr($crsp, 0, 1));
        last if $cop != ATT_READ_BY_TYPE_RSP;

        my $elen = ord(substr($crsp, 1, 1));
        last if $elen < 7;

        my ($pos, $last_decl) = (2, $start);
        while ($pos + $elen <= length($crsp)) {
            my $e    = substr($crsp, $pos, $elen);
            my $decl = unpack('S<', substr($e, 0, 2));
            my $val  = unpack('S<', substr($e, 3, 2));
            my $uuid = unpack('S<', substr($e, 5, 2));
            $self->debug(sprintf('  UUID 0x%04X -> handle 0x%04X', $uuid, $val));

            if ($uuid == $self->{weight_uuid}) {
                $self->{handle_weight}     = $val;
                $self->{handle_weight_cccd} = $val + 1;
            }
            if ($uuid == $self->{battery_uuid}) {
                $self->{handle_battery}     = $val;
                $self->{handle_battery_cccd} = $val + 1;
            }

            $last_decl = $decl;
            $pos += $elen;
        }
        $start = $last_decl + 1;
    }

    $self->debug(sprintf('weight=0x%04X (cccd=0x%04X)  battery=0x%04X (cccd=0x%04X)',
        $self->{handle_weight}, $self->{handle_weight_cccd},
        $self->{handle_battery}, $self->{handle_battery_cccd}));
    return $self->{handle_weight} ? 1 : 0;
}

sub ble_disconnect {
    my ($self) = @_;
    if ($self->{socket}) {
        close($self->{socket});
        $self->{socket} = undef;
    }
}

# ============================================================================
# ATT helpers
# ============================================================================

# Generic write-then-read for ATT request/response pairs (GATT discovery, CCCD).
sub att_request {
    my ($self, $req, $timeout) = @_;
    $timeout //= 2.0;
    return unless $self->{socket};
    syswrite($self->{socket}, $req) or return;

    my $rin = '';
    vec($rin, fileno($self->{socket}), 1) = 1;
    my $n = select(my $rout = $rin, undef, undef, $timeout);
    return unless defined($n) && $n > 0;

    my ($rsp, $r) = ('');
    $r = sysread($self->{socket}, $rsp, 512);
    return unless defined($r) && $r > 0;
    return $rsp;
}

# Request MTU to allow larger notifications.
sub exchange_mtu {
    my ($self, $mtu) = @_;
    $mtu //= 160;
    my $rsp = $self->att_request(pack('C S<', ATT_EXCHANGE_MTU_REQ, $mtu), 2.0);
    return unless defined $rsp && length($rsp) >= 3
                  && ord(substr($rsp, 0, 1)) == ATT_EXCHANGE_MTU_RSP;
    $self->debug(sprintf('MTU: client=%d server=%d', $mtu, unpack('S<', substr($rsp, 1, 2))));
}

# Enable notifications on weight and battery CCCDs.
sub subscribe_notify {
    my ($self) = @_;

    for my $handle ($self->{handle_weight_cccd}, $self->{handle_battery_cccd}) {
        next unless $handle;
        my $req = pack('C S< S<', ATT_WRITE_REQ, $handle, 0x0001);
        my $rsp = $self->att_request($req, 2.0);
        my $uuid = $handle == $self->{handle_weight_cccd} ? 'weight' : 'battery';
        my $ok  = defined($rsp) && length($rsp) >= 1
                  && ord(substr($rsp, 0, 1)) == ATT_WRITE_RSP;
        $self->debug($ok ? "Notifications enabled ($uuid)" : "CCCD write failed for $uuid (continuing)");
    }
    return 1;
}

# ============================================================================
# BS430 measurement: weight and battery
# ============================================================================

# Read weight from the scale.
# Waits for a notification from the weight characteristic.
# Weight is typically sent as uint16 in 0.1 kg units.
sub read_weight {
    my ($self) = @_;
    return $self->_read_measurement($self->{handle_weight}, 'weight');
}

# Read battery level from the scale.
# Battery level is uint8 percentage (0-100).
sub read_battery {
    my ($self) = @_;
    my $val = $self->_read_measurement($self->{handle_battery}, 'battery');
    return $val;
}

# Generic notification listener: waits for data on a specific characteristic.
# Timeout is controlled by $self->{measure_timeout}.
# Returns decoded value or undef on timeout.
sub _read_measurement {
    my ($self, $handle, $type) = @_;
    return undef unless $self->{socket} && $handle;

    my $deadline = time() + $self->{measure_timeout};
    my $timeout  = $self->{measure_timeout};

    while (1) {
        my $remaining = $deadline - time();
        last if $remaining <= 0;

        my $rin = '';
        vec($rin, fileno($self->{socket}), 1) = 1;
        my $n = select(my $rout = $rin, undef, undef, $remaining);
        last unless defined($n) && $n > 0;

        my ($raw, $r) = ('');
        $r = sysread($self->{socket}, $raw, 512);
        last unless defined($r) && $r > 0;

        my $op = ord(substr($raw, 0, 1));
        unless ($op == ATT_HANDLE_VALUE_NOTIF) {
            $self->debug(sprintf('Unexpected opcode 0x%02X, skipping', $op));
            next;
        }

        # [op(1)][notif_handle(2)][value...]
        my $notif_handle = unpack('S<', substr($raw, 1, 2));
        my $value = substr($raw, 3);

        $self->debug(sprintf('Notification on handle 0x%04X: %s', 
            $notif_handle, join(' ', map { sprintf '%02X', $_ } unpack('C*', $value))));

        next unless $notif_handle == $handle;

        # Decode based on type
        if ($type eq 'weight' && length($value) >= 2) {
            my $raw_val = unpack('S<', substr($value, 0, 2));
            my $weight = $raw_val * 0.1;
            return $weight;
        } elsif ($type eq 'battery' && length($value) >= 1) {
            my $percent = unpack('C', substr($value, 0, 1));
            return $percent;
        }
    }

    return undef;
}

sub debug {
    my ($self, $msg) = @_;
    print "  [DEBUG] $msg\n" if $self->{debug};
}

1;

# ============================================================================
# Main package helpers
# ============================================================================

package main;

sub print_usage {
    print <<"EOF";
Usage: $0 -d AA:BB:CC:DD:EE:FF [actions] [options]

Actions (one or more; defaults to --measure --battery):
  --measure       Wait for weight measurement (step on scale)
  --battery       Show battery level

Required:
  -d, --device ADDR       BLE MAC address

Options:
  --addr-type TYPE        public|random (default: public)
  --connect-timeout SEC   Connect timeout in seconds (default: 5)
  --measure-timeout SEC   Timeout waiting for measurement (default: 10)
  -v, --debug             Verbose output
  -h, --help              Show this help

GATT UUID overrides (4-hex-digit):
  --service-uuid UUID         Service UUID (default: 181d)
  --weight-char-uuid UUID     Weight characteristic (default: 2a98)
  --battery-char-uuid UUID    Battery characteristic (default: 2a19)

Examples:
  $0 -d C7:AB:CD:12:34:56 --measure
  $0 -d C7:AB:CD:12:34:56 --battery
  $0 -d C7:AB:CD:12:34:56 --measure --battery
  $0 -d C7:AB:CD:12:34:56 --measure --battery -v

Notes:
  - Weight measurement requires stepping on the scale
  - Device will send notifications when measurement is ready
  - Battery level can be read at any time during connection
EOF
}
