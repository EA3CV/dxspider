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
use Math::BigInt;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use IO::Handle;
use Fcntl qw(:flock);

use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);

our $active = 0;
our $badipfn = "badip";
my $ipv4;
my $ipv6;
my $count4 = 0;
my $count6 = 0;
my @active_ranges;

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
			unless (_badip_parse($_)) {
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
	my @out;
	
	if ($suffix) {
		my $fn = _fn() . ".$suffix";
		my $fh = IO::File->new;
		if ($fh->open("$fn", "a+")) {
			$fh->seek(0, 2);  	# belt and braces !!
			print $fh "$_\n" for @in;
			$fh->close;
		} else {
			LogDbg('err', "DXCIDR::append error appending to $fn $!");
		}
	} else {
		LogDbg('err', "DXCIDR::append require badip suffix");
	}
	return scalar @in;
}

sub add
{
	return 0 unless $active;
	my $count = 0;
	my @out;
	
	for my $ip (@_) {
		# Validate strictly; preserve CIDR prefixes and expand explicit ranges.
		my $parsed = _badip_parse($ip);
		next unless $parsed;
		if ($ip =~ /-/) {
			$count += add(_badip__cidrs($parsed->{family}, $parsed->{lo}, $parsed->{hi}));
			next;
		}
#		next if $ip =~ /^127\./;
#		next if $ip =~ /^::1$/;
#		next if find($ip);
		if ($ip =~ /\./) {
			eval {$ipv4->add_any($ip)};
			if ($@) {
				push @out, $@;
			} else {
				++$count;
				++$count4;
			}
		} elsif ($ip =~ /:/) {
			eval {$ipv6->add_any($ip)};
			if ($@) {
				push @out, $@;
			} else {
				++$count;
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
	return 0 if $_[0] =~ /\./;
	return $ipv6->find($_[0]) if $count6;
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

# Build the complete replacement off-line. Never destroy the active tables
# until every source has been read, validated and loaded successfully.
sub reload
{
    return 0 unless $active;
    my $dir = $main::local_data;
    opendir(my $dh, $dir) or do { LogDbg('err', "DXCIDR::reload opendir $dir: $!"); return undef; };
    my @names = grep { /^badip\.\w+$/ } readdir($dh);
    for my $name (@names) {
        if (-l "$dir/$name" || !-f "$dir/$name") {
            closedir($dh);
            LogDbg('err', "DXCIDR::reload refused unsafe source $dir/$name");
            return undef;
        }
    }
    my @files = sort @names;
    closedir($dh);
    my ($next4, $next6, $n4, $n6, $total);
    my @next_ranges;
    my $ok = eval {
        $next4 = Net::CIDR::Lite->new;
        $next6 = Net::CIDR::Lite->new;
        $n4 = $n6 = $total = 0;
        for my $name (@files) {
            my $path = "$dir/$name";
            open(my $fh, '<', $path) or die "open $path: $!";
            my $lineno = 0;
            while (my $line = <$fh>) {
                ++$lineno;
                $line =~ s/\r?\n$//;
                $line =~ s/\s*\#.*$//;
                $line =~ s/^\s+|\s+$//g;
                next unless length $line;
                my $r = _badip_parse($line)
                    or die "invalid badip entry $path:$lineno: $line";
                push @next_ranges, $r;
                my @cidrs = $line =~ /-/ ? _badip__cidrs($r->{family},$r->{lo},$r->{hi}) : ($line);
                for my $cidr (@cidrs) {
                    if ($r->{family} == AF_INET) { $next4->add_any($cidr); ++$n4; }
                    else { $next6->add_any($cidr); ++$n6; }
                    ++$total;
                }
            }
            close($fh) or die "close $path: $!";
        }
        if ($n4) { $next4->clean; $next4->prep_find; }
        if ($n6) { $next6->clean; $next6->prep_find; }
        1;
    };
    if (!$ok) {
        LogDbg('err', "DXCIDR::reload aborted, old tables retained: $@");
        return undef;
    }
    ($ipv4, $ipv6, $count4, $count6) = ($next4, $next6, $n4, $n6);
    @active_ranges = @next_ranges;
    LogDbg('DXProt', "DXCIDR::reload $total entries (IPv4: $n4 IPv6: $n6) from " . scalar(@files) . " files");
    return $total;
}

sub coverage {
    return _badip_coverage($_[0], \@active_ranges);
}

sub new
{
	return 0 unless $active;

	$ipv4 = Net::CIDR::Lite->new;
	$ipv6 = Net::CIDR::Lite->new;
	$count4 = $count6 = 0; 
}


# CIDR range operations retained inside the existing DXCIDR module.
sub _badip_parse {
    my ($value) = @_;
    return unless defined $value && $value ne '';
    my ($left, $right) = split /-/, $value, 2;
    return if defined($right) && $left =~ m{/};
    return if defined($right) && $right eq '';
    return if $value =~ /\s/;
    my ($addr, $prefix) = split m{/}, $left, 2;
    return if defined($prefix) && ($prefix !~ /^\d+$/);
    my $family = $addr =~ /:/ ? AF_INET6 : AF_INET;
    my $packed = inet_pton($family, $addr) or return;
    my $bits = $family == AF_INET ? 32 : 128;
    return if defined($prefix) && $prefix > $bits;
    my $n = Math::BigInt->from_hex('0x'.unpack('H*',$packed));
    my ($lo,$hi);
    if (defined $right) {
        return if $right =~ m{[/\-]};
        my $end = inet_pton($family, $right) or return;
        $lo = $n;
        $hi = Math::BigInt->from_hex('0x'.unpack('H*',$end));
        return if $lo->bcmp($hi) > 0;
    } else {
        $prefix = $bits unless defined $prefix;
        my $size = Math::BigInt->bone()->blsft($bits-$prefix);
        $lo = $n->copy()->bdiv($size)->bmul($size);
        $hi = $lo->copy()->badd($size)->bdec();
    }
    return { family=>$family, bits=>$bits, lo=>$lo, hi=>$hi };
}
sub _badip__overlap {
    my ($a,$b) = @_;
    return $a->{family} == $b->{family} && $a->{lo}->bcmp($b->{hi}) <= 0 && $b->{lo}->bcmp($a->{hi}) <= 0;
}
sub _badip__cidrs {
    my ($family,$lo,$hi) = @_;
    my $bits = $family == AF_INET ? 32 : 128;
    my @result;
    $lo = $lo->copy();
    while ($lo->bcmp($hi) <= 0) {
        my $hostbits = 0;
        while ($hostbits < $bits) {
            my $size = Math::BigInt->bone()->blsft($hostbits+1);
            last unless $lo->copy()->bmod($size)->is_zero();
            last if $lo->copy()->badd($size)->bdec()->bcmp($hi) > 0;
            ++$hostbits;
        }
        my $hex = $lo->as_hex(); $hex =~ s/^0x//;
        $hex = sprintf('%0*s', $bits/4, $hex); $hex =~ tr/ /0/;
        my $ip = inet_ntop($family, pack('H*',$hex));
        push @result, "$ip/".($bits-$hostbits);
        $lo->badd(Math::BigInt->bone()->blsft($hostbits));
    }
    return @result;
}
sub _badip__line_range {
    my ($line) = @_;
    my ($entry) = $line =~ /^\s*([^\s#]+)\s*(?:#.*)?$/;
    return defined($entry) ? _badip_parse($entry) : undef;
}
sub _badip__files {
    my ($suffix) = @_;
    my $dir = $main::local_data;
    opendir(my $dh, $dir) or die "cannot read $dir: $!";
    my @names = grep { /^badip\.\w+$/ } readdir($dh);
    for my $name (@names) { die "refusing symlink $dir/$name" if -l "$dir/$name"; }
    my @files = sort map { "$dir/$_" } grep { -f "$dir/$_" } @names;
    closedir($dh);
    if (defined $suffix) {
        die 'invalid suffix' unless $suffix =~ /^\w+$/;
        @files = grep { /\Qbadip.$suffix\E$/ } @files;
    }
    return @files;
}
sub _badip__read {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "read $file: $!";
    my @lines = <$fh>;
    close($fh) or die "close $file: $!";
    return @lines;
}
sub _badip_coverage {
    my ($query, $snapshot) = @_;
    my $q = _badip_parse($query) or die "invalid IP/CIDR/range: $query";
    my @segments;
    my @ranges = defined($snapshot) ? @$snapshot : map { map { _badip__line_range($_) } _badip__read($_) } _badip__files();
    for my $r (@ranges) {
            next unless $r && _badip__overlap($q,$r);
            push @segments, [($q->{lo}->bcmp($r->{lo}) >= 0 ? $q->{lo} : $r->{lo})->copy(),
                             ($q->{hi}->bcmp($r->{hi}) <= 0 ? $q->{hi} : $r->{hi})->copy()];
    }
    return 'CLEAN' unless @segments;
    @segments = sort { $a->[0]->bcmp($b->[0]) } @segments;
    my $end = $q->{lo}->copy()->bdec();
    for my $s (@segments) {
        return 'PARTIAL' if $s->[0]->bcmp($end->copy()->binc()) > 0;
        $end = $s->[1]->copy() if $s->[1]->bcmp($end) > 0;
        return 'DIRTY' if $end->bcmp($q->{hi}) >= 0;
    }
    return 'PARTIAL';
}
sub _badip__write_atomic {
    my ($file,$lines) = @_;
    my ($fh,$temp) = tempfile('.badip-XXXXXXXX', DIR=>dirname($file), UNLINK=>0);
    eval {
        my @stat = stat($file);
        if (@stat) { chmod($stat[2] & 07777, $temp) or die "chmod $temp: $!"; }
        if (@stat && $> == 0 && !chown($stat[4],$stat[5],$temp)) { die "chown $temp: $!"; }
        print {$fh} @$lines or die "write $temp: $!";
        $fh->flush() or die "flush $temp: $!";
        $fh->sync() or die "sync $temp: $!";
        close($fh) or die "close $temp: $!";
        rename($temp,$file) or die "rename $temp: $!";
        1;
    } or do { my $e=$@; close($fh); unlink($temp); die $e; };
}
# Restore the exact original bytes for every modified source on a reload error.
sub _badip_restore {
    my ($original) = @_;
    my @errors;
    for my $file (sort keys %$original) {
        my $ok = eval {
            if (defined $original->{$file}) { _badip__write_atomic($file,$original->{$file}); }
            else { unlink($file) or die "unlink $file: $!"; }
            1;
        };
        push @errors, "$file: $@" unless $ok;
    }
    die "badip rollback failed: @errors" if @errors;
    return 1;
}
# Execute a complete command transaction under one advisory lock.
# Readers of the active in-memory snapshot never observe intermediate states.
sub change_and_reload {
    my ($action,$suffix,@queries) = @_;
    my $lockpath = "$main::local_data/.badip.lock";
    die "unsafe lock $lockpath" if -l $lockpath;
    open(my $lock, '>>', $lockpath) or die "open lock $lockpath: $!";
    flock($lock, LOCK_EX) or die "flock $lockpath: $!";
    my ($changes,$files,$original) = _badip_change($action,$suffix,@queries);
    if ($files) {
        my $loaded = reload();
        unless (defined $loaded) {
            my $restored = eval { _badip_restore($original); 1 };
            die $restored
                ? "$action/badip: reload failed; disk restored, old memory retained"
                : "$action/badip: CRITICAL reload and rollback failed: $@";
        }
    }
    return ($changes,$files);
}

sub _badip_change {
    my ($action,$suffix,@queries) = @_;
    die 'invalid action' unless $action eq 'set' || $action eq 'unset';
    my @ranges = map { _badip_parse($_) or die "invalid IP/CIDR/range: $_" } @queries;
    my @files = $action eq 'set' ? _badip__files($suffix) : _badip__files();
    if ($action eq 'set') {
        die 'invalid suffix' unless defined($suffix) && $suffix =~ /^\w+$/;
        die 'refusing symlink target' if -l "$main::local_data/badip.$suffix";
    }
    die "set/badip: suffix required" if $action eq 'set' && !defined $suffix;
    if ($action eq 'set' && !@files) {
        die 'invalid suffix' unless $suffix =~ /^\w+$/;
        @files = ("$main::local_data/badip.$suffix");
        die "refusing symlink $files[0]" if -l $files[0];
    }
    my %updated;
    my $changes = 0;
    for my $file (@files) {
        my @lines = -e $file ? _badip__read($file) : ();
        # Refuse to rewrite a file containing unrecognized active entries.
        # Otherwise an unset could silently leave a blocked address behind.
        for my $line (@lines) {
            my $content = $line;
            $content =~ s/\s*#.*$//;
            $content =~ s/^\s+|\s+$//g;
            die "invalid entry in $file: $content" if length($content) && !_badip_parse($content);
        }
        my @out;
        for my $line (@lines) {
            my $r = _badip__line_range($line);
            if ($action ne 'unset' || !$r) { push @out,$line; next; }
            my @pieces = ([$r->{lo},$r->{hi}]);
            for my $q (@ranges) {
                next unless $r->{family} == $q->{family};
                my @next;
                for my $p (@pieces) {
                    if ($p->[1]->bcmp($q->{lo}) < 0 || $p->[0]->bcmp($q->{hi}) > 0) { push @next,$p; next; }
                    push @next, [$p->[0],$q->{lo}->copy()->bdec()] if $p->[0]->bcmp($q->{lo}) < 0;
                    push @next, [$q->{hi}->copy()->binc(),$p->[1]] if $p->[1]->bcmp($q->{hi}) > 0;
                }
                @pieces = @next;
            }
            if (@pieces == 1 && $pieces[0][0]->bcmp($r->{lo}) == 0 && $pieces[0][1]->bcmp($r->{hi}) == 0) {
                push @out,$line;
            } else {
                ++$changes;
                push @out, map { "$_\n" } map { _badip__cidrs($r->{family},@$_) } @pieces;
            }
        }
        if ($action eq 'set') {
            for my $i (0..$#queries) {
                # Avoid duplicate or fully covered additions in this source.
                my @existing = grep { defined } map { _badip__line_range($_) } @out;
                next if _badip_coverage($queries[$i], \@existing) eq 'DIRTY';
                push @out, "$queries[$i]\n";
                ++$changes;
            }
        }
        $updated{$file}=\@out if join('',@out) ne join('',@lines);
    }
    # Snapshot all affected files before the first commit. Restore earlier files
    # if a later write fails; never silently report partial success.
    my %original;
    for my $file (sort keys %updated) {
        $original{$file} = -e $file ? [ _badip__read($file) ] : undef;
    }
    my @committed;
    my $ok = eval {
        for my $file (sort keys %updated) {
            _badip__write_atomic($file,$updated{$file});
            push @committed,$file;
        }
        1;
    };
    unless ($ok) {
        my $error = $@ || 'unknown write error';
        my @restore_errors;
        for my $file (reverse @committed) {
            my $restored = eval {
                if (defined $original{$file}) { _badip__write_atomic($file,$original{$file}); }
                else { unlink($file) or die "unlink $file: $!"; }
                1;
            };
            push @restore_errors, "$file: $@" unless $restored;
        }
        die "badip commit failed: $error" . (@restore_errors ? " ROLLBACK FAILED: @restore_errors" : ' (rolled back)');
    }
    return ($changes, scalar keys %updated, \%original);
}
1;
