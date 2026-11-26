#
# IP Address block list / checker
#
# This is a DXSpider compatible, optional skin over Net::CIDR::Lite
# A validated interval fallback preserves blocking if the optional engine fails.
#

package DXCIDR;

use strict;
use warnings;
use 5.16.1;
use DXVars;
use DXDebug;
use DXUtil;
use DXLog;
use IO::File;
use File::Copy;
use DXHash ();

use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);

our $active = 0;
our $badipfn = "badip";
my $ipv4;
my $ipv6;
my $count4 = 0;
my $count6 = 0;
my @blocked_intervals;
my %fallback;
my %fallback_index;
# Exact badip.vpn source, independent of the global badip union.
my %vpn_index;
my $engine_available;
# Temporary per-file parse results; never retained after _load returns.
our $reload_parse_cache;

sub _fn
{
	return "$main::local_data/$badipfn";
}

sub _read
{
    my $suffix = shift;
    my $fn = _fn();
    $fn .= ".$suffix" if defined($suffix) && length($suffix);
    my $entries;
    my $ok=eval { ($entries)=DXHash::_badlist_source($fn,'ip'); 1 };
    unless ($ok) { DXHash::_badlist_log("DXCIDR source skipped $fn: $@"); return (); }
    # Populate the existing cache for add() without evaluating file content.
    return @$entries;
}

sub _load
{
	return unless $active;
	my $suffix = shift;
	local $reload_parse_cache = {};
	my @in = _read($suffix);
	return 0 unless @in;
	my $count = add(@in);
    _vpn_build(@in) if defined($suffix) && $suffix eq 'vpn';
    return $count;
}

sub _put
{
	my $suffix = shift;
	my $fn = _fn() . ".$suffix";
	my $r = rand;
	my $fh = IO::File->new (">$fn.$r");
	my $count = 0;
	if ($fh) {
		for (list()) {
			$fh->print("$_\n");
			++$count;
		}
		move "$fn.$r", $fn;
		LogDbg('cmd', "DXCIDR: put (re-)written $fn");
	} else {
		LogDbg('err', "DXCIDR: cannot write $fn.$r $!");
	}
	return $count;
}

sub append
{
    return 0 unless $active;
    my $suffix = shift;
    my @in = @_;
    return 0 unless defined $suffix && $suffix =~ /^\w+$/ && @in;
    my $fn = _fn() . ".$suffix";
    my $fh = IO::File->new($fn, 'a') or do {
        LogDbg('err', "DXCIDR::append error appending to $fn $!");
        return 0;
    };
    my $ok = 1;
    for my $ip (@in) {
        $ok = 0 unless print {$fh} "$ip\n";
    }
    $ok = 0 unless $fh->close();
    return $ok ? scalar @in : 0;
}

# Some Net::CIDR::Lite builds warn in _pack_ipv6 when the optional IPv4
# tail is absent.  Scope the compatibility to calls into that library only.
# All other warnings (including unexpected library warnings) are preserved.
sub _ipv6_cidr_call
{
    my ($code) = @_;
    my $previous_warn = $SIG{__WARN__};
    local $SIG{__WARN__} = sub {
        my ($warning) = @_;
        return if $warning =~ /\A(?:substr outside of string|Use of uninitialized value in concatenation \(\.\) or string) at \S*Net\/CIDR\/Lite\.pm line \d+\.\n?\z/;
        if (ref($previous_warn) eq 'CODE') { $previous_warn->($warning); }
        else { CORE::warn($warning); }
    };
    return $code->();
}

sub add
{
    return 0 unless $active;
    my $count = 0;
    %fallback_index=();
    for my $ip (@_) {
        my ($f, $bits, $lo, $hi) =
            $reload_parse_cache && exists $reload_parse_cache->{$ip}
            ? @{$reload_parse_cache->{$ip}} : _spec_interval($ip);
        next unless defined $f;
        my @cidrs;
        if ($fallback{$f}) {
            ++$count; push @blocked_intervals,[$f,$lo,$hi];
            $f==AF_INET ? ++$count4 : ++$count6;
            next;
        }
        # The already validated interval gives the canonical network start.
        # For a single address or CIDR there is exactly one block; ranges
        # retain the original generic decomposition.
        if ($ip !~ /-/) {
            my $prefix = $bits;
            $prefix = $1 if $ip =~ m{/([0-9]+)$};
            my $hex = $lo->as_hex();
            $hex =~ s/^0x//;
            $hex = substr(('0' x ($bits / 4)) . $hex, -$bits / 4);
            my $network = inet_ntop($f, pack('H*', $hex));
            @cidrs = ("$network/$prefix");
        } else {
            @cidrs = _interval_cidrs($f, $bits, $lo, $hi);
        }
        if ($ip !~ /:/) {
            eval { $ipv4->add_any($_) for @cidrs };
            if ($@) { $fallback{$f}=1; DXHash::_badlist_log("DXCIDR IPv4 engine add failed: $@"); }
            ++$count; push @blocked_intervals, [$f, $lo, $hi]; ++$count4;
        } elsif ($ip =~ /:/) {
            eval { _ipv6_cidr_call(sub { $ipv6->add_any($_) for @cidrs }) };
            if ($@) { $fallback{$f}=1; DXHash::_badlist_log("DXCIDR IPv6 engine add failed: $@"); }
            ++$count; push @blocked_intervals, [$f, $lo, $hi]; ++$count6;
        } else { LogDbg('err', "DXCIDR::add non-ip address '$ip' read"); }
    }
    return $count;
}

sub clean_prep
{
	return unless $active;

    if ($ipv4 && $count4 && !$fallback{AF_INET()}) {
        my $ok=eval { $ipv4->clean; $ipv4->prep_find; 1 };
        unless ($ok) { $fallback{AF_INET()}=1; DXHash::_badlist_log("DXCIDR IPv4 preparation failed: $@"); }
    }
    if ($ipv6 && $count6 && !$fallback{AF_INET6()}) {
        my $ok=eval { _ipv6_cidr_call(sub { $ipv6->clean; $ipv6->prep_find }); 1 };
        unless ($ok) { $fallback{AF_INET6()}=1; DXHash::_badlist_log("DXCIDR IPv6 preparation failed: $@"); }
    }
}

sub _sort
{
	my @in;
	my @out;
	my $c;
	for my $i (@_) {
		my @s;
		
		my @ip = split m|/|, $i;
		if ($ip[0] =~ /:/) {
			@s = map{$_ ? hex($_) : 0} split /:/, $ip[0];
		} else {
			@s = map{$_ ? $_+0 : 0} split /\./, $ip[0];
		}
		while (@s < 8) {
			push @s, 0;
		}
#		my $s = pack "S*", reverse @s;
		my $s = pack "n*", @s; 
#		my $s = join ':', map {sprintf "%04d:", $_} @s;
#		push @in, [inet_pton(m|:|?AF_INET6:AF_INET, $ip[0]), @ip];
		push @in, [$s, @ip];
	}
	@out = sort {$a->[0] cmp $b->[0]} @in;
#	@out = sort {$a->[0] <=> $b->[0]} @in;
	return map { "$_->[1]/$_->[2]"} @out;
}

sub list
{
	return () unless $active;
	my @out;
	push @out, $ipv4->list, $ipv4->list_range if $count4 && !$fallback{AF_INET()};
	push @out, _ipv6_cidr_call(sub { ($ipv6->list, $ipv6->list_range) }) if $count6 && !$fallback{AF_INET6()};
    for my $entry (@blocked_intervals) {
        my ($f,$lo,$hi)=@$entry;
        push @out,_interval_cidrs($f,$f==AF_INET?32:128,$lo,$hi) if $fallback{$f};
    }
	return _sort(@out);
}

# Build a merged numeric interval index only when the native engine is
# unavailable. Point lookups remain logarithmic even for large badip lists.
sub _fallback_find
{
    my ($ip)=@_;
    my ($f,$bits,$lo,$hi)=_spec_interval($ip);
    return 0 unless defined $f;
    return status($ip) eq 'DIRTY' unless $lo->bcmp($hi)==0;
    unless (exists $fallback_index{$f}) {
        my @ordered=sort { $a->[1]->bcmp($b->[1]) } grep { $_->[0]==$f } @blocked_intervals;
        my @merged;
        for my $row (@ordered) {
            if (@merged && $row->[1]->bcmp($merged[-1][1]->copy()->binc())<=0) {
                $merged[-1][1]=$row->[2]->copy() if $row->[2]->bcmp($merged[-1][1])>0;
            } else { push @merged,[$row->[1]->copy(),$row->[2]->copy()]; }
        }
        $fallback_index{$f}=\@merged;
    }
    my $list=$fallback_index{$f};
    my ($l,$r)=(0,$#$list);
    while ($l<=$r) {
        my $m=int(($l+$r)/2);
        if ($lo->bcmp($list->[$m][0])<0) { $r=$m-1; }
        elsif ($lo->bcmp($list->[$m][1])>0) { $l=$m+1; }
        else { return 1; }
    }
    return 0;
}

# Use packed fixed-width addresses for a compact, logarithmic point lookup.
# Build from the same recovered records used by add(), never reread the file.
sub _vpn_build
{
    my %rows;
    for my $spec (@_) {
        my ($f, $bits, $lo, $hi) =
            $reload_parse_cache && exists $reload_parse_cache->{$spec}
            ? @{$reload_parse_cache->{$spec}} : _spec_interval($spec);
        next unless defined $f;
        my @packed = map {
            my $hex = $_->as_hex();
            $hex =~ s/^0x//;
            pack('H*', substr(('0' x ($bits / 4)) . $hex, -$bits / 4));
        } ($lo, $hi);
        push @{$rows{$f}}, \@packed;
    }
    my %index;
    for my $f (keys %rows) {
        my @merged;
        for my $row (sort { $a->[0] cmp $b->[0] } @{$rows{$f}}) {
            if (@merged && $row->[0] le $merged[-1][1]) {
                $merged[-1][1] = $row->[1] if $row->[1] gt $merged[-1][1];
            } else { push @merged, $row; }
        }
        $index{$f} = \@merged;
    }
    %vpn_index = %index;
}

sub find_vpn
{
    my ($ip) = @_;
    return 0 unless $active && %vpn_index && defined($ip) && length($ip);
    return 0 if $ip =~ /[\s\x00-\x1f\x7f-\x9f]/;
    my $f = $ip =~ /:/ ? AF_INET6 : AF_INET;
    my $list = $vpn_index{$f} or return 0;
    my $point = inet_pton($f, $ip);
    return 0 unless defined $point;
    my ($l, $r) = (0, $#$list);
    while ($l <= $r) {
        my $m = int(($l + $r) / 2);
        if ($point lt $list->[$m][0]) { $r = $m - 1; }
        elsif ($point gt $list->[$m][1]) { $l = $m + 1; }
        else { return 1; }
    }
    return 0;
}

sub find
{
	return 0 unless $active;
	return 0 unless defined $_[0] && length $_[0];

	if ($_[0] =~ /:/) {
        return _fallback_find($_[0]) if $fallback{AF_INET6()};
		my $ip = $_[0];
		return 0 unless $count6;
        my $result=eval { _ipv6_cidr_call(sub { $ipv6->find($ip) }) };
        if ($@) { $fallback{AF_INET6()}=1; DXHash::_badlist_log("DXCIDR IPv6 lookup failed: $@"); return _fallback_find($ip); }
        return $result;
	}
	if ($_[0] =~ /\./) {
        return _fallback_find($_[0]) if $fallback{AF_INET()};
		return 0 unless $count4;
        my $ip=$_[0];
        my $result=eval { $ipv4->find($ip) };
        if ($@) { $fallback{AF_INET()}=1; DXHash::_badlist_log("DXCIDR IPv4 lookup failed: $@"); return _fallback_find($ip); }
        return $result;
	}
	return 0;
}


# Strict address/CIDR/range parsing; all arithmetic stays within one family.
sub _spec_interval
{
    my ($spec) = @_;
    return unless defined $spec;
    return if $spec =~ /[\s\x00-\x1f\x7f-\x9f]/;
    return if $spec eq '';
    my ($left, $right, $bits, $family);
    if ($spec =~ m{^([^/]+)/(\d+)$}) {
        ($left, my $prefix) = ($1, $2);
        $family = $left =~ /:/ ? AF_INET6 : AF_INET;
        $bits = $family == AF_INET6 ? 128 : 32;
        return if $prefix > $bits;
        my $packed = inet_pton($family, $left) or return;
        require Math::BigInt;
        my $value = Math::BigInt->from_hex('0x' . unpack('H*', $packed));
        my $size = Math::BigInt->bone()->blsft($bits - $prefix);
        my $start = $value->copy()->bdiv($size)->bmul($size);
        my $end = $start->copy()->badd($size)->bdec();
        return ($family, $bits, $start, $end);
    }
    if ($spec =~ /^(.+)-(.+)$/) {
        ($left, $right) = ($1, $2);
        $family = $left =~ /:/ ? AF_INET6 : AF_INET;
        return if ($right =~ /:/ ? AF_INET6 : AF_INET) != $family;
        $bits = $family == AF_INET6 ? 128 : 32;
        my $a = inet_pton($family, $left) or return;
        my $b = inet_pton($family, $right) or return;
        require Math::BigInt;
        my $start = Math::BigInt->from_hex('0x' . unpack('H*', $a));
        my $end = Math::BigInt->from_hex('0x' . unpack('H*', $b));
        return if $start->bcmp($end) > 0;
        return ($family, $bits, $start, $end);
    }
    $family = $spec =~ /:/ ? AF_INET6 : AF_INET;
    my $packed = inet_pton($family, $spec) or return;
    require Math::BigInt;
    my $value = Math::BigInt->from_hex('0x' . unpack('H*', $packed));
    return ($family, $family == AF_INET6 ? 128 : 32, $value, $value->copy());
}

sub covered
{
    return 0 unless $active;
    my ($family, $bits, $start, $end) = _spec_interval($_[0]);
    return 0 unless defined $family;
    return status($_[0]) eq 'DIRTY' if $fallback{$family};
    my $table = $family == AF_INET ? $ipv4 : $ipv6;
    my @intervals;
    for my $entry ($family == AF_INET6 ? _ipv6_cidr_call(sub { $table->list }) : $table->list) {
        my ($f, $b, $lo, $hi) = _spec_interval($entry);
        push @intervals, [$lo, $hi] if defined $f && $f == $family;
    }
    @intervals = sort { $a->[0]->bcmp($b->[0]) } @intervals;
    my $cursor = $start->copy();
    for my $item (@intervals) {
        next if $item->[1]->bcmp($cursor) < 0;
        return 0 if $item->[0]->bcmp($cursor) > 0;
        return 1 if $item->[1]->bcmp($end) >= 0;
        $cursor = $item->[1]->copy()->binc();
    }
    return 0;
}

# Return CLEAN, PARTIAL or DIRTY for an address, CIDR or address range.
# Work with numeric intervals: Net::CIDR::Lite::find() is a point lookup,
# not a test of whether an entire queried network is covered.
sub status
{
    return 'CLEAN' unless $active;
    my ($family, $bits, $start, $end) = _spec_interval($_[0]);
    return 'CLEAN' unless defined $family;
    # Use intervals captured from successfully loaded entries.  Never call
    # Net::CIDR::Lite list/list_range here: their return formats and method
    # availability vary, and a thrown exception silently suppresses command output.
    my @intervals;
    for my $entry (@blocked_intervals) {
        next unless $entry->[0] == $family;
        my ($lo, $hi) = ($entry->[1], $entry->[2]);
        next if $hi->bcmp($start) < 0 || $lo->bcmp($end) > 0;
        push @intervals, [$lo, $hi];
    }
    return 'CLEAN' unless @intervals;
    @intervals = sort { $a->[0]->bcmp($b->[0]) } @intervals;
    my $cursor = $start->copy();
    for my $item (@intervals) {
        return 'PARTIAL' if $item->[0]->bcmp($cursor) > 0;
        return 'DIRTY' if $item->[1]->bcmp($end) >= 0;
        my $next = $item->[1]->copy()->binc();
        $cursor = $next if $next->bcmp($cursor) > 0;
    }
    return 'PARTIAL';
}

# Coverage within the explicitly selected source, not the global union.
sub covered_suffix
{
    my ($suffix, $spec) = @_;
    return 0 unless $active && defined $suffix && $suffix =~ /^\w+$/;
    my ($family, $bits, $start, $end) = _spec_interval($spec);
    return 0 unless defined $family;
    my @intervals;
    for my $entry (_read($suffix)) {
        my ($f, $b, $lo, $hi) = _spec_interval($entry);
        push @intervals, [$lo, $hi] if defined $f && $f == $family;
    }
    @intervals = sort { $a->[0]->bcmp($b->[0]) } @intervals;
    my $cursor = $start->copy();
    for my $item (@intervals) {
        next if $item->[1]->bcmp($cursor) < 0;
        return 0 if $item->[0]->bcmp($cursor) > 0;
        return 1 if $item->[1]->bcmp($end) >= 0;
        $cursor = $item->[1]->copy()->binc();
    }
    return 0;
}

sub valid_spec
{
    my @parts = _spec_interval($_[0]);
    $reload_parse_cache->{$_[0]} = \@parts
        if $reload_parse_cache && @parts == 4;
    return @parts == 4 ? 1 : 0;
}

sub _interval_cidrs
{
    my ($family, $bits, $start, $end) = @_;
    my @result;
    my $cur = $start->copy();
    while ($cur->bcmp($end) <= 0) {
        my $host = 0;
        while ($host < $bits) {
            my $size = Math::BigInt->bone()->blsft($host + 1);
            last unless $cur->copy()->bmod($size)->is_zero();
            last if $cur->copy()->badd($size)->bdec()->bcmp($end) > 0;
            ++$host;
        }
        my $hex = $cur->as_hex();
        $hex =~ s/^0x//;
        $hex = substr(('0' x ($bits / 4)) . $hex, -$bits / 4);
        my $ip = inet_ntop($family, pack('H*', $hex));
        push @result, "$ip/" . ($bits - $host);
        $cur->badd(Math::BigInt->bone()->blsft($host));
    }
    return @result;
}

# Only rewrite the requested suffix. Preserve unrelated lines verbatim.
# Return the number of source records changed; never claim a removal
# merely because another suffix contains the requested address.
sub remove
{
    return 0 unless $active;
    my ($suffix, $spec) = @_;
    return 0 unless defined $suffix && $suffix =~ /^\w+$/;
    my ($family, $bits, $start, $end) = _spec_interval($spec);
    return 0 unless defined $family;
    my $fn = _fn() . ".$suffix";
    my $fh = IO::File->new($fn, 'r') or return 0;
    my @lines = <$fh>;
    $fh->close();
    my @out;
    my $changed = 0;
    for my $line (@lines) {
        my $raw = $line;
        $raw =~ s/^\s+|\s+$//g;
        my ($f, $b, $lo, $hi) = _spec_interval($raw);
        if (!defined $f || $f != $family || $hi->bcmp($start) < 0 || $lo->bcmp($end) > 0) {
            push @out, $line;
            next;
        }
        ++$changed;
        push @out, map { "$_\n" } _interval_cidrs($f, $b, $lo, $start->copy()->bdec()) if $lo->bcmp($start) < 0;
        push @out, map { "$_\n" } _interval_cidrs($f, $b, $end->copy()->binc(), $hi) if $hi->bcmp($end) > 0;
    }
    return 0 unless $changed;
    # Write in place, as the original append() does: no lock or sidecar file.
    # No sidecar files: retain the original bytes in memory for best-effort
    # restoration if the in-place write fails. This is not crash-atomic.
    $fh = IO::File->new($fn, 'w') or die "DXCIDR::remove cannot write $fn: $!";
    my $ok = print {$fh} @out;
    $ok = $fh->close() && $ok;
    unless ($ok) {
        my $restore = IO::File->new($fn, 'w');
        if ($restore) { print {$restore} @lines; $restore->close(); }
        die "DXCIDR::remove write failed for $fn (restore attempted)";
    }
    return $changed;
}

sub init
{
    $engine_available=eval { require Net::CIDR::Lite; import Net::CIDR::Lite; 1 };
    DXHash::_badlist_log("DXCIDR: Net::CIDR::Lite unavailable; using validated interval fallback: $@") unless $engine_available;

	$active = 1;

	my $fn = _fn();
    if (!-e $fn && !-e "$fn.base" && defined($main::data) && -f "$main::data/$badipfn") {
        copy("$main::data/$badipfn",$fn) or DXHash::_badlist_log("DXCIDR default copy failed: $!");
    }
	if (-f $fn && !-e "$fn.base") {
        move($fn,"$fn.base") or DXHash::_badlist_log("DXCIDR base migration failed: $!");
    }

	_touch("$fn.local");
	
	reload();

}

sub _touch
{
	my $fn = shift;
	my $now = time;
	return if -e $fn || -l $fn; # no need to modify an existing source
    if (open(my $fh,'>>',$fn)) { close $fh; }
    else { DXHash::_badlist_log("DXCIDR::touch: Couldn't touch $fn: $!"); }
}

sub reload
{
	return 0 unless $active;

	new();

	my $count = 0;
	my $files = 0;

	LogDbg('DXProt', "DXCIDR::reload reload database" );

	my $dir;
	unless (opendir($dir, $main::local_data)) {
		LogDbg('err', "DXCIDR::reload cannot open $main::local_data: $!");
		return 0;
	}
	while (my $fn = readdir $dir) {
		next unless $fn eq $badipfn || $fn =~ /^\Q$badipfn\E\.(\w+)$/;
        my $suffix = $fn eq $badipfn ? undef : $1;
        next if DXHash::_inactive_source($fn);
        next unless -f "$main::local_data/$fn";
        my $c;
        my $ok=eval { $c=_load($suffix); 1 };
        unless ($ok) { DXHash::_badlist_log("DXCIDR source load failed $fn: $@"); next; }
		LogDbg('DXProt', "DXCIDR::reload: $fn read containing $c ip addresses" );
		$count += $c;
		$files++;
	}
	closedir $dir;
	clean_prep();
	
	LogDbg('DXProt', "DXCIDR::reload $count ip addresses found (IPV4: $count4 IPV6: $count6) in $files badip files" );

	return $count;
}

sub new
{
	return 0 unless $active;

	%fallback=();
    %fallback_index=();
    %vpn_index=();
    $ipv4 = $engine_available ? eval { Net::CIDR::Lite->new } : undef;
    unless ($ipv4) { $fallback{AF_INET()}=1; DXHash::_badlist_log("DXCIDR IPv4 engine initialization failed: $@") if $engine_available; }
    $ipv6 = $engine_available ? eval { Net::CIDR::Lite->new } : undef;
    unless ($ipv6) { $fallback{AF_INET6()}=1; DXHash::_badlist_log("DXCIDR IPv6 engine initialization failed: $@") if $engine_available; }
	$count4 = $count6 = 0;
    @blocked_intervals = ();
}

1;
