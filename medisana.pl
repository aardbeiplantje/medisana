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
    scan_seconds      => 0,
    addr_type         => 'public',
    mode              => 'bs430',
    connect_timeout   => 5,
    debug             => 0,
    service_uuid      => '181d',
    weight_char_uuid  => '2a98',
    battery_char_uuid => '2a19',
    measure_timeout_s => 10,
    bs444_listen_s    => 30,
    bs444_timeoffset  => 1,
    wait_seconds      => 0,
    dump_gatt         => 0,
);

my ($do_measure, $do_battery) = (0, 0);

GetOptions(
    'device|d=s'             => \$opts{device},
    'scan-seconds=f'         => \$opts{scan_seconds},
    'addr-type=s'            => \$opts{addr_type},
    'mode=s'                 => \$opts{mode},
    'connect-timeout=f'       => \$opts{connect_timeout},
    'service-uuid=s'          => \$opts{service_uuid},
    'weight-char-uuid=s'      => \$opts{weight_char_uuid},
    'battery-char-uuid=s'     => \$opts{battery_char_uuid},
    'measure-timeout=f'       => \$opts{measure_timeout_s},
    'bs444-listen-seconds=f'  => \$opts{bs444_listen_s},
    'bs444-timeoffset!'       => \$opts{bs444_timeoffset},
    'wait-seconds=f'          => \$opts{wait_seconds},
    'dump-gatt'               => \$opts{dump_gatt},
    'measure'                 => \$do_measure,
    'battery'                 => \$do_battery,
    'debug|v+'                => \$opts{debug},
    'help|h'                  => sub { print_usage(); exit 0; },
) or do { print_usage(); exit 1; };

if ($opts{scan_seconds} < 0) {
    print STDERR "Error: --scan-seconds must be >= 0\n";
    exit 1;
}
if ($opts{device} && $opts{device} !~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
    print STDERR "Error: Invalid Bluetooth address format\n";
    exit 1;
}
if ($opts{addr_type} !~ /^(?:public|random)$/i) {
    print STDERR "Error: --addr-type must be 'public' or 'random'\n";
    exit 1;
}
if ($opts{mode} !~ /^(?:bs430|bs444|bs430-legacy)$/i) {
    print STDERR "Error: --mode must be 'bs430', 'bs444', or 'bs430-legacy'\n";
    exit 1;
}
$opts{mode} = lc $opts{mode};

# Assume BS430 behaves like BS444 unless explicitly forced to legacy mode.
if ($opts{mode} eq 'bs430') {
    $opts{mode} = 'bs444';
} elsif ($opts{mode} eq 'bs430-legacy') {
    $opts{mode} = 'bs430';
}

if (!$opts{device}) {
    if ($opts{scan_seconds} > 0) {
        my $found = auto_find_target_device(\%opts);
        unless ($found) {
            print STDERR "Error: no matching device found during scan\n";
            exit 1;
        }
        $opts{device} = $found;
        print "Auto-selected device: $found\n";
    } else {
        print STDERR "Error: -d / --device is required (or use --scan-seconds)\n";
        print_usage();
        exit 1;
    }
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
    ATT_READ_BY_GROUP_TYPE_REQ => 0x10,
    ATT_READ_BY_GROUP_TYPE_RSP => 0x11,
    ATT_READ_BY_TYPE_REQ      => 0x08,
    ATT_READ_BY_TYPE_RSP      => 0x09,
    ATT_READ_REQ              => 0x0A,
    ATT_READ_RSP              => 0x0B,
    ATT_WRITE_REQ             => 0x12,
    ATT_WRITE_RSP             => 0x13,
    ATT_HANDLE_VALUE_NOTIF    => 0x1B,
    ATT_HANDLE_VALUE_IND      => 0x1D,
    ATT_HANDLE_VALUE_CFM      => 0x1E,
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
        wait_seconds     => $o{wait_seconds} // 0,
        debug            => $o{debug} // 0,
        mode             => $o{mode} // 'bs430',

        service_uuid     => hex($o{service_uuid}),
        weight_uuid      => hex($o{weight_char_uuid}),
        battery_uuid     => hex($o{battery_char_uuid}),
        measure_timeout  => $o{measure_timeout_s} // 10,
        bs444_listen_s   => $o{bs444_listen_s} // 30,
        bs444_timeoffset => $o{bs444_timeoffset} ? 1 : 0,
        dump_gatt        => $o{dump_gatt} // 0,

        bs444_service_uuid => '000078b200001000800000805f9b34fb',
        bs444_person_uuid  => '00008a8200001000800000805f9b34fb',
        bs444_weight_uuid  => '00008a2100001000800000805f9b34fb',
        bs444_body_uuid    => '00008a2200001000800000805f9b34fb',
        bs444_command_uuid => '00008a8100001000800000805f9b34fb',

        bs444_service_start => 0,
        bs444_service_end   => 0,
        bs444_person_handle => 0,
        bs444_weight_handle => 0,
        bs444_body_handle   => 0,
        bs444_command_handle => 0,

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

    if ($self->{mode} eq 'bs444') {
        print "Mode:   BS444\n";
    } else {
        print "Mode:   BS430\n";
    }

    unless ($self->ble_connect_with_retry()) {
        print STDERR "ERROR: BLE connection failed\n";
        return 1;
    }
    if ($self->{dump_gatt}) {
        $self->dump_gatt();
        $self->ble_disconnect();
        return 0;
    }

    if ($self->{mode} eq 'bs444') {
        my $ok = $self->run_bs444();
        $self->ble_disconnect();
        return $ok ? 0 : 1;
    }

    unless ($self->discover_handles(
        need_weight  => $todo{measure},
        need_battery => $todo{battery},
    )) {
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

sub run_bs444 {
    my ($self) = @_;

    unless ($self->discover_bs444_handles()) {
        print STDERR "ERROR: Could not discover BS444 service/characteristics\n";
        return 0;
    }

    $self->exchange_mtu(160);
    $self->subscribe_bs444_indications();
    $self->send_bs444_command();
    $self->listen_bs444_indications();
    return 1;
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

sub ble_connect_with_retry {
    my ($self) = @_;
    return 1 if $self->ble_connect();

    my $wait = $self->{wait_seconds} // 0;
    return 0 if $wait <= 0;

    my $deadline = time() + $wait;
    while (time() < $deadline) {
        select(undef, undef, undef, 0.7);
        return 1 if $self->ble_connect();
    }
    return 0;
}

sub dump_gatt {
    my ($self) = @_;

    # Read and print device name first (characteristic 0x2A00 inside service 0x1800)
    my $name_rsp = $self->att_request(
        pack('C S< S< S<', ATT_READ_BY_TYPE_REQ, 0x0001, 0x000B, 0x2A00),
        2.0
    );
    if (defined $name_rsp && length($name_rsp) >= 4
            && ord(substr($name_rsp, 0, 1)) == ATT_READ_BY_TYPE_RSP) {
        my $elen  = ord(substr($name_rsp, 1, 1));
        my $voff  = 4;  # [op][elen][decl_handle(2)] then value starts at byte 4
        my $vlen  = $elen - 2;  # subtract declaration handle bytes
        if ($elen >= 4 && length($name_rsp) >= 2 + $elen && $vlen > 0) {
            my $name = substr($name_rsp, 2 + 2, $vlen);
            $name =~ s/[^\x20-\x7E]//g;
            print "Device name: $name\n" if length($name);
        }
    }

    print "GATT services (primary)\n";
    print "=======================\n";

    # Paginate through all services (ATT_READ_BY_GROUP_TYPE_RSP paginates at MTU boundary)
    my $start_h = 0x0001;
    my $found   = 0;
    while ($start_h <= 0xFFFF) {
        my $rsp = $self->att_request(
            pack('C S< S< S<', ATT_READ_BY_GROUP_TYPE_REQ, $start_h, 0xFFFF, GATT_PRIMARY_SERVICE_UUID),
            3.0
        );
        last unless defined $rsp && length($rsp) >= 2
                    && ord(substr($rsp, 0, 1)) == ATT_READ_BY_GROUP_TYPE_RSP;

        my $elen     = ord(substr($rsp, 1, 1));
        my $pos      = 2;
        my $last_end = $start_h;
        last if $elen < 6;

        while ($pos + $elen <= length($rsp)) {
            my $e = substr($rsp, $pos, $elen);
            my ($svc_start, $svc_end) = unpack('S< S<', substr($e, 0, 4));

            my $uuid = 'unknown';
            if ($elen == 6) {
                $uuid = sprintf('%04x', unpack('S<', substr($e, 4, 2)));
            } elsif ($elen == 20) {
                my @b = unpack('C16', substr($e, 4, 16));
                $uuid = join('', map { sprintf('%02x', $_) } reverse @b);
            }

            printf "- 0x%04X-0x%04X  UUID %s\n", $svc_start, $svc_end, $uuid;
            $last_end = $svc_end;
            $found++;
            $pos += $elen;
        }

        last if $last_end >= 0xFFFF;
        $start_h = $last_end + 1;
    }

    print "No primary service response\n" unless $found;
}

sub discover_bs444_handles {
    my ($self) = @_;

    my ($svc_start, $svc_end) = $self->find_service_range($self->{bs444_service_uuid});
    unless ($svc_start) {
        $self->debug('BS444 service 78b2 not found');
        return 0;
    }
    $self->{bs444_service_start} = $svc_start;
    $self->{bs444_service_end}   = $svc_end;
    $self->debug(sprintf('BS444 service: 0x%04X-0x%04X', $svc_start, $svc_end));

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
            my $e = substr($crsp, $pos, $elen);
            my $decl = unpack('S<', substr($e, 0, 2));
            my $val  = unpack('S<', substr($e, 3, 2));

            my $uuid = '';
            if ($elen == 7) {
                $uuid = sprintf('%04x', unpack('S<', substr($e, 5, 2)));
            } elsif ($elen == 21) {
                my @b = unpack('C16', substr($e, 5, 16));
                $uuid = join('', map { sprintf('%02x', $_) } reverse @b);
            }

            $self->debug(sprintf('  BS444 char uuid=%s handle=0x%04X', $uuid || '?', $val));

            if ($uuid eq $self->{bs444_person_uuid}) {
                $self->{bs444_person_handle} = $val;
            } elsif ($uuid eq $self->{bs444_weight_uuid}) {
                $self->{bs444_weight_handle} = $val;
            } elsif ($uuid eq $self->{bs444_body_uuid}) {
                $self->{bs444_body_handle} = $val;
            } elsif ($uuid eq $self->{bs444_command_uuid}) {
                $self->{bs444_command_handle} = $val;
            }

            $last_decl = $decl;
            $pos += $elen;
        }
        $start = $last_decl + 1;
    }

    $self->debug(sprintf(
        'BS444 handles: person=0x%04X weight=0x%04X body=0x%04X command=0x%04X',
        $self->{bs444_person_handle},
        $self->{bs444_weight_handle},
        $self->{bs444_body_handle},
        $self->{bs444_command_handle}
    ));

    return $self->{bs444_person_handle}
        && $self->{bs444_weight_handle}
        && $self->{bs444_body_handle}
        && $self->{bs444_command_handle};
}

sub find_service_range {
    my ($self, $target_uuid) = @_;
    my $start_h = 0x0001;

    while ($start_h <= 0xFFFF) {
        my $rsp = $self->att_request(
            pack('C S< S< S<', ATT_READ_BY_GROUP_TYPE_REQ, $start_h, 0xFFFF, GATT_PRIMARY_SERVICE_UUID),
            3.0
        );
        last unless defined $rsp && length($rsp) >= 2
                    && ord(substr($rsp, 0, 1)) == ATT_READ_BY_GROUP_TYPE_RSP;

        my $elen     = ord(substr($rsp, 1, 1));
        my $pos      = 2;
        my $last_end = $start_h;
        last if $elen < 6;

        while ($pos + $elen <= length($rsp)) {
            my $e = substr($rsp, $pos, $elen);
            my ($svc_start, $svc_end) = unpack('S< S<', substr($e, 0, 4));

            my $uuid = '';
            if ($elen == 6) {
                $uuid = sprintf('%04x', unpack('S<', substr($e, 4, 2)));
            } elsif ($elen == 20) {
                my @b = unpack('C16', substr($e, 4, 16));
                $uuid = join('', map { sprintf('%02x', $_) } reverse @b);
            }

            if ($uuid eq lc($target_uuid)) {
                return ($svc_start, $svc_end);
            }

            $last_end = $svc_end;
            $pos += $elen;
        }

        last if $last_end >= 0xFFFF;
        $start_h = $last_end + 1;
    }

    return (0, 0);
}

sub has_target_service {
    my ($self) = @_;
    if ($self->{mode} eq 'bs444') {
        my ($s, $e) = $self->find_service_range($self->{bs444_service_uuid});
        return $s ? 1 : 0;
    }

    my $rsp = $self->att_request(
        pack('C S< S< S<', ATT_FIND_BY_TYPE_REQ, 0x0001, 0xFFFF,
            GATT_PRIMARY_SERVICE_UUID, $self->{service_uuid}),
        2.0
    );
    return (defined $rsp && length($rsp) >= 5
        && ord(substr($rsp, 0, 1)) == ATT_FIND_BY_TYPE_RSP) ? 1 : 0;
}

sub subscribe_bs444_indications {
    my ($self) = @_;
    for my $h ($self->{bs444_person_handle}, $self->{bs444_weight_handle}, $self->{bs444_body_handle}) {
        next unless $h;
        my $cccd = $h + 1;
        my $req = pack('C S< S<', ATT_WRITE_REQ, $cccd, 0x0002);
        my $rsp = $self->att_request($req, 2.0);
        my $ok  = defined($rsp) && length($rsp) >= 1 && ord(substr($rsp, 0, 1)) == ATT_WRITE_RSP;
        $self->debug($ok ? sprintf('Indications enabled (cccd=0x%04X)', $cccd)
                         : sprintf('Indication enable failed (cccd=0x%04X)', $cccd));
    }
}

sub send_bs444_command {
    my ($self) = @_;
    my $h = $self->{bs444_command_handle};
    return unless $h;

    my $ts = time();
    $ts -= 1262304000 if $self->{bs444_timeoffset};
    my $payload = pack('C V', 0x02, $ts & 0xFFFFFFFF);

    my $req = pack('C S<', ATT_WRITE_REQ, $h) . $payload;
    my $rsp = $self->att_request($req, 2.0);
    my $ok  = defined($rsp) && length($rsp) >= 1 && ord(substr($rsp, 0, 1)) == ATT_WRITE_RSP;
    $self->debug($ok ? 'BS444 command sent' : 'BS444 command write failed');
}

sub listen_bs444_indications {
    my ($self) = @_;

    my $person_data_h = $self->{bs444_person_handle} ? ($self->{bs444_person_handle} - 1) : 0;
    my $weight_data_h = $self->{bs444_weight_handle} ? ($self->{bs444_weight_handle} - 1) : 0;
    my $body_data_h   = $self->{bs444_body_handle} ? ($self->{bs444_body_handle} - 1) : 0;

    my $deadline = time() + $self->{bs444_listen_s};
    print sprintf("Listening for BS444 data for %.0f seconds...\n", $self->{bs444_listen_s});

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
        next unless $op == ATT_HANDLE_VALUE_NOTIF || $op == ATT_HANDLE_VALUE_IND;

        if ($op == ATT_HANDLE_VALUE_IND) {
            syswrite($self->{socket}, pack('C', ATT_HANDLE_VALUE_CFM));
        }

        next if length($raw) < 4;
        my $h = unpack('S<', substr($raw, 1, 2));
        my @v = unpack('C*', substr($raw, 3));

        if ($person_data_h && $h == $person_data_h) {
            my $d = $self->decode_bs444_person(\@v);
            next unless $d->{valid};
            printf "Person: id=%d sex=%s age=%d size=%.2fm activity=%s\n",
                $d->{person}, $d->{male} ? 'male' : 'female', $d->{age}, $d->{size_m},
                $d->{high_activity} ? 'high' : 'normal';
        } elsif ($weight_data_h && $h == $weight_data_h) {
            my $d = $self->decode_bs444_weight(\@v);
            next unless $d->{valid};
            printf "Weight: %.2f kg (person=%d ts=%d)\n", $d->{weight}, $d->{person}, $d->{timestamp};
        } elsif ($body_data_h && $h == $body_data_h) {
            my $d = $self->decode_bs444_body(\@v);
            next unless $d->{valid};
            printf "Body: person=%d kcal=%d fat=%.1f tbw=%.1f muscle=%.1f bone=%.1f ts=%d\n",
                $d->{person}, $d->{kcal}, $d->{fat}, $d->{tbw}, $d->{muscle}, $d->{bone}, $d->{timestamp};
        } else {
            $self->debug(sprintf('Unhandled BS444 packet handle=0x%04X len=%d', $h, scalar(@v)));
        }
    }
}

sub decode_bs444_person {
    my ($self, $v) = @_;
    return { valid => 0 } unless @$v >= 9;
    return {
        valid         => ($v->[0] == 0x84) ? 1 : 0,
        person        => $v->[2],
        male          => ($v->[4] == 1) ? 1 : 0,
        age           => $v->[5],
        size_m        => $v->[6] / 100.0,
        high_activity => ($v->[8] == 3) ? 1 : 0,
    };
}

sub decode_bs444_weight {
    my ($self, $v) = @_;
    return { valid => 0 } unless @$v >= 14;
    my $ts = ($v->[8] << 24) | ($v->[7] << 16) | ($v->[6] << 8) | $v->[5];
    $ts += 1262304000 if $self->{bs444_timeoffset};
    return {
        valid     => ($v->[0] == 0x1d) ? 1 : 0,
        weight    => (($v->[2] << 8) | $v->[1]) / 100.0,
        timestamp => $ts,
        person    => $v->[13],
    };
}

sub decode_bs444_body {
    my ($self, $v) = @_;
    return { valid => 0 } unless @$v >= 16;
    my $ts = ($v->[4] << 24) | ($v->[3] << 16) | ($v->[2] << 8) | $v->[1];
    $ts += 1262304000 if $self->{bs444_timeoffset};
    return {
        valid     => ($v->[0] == 0x6f) ? 1 : 0,
        timestamp => $ts,
        person    => $v->[5],
        kcal      => ($v->[7] << 8) | $v->[6],
        fat       => (0x0fff & (($v->[9] << 8) | $v->[8])) / 10.0,
        tbw       => (0x0fff & (($v->[11] << 8) | $v->[10])) / 10.0,
        muscle    => (0x0fff & (($v->[13] << 8) | $v->[12])) / 10.0,
        bone      => (0x0fff & (($v->[15] << 8) | $v->[14])) / 10.0,
    };
}

sub discover_handles {
    my ($self, %need) = @_;

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

    my $need_weight  = $need{need_weight} ? 1 : 0;
    my $need_battery = $need{need_battery} ? 1 : 0;
    my $ok_weight    = !$need_weight  || $self->{handle_weight};
    my $ok_battery   = !$need_battery || $self->{handle_battery};
    return ($ok_weight && $ok_battery) ? 1 : 0;
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

sub probe_candidate_device {
    my ($opts, $mac) = @_;

    # Try requested address type first, then fallback quickly to the other type.
    my @atypes = ($opts->{addr_type});
    push @atypes, grep { $_ ne $opts->{addr_type} } qw(public random);

    for my $atype (@atypes) {
        my %probe_opts = %{$opts};
        $probe_opts{device} = $mac;
        $probe_opts{addr_type} = $atype;
        $probe_opts{wait_seconds} = 0;
        # Keep connect attempts short for short advertising windows.
        $probe_opts{connect_timeout} = ($probe_opts{connect_timeout} > 1.5)
            ? 1.5 : $probe_opts{connect_timeout};

        my $probe = Medisana::BS430->new(%probe_opts);
        next unless $probe->ble_connect();

        my $match = $probe->has_target_service();
        $probe->ble_disconnect();
        return 1 if $match;
    }

    return 0;
}

sub auto_find_target_device {
    my ($opts) = @_;

    my $seconds = int($opts->{scan_seconds});
    print "Scanning for BLE devices for $seconds seconds...\n";

    my @cmd = ('bash', '-lc', "bluetoothctl --timeout $seconds scan on 2>&1");
    open(my $fh, '-|', @cmd) or return undef;

    my %seen;
    my $seen_count = 0;
    while (my $line = <$fh>) {
        while ($line =~ /([0-9A-F]{2}(?::[0-9A-F]{2}){5})/ig) {
            my $mac = uc $1;
            next if $seen{$mac}++;
            $seen_count++;

            print "Seen $mac -> probing now...\n";
            if (probe_candidate_device($opts, $mac)) {
                close $fh;
                return $mac;
            }
        }
    }
    close $fh;

    print "Scan candidates seen: $seen_count\n";

    return undef;
}

sub print_usage {
    print <<"EOF";
Usage: $0 -d AA:BB:CC:DD:EE:FF [actions] [options]

Actions (one or more; defaults to --measure --battery):
  --measure       Wait for weight measurement (step on scale)
  --battery       Show battery level

Required:
    -d, --device ADDR          BLE MAC address
            --scan-seconds SEC     Scan and auto-select first matching device

Options:
  --addr-type TYPE        public|random (default: public)
    --mode MODE             bs430|bs444|bs430-legacy (default: bs430 -> bs444)
  --connect-timeout SEC   Connect timeout in seconds (default: 5)
    --wait-seconds SEC      Keep retrying connect for this many seconds (default: 0)
  --measure-timeout SEC   Timeout waiting for measurement (default: 10)
    --bs444-listen-seconds SEC  Listen window in BS444 mode (default: 30)
    --[no-]bs444-timeoffset     Add 2010 offset to scale timestamps (default: on)
    --dump-gatt             Print discovered primary services and exit
  -v, --debug             Verbose output
  -h, --help              Show this help

GATT UUID overrides (4-hex-digit):
  --service-uuid UUID         Service UUID (default: 181d)
  --weight-char-uuid UUID     Weight characteristic (default: 2a98)
  --battery-char-uuid UUID    Battery characteristic (default: 2a19)

Examples:
  $0 -d C7:AB:CD:12:34:56 --measure
  $0 -d C7:AB:CD:12:34:56 --battery
    $0 -d C7:AB:CD:12:34:56 --mode bs430 -v
    $0 --scan-seconds 20 --mode bs430 --addr-type public -v
  $0 -d C7:AB:CD:12:34:56 --measure --battery
    $0 -d C7:AB:CD:12:34:56 --addr-type random --wait-seconds 30 --dump-gatt -v
    $0 -d C7:AB:CD:12:34:56 --mode bs444 --addr-type public --bs444-listen-seconds 30 -v
    $0 -d C7:AB:CD:12:34:56 --mode bs430-legacy --measure --battery -v
  $0 -d C7:AB:CD:12:34:56 --measure --battery -v

Notes:
  - Weight measurement requires stepping on the scale
  - Device will send notifications when measurement is ready
  - Battery level can be read at any time during connection
EOF
}
