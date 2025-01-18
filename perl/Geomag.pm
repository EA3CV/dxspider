#!/usr/bin/perl
# 
# The geomagnetic information and calculation module
# a chanfe
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
#
#

package Geomag;

use DXVars;
use DXUtil;
use DXLog;
use Julian;
use IO::File;
use DXDebug;
use DXDupe;
use Time::HiRes qw(gettimeofday tv_interval);

use strict;

use vars qw($date $sfi $k $a $r $forecast @allowed @denied $fp $node $from 
            $dirprefix $param
            $duplth $dupage $filterdef);

$fp = 0;						# the DXLog fcb
$date = 0;						# the unix time of the WWV (notional)
$sfi = 0;						# the current SFI value
$k = 0;							# the current K value
$a = 0;							# the current A value
$r = 0;							# the current R value
$forecast = "";					# the current geomagnetic forecast
$node = "";						# originating node
$from = "";						# who this came from
@allowed = ();					# if present only these callsigns are regarded as valid WWV updators
@denied = ();					# if present ignore any wwv from these callsigns
$duplth = 20;					# the length of text to use in the deduping
$dupage = 12*3600;				# the length of time to hold spot dups

$dirprefix = "$main::local_data/wwv";
$param = "$dirprefix/param";

our $maxcache = 10;
our @cache;


$filterdef = bless ([
			  # tag, sort, field, priv, special parser 
			  ['by', 'c', 0],
			  ['origin', 'c', 1],
			  ['channel', 'c', 2],
			  ['by_dxcc', 'nc', 3],
			  ['by_itu', 'ni', 4],
			  ['by_zone', 'nz', 5],
			  ['origin_dxcc', 'nc', 6],
			  ['origin_itu', 'ni', 7],
			  ['origin_zone', 'nz', 8],
			 ], 'Filter::Cmd');

sub init
{
	$fp = DXLog::new('wwv', 'dat', 'm');
	do "$param" if -e "$param";
	# read in existing data
	my $t0 = [gettimeofday];
	@cache = readfile($main::systime);
	shift @cache while @cache > $maxcache;	
	dbg(sprintf "WWV read in last %d records into cache in %dmS", scalar @cache, _diffms($t0));	
	confess $@ if $@;
}

# write the current data away
sub store
{
	my $fh = new IO::File;
	open $fh, "> $param" or confess "can't open $param $!";
	print $fh "# Geomagnetic data parameter file last mod:", scalar gmtime, "\n";
	print $fh "\$date = $date;\n";
	print $fh "\$sfi = $sfi;\n";
	print $fh "\$a = $a;\n";
	print $fh "\$k = $k;\n";
	print $fh "\$r = $r;\n";
	print $fh "\$from = '$from';\n";
	print $fh "\$node = '$node';\n";
	print $fh "\@denied = qw(", join(' ', @denied), ");\n" if @denied > 0;
	print $fh "\@allowed = qw(", join(' ', @allowed), ");\n" if @allowed > 0;
	close $fh;
	
	# log it
	my $s ="$from^$date^$sfi^$a^$k^$forecast^$node^$r";
	$fp->writeunix($date, $s);
	push @cache, [ split /\^/, $s ];
	shift @cache while @cache > $maxcache; 
}

# update WWV info in one go (usually from a PC23)
sub update
{
	my ($mydate, $mytime, $mysfi, $mya, $myk, $myforecast, $myfrom, $mynode, $myr) = @_;
	$myfrom =~ s/-\d+$//;
	if ((@allowed && grep {$_ eq $myfrom} @allowed) || 
		(@denied && !grep {$_ eq $myfrom} @denied) ||
		(@allowed == 0 && @denied == 0)) {
		
		#	my $trydate = cltounix($mydate, sprintf("%02d18Z", $mytime));
		if ($mydate > $date) {
			if ($myr) {
				$r = 0 + $myr;
			} else {
				$r = 0 unless abs ($mysfi - $sfi) > 3;
			}
			$sfi = 0 + $mysfi;
			$k = 0 + $myk;
			$a = 0 + $mya;
			$forecast = $myforecast;
			$date = $mydate;
			$from = $myfrom;
			$node = $mynode;
			
			store();
		}
	}
}

# add or substract an allowed callsign
sub allowed
{
	my $flag = shift;
	if ($flag eq '+') {
		push @allowed, map {uc $_} @_;
	} else {
		my $c;
		foreach $c (@_) {
			@allowed = map {$_ ne uc $c} @allowed; 
		} 
	}
	store();
}

# add or substract a denied callsign
sub denied
{
	my $flag = shift;
	if ($flag eq '+') {
		push @denied, map {uc $_} @_;
	} else {
		my $c;
		foreach $c (@_) {
			@denied = map {$_ ne uc $c} @denied; 
		} 
	}
	store();
}

# accessor routines (when I work how symbolic refs work I might use one of those!)
sub sfi
{
	@_ ? $sfi = shift : $sfi ;
}

sub k
{
	@_ ? $k = shift : $k ;
}

sub r
{
	@_ ? $r = shift : $r ;
}

sub a
{
	@_ ? $a = shift : $a ;
}

sub forecast
{
	@_ ? $forecast = shift : $forecast ;
}


#
# print some items from the log backwards in time
#
# This command outputs a list of n lines starting from line $from to $to
#
sub search
{
	my $from = shift;
	my $to = shift;
	my $t = shift;
	my $date = $fp->unixtoj($t);
	my $pattern = shift;
	my $search;
	my @out;
	my $eval;
	my $count;

	if ($t == $main::systime && ($to <= $maxcache)) {
		dbg("using wwv cache") if isdbg('wwv');
		@out = reverse @cache;
		pop @out while @out > $to;
	} else {
		dbg("using wwv file(s))") if isdbg('wwv');
		$search = 1;
		$eval = qq(
			   my \$c;
			   my \$ref;
			   for (\$c = \$#in; \$c >= 0; \$c--) {
					\$ref = \$in[\$c];
					if ($search) {
						\$count++;
						next if \$count < \$from;
						push \@out, \$ref;
						last if \$count >= \$to; # stop after n
					}
				}
			  );
	
		$fp->close;					# close any open files
		
		my $fh = $fp->open($date); 
		for ($count = 0; $count < $to; ) {
			my @in = ();
			if ($fh) {
				while (<$fh>) {
					chomp;
					push @in, [ split '\^' ] if length > 2;
				}
				eval $eval;			# do the search on this file
				return ("Geomag search error", $@) if $@;
				last if $count >= $to; # stop after n
			}
			$fh = $fp->openprev();	# get the next file
			last if !$fh;
		}
	}
	
	return @out;
}

#
# the standard log printing interpreting routine.
#
# every line that is printed should call this routine to be actually visualised
#
# Don't really know whether this is the correct place to put this stuff, but where
# else is correct?
#
# I get a reference to an array of items
#
sub print_item
{
	my $r = shift;
	my @ref = @$r;
	my $d = cldate($ref[1]);
	my ($t) = (gmtime($ref[1]))[2];
	
	return sprintf("$d   %02d %5d %3d %3d %-37s <%s>", $t, $ref[2], $ref[3], $ref[4], $ref[5], $ref[0]);
}

#
# read in this month's data
#
sub readfile
{
	my $date = $fp->unixtoj(shift);
	my $fh = $fp->open($date); 
	my @spots = ();
	my @in;
	
	if ($fh) {
		while (<$fh>) {
			chomp;
			push @in, [ split '\^' ] if length > 2;
		}
	}
	return @in;
}

# enter the spot for dup checking and return true if it is already a dup
sub dup
{
	my ($d, $sfi, $k, $a, $text, $call) = @_; 

	# dump if too old
	return 2 if $d < $main::systime - $dupage;
 
	my $dupkey = "W$d|$sfi|$k|$a|$call";
	return DXDupe::check_add($dupkey, $main::systime+$dupage);
}

sub listdups
{
	return DXDupe::listdups('W', $dupage, @_);
}
1;
__END__;

