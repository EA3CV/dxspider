#!/usr/bin/perl
#
# show moonrise and moonset times for each callsign or prefix entered
#
# 1999/11/9 Steve Franke K9AN
# 2000/10/27 fixed bug involving degree to radian conversion.
# 2001/09/15 accept prefix/call and number of days from today (+ or -).
#
# 2026/08/21
#   - always display a date for both Moon rise and Moon set
#   - display the next Moon set chronologically following the displayed rise
#   - optional "local" argument uses Prefix::utcoff(), matching show/time
#

use Time::Local qw(timegm);

my ($self, $line) = @_;
my @l = split /\s+/, $line;
my @f;

my @out;
my $f;
my $l;
my $n_offset;
my @list;
my $want_local = 0;
my ($rise, $set, $az, $dec, $loss, $ifrac);

@f = map {
    if (/^local$/i) {
        $want_local = 1;
        ();
    } else {
        $_
    }
} @l;

while ($f = shift @f) {
    if (!defined $n_offset) {
        ($n_offset) = $f =~ /^([-+]?\d+)$/;
        next if defined $n_offset;
    }
    push @list, $f;
}

$n_offset = 0 unless defined $n_offset;
$n_offset = 0 if $n_offset > 365;
$n_offset = 0 if $n_offset < -365;

my ($lat, $lon);
my $base_epoch = $main::systime + $n_offset * 24 * 60 * 60;
my ($sec, $min, $hr, $day, $month0, $yr0) = (gmtime($base_epoch))[0,1,2,3,4,5];
my $month = $month0 + 1;
my $yr = $yr0 + 1900;

sub _moon_prefix_offset
{
    my $call = shift;
    return 0 unless defined $call && length $call;

    my @ans = Prefix::extract($call);
    return 0 unless @ans;

    shift @ans;
    my $a = shift @ans;
    return 0 unless $a;

    my $off = $a->utcoff();
    return 0 unless defined $off;

    my $frac = $off - int $off;
    $off = (int $off) + (($frac * 100) / 60);
    return $off;
}

sub _moon_event_epoch
{
    my ($epoch_midnight, $time) = @_;
    return undef unless defined $time;
    return undef unless $time =~ /^(\d{2}):(\d{2})Z$/;

    return $epoch_midnight + $1 * 3600 + $2 * 60;
}

sub _moon_format_event
{
    my ($epoch, $time, $local, $off) = @_;

    return $time unless defined $epoch;

    my $display_epoch = $epoch;
    my $suffix = 'Z';

    if ($local) {
        $display_epoch -= 3600 * $off;
        $suffix = 'L';
    }

    my ($s, $m, $h, $d, $mo, $y) = gmtime($display_epoch);
    return sprintf("%02d/%02d/%04d %02d:%02d%s",
                   $d, $mo + 1, $y + 1900, $h, $m, $suffix);
}

my @in;
if (@list) {
    foreach $l (@list) {
        my $user = DXUser::get_current(uc $l);
        if ($user && $user->lat && $user->long) {
            push @in, [
                $user->qth,
                $user->lat,
                -$user->long,
                uc $l,
                _moon_prefix_offset(uc $l),
            ];
        } else {
            my @ans = Prefix::extract($l);
            next if !@ans;
            my $pre = shift @ans;
            my $a;
            foreach $a (@ans) {
                $lat = $a->{lat};
                $lon = -$a->{long};

                my $off = $a->utcoff();
                if (defined $off) {
                    my $frac = $off - int $off;
                    $off = (int $off) + (($frac * 100) / 60);
                } else {
                    $off = 0;
                }

                push @in, [ $a->name, $lat, $lon, $pre, $off ];
            }
        }
    }
} else {
    if ($self->user->lat && $self->user->long) {
        push @in, [
            $self->user->qth,
            $self->user->lat,
            -$self->user->long,
            $self->call,
            _moon_prefix_offset($self->call),
        ];
    } else {
        push @in, [
            $main::myqth,
            $main::mylatitude,
            -$main::mylongitude,
            $main::mycall,
            _moon_prefix_offset($main::mycall),
        ];
    }
}

if (!$n_offset) {
    push @out, $want_local
        ? "Call   QTH                            Moonrise (local)        Moonset (local)           Az     El"
        : "Call   QTH                            Moonrise (UTC)          Moonset (UTC)             Az     El";
} else {
    push @out, $want_local
        ? "Call   QTH                            Moonrise (local)        Moonset (local)"
        : "Call   QTH                            Moonrise (UTC)          Moonset (UTC)";
}

foreach $l (@in) {
    ($rise, $set, $az, $dec, $loss, $ifrac) =
        Sun::rise_set($yr, $month, $day, $hr, $min, $l->[1], $l->[2], 1);

    my $midnight = timegm(0, 0, 0, $day, $month - 1, $yr);
    my $rise_epoch = _moon_event_epoch($midnight, $rise);
    my $set_epoch  = _moon_event_epoch($midnight, $set);

    if (defined $rise_epoch && defined $set_epoch && $set_epoch <= $rise_epoch) {
        my $next_midnight = $midnight + 86400;
        my ($ns, $nm, $nh, $nd, $nmon0, $ny0) = (gmtime($next_midnight))[0,1,2,3,4,5];
        my $nmon = $nmon0 + 1;
        my $ny = $ny0 + 1900;

        my ($next_rise, $next_set) =
            Sun::rise_set($ny, $nmon, $nd, $nh, $nm, $l->[1], $l->[2], 1);

        my $next_set_epoch = _moon_event_epoch($next_midnight, $next_set);
        if (defined $next_set_epoch) {
            $set = $next_set;
            $set_epoch = $next_set_epoch;
        }
    }

    $l->[3] =~ s{(-\d+|/\w+)$}{};

    my $rise_display = _moon_format_event($rise_epoch, $rise, $want_local, $l->[4]);
    my $set_display  = _moon_format_event($set_epoch,  $set,  $want_local, $l->[4]);

    if (!$n_offset) {
        push @out, sprintf(
            "%-6.6s %-30.30s %-22s %-22s %6.1f %6.1f",
            $l->[3], $l->[0], $rise_display, $set_display, $az, $dec
        );
    } else {
        push @out, sprintf(
            "%-6.6s %-30.30s %-22s %-22s",
            $l->[3], $l->[0], $rise_display, $set_display
        );
    }
}

push @out, sprintf("Illuminated fraction of the Moon's disk is %4.2f", $ifrac)
    if defined $ifrac;

return (1, @out);
