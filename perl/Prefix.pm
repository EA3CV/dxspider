#
# prefix handling
#
# Copyright (c) - Dirk Koopman G1TLH
#

package Prefix;

use IO::File;
use DXVars;
use Data::Dumper;
use DXDebug;
use DXUtil;
use USDB;
use LRU;
use DXBearing;

use strict;

use vars qw($db %prefix_loc %pre $lru $lrusize $misses $hits $matchtotal);

$db = undef;                    # compatibility truth value: prefix data loaded
%prefix_loc = ();               # the meat of the info
%pre = ();                      # active prefix -> arrayref of Prefix objects
$hits = $misses = $matchtotal = 1;
$lrusize = 5000;

my @pre_keys;                   # sorted keys for get()/next() compatibility
my $cursor_index = -1;

sub init
{
    my $r = load();
    return $r if $r;

    unless (@main::my_cc) {
        push @main::my_cc, (61..67) if $main::mycall =~ /^GB/;
        push @main::my_cc, qw(EA EA6 EA8 EA9) if $main::mycall =~ /^E[ABCD]/;
        push @main::my_cc, qw(I IT IS) if $main::mycall =~ /^I/;
        push @main::my_cc, qw(SV SV5 SV9) if $main::mycall =~ /^SV/;
        push @main::my_cc, $main::mycall unless @main::my_cc;
    }
    my @c;
    for (@main::my_cc) {
        if (/^\d+$/) {
            push @c, $_;
        } else {
            my @dxcc = extract($_);
            push @c, $dxcc[1]->dxcc if @dxcc > 1;
        }
    }
    return "\@main::my_cc does not contain a valid prefix or callsign (" . join(',', @main::my_cc) . ")" unless @c;
    @main::my_cc = @c;
    return undef;
}

sub _load_candidate
{
    my $fn = localdata("prefix_data.pl");
    die "Prefix.pm: cannot find $fn, have you run /spider/perl/create_prefix.pl?" unless -e $fn;

    my (%raw_pre, %raw_loc);
    my $ok;
    my $err = '';
    {
        local *pre = \%raw_pre;
        local *prefix_loc = \%raw_loc;
        $ok = eval { do $fn };
        $err = $@ if $@;
        $err ||= $! unless defined $ok;
    }
    return (undef, undef, undef, "Prefix.pm: cannot load $fn: $err") unless $ok;
    return (undef, undef, undef, "Prefix.pm: $fn contains no prefix keys") unless keys %raw_pre;
    return (undef, undef, undef, "Prefix.pm: $fn contains no location records") unless keys %raw_loc;

    my %candidate;
    for my $key (keys %raw_pre) {
        my @ids = split ',', $raw_pre{$key};
        return (undef, undef, undef, "Prefix.pm: empty location list for '$key'") unless @ids;
        my @refs;
        for my $id (@ids) {
            return (undef, undef, undef, "Prefix.pm: prefix '$key' references missing location '$id'")
                unless exists $raw_loc{$id} && ref $raw_loc{$id} eq 'Prefix';
            push @refs, $raw_loc{$id};
        }
        $candidate{$key} = \@refs;
    }

    my @keys = sort keys %candidate;
    return (\%raw_pre, \%raw_loc, [\%candidate, \@keys], undef);
}

sub load
{
    my ($raw_pre, $raw_loc, $compiled, $err) = _load_candidate();
    return $err if $err;

    my ($candidate, $keys) = @$compiled;
    my $new_lru = LRU->newbase('Prefix', $lrusize);

    # The old data remains active until the new dataset has been fully loaded,
    # compiled and validated. The swap itself happens only after that point.
    my $old_lru = $lru;
    %pre = %$candidate;
    %prefix_loc = %$raw_loc;
    @pre_keys = @$keys;
    $cursor_index = -1;
    $lru = $new_lru;
    $db = 1;

    $old_lru->close if $old_lru;
    return undef;
}

sub loaded
{
    return $db;
}

sub _lower_bound
{
    my $key = shift;
    my ($lo, $hi) = (0, scalar @pre_keys);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if ($pre_keys[$mid] lt $key) {
            $lo = $mid + 1;
        } else {
            $hi = $mid;
        }
    }
    return $lo;
}

sub exact_get
{
    my $key = shift;
    my $refs = $pre{$key};
    return () unless $refs;
    return ($key, @$refs);
}

# Preserve the DB_BTREE R_CURSOR semantics used by the historical API:
# return the first key >= the requested key, but only if it starts with it.
sub get
{
    my $key = shift;
    return () unless @pre_keys;
    my $i = _lower_bound($key);
    $cursor_index = $i;
    return () if $i >= @pre_keys;
    my $gotkey = $pre_keys[$i];
    return () if $key ne substr $gotkey, 0, length $key;
    my $refs = $pre{$gotkey};
    return ($gotkey, @$refs);
}

sub next
{
    my $key = shift;
    return () if $cursor_index < 0;
    ++$cursor_index;
    return () if $cursor_index >= @pre_keys;
    my $gotkey = $pre_keys[$cursor_index];
    return () if $key ne substr $gotkey, 0, length $key;
    my $refs = $pre{$gotkey};
    return ($gotkey, @$refs);
}

sub lru_put
{
    my ($call, $ref) = @_;
    $call =~ s/^=//;
    my @s = USDB::get($call);

    if (@s) {
        # This is a reference to static prefix data and must be copied before
        # adding mutable USDB city/state information.
        my $h = { %{$ref->[1]} };
        bless $h, ref $ref->[1];
        $h->{city} = $s[0];
        $h->{state} = $s[1];
        $ref->[1] = $h;
    } else {
        $ref->[1]->{city} = $ref->[1]->{state} = "" unless exists $ref->[1]->{state};
    }

    dbg("Prefix::lru_put $call -> ($ref->[1]->{city}, $ref->[1]->{state})") if isdbg('prefix');
    $lru->put($call, $ref);
}

sub matchprefix
{
    my $pref = shift;
    my @partials;
    for (my $i = length $pref; $i; $i--) {
        $matchtotal++;
        my $s = substr($pref, 0, $i);
        push @partials, $s;
        my $p = $lru->get($s);
        if ($p) {
            $hits++;
            if (isdbg('prefix')) {
                my $percent = sprintf "%.1f", $hits * 100 / $misses;
                dbg("Partial Prefix Cache Hit: $s Hits: $hits/$misses of $matchtotal = $percent\%");
            }
            lru_put($_, $p) for @partials;
            return @$p;
        } else {
            $misses++;
            my @out = exact_get($s);
            if (isdbg('prefix')) {
                my $part = $out[0] || "*";
                $part .= '*' unless $part eq '*' || $part eq $s;
                dbg("Partial prefix: $pref $s $part" );
            }
            if (@out) {
                return @out;
            }
        }
    }
    return ();
}

sub extract
{
    my $calls = uc shift;
    my @out;
    my $p;
    my @parts;
    my ($call, $sp, $i);

LM: foreach $call (split /,/, $calls) {
        $matchtotal++;
        $call =~ s/-\d+$//;
        my @nout;
        my $ecall = "=$call";

        my $p = $lru->get($ecall);
        if ($p) {
            $hits++;
            if (isdbg('prefix')) {
                my $percent = sprintf "%.1f", $hits * 100 / $misses;
                dbg("Prefix Exact Cache Hit: $call Hits: $hits/$misses of $matchtotal = $percent\%");
            }
            push @out, @$p;
            next;
        }

        $p = $lru->get($call);
        if ($p) {
            $hits++;
            if (isdbg('prefix')) {
                my $percent = sprintf "%.1f", $hits * 100 / $misses;
                dbg("Prefix Cache Hit: $call Hits: $hits/$misses of $matchtotal = $percent\%");
            }
            push @out, @$p;
            next;
        }

        my @s = USDB::get($call);
        if (@s) {
            # Keep the historical lower-bound lookup here. Unlike the other
            # exact probes in extract(), this branch accepted a longer key
            # beginning with the complete US callsign.
            @nout = get($call);
            @nout = matchprefix($call) unless @nout;
            $nout[0] = $ecall if @nout;
        } else {
            @nout = exact_get($ecall);
        }

        if (@nout && $nout[0] eq $ecall) {
            $misses++;
            $nout[0] = $call;
            lru_put("=$call", \@nout);
            dbg("got exact prefix: $nout[0]") if isdbg('prefix');
            push @out, @nout;
            next;
        }

        if ((@nout = exact_get($call))) {
            $misses++;
            lru_put($call, \@nout);
            dbg("got exact prefix: $nout[0]") if isdbg('prefix');
            push @out, @nout;
            next;
        }

        @parts = ($call =~ '/') ? split('/', $call) : ($call);
        dbg("Parts: $call = " . join(' ', @parts)) if isdbg('prefix');

        if (@parts > 1) {
            pop @parts if $parts[-1] =~ /^(?:[PABM]|AM|MM|BCN|JOTA|SIX|WEB|NET|Q\w+|0)$/;
            my $s = join('/', @parts);
            @nout = exact_get($s);
            if (@nout) {
                dbg("got exact multipart prefix: $call $s") if isdbg('prefix');
                $misses++;
                lru_put($call, \@nout);
                push @out, @nout;
                next;
            }
        }
        dbg("Parts now: $call = " . join(' ', @parts)) if isdbg('prefix');

        if (@parts == 3 && length $parts[0] <= length $parts[1]) {
            @nout = matchprefix($parts[0]);
            if (@nout) {
                my $s = join('/', $nout[0], $parts[2]);
                my @try = exact_get($s);
                if (@try) {
                    dbg("got 3 part prefix: $call $s") if isdbg('prefix');
                    $misses++;
                    lru_put($call, \@try);
                    push @out, @try;
                    next;
                }
                if (is_callsign($parts[1]) && length $parts[2] == 1) {
                    pop @parts;
                }
            }
        }

        if (@parts == 2) {
            @nout = matchprefix($parts[0]);
            if (@nout) {
                my $s = join('/', $nout[0], $parts[1]);
                my @try = exact_get($s);
                if (@try) {
                    dbg("got 2 part prefix: $call $s") if isdbg('prefix');
                    $misses++;
                    lru_put($call, \@try);
                    push @out, @try;
                    next;
                }
            }
        }

        pop @parts if @parts > 1 && $parts[$#parts] eq 'J';

        if (@parts == 1) {
            @nout = matchprefix($parts[0]);
            if (@nout) {
                dbg("got prefix: $call = $nout[0]") if isdbg('prefix');
                $misses++;
                lru_put($call, \@nout);
                push @out, @nout;
                next;
            }
        }

        my @checked;
        my $n;
L1:     for ($n = 0; $n < @parts; $n++) {
            my $sp = '';
            my ($k, $i);
            for ($i = $k = 0; $i < @parts; $i++) {
                next if $checked[$i];
                my $p = $parts[$i];
                if (!$sp || length $p < length $sp) {
                    dbg("try part: $p") if isdbg('prefix');
                    $k = $i;
                    $sp = $p;
                }
            }
            $checked[$k] = 1;
            $sp =~ s/-\d+$//;
            @nout = matchprefix($sp);

            if (@nout) {
                if (@parts > 1) {
                    $parts[$k] = $nout[0];
                    my $try = join('/', @parts);
                    my @try = exact_get($try);
                    if (isdbg('prefix')) {
                        my $part = $try[0] || "*";
                        $part .= '*' unless $part eq '*' || $part eq $try;
                        dbg("Compound prefix: $try $part" );
                    }
                    if (@try) {
                        $misses++;
                        lru_put($call, \@try);
                        push @out, @try;
                    } else {
                        $misses++;
                        lru_put($call, \@nout);
                        push @out, @nout;
                    }
                } else {
                    $misses++;
                    lru_put($call, \@nout);
                    push @out, @nout;
                }
                next LM;
            }
        }

        @nout = matchprefix('QQ');
        $misses++;
        lru_put($call, \@nout);
        push @out, @nout;
    }

    if (isdbg('prefixdata')) {
        my $dd = new Data::Dumper([ \@out ], [qw(@out)]);
        dbg($dd->Dumpxs);
    }
    return @out;
}

sub to_ciz
{
    my $cmd = shift;
    my @out;

    foreach my $v (@_) {
        if ($cmd ne 'ns' && $v =~ /^\d+$/) {
            push @out, $v unless grep $_ eq $v, @out;
        } else {
            if ($cmd eq 'ns' && $v =~ /^[A-Z][A-Z]$/i) {
                push @out, uc $v unless grep $_ eq uc $v, @out;
            } else {
                my @pre = Prefix::extract($v);
                if (@pre) {
                    shift @pre;
                    foreach my $p (@pre) {
                        my $n = $p->dxcc if $cmd eq 'nc';
                        $n = $p->itu if $cmd eq 'ni';
                        $n = $p->cq if $cmd eq 'nz';
                        $n = $p->state if $cmd eq 'ns';
                        push @out, $n unless grep $_ eq $n, @out;
                    }
                }
            }
        }
    }
    return @out;
}

sub cty_data
{
    my $call = shift;
    my @dxcc = extract($call);
    if (@dxcc) {
        my $state = $dxcc[1]->state || '';
        my $city = $dxcc[1]->city || '';
        my $name = $dxcc[1]->name || '';
        return ($dxcc[1]->dxcc, $dxcc[1]->itu, $dxcc[1]->cq, $state, $city, $name);
    }
    return (666,0,0,'','','Pirate-Country-QQ');
}

my %valid = (
    city => '0,City',
    cont => '0,Continent',
    cq => '0,CQ',
    dxcc => '0,DXCC',
    itu => '0,ITU',
    lat => '0,Latitude,slat',
    long => '0,Longitude,slong',
    name => '0,Name',
    qra => '0,Locator',
    state => '0,State',
    utcoff => '0,UTC offset',
);

sub AUTOLOAD
{
    no strict;
    my $name = $AUTOLOAD;
    return if $name =~ /::DESTROY$/;
    $name =~ s/^.*:://o;
    confess "Non-existant field '$AUTOLOAD'" if !$valid{$name};
    *$AUTOLOAD = sub {@_ > 1 ? $_[0]->{$name} = $_[1] : $_[0]->{$name}};
    goto &$AUTOLOAD;
}

sub field_prompt
{
    my ($self, $ele) = @_;
    return $valid{$ele};
}

1;

__END__
