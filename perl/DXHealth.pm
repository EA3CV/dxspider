#
# DXHealth - bounded in-memory DXSpider health/telemetry counters
#
# Central home for bounded RAM-only health/telemetry that DXSpider does not already expose.
# Reuse existing DXSpider getters where they exist; do not duplicate them here.
# No timers, no I/O, no persistence, no protocol generation. Counters reset with the process.
#
package DXHealth;

use strict;

our $VERSION = '0.1';
our @SORTS = qw(A D C K);
our %VALID = map { $_ => 1 } @SORTS;
our %logical;
our %physical;

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
    return 1;
}

1;
