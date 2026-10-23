#
# User routing routines
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
#
# 

package Route::User;

use DXDebug;
use Route;
use DXUtil;
use DXJSON;
use Time::HiRes qw(gettimeofday);

use strict;

use vars qw(%list %valid @ISA $max $filterdef);
@ISA = qw(Route);

$filterdef = $Route::filterdef;
%list = ();
$max = 0;

our $cachefn = localdata('route_user_cache');

sub count
{
	my $n = scalar(keys %list);
	$max = $n if $n > $max;
	return $n;
}

sub max
{
	count();
	return $max;
}

sub new
{
	my $pkg = shift;
	my $call = uc shift;
	my $ncall = uc shift;
	my $flags = shift;
	my $ip = shift;

	confess "already have $call in $pkg" if $list{$call};
	
	my $self = $pkg->SUPER::new($call);
	$self->{parent} = [ $ncall ];
	$self->{flags} = $flags || Route::here(1);
	$self->{ip} = $ip if defined $ip;
	$list{$call} = $self;
	dbg("CLUSTER: user $call added") if isdbg('cluster');

	return $self;
}

sub get_all
{
	return values %list;
}

sub get_all_keys
{
	return keys %list;
}

sub del
{
	my $self = shift;
	my $pref = shift;
	my $call = $self->{call};
	$self->delparent($pref);
	unless (@{$self->{parent}}) {
		delete $list{$call};
		dbg("CLUSTER: user $call deleted") if isdbg('cluster');
		return $self;
	}
	return undef;
}

sub get
{
	my $call = shift;
	$call = shift if ref $call;
	my $ref = $list{uc $call};
	dbg("Failed to get User $call" ) if !$ref && isdbg('routerr');
	return $ref;
}

sub addparent
{
	my $self = shift;
    return $self->_addlist('parent', @_);
}

sub delparent
{
	my $self = shift;
    return $self->_dellist('parent', @_);
}

sub TO_JSON { return { %{ shift() } }; }

sub write_cache
{
	my $json = DXJSON->new;
	$json->canonical(isdbg('routecache')||0);
	
	my $ta = [ gettimeofday ];
	my @s;
	eval {
		while (my ($k, $v) = each  %list) {
		    push @s, "$k:" . $json->encode($v) . "\n";
	    }
	};
	if (!$@ && @s) {
		my $fh = IO::File->new(">$cachefn") or dbg("Route::User: ERROR writing $cachefn $!"), return;
		print $fh $_ for (sort @s);
		$fh->close;
	} else {
		dbg("Route::User::write_cache error '$@'");
		return;
	}
	my $diff = _diffms($ta);
	dbg("Route::User::write_cache time to write: $diff mS");
}

sub read_cache
{
	my $json = DXJSON->new;
	$json->canonical(isdbg('routecache'));
	
	my $ta = [ gettimeofday ];
	my $count;
	
	my $fh = IO::File->new("$cachefn") or dbg("Route::User: ERROR reading $cachefn $!"), return;
	while (my $l = <$fh>) {
		chomp $l;
		my ($k, $v) = split /:/, $l, 2;
		$list{$k} = bless $json->decode($v) or dbg("Route::User: Error json error $! decoding '$v'"), next;
		++$count;
	}
	$fh->close if $fh;

	my $diff = _diffms($ta);
	dbg("Route::User::read_cache time to read $count records from $cachefn : $diff mS");
}

#
# generic AUTOLOAD for accessors
#

sub AUTOLOAD
{
	no strict;
	my ($pkg,$name) = $AUTOLOAD =~ /^(.*)::(\w+)$/;
	return if $name eq 'DESTROY';
  
	confess "Non-existant field '$AUTOLOAD'" unless $valid{$name} || $Route::valid{$name};

	# this clever line of code creates a subroutine which takes over from autoload
	# from OO Perl - Conway
	*$AUTOLOAD = sub {$_[0]->{$name} = $_[1] if @_ > 1; return $_[0]->{$name}};
	goto &$AUTOLOAD;	
#	*{"${pkg}::$name"} = sub {$_[0]->{$name} = $_[1] if @_ > 1; return $_[0]->{$name}};
#	goto &{"${pkg}::$name"};	
}

1;
