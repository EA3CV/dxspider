#
# prefix handling
#
# Copyright (c) - Dirk Koopman G1TLH
#
#
#

package Prefix;

use IO::File;
use DXVars;
use DB_File;
use Data::Dumper;
use DXDebug;
use DXUtil;
use USDB;
use LRU;
use DXBearing;

use strict;

use vars qw($db %prefix_loc %pre $lru $lrusize $misses $hits $matchtotal);

$db = undef;					# the DB_File handle
%prefix_loc = ();				# the meat of the info
%pre = ();						# the prefix list
$hits = $misses = $matchtotal = 1;		# cache stats
$lrusize = 5000;				# size of prefix LRU cache

sub init
{
	my $r = load();
	return $r if $r;

	# fix up the node's default country codes
	unless (@main::my_cc) {
		push @main::my_cc, (61..67) if $main::mycall =~ /^GB/;
		push @main::my_cc, qw(EA EA6 EA8 EA9) if $main::mycall =~ /^E[ABCD]/;
		push @main::my_cc, qw(I IT IS) if $main::mycall =~ /^I/;
		push @main::my_cc, qw(SV SV5 SV9) if $main::mycall =~ /^SV/;

		# catchall
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

sub load
{
	# untie every thing
	if ($db) {
		undef $db;
		untie %pre;
		%pre = ();
		%prefix_loc = ();
		$lru->close if $lru;
		undef $lru;
	}

	# tie the main prefix database
	eval {$db = tie(%pre, "DB_File", undef, O_RDWR|O_CREAT, 0664, $DB_BTREE);};
	my $out = "$@($!)" if !$db || $@ ;
	my $fn = localdata("prefix_data.pl");
	die "Prefix.pm: cannot find $fn, have you run /spider/perl/create_prefix.pl?" unless -e $fn;
	
	eval {do $fn if !$out; };
	$out .= $@ if $@;
	$lru = LRU->newbase('Prefix', $lrusize);

 	return $out;
}

sub loaded
{
	return $db;
}


# what you get is a list that looks like:-
# 
# prefix => @list of blessed references to prefix_locs 
#
# This routine will only do what you ask for, if you wish to be intelligent
# then that is YOUR problem!
#

sub get
{
	my $key = shift;
	my $ref;
	my $gotkey = $key;
	return () if $db->seq($gotkey, $ref, R_CURSOR);
	return () if $key ne substr $gotkey, 0, length $key;

	return ($gotkey,  map { $prefix_loc{$_} } split ',', $ref);
}

#
# get the next key that matches, this assumes that you have done a 'get' first
#
# 
sub next
{
	my $key = shift;
	my $ref;
	my $gotkey;
  
	return () if $db->seq($gotkey, $ref, R_NEXT);
	return () if $key ne substr $gotkey, 0, length $key;
  
	return ($gotkey,  map { $prefix_loc{$_} } split ',', $ref);
}

#
# put the key LRU incluing the city state info
#

sub lru_put
{
	my ($call, $ref) = @_;
	$call =~ s/^=//;
	my @s = USDB::get($call);
	
	if (@s) {
		# this is deep magic, because this is a reference to static data, it
        # must be copied.
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

# 
# search for the nearest match of a prefix string (starting
# from the RH end of the string passed)
#

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
			my @out = get($s);
			if (isdbg('prefix')) {
				my $part = $out[0] || "*";
				$part .= '*' unless $part eq '*' || $part eq $s;
				dbg("Partial prefix: $pref $s $part" );
			} 
			if (@out && $out[0] eq $s) {
				return @out;
			} 
		}
	}
	return ();
}

#
# extract a 'prefix' from a callsign, in other words the largest entity that will
# obtain a result from the prefix table.
#
# This is done by repeated probing, callsigns of the type VO1/G1TLH or
# G1TLH/VO1 (should) return VO1
#

sub extract
{
	my $calls = uc shift;
	my @out;
	my $p;
	my @parts;
	my ($call, $sp, $i);

LM:	foreach $call (split /,/, $calls) {

		$matchtotal++;
		$call =~ s/-\d+$//;		# ignore SSIDs
		my @nout;
		my $ecall = "=$call";

		# first check if this is a call (by prefixing it with an = sign)
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

		# then check if the whole thing succeeds either because it is cached
		# or because it simply is a stored prefix as callsign (or even a prefix)
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

		# is it in the USDB, force a matchprefix to match?
		my @s = USDB::get($call);
		if (@s) {
			@nout = get($call);
			@nout = matchprefix($call) unless @nout;
			$nout[0] = $ecall if @nout;
		} else {

			# try a straight get for an exact callsign
			@nout = get($ecall);
		}

		# now store the exact prefix if it has been found
		if (@nout && $nout[0] eq $ecall) {
			$misses++;
			$nout[0] = $call;
			lru_put("=$call", \@nout);
			dbg("got exact prefix: $nout[0]") if isdbg('prefix');
			push @out, @nout;
			next;
		}

		# now try a non-exact call/prefix
		if ((@nout = get($call)) && $nout[0] eq $call) {
			$misses++;
			lru_put($call, \@nout);
			dbg("got exact prefix: $nout[0]") if isdbg('prefix');
			push @out, @nout;
			next;
		}

		# now split the call into parts if required
		@parts = ($call =~ '/') ? split('/', $call) : ($call);
		dbg("Parts: $call = " . join(' ', @parts))	if isdbg('prefix');

		# remove any /0-9 /P /A /M /MM /AM suffixes etc
		if (@parts > 1) {
			pop @parts if $parts[-1] =~ /^(?:[PABM]|AM|MM|BCN|JOTA|SIX|WEB|NET|Q\w+)$/;

			# can we resolve them by direct lookup
			my $s = join('/', @parts); 
			@nout = get($s);
			if (@nout && $nout[0] eq $s) {
				dbg("got exact multipart prefix: $call $s") if isdbg('prefix');
				$misses++;
				lru_put($call, \@nout);
				push @out, @nout;
				next;
			}
		}
		dbg("Parts now: $call = " . join(' ', @parts))	if isdbg('prefix');
  
		# at this point we should have two or three parts
		# if it is three parts then join the first and last parts together
		# to get an answer

		# first deal with prefix/x00xx/single letter things
		if (@parts == 3 && length $parts[0] <= length $parts[1]) {
			@nout = matchprefix($parts[0]);
			if (@nout) {
				my $s = join('/', $nout[0], $parts[2]);
				my @try = get($s);
				if (@try && $try[0] eq $s) {
					dbg("got 3 part prefix: $call $s") if isdbg('prefix');
					$misses++;
					lru_put($call, \@try);
					push @out, @try;
					next;
				}
				
				# if the second part is a callsign and the last part is one letter
				if (is_callsign($parts[1]) && length $parts[2] == 1) {
					pop @parts;
				}
			}
		}

		# if it is a two parter 
		if (@parts == 2) {

			# try it as it is as compound, taking the first part as the prefix
			@nout = matchprefix($parts[0]);
			if (@nout) {
				my $s = join('/', $nout[0], $parts[1]);
				my @try = get($s);
				if (@try && $try[0] eq $s) {
					dbg("got 2 part prefix: $call $s") if isdbg('prefix');
					$misses++;
					lru_put($call, \@try);
					push @out, @try;
					next;
				}
			}
		}

		# remove the problematic /J suffix
		pop @parts if @parts > 1 && $parts[$#parts] eq 'J';

		# single parter
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

		# try ALL the parts
        my @checked;
		my $n;
L1:		for ($n = 0; $n < @parts; $n++) {
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
			$sp =~ s/-\d+$//;     # remove any SSID
			
			# now start to resolve it from the right hand end
			@nout = matchprefix($sp);
			
			# try and search for it in the descriptions as
			# a whole callsign if it has multiple parts and the output
			# is more two long, this should catch things like
			# FR5DX/T without having to explicitly stick it into
			# the prefix table.
			
			if (@nout) {
				if (@parts > 1) {
					$parts[$k] = $nout[0];
					my $try = join('/', @parts);
					my @try = get($try);
					if (isdbg('prefix')) {
						my $part = $try[0] || "*";
						$part .= '*' unless $part eq '*' || $part eq $try;
						dbg("Compound prefix: $try $part" );
					}
					if (@try && $try eq $try[0]) {
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

		# we are a pirate!
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

#
# turn a list of prefixes / dxcc numbers into a list of dxcc/itu/zone numbers
#
# nc = dxcc
# ni = itu
# nz = zone
# ns = state
#

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
						my $n = $p->dxcc if $cmd eq 'nc' ;
						$n = $p->itu if $cmd eq 'ni' ;
						$n = $p->cq if $cmd eq 'nz' ;
						$n = $p->state if $cmd eq 'ns';
						push @out, $n unless grep $_ eq $n, @out;
					}
				}
			}			
		}
	}
	return @out;
}

# get the full country data (dxcc, itu, cq, state, city) as a list
# from a callsign. 
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
	# this clever line of code creates a subroutine which takes over from autoload
	# from OO Perl - Conway
	*$AUTOLOAD = sub {@_ > 1 ? $_[0]->{$name} = $_[1] : $_[0]->{$name}} ;
       goto &$AUTOLOAD;
}

#
# return a prompt for a field
#

sub field_prompt
{ 
	my ($self, $ele) = @_;
	return $valid{$ele};
}
1;

__END__
