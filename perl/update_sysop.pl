#!/usr/bin/env perl
#
# remove all records with the sysop/cluster callsign and recreate
# it from the information contained in DXVars
#
# WARNING - this must be run when the cluster.pl is down!
#
# This WILL NOT delete an old sysop call if you are simply
# changing the callsign.
#
# Copyright (c) 1998 Dirk Koopman G1TLH
#
#
# 

# make sure that modules are searched in the order local then perl
BEGIN {
	# root of directory tree for this system
	$root = "/spider"; 
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};

    unshift @INC, "$root/perl"; # this IS the right way round!
	unshift @INC, "$root/local";
}

use DXVars;
use SysVar;
use DXUser;
use DXUtil;

sub create_it
{
	my $ref;
	
	if ($ref = DXUser::get(uc $mycall)) {
		print "old call $mycall deleted\n";
		$ref->del();
	}
	
	my $self = DXUser->new(uc $mycall);
	$self->{alias} = uc $myalias;
	$self->{name} = $myname;
	$self->{qth} = $myqth;
	$self->{qra} = uc $mylocator;
	$self->{lat} = $mylatitude;
	$self->{long} = $mylongitude;
	$self->{email} = $myemail;
	$self->{bbsaddr} = $mybbsaddr;
	$self->{homenode} = uc $mycall;
	$self->{sort} = 'S';		# C - Console user, S - Spider cluster, A - AK1A, U - User, B - BBS
	$self->{priv} = 9;			# 0 - 9 - with 9 being the highest
	$self->{lastin} = time;
	$self->{dxok} = 1;
	$self->{annok} = 1;

	# write it away
	$self->close();
	print "new call $mycall added\n";

	# now do one for the alias
	if ($ref = DXUser::get($myalias)) {
		print "old call $myalias deleted\n";
		$ref->del();
	}

	$self = DXUser->new(uc $myalias);
	$self->{name} = $myname;
	$self->{qth} = $myqth;
	$self->{qra} = uc $mylocator;
	$self->{lat} = $mylatitude;
	$self->{long} = $mylongitude;
	$self->{email} = $myemail;
	$self->{bbsaddr} = $mybbsaddr;
	$self->{homenode} = uc $mycall;
	$self->{sort} = 'U';		# C - Console user, S - Spider cluster, A - AK1A, U - User, B - BBS
	$self->{priv} = 9;			# 0 - 9 - with 9 being the highest
	$self->{lastin} = time;
	$self->{dxok} = 1;
	$self->{annok} = 1;
	$self->{lang} = 'en';
	$self->{group} = [qw(local #9000)];
  
	# write it away
	$self->close();
	print "new call $myalias added\n";

}

die "\$myalias \& \$mycall are the same ($mycall)!, they must be different (hint: make \$mycall = '${mycall}-2';).\n" if $mycall eq $myalias;

$lockfn = "$main::local_data/cluster.lck";       # lock file name (now in local d
if (-e $lockfn) {
	open(CLLOCK, "$lockfn") or die "Can't open Lockfile ($lockfn) $!";
	my $pid = <CLLOCK>;
	chomp $pid;
	die "Sorry, Lockfile ($lockfn) and process $pid exist, a cluster is running\n" if kill 0, $pid;
	close CLLOCK;
}

DXUser::init();
create_it();
DXUser::finish();
print "Update of $myalias on cluster $mycall successful\n";
exit(0);

