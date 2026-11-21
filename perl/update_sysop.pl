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
use DXDebug;

sub _dxcss_member_node
{
    # DXCSS: enable preservation only for a node explicitly configured as a
    # member of this DxCSS cluster. A normal DXSpider installation therefore
    # retains the upstream update_sysop behaviour unchanged.
    return 0 unless defined $main::cluster_id && length $main::cluster_id;
    return 0 unless @main::cluster_nodes;
    my $call = uc($main::mycall || '');
    return scalar grep { uc($_) eq $call } @main::cluster_nodes;
}

sub _dxcss_refresh_existing
{
    my ($self, $is_alias) = @_;

    # DXCSS: refresh only identity/configuration owned by update_sysop/DXVars.
    # Preserve administrative/authentication and runtime state (including
    # lockout, registered, passwd, passphrase, lastin, lastseen and connlist).
    $self->{alias} = uc $myalias unless $is_alias;
    $self->{name} = $myname;
    $self->{qth} = $myqth;
    $self->{qra} = uc $mylocator;
    $self->{lat} = $mylatitude;
    $self->{long} = $mylongitude;
    $self->{email} = $myemail;
    $self->{bbsaddr} = $mybbsaddr;
    $self->{homenode} = uc $mycall;
    $self->{sort} = $is_alias ? 'U' : 'S';
    $self->{priv} = 9;
    $self->put(preserve_lastseen => 1);
}

sub create_it
{
    my $ref;
    my $dxcss = _dxcss_member_node();

    if ($ref = DXUser::get(uc $mycall)) {
        if ($dxcss) {
            # DXCSS: do not delete an existing cluster-member DXUser record.
            _dxcss_refresh_existing($ref, 0);
            dbg "existing call $mycall preserved and refreshed for DxCSS";
        } else {
            dbg "old call $mycall deleted";
            $ref->del();
            $ref = undef;
        }
    }

    unless ($ref && $dxcss) {
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
        $self->{sort} = 'S';
        $self->{priv} = 9;
        $self->{lastin} = time;
        $self->{dxok} = 1;
        $self->{annok} = 1;
        $self->close();
        dbg "new call $mycall added";
    }

    if ($ref = DXUser::get(uc $myalias)) {
        if ($dxcss) {
            # DXCSS: preserve the existing SYSOP alias record as well.
            _dxcss_refresh_existing($ref, 1);
            dbg "existing call $myalias preserved and refreshed for DxCSS";
        } else {
            dbg "old call $myalias deleted";
            $ref->del();
            $ref = undef;
        }
    }

    unless ($ref && $dxcss) {
        my $self = DXUser->new(uc $myalias);
        $self->{name} = $myname;
        $self->{qth} = $myqth;
        $self->{qra} = uc $mylocator;
        $self->{lat} = $mylatitude;
        $self->{long} = $mylongitude;
        $self->{email} = $myemail;
        $self->{bbsaddr} = $mybbsaddr;
        $self->{homenode} = uc $mycall;
        $self->{sort} = 'U';
        $self->{priv} = 9;
        $self->{lastin} = time;
        $self->{dxok} = 1;
        $self->{annok} = 1;
        $self->{lang} = 'en';
        $self->{group} = [qw(local #9000)];
        $self->close();
        dbg "new call $myalias added";
    }
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

dbg "Start update sysop with $myalias on $main::mycall";
dbginit();
DXUser::init();
create_it();
DXUser::finish();
dbg "Update of $myalias on cluster $mycall successful";
dbgclose();
exit(0);
