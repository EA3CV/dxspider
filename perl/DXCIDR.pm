#
# IP Address block list / checker
#
# This is a DXSpider compatible, optional skin over Net::CIDR::Lite
# If Net::CIDR::Lite is not present, then a find will always returns 0
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

use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);

our $active = 0;
our $badipfn = "badip";
my $ipv4;
my $ipv6;
my $count4 = 0;
my $count6 = 0;
my @blocked_intervals;

sub _fn
{
	return localdata($badipfn);
}

sub _read
{
	my $suffix = shift;
	my $fn = _fn();
	$fn .= ".$suffix" if $suffix;
	my $fh = IO::File->new($fn);
	my @out;
	my $ecount;
	my $line;
	

	if ($fh) {
		while (<$fh>) {
			chomp;
			++$line;
			next if /^\s*\#/;
			next unless /[\.:]/;
			next unless $_;
			unless (valid_spec($_)) {
				++$ecount;
				LogDbg('err', qq(DXCIDR: $fn line $line: '$_' not an ip address));
				if ($ecount > 10) {
					LogDbg('err', qq(DXCIDR: More than 10 errors in $fn at/after line $line: '$_' - INVALID INPUT FILE));
					return ();
				}
				next;
			}
			push @out, $_;
		}
		$fh->close;
	} else {
		LogDbg('err', "DXCIDR: $fn read error ($!)");
	}
	return @out;
}

sub _load
{
	return unless $active;
	my $suffix = shift;
	my @in = _read($suffix);
	return 0 unless @in;
	return scalar add(@in);
}

sub _put
{
	my $suffix = shift;
	my $fn = _fn() . ".$suffix";
	my $r = rand;
	my $fh = IO::File->new (">$fn.$r");
	my $count = 0;
	if ($fh) {
		for ($ipv4->list, $ipv6->list) {
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

sub add
{
	return 0 unless $active;
	my $count = 0;
	my @out;
	
	for my $ip (@_) {
		# protect against stupid or malicious
		next unless valid_spec($ip);
#		next if $ip =~ /^127\./;
#		next if $ip =~ /^::1$/;
#		next if find($ip);
		if ($ip !~ /:/) {
			eval { $ipv4->add_any($_) for _interval_cidrs(_spec_interval($ip)) };
			if ($@) {
				push @out, $@;
			} else {
				++$count;
				my ($f, $bits, $lo, $hi) = _spec_interval($ip);
                push @blocked_intervals, [$f, $lo, $hi];
                ++$count4;
			}
		} elsif ($ip =~ /:/) {
			eval { $ipv6->add_any($_) for _interval_cidrs(_spec_interval($ip)) };
			if ($@) {
				push @out, $@;
			} else {
				++$count;
				my ($f, $bits, $lo, $hi) = _spec_interval($ip);
                push @blocked_intervals, [$f, $lo, $hi];
                ++$count6;
			}
		} else {
			LogDbg('err', "DXCIDR::add non-ip address '$ip' read");
		}
	}
	return $count;
}

sub clean_prep
{
	return unless $active;

	if ($ipv4 && $count4) {
		$ipv4->clean;
		$ipv4->prep_find;
	}
	if ($ipv6 && $count6) {
		$ipv6->clean;
		$ipv6->prep_find;
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
	push @out, $ipv4->list, $ipv4->list_range if $count4;
	push @out, $ipv6->list, $ipv6->list_range if $count6;
	return _sort(@out);
}

sub find
{
	return 0 unless $active;
	return 0 unless $_[0];

	if ($_[0] =~ /\./) {
		return $ipv4->find($_[0]) if $count4;
	}
	return $ipv6->find($_[0]) if $count6;
}


# Strict address/CIDR/range parsing; all arithmetic stays within one family.
sub _spec_interval
{
    my ($spec) = @_;
    return unless defined $spec;
    return if $spec =~ /\s/;
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
    my $table = $family == AF_INET ? $ipv4 : $ipv6;
    my @intervals;
    for my $entry ($table->list) {
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
	eval { require Net::CIDR::Lite };
	if ($@) {
		LogDbg('DXProt', "DXCIDR: load (cpanm) the perl module Net::CIDR::Lite to check for bad IP addresses (or CIDR ranges)");
		return;
	}

	eval {import Net::CIDR::Lite };
	if ($@) {
		LogDbg('DXProt', "DXCIDR: import Net::CIDR::Lite error $@");
		return;
	}

	$active = 1;

	my $fn = _fn();
	if (-e $fn) {
		move $fn, "$fn.base";
	}

	_touch("$fn.local");
	
	reload();

}

sub _touch
{
	my $fn = shift;
	my $now = time;
	local (*TMP);
	utime ($now, $now, $fn) || open (TMP, ">>$fn") || LogDbg('err', "DXCIDR::touch: Couldn't touch $fn: $!");
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
		next unless my ($suffix) = $fn =~ /^badip\.(\w+)$/;
		my $c = _load($suffix);
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

	$ipv4 = Net::CIDR::Lite->new;
	$ipv6 = Net::CIDR::Lite->new;
	$count4 = $count6 = 0;
    @blocked_intervals = ();
}

1;
