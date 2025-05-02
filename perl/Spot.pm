#
# the dx spot handler
#
# Copyright (c) - 1998 Dirk Koopman G1TLH
#
#
#

package Spot;

use IO::File;
use DXVars;
use DXDebug;
use DXUtil;
use DXLog;
use Julian;
use Prefix;
use DXDupe;
use Data::Dumper;
use QSL;
use DXSql;
use Time::HiRes qw(gettimeofday tv_interval);
use Math::Round qw(nearest nearest_floor);

use strict;

use vars qw($fp $statp $maxspots $defaultspots $maxdays $dirprefix $duplth $dupage $filterdef
			$totalspots $hfspots $vhfspots $maxcalllth $can_encode $use_db_for_search);

$fp = undef;
$statp = undef;
$maxspots = 100;					# maximum spots to return
$defaultspots = 10;				# normal number of spots to return
$maxdays = 100;				# normal maximum no of days to go back
$dirprefix = "spots";
$duplth = 15;					# the length of text to use in the deduping
$dupage = 10*60;               # the length of time to hold spot dups
$maxcalllth = 12;                               # the max length of call to take into account for dupes
$filterdef = bless ([
					 # tag, sort, field, priv, special parser 
					 ['freq', 'r', 0, 0, \&decodefreq],
					 ['on', 'r', 0, 0, \&decodefreq],
					 ['call', 'c', 1],
					 ['info', 't', 3],
					 ['spotter', 'c', 4],
					 ['by', 'c', 4],
					 ['dxcc', 'nc', 5],
					 ['call_dxcc', 'nc', 5],
					 ['by_dxcc', 'nc', 6],
					 ['origin', 'c', 7, 9],
					 ['call_itu', 'ni', 8],
					 ['itu', 'ni', 8],
					 ['call_zone', 'nz', 9],
					 ['cq', 'nz', 9],
					 ['zone', 'nz', 9],
					 ['by_itu', 'ni', 10],
					 ['byitu', 'ni', 10],
					 ['by_zone', 'nz', 11],
					 ['byzone', 'nz', 11],
					 ['bycq', 'nz', 11],
					 ['call_state', 'ns', 12],
					 ['state', 'ns', 12],
					 ['by_state', 'ns', 13],
					 ['bystate', 'ns', 13],
					 ['ip', 'c', 14],
					 ['db', 'n', 15 ],
					 ['q', 'n', 16],
					 #					 ['channel', 'c', 15],
					 #					 ['rbn', 'a', 4, 0, \&filterrbnspot],
					], 'Filter::Cmd');


$totalspots = $hfspots = $vhfspots = 0;
$use_db_for_search = 0;

our %spotcache;					# the cache of data within the last $spotcachedays 0 or 2+ days
our $spotcachedays = 2;			# default 2 days worth
our $minselfspotqrg = 0;        # minimum freq above which self spotting is allowed

our $readback = $main::is_win ? 0 : 1; # don't read spot files backwards if it's windows
our $qrggranularity = 1;       # normalise the qrg to this number of khz (default: 25khz), so tough luck if you have a fumble fingers moment
our $timegranularity = 60;		# ditto to the nearest 60 seconds 
our $dupecall = 10;	            # check that call is not spotted too often - this the base dedupe interval - set to 0 to disable
our $calltick = 5;				# the escalator by which duping of calls are added to get them to actual DUPE status - meaning that below the threshold this call is passed above DUPE.
our $dupecallthreshold = 35;    # This is threshold at which a repeated call's dupe record actually becomes a dupe. So
                                # somewhere between 4 slowish and 3 fast spots will cause this indicate a possible flood.
our $dupeqrgcall = 1*60+5;	    # check that call is not spotted on the same (normalised) qrg too often - this the dedupe interval - set to 0 to disable1
our $store_nocomment = 0;		# Don't take into account the comments (add a time period for these)
our $nodetime = 10;				# as $dupecall but for nodes
our $nodetimethreshold = 50;	# as $dupecallthreshold but for nodes

our $do_node_check = 0;			# Enable / disable flags 
our $do_call_check = 1;			# Do checks and adds for nodes, (spot) calls, by (calls) and ip addresses
our $do_by_check = 1;			# 
our $do_ipaddr_check = 1;		# 

our $floodinterval = 0;			# superceded by the next variable
our $dupecallinfo = 5*60+5;		# floodinterval replacement
our $spotage = 2*60+5;			# the spot time stamp cannot be older than this no of secs



if ($readback) {
	$readback = `which tac`;
	chomp $readback;
}

# create a Spot Object
sub new
{
	my $class = shift;
	my $self = [ @_ ];
	return bless $self, $class;
}

sub decodefreq
{
	my $dxchan = shift;
	my $l = shift;
	my @f = split /,/, $l;
	my @out;
	my $f;
	
	foreach $f (@f) {
		my ($a, $b); 
		if ($f =~ m{^\d+[-/]\d+$}) {
			push @out, $f;
		} elsif (($a, $b) = $f =~ m{^(\w+)(?:/(\w+))?$}) {
			$b = lc $b if $b;
			my @fr = Bands::get_freq(lc $a, $b);
			if (@fr) {
				while (@fr) {
					$a = shift @fr;
					$b = shift @fr;
					push @out, "$a/$b";  # add them as ranges
				}
			} else {
				return ('dfreq', $dxchan->msg('dfreq1', $f));
			}
		} else {
			return ('dfreq', $dxchan->msg('e20', $f));
		}
	}
	return (0, join(',', @out));			 
}

# filter setup for rbn spot so return the regex to detect it
sub filterrbnspot
{
	my $dxchan = shift;
	return ('-#$');
}

sub init
{
	mkdir "$dirprefix", 0777 if !-e "$dirprefix";
	$fp = DXLog::new($dirprefix, "dat", 'd');
	$statp = DXLog::new($dirprefix, "dys", 'd');
	my $today = Julian::Day->new(time);

	# load up any old spots 
	if ($main::dbh) {
		unless (grep $_ eq 'spot', $main::dbh->show_tables) {
			dbg('initialising spot tables');
			my $t = time;
			my $total;
			$main::dbh->spot_create_table;
			
			my $now = Julian::Day->alloc(1995, 0);
			my $sth = $main::dbh->spot_insert_prepare;
			while ($now->cmp($today) <= 0) {
				my $fh = $fp->open($now);
				if ($fh) {
#					$main::dbh->{RaiseError} = 0;
					$main::dbh->begin_work;
					my $count = 0;
					while (<$fh>) {
						chomp;
						my @s = split /\^/;
						if (@s < 14) {
							my @a = (Prefix::cty_data($s[1]))[1..3];
							my @b = (Prefix::cty_data($s[4]))[1..3];
							push @s, $b[1] if @s < 7;
							push @s, '' if @s < 8;
							push @s, @a[0,1], @b[0,1] if @s < 12;
							push @s,  $a[2], $b[2] if @s < 14;
						} 
						$main::dbh->spot_insert(\@s, $sth);
						$count++;
					}
					$main::dbh->commit;
					dbg("inserted $count spots from $now->[0] $now->[1]");
					$fh->close;
					$total += $count;
				}
				$now = $now->add(1);
			}
			$main::dbh->begin_work;
			$main::dbh->spot_add_indexes;
			$main::dbh->commit;
#			$main::dbh->{RaiseError} = 1;
			$t = time - $t;
			my $min = int($t / 60);
			my $sec = $t % 60;
			dbg("$total spots converted in $min:$sec");
		}
		unless ($main::dbh->has_ipaddr) {
			$main::dbh->add_ipaddr;
			dbg("added ipaddr field to spot table");
		}
	}

	# initialise the cache if required
	if ($spotcachedays > 0) {
		my $t0 = [gettimeofday];
		$spotcachedays = 2 if $spotcachedays < 2;
		for (my $i = 0; $i < $spotcachedays; ++$i) {
			my $now = $today->sub($i);
			my $fh = $fp->open($now);
			if ($fh) {
				my @in;
				my $rec;
				for ($rec = 0; <$fh>; ++$rec) {
					chomp;
					my @s = split /\^/;
					if (@s < 14) {
						my @a = (Prefix::cty_data($s[1]))[1..3];
						my @b = (Prefix::cty_data($s[4]))[1..3];
						push @s, $b[1] if @s < 7;
						push @s, '' if @s < 8;
						push @s, @a[0,1], @b[0,1] if @s < 12;
						push @s,  $a[2], $b[2] if @s < 14;
					}
					unshift @in, \@s; 
				}
				$fh->close;
				dbg("Spot::init read $rec spots from " . _cachek($now));
				$spotcache{_cachek($now)} = \@in;
			}
			$now->add(1);
		}
		dbg("Spot::init $spotcachedays files of spots read into cache in " . _diffms($t0) . "mS")
	}
}

sub prefix
{
	return $fp->{prefix};
}

# fix up the full spot data from the basic spot data
# input is
# freq, call, time, comment, spotter, origin[, ip_address, strength dB, quality]
sub prepare
{
	# $freq, $call, $t, $comment, $spotter, node, ip address, quality, dB = @_
	my @out = @_[0..4];      # just up to the spotter

	# normalise frequency
	$out[0] = sprintf "%.1f", $out[0];
  
	# remove ssids and /xxx if present on spotter
	$out[4] =~ s/-\d+$//o;

	# remove leading and trailing spaces from comment field
	$out[3] = unpad($out[3]);
	
	# add the 'dxcc' country on the end for both spotted and spotter, then the cluster call
	my @spd = Prefix::cty_data($out[1]);
	push @out, $spd[0];
	my @spt = Prefix::cty_data($out[4]);
	push @out, $spt[0];
	push @out, $_[5];
	push @out, @spd[1,2], @spt[1,2], $spd[3], $spt[3];

	push @out, ($_[6] && is_ipaddr($_[6])) ? $_[6] : '';
	push @out, (defined $_[7]) ? $_[7] : 0;
	push @out, (defined $_[8]) ? $_[8] : 0;
	
	# thus we now have:
	# freq, call, time, comment, spotter, call country code, spotter country code, origin, call itu, call cqzone, spotter itu, spotter cqzone, call state, spotter state, spotter ip address, dB strength, quality
	# RBN stuff is tacked on by the RBN module after this the base spot preparation
	return @out;
}

sub add_local
{
	my $buf = join('^', @_);

	dup_new(@_[0..4,7,14]);

	$fp->writeunix($_[2], $buf);
	if ($spotcachedays > 0) {
		my $now = Julian::Day->new($_[2]);
		my $day = _cachek($now);
		my $r = (exists $spotcache{$day}) ? $spotcache{$day} : ($spotcache{$day} = []);
		unshift @$r, \@_;
	}
	if ($main::dbh) {
		$main::dbh->begin_work;
		$main::dbh->spot_insert(\@_);
		$main::dbh->commit;
	}
	$totalspots++;
	if ($_[0] <= 30000) {
		$hfspots++;
	} else {
		$vhfspots++;
	}
	if ($_[3] =~ /(?:QSL|VIA)/i) {
		my $q = QSL::get($_[1]) || new QSL $_[1];
		$q->update($_[3], $_[2], $_[4]);
	}
}

# search the spot database for records based on the field no and an expression
# this returns a set of references to the spots
#
# the expression is a legal perl 'if' statement with the possible fields indicated
# by $f<n> where :-
#
#   $f0 = frequency
#   $f1 = call
#   $f2 = date in unix format
#   $f3 = comment
#   $f4 = spotter
#   $f5 = spotted dxcc country
#   $f6 = spotter dxcc country
#   $f7 = origin
#   $f8 = spotted itu
#   $f9 = spotted cq zone
#   $f10 = spotter itu
#   $f11 = spotter cq zone
#   $f12 = spotted us state
#   $f13 = spotter us state
#   $f14 = ip address
#   $f15 = signal strength (RBN)
#   $f16 = quality  (RBN)
#
# In addition you can specify a range of days, this means that it will start searching
# from <n> days less than today to <m> days less than today
#
# Also you can select a range of entries so normally you would get the 0th (latest) entry
# back to the 5th latest, you can specify a range from the <x>th to the <y>the oldest.
#
# This routine is designed to be called as Spot::search(..)
#

sub search
{
	my ($expr, $dayfrom, $dayto, $from, $to, $hint, $dofilter, $dxchan) = @_;
	my @out;
	my $ref;
	my $i;
	my $count;
	my $today = Julian::Day->new(time());
	my $fromdate;
	my $todate;

	$dayfrom = 0 if !$dayfrom;
	$dayto = $maxdays unless $dayto;
	$dayto = $dayfrom + $maxdays if $dayto < $dayfrom;
	$fromdate = $today->sub($dayfrom);
	$todate = $fromdate->sub($dayto);
	$from = 0 unless $from;
	$to = $defaultspots unless $to;
	$hint = $hint ? "next unless $hint" : "";
	$expr = "1" unless $expr;
	
	$to = $from + $maxspots if $to - $from > $maxspots || $to - $from <= 0;

	if ($main::dbh && $use_db_for_search) {
		return $main::dbh->spot_search($expr, $dayfrom, $dayto, $from, $to, $hint, $dofilter, $dxchan);
	}

	#	$expr =~ s/\$f(\d\d?)/\$ref->[$1]/g; # swap the letter n for the correct field name
	#  $expr =~ s/\$f(\d)/\$spots[$1]/g;               # swap the letter n for the correct field name
  

	dbg("Spot::search hint='$hint', expr='$expr', spotno=$from-$to, day=$dayfrom-$dayto\n") if isdbg('search');
  
	# build up eval to execute

	dbg("Spot::search Spot eval: $expr") if isdbg('searcheval');
	$expr =~ s/\$r/\$_[0]/g;
	my $eval = qq{ sub { return $expr; } };
	dbg("Spot::search Spot eval: $eval") if isdbg('searcheval');
	my $ecode = eval $eval;
	return ("Spot search error", $@) if $@;
	
	my $fh;
	my $now = $fromdate;
	my $today = Julian::Day->new($main::systime);
	
	for ($i = $count = 0; $count < $to && $i < $maxdays; ++$i) { # look thru $maxdays worth of files only
		last if $now->cmp($todate) <= 0;


		my $this = $now->sub($i);
		my $fn = $fp->fn($this);
		my $cachekey = _cachek($this); 
		my $rec = 0;

		if ($spotcachedays > 0 && $spotcache{$cachekey}) {
			foreach my $r (@{$spotcache{$cachekey}}) {
				++$rec;
				if ($dofilter && $dxchan && $dxchan->{spotsfilter}) {
					my ($gotone, undef) = $dxchan->{spotsfilter}->it(@$r);
					next unless $gotone;
				}
				if (&$ecode($r)) {
					++$count;
					next if $count < $from;
					push @out, $r;
					last if $count >= $to;
				}
			}
			dbg("Spot::search cache recs read: $rec") if isdbg('search');
		} else {
			if ($readback) {
				dbg("Spot::search search using tac fn: $fn $i") if isdbg('search');
				$fh = IO::File->new("$readback $fn |");
			}
			else {
				dbg("Spot::search search fn: $fp->{fn} $i") if isdbg('search');
				$fh = $fp->open($now->sub($i));	# get the next file
			}
			if ($fh) {
				my $in;
				while (<$fh>) {
					chomp;
					my @r = split /\^/;
					$r[6] = '' unless defined $r[6];
					$r[7] = 0 unless defined $r[7];
					$r[8] = 0 unless defined $r[8];
					
					++$rec;
					if ($dofilter && $dxchan && $dxchan->{spotsfilter}) {
						my ($gotone, undef) = $dxchan->{spotsfilter}->it(@r);
						next unless $gotone;
					}
					if (&$ecode(\@r)) {
						++$count;
						next if $count < $from;
						if ($readback) {
							push @out, \@r;
							last if $count >= $to;
						} else {
							push @out, \@r;
							shift @out if $count >= $to;
						}
					}
				}
				dbg("Spot::search file recs read: $rec") if isdbg('search');
				last if $count >= $to; # stop after to
			}
		}
	}
	return ("Spot search error", $@) if $@;

	@out = sort {$b->[2] <=> $a->[2]} @out if @out;
	return @out;
}

# change a freq range->regular expression
sub ftor
{
	my ($a, $b) = @_;
	return undef unless $a < $b;
	$b--;
	my $d = $b - $a;
	my @a = split //, $a;
	my @b = split //, $b;
	my $out;
	while (@b > @a) {
		$out .= shift @b;
	}
	while (@b) {
		my $aa = shift @a;
		my $bb = shift @b;
		if (@b < (length $d)) {
			$out .= '\\d';
		} elsif ($aa eq $bb) {
			$out .= $aa;
		} elsif ($aa < $bb) {
			$out .= "[$aa-$bb]";
		} else {
			$out .= "[0-$bb$aa-9]";
		}
	}
	return $out;
}

# format a spot for user output in list mode
sub formatl
{
	my $t = ztime($_[3]);
	my $d = cldate($_[3]);
	my $spotter = "<$_[5]>";
	my $comment = $_[4] || '';
	$comment =~ s/\t+/ /g;
	my $cl = length $comment;
	my $s = sprintf "%9.1f %-11s %s %s", $_[1], $_[2], $d, $t;
	my $width = ($_[0] ? $_[0] : 80) - length($spotter) - length($s) - 4;
	
	$comment = substr $comment, 0, $width if $cl > $width;
	$comment .= ' ' x ($width-$cl) if $cl < $width;

#	return sprintf "%8.1f  %-11s %s %s  %-28.28s%7s>", $_[0], $_[1], $d, $t, ($_[3]||''), "<$_[4]" ;
	return "$s $comment$spotter";
}

# Add the dupe if it is new. 
sub dup_add
{
	my ($just_find, $freq, $call, $d, $text, $by, $node, $ipaddr, $reason) = @_;

	my $check = $just_find ? 'CHECK' : 'ADD  ';

	# turn the time into minutes (it is seconds to a granularity of seconds)
	$d = int ($d / 60);
    $d *= 60;
	#	my $nd = nearest($timegranularity, $d);
	my $nd = $d;
	my $hd = htime($d);
	my $testtype;

	dbg("Spot::add_dup: $check (+INPUT+)   freq=$freq call=$call d=$d ($hd) text='$text' by=$by node=$node ipaddr='$ipaddr'") if isdbg('spotdup');

		# dump if too old
	if ($spotage && $nd < $main::systime - $spotage) {
		$testtype ='(TOO OLD)';
		$$reason = $testtype if ref $reason;
		dbg("PCPROT: Spot too old req=$freq call=$call d=$hd text='$text' by=$by node=$node ipaddr='$ipaddr' is more than " . ($main::systime - $nd) . " (max $spotage) secs old $testtype") if isdbg('pc11');
		return $d;
	}


	$freq = sprintf "%.1f", $freq;       # normalise frequency
#	$freq = int $freq;       # normalise frequency

	my $qrg = nearest($qrggranularity, $freq); # to the nearest however many hz
	
	$call = substr($call, 0, $maxcalllth) if length $call > $maxcalllth;

	# remove SSID or area on call, by
	$call = basecall($call);
	$by = barecall($by);

	my $t = 0;
	my $ldupkey;
	my $dtext;
	
	my $l = length $text;
	$dtext = qq{original:'$text'($l)} if isdbg('spottext');

	chomp $text;
	
	$text =~ s/\%([0-9A-F][0-9A-F])/chr(hex($1))/eg;
	$text = uc unpad($text);
	$text =~ s/^\s*\d{1,2}[-+.:]\d\d\s+//; # remove anything that looks like a time from the front

	my $storet;
	
	$l = length $text;
	$dtext .= qq{->afterhex: '$text'($l)} if isdbg('spottext');
	my @dubious;
	if (isdbg('spottext')) {
		(@dubious) = $text =~ /([?\x00-\x08\x0a-\x1F\x7B-\xFF]+)+/;
		$dtext .= sprintf q{DUBIOUS '%s'}, join '', @dubious if @dubious;
	}

	my $otext = $text;
#	$text = Encode::encode("iso-8859-1", $text) if $main::can_encode && Encode::is_utf8($text, 1);
	$text =~ s/^\+\w+\s*//;			# remove leading LoTW callsign
	$text =~ s/\s{2,}[\dA-Z]?[A-Z]\d?$//g if length $text > 24;
	$text =~ s/\x09+//g;
	$text =~ s/[\W\x00-\x2F\x7B-\xFF]//g; # tautology, just to make quite sure!
	$text = substr($text, 0, $duplth) if length $text > $duplth;

	$l = length $text;
	$dtext .= qq{->final:'$text'($l)} if isdbg('spottext');

	
	# new feature: don't include the origin node in Spot dupes and use normalised qrg, rather than raw freq
	# $text = normalised text
	my $t;

	$text =~ s/^\s*$//;
	$text ||= 'blank';
	if ($dupage) {
		$testtype = '(NORM TEXT)';
		$$reason = $testtype if ref $reason;
		$ldupkey = "X$call|$by|$qrg|$nd|$text";
		$t = DXDupe::find($ldupkey);
		$storet = !$t && !$just_find ? " +$dupage secs STORE=>".htime($main::systime+$dupage) :'';
		dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey $storet", $testtype) . ($t?(' DUPE=>'.htime($t)) :'')) if isdbg('spotdup');
		$dtext .= ' DUPE' if $t;
		dbg("text transforms: $dtext") if length $text && isdbg('spottext');
		return $t if $t;

		DXDupe::add($ldupkey, $main::systime+$dupage) unless $just_find;
	}
	
	# Without comment
	if ($store_nocomment) {
		$testtype ='(NOTEXT)';
		$$reason = $testtype if ref $reason;
		$ldupkey = "X$call|$by|$qrg";
		$t = DXDupe::find($ldupkey);
		$storet = !$t && !$just_find ? " $store_nocomment secs STORE=>".htime($main::systime+$store_nocomment) :'';
		dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey $storet", $testtype). ($t?(' (DUPE=>'.htime($t)) :'')) if isdbg('spotdup');
		
		return $t if $t;	

		DXDupe::add($ldupkey, $main::systime+$dupage) unless $just_find;
	}

	if ($dupeqrgcall) {
		$testtype = '(QRG-CALL)';
		$$reason = $testtype if ref $reason;
	    $ldupkey = "X$call|$qrg";
		$t = DXDupe::find($ldupkey);
		$storet = !$t && !$just_find ? " +$dupeqrgcall secs STORE=>".htime($main::systime+$dupeqrgcall) :'';
		dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey $storet", $testtype) . ($t?(' DUPE=>'.htime($t)) :'')) if isdbg('spotdup');

		return $t if $t;	

		DXDupe::add($ldupkey, $main::systime+$dupeqrgcall) unless $just_find;
	}

	if ($dupecallinfo) {
		$testtype = '(CALL-INFO)';
		$$reason = $testtype if ref $reason;
	    $ldupkey = "X$call|$text";
		$t = DXDupe::find($ldupkey);
		$storet = !$t && !$just_find ? " +$dupecallinfo secs STORE=>".htime($main::systime+$dupecallinfo) :'';
		dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey $storet", $testtype) . ($t?(' DUPE=>'.htime($t)) :'')) if isdbg('spotdup');

		return $t if $t;	

		DXDupe::add($ldupkey, $main::systime+$dupecallinfo) unless $just_find;
	}

	# first crude flood protection. This plain callsign checking spotting anything that isn't caught by preceding tests.
	if ($dupecall) {
		$t = handle_dupecalls($call, $reason, "(CALL)", $just_find) if $do_call_check;
		$t ||= handle_dupecalls($by, $reason, "(BY)", $just_find) if $do_by_check;
		$t ||= handle_dupecalls("N$node", $reason, "(NODE)", $just_find, $nodetime, $nodetimethreshold) if $do_node_check;
		$t ||= handle_dupecalls($ipaddr, $reason, "(IPADDR)", $just_find) if $do_ipaddr_check && $ipaddr && is_ipaddr($ipaddr);

		return $t if $t && $just_find;
	}

	# This left here for reference but never fire
	if ($floodinterval) {
		$testtype = '(SP-FLOOD)';
		$ldupkey = "XX$call|$text";
		$t = DXDupe::find($ldupkey);
		$$reason = $testtype if ref $reason;
		$storet = !$t && !$just_find ? " +$floodinterval secs STORE=>".htime($main::systime+$floodinterval) :'';
		# This is a fast flood, DUPE it immediately
		my $left = $t > 0 &&  $main::systime - $t > 0 ?  $main::systime - $t : 0;
		if ($just_find && $left && $left <= $floodinterval) {
			dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey FAST FLOOD DUPE=>%s %d secs left", $testtype, htime($t), $left)) if isdbg('spotdup');
			DXDupe::add($ldupkey, $main::systime+$floodinterval); # update the time
			return $t;
		}
		#			DXDupe::del($ldupkey); # if not cleaned yet
		$storet = !$just_find ? " +$floodinterval secs STORE=>".htime($main::systime) :'';
		dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey $storet ", $testtype)) if isdbg('spotdup');
		DXDupe::add($ldupkey, $main::systime+$floodinterval) # for the first occurrance of this spot;
	}
	
	return 0;
}

sub handle_dupecalls
{
	my $call = shift;
	my $reason = shift;
	my $testtype = shift;
	my $just_find = shift;
	my $timeout = shift || $dupecall;
	my $threshold = shift || $dupecallthreshold;
	my $tick = shift || $calltick;
			
	my $check = $just_find ? 'CHECK' : 'ADD  ';
	
    # we are DEFINITELY kicking the timer down the road until it stops
	# in a sustained attack this will oscillate between systime and systime + threshold until
	# the attack stops and the record is cleaned away as normal
	my $ldupkey = "X$call";
	my $t = DXDupe::find($ldupkey);
	
	if ($t > 0) {
		my $new = $t + $tick;
		if ($t < $main::systime + $threshold) {
			dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey NOW %s ADD +%d secs => %s PASSED", $testtype, htime($t), $tick, htime($new))) if isdbg('spotdup');
			DXDupe::add($ldupkey, $new); # update the time
			$t = 0;
			# allow this to return
		} else {
			$$reason = $testtype if ref $reason;
			dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey FLOOD DUPE=>%s %d secs left", $testtype, htime($t), $t-$main::systime)) if isdbg('spotdup');
		}
	} else {
		my $storet = !$just_find ? " +$timeout secs STORE=>".htime($main::systime+$timeout) :'';
		dbg(sprintf("Spot::add_dup: $check %-11.11s $ldupkey $storet ", $testtype)) if isdbg('spotdup');
		DXDupe::add($ldupkey, $main::systime+$timeout) unless $just_find;
	}

	return $t;
}

sub dup_find
{
	return dup_add(1, @_);
}

sub dup_new
{
	return dup_add(0, @_);
}

sub listdups
{
	my @dups = DXDupe::listdups('X', $dupage, @_);
	my @out = sort @dups;
	push @out, scalar @out . " Duplicate spots";
	return @out;
}

sub genstats
{
	my $date = shift;
	my $in = $fp->open($date) or dbg("Spot::genstats: Cannot open " . $fp->fn($date) . " $!");
	my $out = $statp->open($date, 'w') or dbg("Spot::genstats: Cannot open " . $statp->fn($date) . " $!");
	my @freq;
	my %list;
	my @tot;
	
	if ($in && $out) {
		my $i = 0;
		@freq = map {[$i++, Bands::get_freq($_)]} qw(136khz 160m 80m 60m 40m 30m 20m 17m 15m 12m 10m 6m 4m 2m 220 70cm 23cm 13cm 9cm 6cm 3cm 12mm 6mm);
		while (<$in>) {
			chomp;
			my ($freq, $by, $dxcc) = (split /\^/)[0,4,6];
			my $ref = $list{$by} || [0, $dxcc];
			for (@freq) {
				next unless defined $_;
				if ($freq >= $_->[1] && $freq <= $_->[2]) {
					$$ref[$_->[0]+2]++;
					$tot[$_->[0]+2]++;
					$$ref[0]++;
					$tot[0]++;
					$list{$by} = $ref;
					last;
				}
			}
		}

		for ($i = 0; $i < @freq+2; $i++) {
			$tot[$i] ||= 0;
		}
		$statp->write($date, join('^', 'TOTALS', @tot));

		for (sort {$list{$b}->[0] <=> $list{$a}->[0]} keys %list) {
			my $ref = $list{$_};
			my $call = $_;
			for ($i = 0; $i < @freq+2; ++$i) {
				$ref->[$i] ||= 0;
			}
			$statp->write($date, join('^', $call, @$ref));
		}
		$statp->close;
	}
}

# return true if the stat file is newer than than the spot file
sub checkstats
{
	my $date = shift;
	my $in = $fp->mtime($date);
	my $out = $statp->mtime($date);
	return defined $out && defined $in && $out >= $in;
}

# daily processing
sub daily
{
	my $date = Julian::Day->new($main::systime)->sub(1);
	genstats($date) unless checkstats($date);
	clean_cache();
}

sub _cachek
{
	return "$_[0]->[0]|$_[0]->[1]";
}

sub clean_cache
{
	if ($spotcachedays > 0) {
		my $now = Julian::Day->new($main::systime);
		for (my $i = $spotcachedays; $i < $spotcachedays + 5; ++$i ) {
			my $k = _cachek($now->sub($i));
			if (exists $spotcache{$k}) {
				dbg("Spot::spotcache deleting day $k, more than $spotcachedays days old");
				delete $spotcache{$k};
			}
		}
	}
}
1;




