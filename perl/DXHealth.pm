#
# DXHealth - bounded in-memory DXSpider health/telemetry counters
#
# Central home for bounded RAM-only health/telemetry that DXSpider does not already expose.
# Reuse existing DXSpider getters where they exist; do not duplicate them here.
# No timers, no I/O, no persistence, no protocol generation. Counters reset with the process.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#
package DXHealth;

use strict;

our $VERSION = '0.7';
our @SORTS = qw(A D C K);
our %VALID = map { $_ => 1 } @SORTS;
our %logical;
our %physical;
our %pc92k_advertised;
our $MAX_PC92K_ADVERTISED = 1024;
our %protocol;
our %protocol_peer;
our $local_spots_generated = 0;
our %protocol_logical;
our %protocol_reject;
our %protocol_reject_peer;

# Protocol input diagnostics. These counters are deliberately limited to
# failures proven at the protocol boundary. Duplicates are NOT rejects here:
# a syntactically valid duplicate remains part of physical IN and is handled
# later by the normal DXSpider duplicate logic.
sub protocol_reject_unknown {
    my ($peer, $line) = @_;
    my $bytes = defined($line) && !ref($line) ? length($line) : 0;
    $protocol_reject{unknown_protocol}{packets}++;
    $protocol_reject{unknown_protocol}{bytes} += $bytes;
    if (defined $peer && length $peer) {
        $protocol_reject_peer{$peer}{unknown_protocol}{packets}++;
        $protocol_reject_peer{$peer}{unknown_protocol}{bytes} += $bytes;
    }
    return 1;
}

sub protocol_reject_malformed {
    my ($peer, $pc, $field, $line) = @_;
    return 0 unless defined $pc && $pc >= 10 && $pc <= 99;
    my $bytes = defined($line) && !ref($line) ? length($line) : 0;
    my $name = sprintf('PC%02d', $pc);
    $protocol_reject{malformed}{packets}++;
    $protocol_reject{malformed}{bytes} += $bytes;
    $protocol_reject{malformed}{by_pc}{$name}{packets}++;
    $protocol_reject{malformed}{by_pc}{$name}{bytes} += $bytes;
    $protocol_reject{malformed}{by_pc}{$name}{fields}{$field}++ if defined $field && $field =~ /^\d+$/;
    if (defined $peer && length $peer) {
        $protocol_reject_peer{$peer}{malformed}{packets}++;
        $protocol_reject_peer{$peer}{malformed}{bytes} += $bytes;
        $protocol_reject_peer{$peer}{malformed}{by_pc}{$name}{packets}++;
        $protocol_reject_peer{$peer}{malformed}{by_pc}{$name}{bytes} += $bytes;
    }
    return 1;
}



# Connection telemetry: bounded RAM-only event counters.  Live online state is
# deliberately NOT duplicated here; DXSupervisor joins these counters with the
# authoritative DXChannel snapshot.
our %connections;
our %connection_totals = (connects => 0, disconnects => 0, too_many => 0);
our $CONNECTION_RETENTION = 48 * 3600;   # enough for the 24 h UI window
our $MAX_CONNECTIONS_TRACKED = 4096;

sub _connection_host {
    my ($c) = @_;
    return '' unless ref $c;
    return $c->{hostname} if defined $c->{hostname} && length $c->{hostname};
    my $conn = $c->{conn};
    return ($conn->{peerhost} || '') if ref $conn;
    return '';
}

sub _connection_direction {
    my ($c) = @_;
    return '' unless ref $c;
    return $c->{outbound} ? 'out' : 'in' if defined $c->{outbound};
    return '';
}

sub _connection_touch {
    my ($call) = @_;
    return unless defined $call && length $call;
    $call = uc $call;
    $connections{$call} ||= { call => $call };
    return $connections{$call};
}

sub _connection_kind {
    my ($c, $kind) = @_;
    return $kind if defined $kind && length $kind;
    return '' unless ref $c;
    my $s = $c->{sort} || '';
    return 'rbn'  if $s eq 'N';
    return 'web'  if $s eq 'W';
    return 'user' if $s eq 'U';
    return 'node' if $s =~ /^[ACRSXL]$/;
    return 'other';
}

sub connection_up {
    my ($c, $kind) = @_;
    return 0 unless ref $c && defined $c->{call} && length $c->{call};
    my $e = _connection_touch($c->{call}) or return 0;
    my $now = time();
    my $first = !$c->{_dxhealth_connection_up};
    if ($first) {
        $c->{_dxhealth_connection_up} = 1;
        $e->{connect_count} = 0 + ($e->{connect_count} || 0) + 1;
        $e->{last_connect} = $now;
        $e->{last_event} = $now;
        $connection_totals{connects}++;
    }
    $e->{last_host} = _connection_host($c) if length _connection_host($c);
    $e->{last_direction} = _connection_direction($c) if length _connection_direction($c);
    $e->{last_kind} = _connection_kind($c, $kind);
    return 1;
}

sub connection_down {
    my ($c, $kind) = @_;
    return 0 unless ref $c && defined $c->{call} && length $c->{call};
    return 1 if $c->{_dxhealth_connection_down};
    $c->{_dxhealth_connection_down} = 1;
    my $e = _connection_touch($c->{call}) or return 0;
    my $now = time();
    $e->{disconnect_count} = 0 + ($e->{disconnect_count} || 0) + 1;
    $e->{last_disconnect} = $now;
    $e->{last_event} = $now;
    $e->{last_host} = _connection_host($c) if length _connection_host($c);
    $e->{last_direction} = _connection_direction($c) if length _connection_direction($c);
    $e->{last_kind} = _connection_kind($c, $kind) || $e->{last_kind} || '';
    $connection_totals{disconnects}++;
    return 1;
}

sub connection_too_many {
    my ($call, $host, $limit, $parents) = @_;
    my $e = _connection_touch($call) or return 0;
    my $now = time();
    $e->{too_many_count} = 0 + ($e->{too_many_count} || 0) + 1;
    $e->{last_too_many} = $now;
    $e->{last_event} = $now;
    $e->{last_host} = $host if defined $host && length $host;
    $e->{last_too_many_limit} = 0 + $limit if defined $limit && $limit =~ /^\d+$/;
    $e->{last_too_many_parents} = 0 + $parents if defined $parents && $parents =~ /^\d+$/;
    $connection_totals{too_many}++;
    return 1;
}

sub _connection_prune {
    my ($online) = @_;
    $online ||= {};
    my $cut = time() - $CONNECTION_RETENTION;
    for my $call (keys %connections) {
        next if $online->{$call};
        my $t = $connections{$call}{last_event} || 0;
        delete $connections{$call} if $t && $t < $cut;
    }
    if (keys(%connections) > $MAX_CONNECTIONS_TRACKED) {
        my @old = sort { ($connections{$a}{last_event}||0) <=> ($connections{$b}{last_event}||0) }
                  grep { !$online->{$_} } keys %connections;
        while (keys(%connections) > $MAX_CONNECTIONS_TRACKED && @old) {
            delete $connections{shift @old};
        }
    }
}

sub connection_snapshot {
    my ($online) = @_;
    $online ||= {};
    _connection_prune($online);
    my %rows;
    for my $call (keys %connections) {
        my $e = $connections{$call};
        $rows{$call} = {
            call => $call,
            connect_count => 0 + ($e->{connect_count} || 0),
            disconnect_count => 0 + ($e->{disconnect_count} || 0),
            last_connect => 0 + ($e->{last_connect} || 0),
            last_disconnect => 0 + ($e->{last_disconnect} || 0),
            last_event => 0 + ($e->{last_event} || 0),
            last_host => $e->{last_host} || '',
            last_direction => $e->{last_direction} || '',
            last_kind => $e->{last_kind} || '',
            too_many_count => 0 + ($e->{too_many_count} || 0),
            last_too_many => 0 + ($e->{last_too_many} || 0),
            last_too_many_limit => defined $e->{last_too_many_limit} ? 0 + $e->{last_too_many_limit} : undef,
            last_too_many_parents => defined $e->{last_too_many_parents} ? 0 + $e->{last_too_many_parents} : undef,
        };
    }
    return {
        totals => { map { $_ => 0 + ($connection_totals{$_} || 0) } qw(connects disconnects too_many) },
        retained => scalar(keys %rows),
        retention_seconds => 0 + $CONNECTION_RETENTION,
        max_entries => 0 + $MAX_CONNECTIONS_TRACKED,
        rows => \%rows,
    };
}
# Logical semantics are deliberately opt-in. Missing kinds mean unsupported,
# not zero. Forwarded is enabled only where the routing/distribution path can
# report that at least one real protocol egress survived filters and hop checks.
our %PROTOCOL_LOGICAL_CAPS = (
    11 => { accepted => 1, forwarded => 1 },
    23 => { accepted => 1, forwarded => 1 },
    24 => { accepted => 1, forwarded => 1 },
    51 => { accepted => 1, forwarded => 1, reply => 1 },
    61 => { accepted => 1, generated => 1, forwarded => 1 },
    73 => { accepted => 1, forwarded => 1 },
    93 => { accepted => 1, generated => 1 },
);


# Generic physical PCxx telemetry.  This deliberately records only facts at
# the protocol boundary: a valid PC frame came IN from a neighbour or a PC
# frame was queued OUT to a neighbour.  Logical generated/accepted/forwarded
# counters are kept separate because their semantics differ by protocol.
sub _pc_from_line {
    my ($line) = @_;
    return unless defined $line && !ref($line) && $line =~ /^PC(\d\d)\^/;
    my $pc = 0 + $1;
    return unless $pc >= 10 && $pc <= 99;
    return $pc;
}

sub _protocol_inc {
    my ($dir, $peer, $pc, $bytes) = @_;
    return 0 unless $dir eq 'in' || $dir eq 'out';
    return 0 unless defined $pc && $pc >= 10 && $pc <= 99;
    $bytes = 0 unless defined $bytes && $bytes >= 0;
    $protocol{$pc}{$dir}{packets}++;
    $protocol{$pc}{$dir}{bytes} += $bytes;
    if (defined $peer && length $peer) {
        $protocol_peer{$peer}{$pc}{$dir}{packets}++;
        $protocol_peer{$peer}{$pc}{$dir}{bytes} += $bytes;
    }
    return 1;
}

sub protocol_physical_in_line {
    my ($peer, $line) = @_;
    my $pc = _pc_from_line($line);
    return 0 unless defined $pc;
    return _protocol_inc('in', $peer, $pc, length($line));
}

sub protocol_physical_out_line {
    my ($peer, $line) = @_;
    my $pc = _pc_from_line($line);
    return 0 unless defined $pc;
    return _protocol_inc('out', $peer, $pc, length($line));
}

sub local_spot_generated {
    $local_spots_generated++;
    return 1;
}

sub protocol_logical_inc {
    my ($pc, $kind, $bytes) = @_;
    return 0 unless defined $pc && $pc >= 10 && $pc <= 99;
    return 0 unless defined $kind && $PROTOCOL_LOGICAL_CAPS{$pc}{$kind};
    $bytes = 0 unless defined $bytes && $bytes >= 0;
    $protocol_logical{$pc}{$kind}{packets}++;
    $protocol_logical{$pc}{$kind}{bytes} += $bytes;
    return 1;
}

sub protocol_logical_line {
    my ($kind, $line) = @_;
    my $pc = _pc_from_line($line);
    return 0 unless defined $pc;
    return protocol_logical_inc($pc, $kind, length($line));
}

sub protocol_snapshot {
    my %out = (protocols => {}, peers => {}, logical => {}, capabilities => {}, local_spots_generated => 0 + $local_spots_generated);
    for my $pc (sort {$a <=> $b} keys %protocol) {
        my $name = sprintf('PC%02d', $pc);
        for my $dir (qw(in out)) {
            $out{protocols}{$name}{$dir} = {
                packets => 0 + ($protocol{$pc}{$dir}{packets} || 0),
                bytes   => 0 + ($protocol{$pc}{$dir}{bytes} || 0),
            };
        }
    }
    for my $peer (sort keys %protocol_peer) {
        for my $pc (sort {$a <=> $b} keys %{$protocol_peer{$peer}}) {
            my $name = sprintf('PC%02d', $pc);
            for my $dir (qw(in out)) {
                $out{peers}{$peer}{$name}{$dir} = {
                    packets => 0 + ($protocol_peer{$peer}{$pc}{$dir}{packets} || 0),
                    bytes   => 0 + ($protocol_peer{$peer}{$pc}{$dir}{bytes} || 0),
                };
            }
        }
    }
    for my $pc (sort {$a <=> $b} keys %PROTOCOL_LOGICAL_CAPS) {
        my $name = sprintf('PC%02d', $pc);
        for my $kind (qw(generated accepted forwarded reply)) {
            next unless $PROTOCOL_LOGICAL_CAPS{$pc}{$kind};
            $out{capabilities}{$name}{$kind} = 1;
            $out{logical}{$name}{$kind} = {
                packets => 0 + ($protocol_logical{$pc}{$kind}{packets} || 0),
                bytes   => 0 + ($protocol_logical{$pc}{$kind}{bytes} || 0),
            };
        }
    }
    $out{input_diagnostics} = {
        malformed => {
            packets => 0 + ($protocol_reject{malformed}{packets} || 0),
            bytes => 0 + ($protocol_reject{malformed}{bytes} || 0),
            by_pc => $protocol_reject{malformed}{by_pc} || {},
        },
        unknown_protocol => {
            packets => 0 + ($protocol_reject{unknown_protocol}{packets} || 0),
            bytes => 0 + ($protocol_reject{unknown_protocol}{bytes} || 0),
        },
        peers => \%protocol_reject_peer,
    };
    return \%out;
}

sub _sort {
    my ($s) = @_;
    return undef unless defined $s;
    $s = uc $s;
    return $VALID{$s} ? $s : undef;
}

sub _line_sort {
    my ($line) = @_;
    return unless defined $line && !ref($line) && $line =~ /^PC92\^[^^]*\^[^^]*\^([ADCK])\^/;
    return $1;
}

sub _inc {
    my ($slot, $sort, $bytes) = @_;
    $$slot ||= {};
    $$slot->{$sort}{packets}++;
    $$slot->{$sort}{bytes} += ($bytes || 0);
}

sub pc92_generated {
    my ($sort, $bytes) = @_;
    $sort = _sort($sort) or return 0;
    _inc(\$logical{generated}, $sort, $bytes);
    return 1;
}

sub pc92_generated_line {
    my ($line) = @_;
    my $sort = _line_sort($line) or return 0;
    return pc92_generated($sort, length($line));
}

sub pc92_received {
    my ($sort, $bytes) = @_;
    $sort = _sort($sort) or return 0;
    _inc(\$logical{received}, $sort, $bytes);
    return 1;
}

sub pc92_forwarded {
    my ($sort, $bytes) = @_;
    $sort = _sort($sort) or return 0;
    _inc(\$logical{forwarded}, $sort, $bytes);
    return 1;
}

sub pc92_physical_in {
    my ($neighbour, $sort, $bytes) = @_;
    $sort = _sort($sort) or return 0;
    return 0 unless defined $neighbour && length $neighbour;
    _inc(\$physical{in}{$neighbour}, $sort, $bytes);
    return 1;
}

sub pc92_physical_out {
    my ($neighbour, $sort, $bytes) = @_;
    $sort = _sort($sort) or return 0;
    return 0 unless defined $neighbour && length $neighbour;
    _inc(\$physical{out}{$neighbour}, $sort, $bytes);
    return 1;
}

sub pc92_physical_out_line {
    my ($neighbour, $line) = @_;
    my $sort = _line_sort($line) or return 0;
    return pc92_physical_out($neighbour, $sort, length($line));
}

sub _copy_bucket {
    my ($src) = @_;
    my %out;
    for my $s (@SORTS) {
        $out{$s} = {
            packets => 0 + ($src->{$s}{packets} || 0),
            bytes   => 0 + ($src->{$s}{bytes} || 0),
        };
    }
    return \%out;
}


sub pc92k_advertised {
    my ($call, $nodes, $users) = @_;
    return 0 unless defined $call && length $call;
    return 0 unless defined $nodes && $nodes =~ /^\d+$/;
    return 0 unless defined $users && $users =~ /^\d+$/;

    $pc92k_advertised{$call} = {
        nodes => 0 + $nodes,
        users => 0 + $users,
        seen  => time(),
    };

    # Bounded RAM-only telemetry: if churn ever takes us over the cap, discard
    # the oldest K observations.  This never touches Route::Node or routing.
    if (keys(%pc92k_advertised) > $MAX_PC92K_ADVERTISED) {
        my @oldest = sort {
            ($pc92k_advertised{$a}{seen} || 0) <=> ($pc92k_advertised{$b}{seen} || 0)
        } keys %pc92k_advertised;
        my $drop = keys(%pc92k_advertised) - $MAX_PC92K_ADVERTISED;
        delete @pc92k_advertised{@oldest[0 .. $drop-1]} if $drop > 0;
    }
    return 1;
}

sub pc92k_advertised_get {
    my ($call) = @_;
    return unless defined $call && exists $pc92k_advertised{$call};
    my $v = $pc92k_advertised{$call};
    return {
        nodes => 0 + $v->{nodes},
        users => 0 + $v->{users},
        seen  => 0 + $v->{seen},
    };
}

sub pc92_snapshot {
    my %out = (logical => {}, physical => {in => {}, out => {}}, totals => {in => {}, out => {}});
    for my $kind (qw(generated received forwarded)) {
        $out{logical}{$kind} = _copy_bucket($logical{$kind} || {});
    }
    for my $dir (qw(in out)) {
        for my $n (sort keys %{$physical{$dir} || {}}) {
            $out{physical}{$dir}{$n} = _copy_bucket($physical{$dir}{$n});
        }
        $out{totals}{$dir} = _copy_bucket({});
        for my $n (keys %{$physical{$dir} || {}}) {
            for my $s (@SORTS) {
                $out{totals}{$dir}{$s}{packets} += $physical{$dir}{$n}{$s}{packets} || 0;
                $out{totals}{$dir}{$s}{bytes}   += $physical{$dir}{$n}{$s}{bytes} || 0;
            }
        }
    }
    return \%out;
}

sub pc92_reset {
    %logical = ();
    %physical = ();
    %pc92k_advertised = ();
    return 1;
}

1;
