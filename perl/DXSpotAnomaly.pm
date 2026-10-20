package DXSpotAnomaly;
use strict;
use warnings;
use Fcntl qw(:DEFAULT);
use DXUtil;
use Route::Node;

my %ips;
my $last_gc = 0;
my $last_status = 0;
my %stats = (observed => 0, valid => 0, alerts => 0, errors => 0);
our $window = 300;

sub data_dir {
    my $dir = $main::local_data;
    return unless defined $dir && $dir =~ m{^/} && -d $dir;
    return $dir;
}

# Write at most once every 10 seconds, only when an original PC61 survives
# the existing input filters and Spot::dup_find. No per-spot disk log.
sub status {
    my ($dir, $now) = @_;
    return if $now - $last_status < 10;
    $last_status = $now;
    my $path = "$dir/pc61_anomaly.status";
    my $tmp = "$path.$$";
    if (open my $fh, '>', $tmp) {
        print {$fh} join("\t", $now, @stats{qw(observed valid alerts errors)}), "\n";
        if (close $fh) { rename($tmp, $path) or unlink $tmp }
        else { unlink $tmp }
    }
}

# Only decimal SSIDs 1..99 collapse to their base call.
sub callbase {
    my ($call) = @_;
    return $1 if $call =~ /^(.*)-([1-9][0-9]?)$/ && length($1);
    return $call;
}

sub observe {
    my $dir = data_dir();
    return unless defined $dir && -f "$dir/pc61_anomaly.enabled";
    my $now = time;
    ++$stats{observed};
    my ($spotter, $ip, $node, $peer) = @_;
    unless (defined $spotter && defined $ip && defined $node &&
            $spotter =~ /^[A-Z0-9\/-]{2,24}$/ &&
            $node =~ /^[A-Z0-9\/-]{2,24}$/ &&
            $ip =~ /^[0-9a-fA-F:.]{3,45}$/) {
        status($dir, $now);
        return;
    }
    ++$stats{valid};
    if ($now - $last_gc >= 60) {
        for my $addr (keys %ips) {
            my $state = $ips{$addr};
            delete $state->{calls}{$_} for grep { $state->{calls}{$_}{last} < $now - $window } keys %{$state->{calls}};
            delete $ips{$addr} unless keys %{$state->{calls}};
        }
        $last_gc = $now;
    }
    my $state = ($ips{$ip} ||= { calls => {}, last_alert => 0 });
    # Expire this IP on every observation, not only during periodic global GC.
    delete $state->{calls}{$_} for grep {
        $state->{calls}{$_}{last} < $now - $window
    } keys %{$state->{calls}};
    my $base = callbase($spotter);
    my $is_new = !grep { callbase($_) eq $base } keys %{$state->{calls}};
    $state->{calls}{$spotter} = { last => $now, node => $node, peer => ($peer // '-') };
    my %bases = map { callbase($_) => 1 } keys %{$state->{calls}};
    my $n = scalar keys %bases;
    my $route = Route::Node::get($node);
    my $routing_known = $route && $route->last_PC92C && $route->users;
    my $absent = $routing_known && !$route->is_user($spotter);
    my @reason;
    push @reason, "SHARED_IP:$n" if $n >= 2 && ($is_new || $now - $state->{last_alert} >= 60);
    push @reason, 'USER_NOT_ON_NODE' if $absent && ($is_new || $now - $state->{last_alert} >= 60);
    if (@reason) {
        $state->{last_alert} = $now;
        $peer //= '-';
        $peer =~ s/[^A-Za-z0-9\/-]/_/g;
        # Extended TSV: preserve first six columns for older consumers.
        # Every contributing original PC61 spotter is explicitly identified.
        my @members = map {
            my $c = $_;
            my $v = $state->{calls}{$c};
            join(':', 'SPOTTER', $c, callbase($c), $v->{node}, $v->{peer})
        } sort keys %{$state->{calls}};
        my $record = join("\t", $now, $spotter, $ip, $node, $peer,
                          join(',', @reason), join(';', @members)) . "\n";
        my $out = "$dir/pc61_anomaly.events";
        sysopen(my $fh, $out, O_WRONLY|O_APPEND|O_CREAT, 0640)
            or die "PC61 anomaly open $out: $!";
        print {$fh} $record or die "PC61 anomaly write $out: $!";
        close $fh or die "PC61 anomaly close $out: $!";
        ++$stats{alerts};
    }
    status($dir, $now);
}
1;
