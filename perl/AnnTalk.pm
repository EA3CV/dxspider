#
# Announce and Talk Handling routines
#
# Copyright (c) 2000 Dirk Koopman
#
#
#

package AnnTalk;

use strict;

use DXVars;
use DXUtil;
use DXDebug;
use DXDupe;
use DXLog;
use DXLogPrint;
use Time::HiRes qw(gettimeofday tv_interval);

use vars qw(%dup $duplth $dupage $filterdef);

$duplth = 30;					# the length of text to use in the deduping
$dupage = 18*3600;				# the length of time to hold ann dups
$filterdef = bless ([
			  # tag, sort, field, priv, special parser 
			  ['by', 'c', 0],
			  ['dest', 'c', 1],
			  ['info', 't', 2],
			  ['group', 't', 3],
			  ['origin', 'c', 4],
			  ['wx', 't', 5],
			  ['channel', 'c', 6],
			  ['by_dxcc', 'nc', 7],
			  ['by_itu', 'ni', 8],
			  ['by_zone', 'nz', 9],
			  ['origin_dxcc', 'nc', 10],
			  ['origin_itu', 'ni', 11],
			  ['origin_zone', 'nz', 12],
			  ['by_state', 'nz', 13],
			  ['origin_state', 'nz', 14],
		   ], 'Filter::Cmd');

our $maxcache = 130;
our @anncache;

sub init
{
	my $t0 = [gettimeofday];
	@anncache = DXLog::search(0, $maxcache, $main::systime, 'ann');
	shift @anncache while @anncache > $maxcache;
	my $l = @anncache;
	dbg("AnnTalk: loaded last $l announcements into cache in " . _diffms($t0) . "mS");
}

sub add_anncache
{
	push @anncache, [ $main::systime, @_ ];
	shift @anncache while @anncache > $maxcache;
}

# enter the spot for dup checking and return true if it is already a dup
sub dup
{
	my ($call, $to, $text, $t) = @_; 

	$t ||= $main::systime + $dupage;
	chomp $text;
	unpad($text);
	$text =~ s/\%([0-9A-F][0-9A-F])/chr(hex($1))/eg;
#	$text = Encode::encode("iso-8859-1", $text) if $main::can_encode && Encode::is_utf8($text, 1);
	$text =~ s/[^\#a-zA-Z0-9]//g;
	$text = substr($text, 0, $duplth) if length $text > $duplth; 
	my $dupkey = "A$call|$to|\L$text";
	return DXDupe::check_add($dupkey, $t);
}

sub listdups
{
	return DXDupe::listdups('A', $dupage, @_);
}

# is this text field a likely announce to talk substitution?
# this may involve all sorts of language dependant heuristics, but 
# then again, it might not
sub is_talk_candidate
{
	my ($from, $text) = @_;
	my $call;

	($call) = $text =~ /^\s*(?:[Xx]|[Tt][Oo]?:?)\s+([\w-]+)/;
	($call) = $text =~ /^\s*>\s*([\w-]+)\b/ unless $call;
	($call) = $text =~ /^\s*([\w-]+):?\b/ unless $call;
	if ($call) {
		$call = uc $call;
		return is_callsign($call);
	}
    return undef;
}
1; 

