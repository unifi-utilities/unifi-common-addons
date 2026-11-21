#!/usr/bin/perl
# hdhomerun-discovery proxy: answers HDHomeRun discovery across networks.
#
# An app on a client network sends a discovery request (UDP 65001) as a
# broadcast. The proxy checks it, sends its own copy as a broadcast on each
# tuner network, and sends each valid answer back to the app that asked.
# It uses ordinary UDP sockets only, and runs as an unprivileged user.
#
# Usage:
#   proxy.pl --client IF [--client IF ...] --tuner IF [--tuner IF ...] [-d]
#   proxy.pl --probe --tuner IF [--tuner IF ...]   (list the tuners, exit)
#
# Needs only perl-base. Design and limits: README.md.
use strict;
use warnings;
use Socket qw(:DEFAULT IPPROTO_UDP SOL_SOCKET SO_REUSEADDR SO_BROADCAST MSG_DONTWAIT);
use IO::Select;

use constant {
    PORT            => 65001,
    SO_BINDTODEVICE => 25,      # Linux on aarch64 and x86_64 (asm-generic)
    TYPE_REQ        => 0x0002,  # HDHOMERUN_TYPE_DISCOVER_REQ
    TYPE_RPY        => 0x0003,  # HDHOMERUN_TYPE_DISCOVER_RPY
    MAX_PKT         => 1460,    # HDHOMERUN_MAX_PACKET_SIZE
    WINDOW          => 2,       # seconds to collect answers (whole seconds:
                                # perl-base has no Time::HiRes)
    MAX_PENDING     => 32,      # sockets waiting for answers, at most
    MAX_SOURCES     => 1024,    # app addresses with a rate-limit record
    SRC_BURST       => 10,      # requests one app may send at once
    SRC_RATE        => 5,       # ... and per second after that
    CHECK_EVERY     => 10,      # seconds between interface checks
    LOG_EVERY       => 600,     # seconds between repeats of one warning
};

# Only the tests lower the cap, to reach it with few requests.
my $max_pending = ($ENV{HDHR_MAX_PENDING} // '') =~ /^([1-9][0-9]{0,3})$/ ? $1 : MAX_PENDING;

my (@clients, @tuners, $probe, $debug);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--client') { push @clients, shift(@ARGV) // die "--client needs a name\n" }
    elsif ($a eq '--tuner')  { push @tuners,  shift(@ARGV) // die "--tuner needs a name\n" }
    elsif ($a eq '--probe')  { $probe = 1 }
    elsif ($a eq '-d')       { $debug = 1 }
    else { die "unknown argument '$a'\n" }
}
for (@clients, @tuners) {
    die "bad interface name '$_'\n" unless /^[A-Za-z0-9_.@-]{1,15}$/;
}
my %seen;
for (@clients, @tuners) { die "interface $_ is listed twice\n" if $seen{$_}++ }
die "give one or more --tuner\n" unless @tuners;
die "give one or more --client\n" unless @clients || $probe;
$| = 1;

sub logmsg { print STDERR "hdhomerun-discovery: @_\n" }
sub dbg    { logmsg(@_) if $debug }
my %last_warn;
sub warn_limited {    # one line per kind of warning, at most every LOG_EVERY s
    my ($kind, $msg) = @_;
    my $now = time;
    return if $last_warn{$kind} && $now - $last_warn{$kind} < LOG_EVERY;
    $last_warn{$kind} = $now;
    logmsg($msg);
}

# ---------- packets ----------

# CRC-32 as in libhdhomerun (the zlib polynomial), stored little-endian.
my @crc_table = map {
    my $c = $_;
    $c = $c & 1 ? 0xEDB88320 ^ ($c >> 1) : $c >> 1 for 1 .. 8;
    $c;
} 0 .. 255;
sub crc32 {
    my $c = 0xFFFFFFFF;
    $c = $crc_table[($c ^ $_) & 0xFF] ^ ($c >> 8) for unpack('C*', $_[0]);
    return $c ^ 0xFFFFFFFF;
}

# frame_type DATA: the packet type if DATA is one whole HDHomeRun frame
# (type, length, payload, CRC) with a correct CRC; undef otherwise.
sub frame_type {
    my ($d) = @_;
    my $n = length $d;
    return undef if $n < 8 || $n > MAX_PKT;
    my ($type, $len) = unpack('n n', $d);
    return undef if 4 + $len + 4 != $n;
    return undef if crc32(substr($d, 0, 4 + $len)) != unpack('V', substr($d, 4 + $len, 4));
    return $type;
}

sub make_request {    # any tuner, any device ID
    my $p = pack('n n', TYPE_REQ, 12) . pack('C C N', 0x01, 4, 0xFFFFFFFF) . pack('C C N', 0x02, 4, 0xFFFFFFFF);
    return $p . pack('V', crc32($p));
}

# reply_id DATA: the device ID from a discovery answer, as 8 hex digits.
sub reply_id {
    my ($d) = @_;
    my $len = unpack('n', substr($d, 2, 2));
    my $pos = 4;
    my $end = 4 + $len;
    while ($pos + 2 <= $end) {
        my $tag = unpack('C', substr($d, $pos++, 1));
        my $l = unpack('C', substr($d, $pos++, 1));
        if ($l & 0x80) {
            last if $pos >= $end;
            $l = ($l & 0x7F) | (unpack('C', substr($d, $pos++, 1)) << 7);
        }
        last if $pos + $l > $end;
        return sprintf('%08X', unpack('N', substr($d, $pos, 4))) if $tag == 0x02 && $l == 4;
        $pos += $l;
    }
    return 'unknown';
}

# ---------- interfaces ----------

sub ifindex {
    open(my $fh, '<', "/sys/class/net/$_[0]/ifindex") or return -1;
    my $i = <$fh>;
    close $fh;
    chomp $i;
    return $i;
}

# nets DEV: the IPv4 networks on DEV, as [network, mask] pairs.
sub nets {
    my ($dev) = @_;
    my @n;
    open(my $fh, '-|', 'ip', '-4', '-o', 'addr', 'show', 'dev', $dev) or return [];
    # A named variable: callers loop over interface names in $_.
    while (my $line = <$fh>) {
        next unless $line =~ m{\binet (\d+\.\d+\.\d+\.\d+)/(\d+)};
        my $mask = $2 == 0 ? 0 : (0xFFFFFFFF << (32 - $2)) & 0xFFFFFFFF;
        push @n, [unpack('N', inet_aton($1)) & $mask, $mask];
    }
    close $fh;
    return \@n;
}

sub in_nets {
    my ($ip, $n) = @_;
    for (@$n) { return 1 if ($ip & $_->[1]) == $_->[0] }
    return 0;
}

sub bound_socket {    # bound_socket DEV PORT BROADCAST
    my ($dev, $port, $bcast) = @_;
    socket(my $s, PF_INET, SOCK_DGRAM, IPPROTO_UDP) or die "socket: $!\n";
    setsockopt($s, SOL_SOCKET, SO_REUSEADDR, 1) or die "SO_REUSEADDR: $!\n" if $port;
    setsockopt($s, SOL_SOCKET, SO_BROADCAST, 1) or die "SO_BROADCAST: $!\n" if $bcast;
    setsockopt($s, SOL_SOCKET, SO_BINDTODEVICE, pack('Z*', $dev)) or die "cannot bind to $dev: $!\n";
    bind($s, sockaddr_in($port, INADDR_ANY)) or die "cannot bind UDP $port on $dev: $!\n";
    return $s;
}

my $bcast = sockaddr_in(PORT, INADDR_BROADCAST);
my %tnet;
$tnet{$_} = nets($_) for @tuners;
for (@tuners) { die "$_ has no IPv4 address\n" unless @{ $tnet{$_} } }

# valid_answer SOCKADDR DATA TUNER: from port 65001 on the tuner network,
# a whole discovery answer.
sub valid_answer {
    my ($from, $data, $t) = @_;
    my ($port, $addr) = sockaddr_in($from);
    return 0 unless $port == PORT && in_nets(unpack('N', $addr), $tnet{$t});
    my $type = frame_type($data);
    return defined $type && $type == TYPE_RPY;
}

# ---------- probe ----------

if ($probe) {
    my $sel = IO::Select->new;
    my %dev_of;
    for my $t (@tuners) {
        my $s = bound_socket($t, 0, 1);
        send($s, make_request(), 0, $bcast) or die "cannot send on $t: $!\n";
        $dev_of{fileno $s} = $t;
        $sel->add($s);
    }
    my %found;
    my $end = time + 2;
    while ((my $left = $end - time) > 0) {
        for my $s ($sel->can_read($left)) {
            my $from = recv($s, my $data, 2048, MSG_DONTWAIT) // next;
            my $t = $dev_of{fileno $s};
            next unless valid_answer($from, $data, $t);
            my $ip = inet_ntoa((sockaddr_in($from))[1]);
            $found{"$ip $t"} //= "tuner $ip on $t, device ID " . reply_id($data);
        }
    }
    print "$_\n" for map { $found{$_} } sort keys %found;
    exit(%found ? 0 : 3);
}

# ---------- proxy ----------

my $sel = IO::Select->new;
my (%client_of, %pending, %idx, %bucket);
for my $c (@clients) {
    my $s = bound_socket($c, PORT, 0);
    $client_of{fileno $s} = [$c, $s];
    $sel->add($s);
}
for (@clients, @tuners) {
    $idx{$_} = ifindex($_);
    die "$_: not in /sys/class/net\n" if $idx{$_} eq '-1';
}
logmsg("clients @clients, tuners @tuners, UDP " . PORT);

$SIG{TERM} = $SIG{INT} = sub { logmsg('stopping'); exit 0 };

# allow IP: a token bucket for each app address, so that one app cannot make
# the proxy flood the tuner networks.
sub allow {
    my ($ip, $now) = @_;
    my $b = $bucket{$ip};
    unless ($b) {
        # A bound on memory: spoofed source addresses could add records
        # without end.
        return 0 if keys(%bucket) >= MAX_SOURCES;
        $b = $bucket{$ip} = [SRC_BURST, $now];
    }
    my $dt = $now - $b->[1];
    $dt = 0 if $dt < 0;    # the clock stepped back
    $b->[0] += $dt * SRC_RATE;
    $b->[0] = SRC_BURST if $b->[0] > SRC_BURST;
    $b->[1] = $now;
    return 0 if $b->[0] < 1;
    $b->[0]--;
    return 1;
}

sub drop_pending {
    my ($fd) = @_;
    my $p = delete $pending{$fd} or return;
    $sel->remove($p->{sock});
    close $p->{sock};
}

sub on_request {
    my ($cdev, $csock, $from, $data, $now) = @_;
    my ($aport, $aaddr) = sockaddr_in($from);
    my $app = inet_ntoa($aaddr) . ":$aport";
    my $type = frame_type($data);
    unless (defined $type && $type == TYPE_REQ) {
        dbg("drop from $app on $cdev: not a discovery request");
        return;
    }
    # Check the capacity first, so that a dropped request costs no
    # rate-limit record.
    if (keys(%pending) + @tuners > $max_pending) {
        warn_limited('busy', 'too many requests at once; some are dropped');
        return;
    }
    unless (allow(inet_ntoa($aaddr), $now)) {
        warn_limited('rate', "requests from " . inet_ntoa($aaddr) . " exceed the rate limit or the table is full; some are dropped");
        return;
    }
    for my $t (@tuners) {
        my $s = eval { bound_socket($t, 0, 1) };
        unless ($s) {
            warn_limited("sock $t", "cannot open a socket on $t: $@");
            next;
        }
        unless (send($s, $data, 0, $bcast)) {
            warn_limited("send $t", "cannot send on $t: $!");
            close $s;
            next;
        }
        $pending{fileno $s} = { sock => $s, tuner => $t, csock => $csock, app => $from, until => $now + WINDOW };
        $sel->add($s);
        dbg("request from $app on $cdev -> $t");
    }
}

sub on_answer {
    my ($p, $from, $data) = @_;
    my ($tport, $taddr) = sockaddr_in($from);
    unless (valid_answer($from, $data, $p->{tuner})) {
        dbg('drop from ' . inet_ntoa($taddr) . ":$tport on $p->{tuner}: not a discovery answer");
        return;
    }
    send($p->{csock}, $data, MSG_DONTWAIT, $p->{app})
        or warn_limited('answer', "cannot send an answer to an app: $!");
    my ($aport, $aaddr) = sockaddr_in($p->{app});
    dbg('answer from ' . inet_ntoa($taddr) . ' -> ' . inet_ntoa($aaddr) . ":$aport");
}

my $next_check = time + CHECK_EVERY;
while (1) {
    my $now = time;
    # If the clock stepped back, keep every deadline within its normal
    # distance from now, so that nothing waits for the clock to catch up.
    $next_check = $now + CHECK_EVERY if $next_check > $now + CHECK_EVERY;
    for (values %pending) { $_->{until} = $now + WINDOW if $_->{until} > $now + WINDOW }
    if ($now >= $next_check) {
        $next_check = $now + CHECK_EVERY;
        # UniFi OS can create a bridge again when a network changes. The
        # sockets of the old bridge then receive nothing. Exit, so that
        # systemd starts the proxy again on the new bridge.
        for (keys %idx) {
            if (ifindex($_) ne $idx{$_}) {
                logmsg("interface $_ changed; exiting so that systemd starts the proxy again");
                exit 1;
            }
        }
        $tnet{$_} = nets($_) for @tuners;
        for (keys %bucket) { delete $bucket{$_} if $now - $bucket{$_}[1] > 60 }
    }
    for my $fd (keys %pending) { drop_pending($fd) if $pending{$fd}{until} <= $now }

    for my $s ($sel->can_read(1)) {
        my $from = recv($s, my $data, 2048, MSG_DONTWAIT);
        next unless defined $from && length $from;
        if (my $c = $client_of{fileno $s}) {
            on_request($c->[0], $c->[1], $from, $data, time);
        } elsif (my $p = $pending{fileno $s}) {
            on_answer($p, $from, $data);
        }
    }
}
