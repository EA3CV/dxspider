#
# This package impliments some of the ak1a aliases that can't
# be done with interpolation from the file names.
#
# Basically it takes the input and bashes down the list of aliases
# for that starting letter until it either matches (in which a substitution
# is done) or fails
#
# To roll your own Aliases, copy the /spider/cmd/Aliases file to 
# /spider/local_cmd and alter it to your taste.
#
# To make it active type 'load/aliases'
#
#
# Copyright (c) 1998 Dirk Koopman G1TLH
#
#
#

package CmdAlias;

use DXVars;
use DXDebug;

use strict;

use vars qw(%alias %newalias $fn $localfn);

%alias = ();
%newalias = ();

$fn = "$main::cmd/Aliases";
$localfn = "$main::localcmd/Aliases";

sub load
{
	my $ref = shift;
	
	do $fn;
	return ($@) if $@ && ref $ref;
	confess $@ if $@;
	if (-e $localfn) {
		my %oldalias = %alias;
		local %alias;    # define a local one
		
		do $localfn;
		return ($@) if $@ && ref $ref;
		confess $@ if $@;
		my $let;
		foreach $let (keys %alias) {
			# stick any local definitions at the front
			my @a;
			push @a, (@{$alias{$let}});
			push @a, (@{$oldalias{$let}}) if exists $oldalias{$let};
			$oldalias{$let} = \@a; 
		}
		%newalias = %oldalias;
	}
	%alias = %newalias if -e $localfn;
	return ();
}

sub init
{
	load();
}

#
# called as CmdAlias::get_cmd("string");
#
sub get_cmd
{
	my $s = shift;
	my ($let) = unpack "A1", $s;
	my ($i, $n, $ref);
	
	$let = lc $let;
	
	$ref = $alias{$let};
	return undef if !$ref;
	
	$n = @{$ref};
	for ($i = 0; $i < $n; $i += 3) {
		if ($s =~ /$ref->[$i]/i) {
			my $ri = qq{\$ro = "$ref->[$i+1]"};
			my $ro;
			eval $ri;
			dbg qq{CmdAlias: s='$s' let='$let', ri='$ri', ro='$ro'} if isdbg 'cmdalias'; 
			return $ro;
		}
	}
	return undef;
}

#
# called as CmdAlias::get_hlp("string");
#
sub get_hlp
{
	my $s = shift;
	my ($let) = unpack "A1", $s;
	my ($i, $n, $ref);
	
	$let = lc $let;
	
	$ref = $alias{$let};
	return undef if !$ref;
	
	$n = @{$ref};
	for ($i = 0; $i < $n; $i += 3) {
		if ($s =~ /$ref->[$i]/i) {
			my $ri = qq{\$ro = "$ref->[$i+2]"};
			my $ro;
			eval $ri;
			return $ro;
		}
	}
	return undef;
}

1;


