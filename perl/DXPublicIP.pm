package DXPublicIP;
use strict;
use warnings;
use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);
use DXUtil ();

# Linux procfs route tables are kernel interfaces, not distribution command output.
# Directly connected, non-default routes supplement private intranet ranges.
# Explicit local aliases remain supported by DXUtil::alias_localhost.
my @networks;
my $published;
my $previous;
my $refreshing = 0;

sub _unmap_ipv4 {
    my ($ip) = @_;
    return $ip unless defined $ip;
    return $1 if $ip =~ /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i
        && inet_pton(AF_INET, $1);
    # Also accept the hexadecimal spelling of an IPv4-mapped IPv6 address.
    if ($ip =~ /:/) {
        my $packed = inet_pton(AF_INET6, $ip);
        return inet_ntop(AF_INET, substr($packed, 12, 4))
            if defined($packed) && substr($packed, 0, 12) eq ("\0" x 10 . "\xff\xff");
    }
    return $ip;
}

sub _prefix_match {
    my ($ip, $net, $bits) = @_;
    $ip = _unmap_ipv4($ip);
    return 0 if !defined($ip) || !defined($net) || !defined($bits);
    my $family = $ip =~ /:/ ? AF_INET6 : AF_INET;
    my $a = inet_pton($family, $ip) or return 0;
    my $b = inet_pton($family, $net) or return 0;
    return 0 if length($a) != length($b) || $bits < 0 || $bits > 8 * length($a);
    my $full = int($bits / 8);
    return 0 if substr($a, 0, $full) ne substr($b, 0, $full);
    my $rem = $bits % 8;
    return 1 unless $rem;
    my $mask = (0xff << (8 - $rem)) & 0xff;
    return (ord(substr($a, $full, 1)) & $mask) == (ord(substr($b, $full, 1)) & $mask);
}

sub discover_networks {
    my @found;
    if (open my $fh, '<', '/proc/net/route') {
        <$fh>;
        while (my $line = <$fh>) {
            my @f = split /\s+/, $line;
            next unless @f >= 8 && $f[1] =~ /^[0-9a-fA-F]{8}$/ && $f[2] =~ /^[0-9a-fA-F]{8}$/
                && $f[7] =~ /^[0-9a-fA-F]{8}$/;
            next unless (hex($f[3]) & 1) && !(hex($f[3]) & 2) && hex($f[2]) == 0;
            my $mask = pack('V', hex($f[7]));
            my $bitmask = unpack('B32', $mask);
            next unless $bitmask =~ /^1*0*$/;
            my $bits = ($bitmask =~ tr/1/1/);
            next if $bits == 0;
            my $network = inet_ntop(AF_INET, pack('V', hex($f[1])));
            push @found, [$network, $bits];
        }
        close $fh;
    }
    if (open my $fh, '<', '/proc/net/ipv6_route') {
        while (my $line = <$fh>) {
            my @f = split /\s+/, $line;
            next unless @f >= 10 && $f[0] =~ /^[0-9a-fA-F]{32}$/ && $f[1] =~ /^[0-9a-fA-F]{2}$/;
            my $bits = hex($f[1]);
            next if !$bits || $bits > 128 || $f[4] !~ /^0{32}$/;
            my $net = inet_ntop(AF_INET6, pack('H*', $f[0]));
            push @found, [$net, $bits];
        }
        close $fh;
    }
    @networks = @found;
    return scalar @networks;
}

sub _set_networks_for_test { @networks = @_; }
sub networks { return map { $_->[0] . '/' . $_->[1] } @networks }
sub published { return $published }

sub _alias_configured {
    my ($ip) = @_;
    for my $alias (@main::localhost_names) {
        return 1 if defined $alias && $ip eq $alias;
    }
    return 0;
}

sub _is_local_network_address {
    my ($lookup) = @_;
    $lookup = _unmap_ipv4($lookup);
    return 0 unless defined($lookup) && length($lookup);
    return 0 if DXUtil::is_public_ip($lookup);
    # Locally originated protocol addresses may come from routed VLANs or
    # private overlays. Do not depend on a directly connected kernel route.
    # Do not generalise this to all non-public/special-purpose addresses.
    for my $n (['10.0.0.0', 8], ['172.16.0.0', 12], ['192.168.0.0', 16],
               ['100.64.0.0', 10], ['169.254.0.0', 16],
               ['fc00::', 7], ['fe80::', 10]) {
        return 1 if _prefix_match($lookup, @$n);
    }
    # Preserve the previous behaviour for directly connected networks.
    for my $n (@networks) { return 1 if _prefix_match($lookup, @$n) }
    return 0;
}

sub normalize {
    my ($ip) = @_;
    return $ip unless defined $ip && length $ip;
    my $lookup = _unmap_ipv4($ip);
    my $local = $lookup eq 'localhost' || $lookup eq 'ip6-localhost'
        || _prefix_match($lookup, '127.0.0.0', 8) || _prefix_match($lookup, '::1', 128)
        || _alias_configured($ip) || _alias_configured($lookup);
    $local ||= _is_local_network_address($lookup);
    # Old advertised IP is updated only for locally-owned route objects,
    # by the caller; never globally rewrite a remote user's public address.
    return $ip unless $local;
    my $candidate = $published || ($main::me ? $main::me->{hostname} : '') || '';
    return DXUtil::is_public_ip($candidate) ? $candidate : $ip;
}

sub normalize_owned {
    my ($ip) = @_;
    return $published if $published && defined $previous && defined $ip
        && $ip eq $previous;
    return normalize($ip);
}

sub set_explicit { return _apply($_[0]) }

sub _apply {
    my ($ip) = @_;
    return 0 unless DXUtil::is_public_ip($ip);
    return 0 if defined($published) && $published eq $ip;
    $previous = $published;
    $published = $ip;
    $main::me->{hostname} = $ip if $main::me;
    if ($main::routeroot && $main::me) {
        # Reannounce the changed address on the existing periodic PC92 path.
        $main::me->{next_pc92_update} = $main::systime || time;
        $main::me->{next_pc92_keepalive} = $main::systime || time;
    }
    if ($ip =~ /:/) { $main::localhost_alias_ipv6 = $ip }
    else { $main::localhost_alias_ipv4 = $ip }
    # Local Route::User entries were created with the old advertised IP.
    # Update only records belonging to an actual locally connected user.
    if ($main::routeroot) {
        eval {
            require DXChannel;
            require Route::User;
            for my $route (Route::User::get_all()) {
                my $chan = DXChannel::get($route->call) or next;
                next if $chan->is_node;
                my $real = $chan->hostname || '';
                next unless $real eq 'localhost' || _prefix_match($real, '127.0.0.0', 8)
                    || _prefix_match($real, '::1', 128) || _alias_configured($real)
                    || _is_local_network_address($real);
                $route->ip($ip);
            }
        };
    }
    return 1;
}

# Asynchronous sequential fallbacks: no curl, no disabled TLS verification.
# A failed refresh leaves the last known valid public address unchanged.
sub refresh {
    my ($done) = @_;
    return 0 if $refreshing;
    $refreshing = 1;
    discover_networks();
    require Mojo::UserAgent;
    my @urls = (
        'https://api.ipify.org',
        'https://ipv4.icanhazip.com',
        'https://api64.ipify.org',
        'https://icanhazip.com',
    );
    my $ua = Mojo::UserAgent->new;
    $ua->request_timeout(3)->connect_timeout(2)->max_redirects(0);
    my $try;
    $try = sub {
        my $url = shift @urls;
        unless ($url) {
            $refreshing = 0;
            $done->(undef, 0) if $done;
            return;
        }
        $ua->get($url => sub {
            my ($ua, $tx) = @_;
            my $res = eval { $tx->result };
            my $ip = $res && $res->is_success ? $res->body : '';
            $ip =~ s/^\s+|\s+$//g;
            if (length($ip) <= 45 && DXUtil::is_public_ip($ip)) {
                my $changed = _apply($ip);
                $refreshing = 0;
                $done->($ip, $changed) if $done;
            } else { $try->() }
        });
    };
    $try->();
    return 1;
}

# Startup discovery is synchronous and bounded by the individual HTTPS timeouts.
# It runs before listeners and routing are started, never from the live IOLoop.
# The configured public address is retained if all providers fail.
sub init_startup {
    discover_networks();
    my $configured = $main::me ? $main::me->{hostname} : undef;
    _apply($configured) if DXUtil::is_public_ip($configured);
    require Mojo::UserAgent;
    my $ua = Mojo::UserAgent->new;
    $ua->request_timeout(3)->connect_timeout(2)->max_redirects(0);
    for my $url (
        'https://api.ipify.org',
        'https://ipv4.icanhazip.com',
        'https://api64.ipify.org',
        'https://icanhazip.com',
    ) {
        my $tx = eval { $ua->get($url) };
        my $res = $tx ? eval { $tx->result } : undef;
        my $ip = $res && $res->is_success ? $res->body : '';
        $ip =~ s/^\s+|\s+$//g;
        next unless length($ip) <= 45 && DXUtil::is_public_ip($ip);
        my $changed = _apply($ip);
        require DXLog;
        DXLog::LogDbg('Public IP startup discovery: ' . $ip . ($changed ? ' (changed)' : ' (unchanged)'));
        return $ip;
    }
    require DXLog;
    DXLog::LogDbg('Public IP startup discovery failed; retaining configured public address');
    return $published;
}

sub init {
    discover_networks();
    my $configured = $main::me ? $main::me->{hostname} : undef;
    _apply($configured) if DXUtil::is_public_ip($configured);
    require Mojo::IOLoop;
    Mojo::IOLoop->next_tick(sub {
        refresh(sub {
            my ($ip, $changed) = @_;
            require DXLog;
            DXLog::LogDbg(defined($ip)
                ? 'Public IP discovery: ' . $ip . ($changed ? ' (changed)' : ' (unchanged)')
                : 'Public IP discovery failed; retaining configured/last valid address');
        });
    });
}

1;
