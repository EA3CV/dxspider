#
#
# This module impliments the abstracted routing for all protocols and
# is probably what I SHOULD have done the first time.
#
# Heyho.
#
# This is just a container class which I expect to subclass
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
#
#

package Route;

use DXDebug;
use DXChannel;
use Prefix;
use DXUtil;

use strict;


use vars qw(%list %valid $filterdef $maxlevel);

%valid = (
		  call => "0,Callsign",
		  city => '0,City',
		  cq => '0,CQ Zone',
		  dxcc => '0,Country Code',
		  flags => "0,Flags,phex",
		  ip => '0,IP Address',
		  itu => '0,ITU Zone',
		  parent => '0,Parent Calls,parray',
		  state => '0,State',
		  lastseen => '0,Last Seen,cldatetime',
		 );

$filterdef = bless ([
			  # tag, sort, field, priv, special parser
			  ['channel', 'c', 0],
			  ['channel_dxcc', 'nc', 1],
			  ['channel_itu', 'ni', 2],
			  ['channel_zone', 'nz', 3],
			  ['call', 'c', 4],
			  ['by', 'c', 4],
			  ['call_dxcc', 'nc', 5],
			  ['by_dxcc', 'nc', 5],
			  ['call_itu', 'ni', 6],
			  ['by_itu', 'ni', 6],
			  ['call_zone', 'nz', 7],
			  ['by_zone', 'nz', 7],
			  ['channel_state', 'ns', 8],
			  ['call_state', 'ns', 9],
			  ['by_state', 'ns', 9],
			 ], 'Filter::Cmd');

$maxlevel = 25;                 # maximum recursion level in Route::config

sub new
{
	my ($pkg, $call) = @_;
	$pkg = ref $pkg if ref $pkg;

	my $self = bless {call => $call}, $pkg;
	dbg("create $pkg with $call") if isdbg('routelow');

	# add in all the dxcc, itu, zone info
	($self->{dxcc}, $self->{itu}, $self->{cq}, $self->{state}, $self->{city}) =
		Prefix::cty_data($call);

	$self->{flags} = here(1);

	return $self;
}

#
# get a callsign from a passed reference or a string
#

sub _getcall
{
	my $self = shift;
	my $thingy = shift;
	$thingy = $self unless $thingy;
	$thingy = $thingy->call if ref $thingy;
	$thingy = uc $thingy if $thingy;
	return $thingy;
}

#
# add and delete a callsign to/from a list
#

sub _addlist
{
	my $self = shift;
	my $field = shift;
	my @out;
	foreach my $c (@_) {
		confess "Need a ref here" unless ref($c);

		my $call = $c->{call};
		unless (grep $_ eq $call, @{$self->{$field}}) {
			push @{$self->{$field}}, $call;
			dbg(ref($self) . " adding $call to " . $self->{call} . "->\{$field\}") if isdbg('routelow');
			push @out, $c;
		}
	}
	return @out;
}

sub _dellist
{
	my $self = shift;
	my $field = shift;
	my @out;
	foreach my $c (@_) {
		confess "Need a ref here" unless ref($c);
		my $call = $c->{call};
		if (grep $_ eq $call, @{$self->{$field}}) {
			$self->{$field} = [ grep {$_ ne $call} @{$self->{$field}} ];
			dbg(ref($self) . " deleting $call from " . $self->{call} . "->\{$field\}") if isdbg('routelow');
			push @out, $c;
		}
	}
	return @out;
}

sub is_empty
{
	my $self = shift;
	return @{$self->{$_[0]}} == 0;
}

#
# flag field constructors/enquirers
#
# These can be called in various ways:-
#
# Route::here or $ref->here returns 1 or 0 depending on value of the here flag
# Route::here(1) returns 2 (the bit value of the here flag)
# $ref->here(1) or $ref->here(0) sets the here flag
#

sub here
{
	my $self = shift;
	my $r = shift;
	return $self ? 2 : 0 unless ref $self;
	return ($self->{flags} & 2) ? 1 : 0 unless defined $r;
	$self->{flags} = (($self->{flags} & ~2) | ($r ? 2 : 0));
	return $r ? 1 : 0;
}

sub conf
{
	my $self = shift;
	my $r = shift;
	return $self ? 1 : 0 unless ref $self;
	return ($self->{flags} & 1) ? 1 : 0 unless defined $r;
	$self->{flags} = (($self->{flags} & ~1) | ($r ? 1 : 0));
	return $r ? 1 : 0;
}

sub parents
{
	my $self = shift;
	return @{$self->{parent}};
}

#
# display routines
#

sub user_call
{
	my $self = shift;
	my $call = sprintf "%s", $self->{call};
	return $self->here ? "$call" : "($call)";
}

sub config
{
	my $self = shift;
	my $nodes_only = shift || 0;
	my $width = shift || 79;
	my $level = shift;
	my $seen = shift;
	my @out;
	my $line;
	my $call = $self->{call};
	my $printit = 1;

	dbg("config: $call nodes: $nodes_only level: $level calls: " . join(',', @_)) if isdbg('routec');

	# allow ranges
	if (@_) {
		$printit = grep $call =~ m|$_|, @_;
	}

	if ($printit) {
		my $pcall = $self->user_call;
		$pcall .= ":" . $self->obscount if isdbg('obscount');


		$line = ' ' x ($level*2) . $pcall;
		$pcall = ' ' x length $pcall;

		# recursion detector
		if ((DXChannel::get($call) && $level > 1) || $seen->{$call} || $level > $maxlevel) {
			$line .= ' ...';
			push @out, $line;
			return @out;
		}
		$seen->{$call}++;

		# print users
		unless ($nodes_only) {
			if (@{$self->{users}}) {
				$line .= '->';
				foreach my $ucall (sort @{$self->{users}}) {
					my $uref = Route::User::get($ucall);
					my $c;
					if ($uref) {
						$c = $uref->user_call;
					}
					else {
						$c = "$ucall?";
					}
					if ((length $line) + (length $c) + 1 < $width) {
						$line .= $c . ' ';
					}
					else {
						$line =~ s/\s+$//;
						push @out, $line;
						$line = ' ' x ($level*2) . "$pcall->$c ";
					}
				}
			}
		}
		$line =~ s/->$//g;
		$line =~ s/\s+$//;
		push @out, $line if length $line;
	}
	else {
		# recursion detector
		if ((DXChannel::get($call) && $level > 1) || $seen->{$call} || $level > $maxlevel) {
			return @out;
		}
		$seen->{$call}++;
	}

	# deal with more nodes
	foreach my $ncall (sort @{$self->{nodes}}) {
		my $nref = Route::Node::get($ncall);

		if ($nref) {
			my $c = $nref->user_call;
			dbg("recursing from $call -> $c") if isdbg('routec');
			my @rout = $nref->config($nodes_only, $width, $level+1, $seen, @_);
			if (@rout && @_) {
				push @out, ' ' x ($level*2) . $self->user_call unless grep /^\s+$call/, @out;
			}
			push @out, @rout;
		} else {
			push @out, ' ' x (($level+1)*2)  . "$ncall?" if @_ == 0 || (@_ && grep $ncall =~ m|$_|, @_);
		}
	}

	return @out;
}

sub cluster
{
	my $nodes = Route::Node::count();
	my $tot = Route::User::count();
	my ($users, $maxlocalusers) = DXCommandmode::user_count(); # the user count is wrong because of skimmers
	my $maxusers = Route::User::max();
	my $uptime = main::uptime();
	my $localnodes = $DXChannel::count - $users;   # this is now wrong because of skimmers
	
	return ($nodes, $tot, $users, $maxlocalusers, $maxusers, $uptime, $localnodes);
	

}

#
# routing things
#

sub get
{
	my $call = shift;
	return Route::Node::get($call) || Route::User::get($call);
}

sub findroutes
{
	my $call = shift;
	my %cand;
	my @out;

	dbg("ROUTE: findroutes $call") if isdbg('findroutes');

	my $nref = Route::get($call);
	return () unless $nref;

	# we are directly connected, force "best possible" priority, but
	# carry on in case user is connected on other nodes.
	my $dxchan = DXChannel::get($call);
	if ($dxchan) {
		dbg("ROUTE: findroutes $call -> directly connected") if isdbg('findroutes');
		$cand{$call} = 99;
	}

	# obtain the dxchannels that have seen this thingy
	my @parent = $nref->isa('Route::User') ? @{$nref->{parent}} : $call;
	foreach my $p (@parent) {
		next if $p eq $main::mycall; # this is dealt with above

		# deal with directly connected nodes, again "best priority"
		$dxchan = DXChannel::get($p);
		if ($dxchan) {
			dbg("ROUTE: findroutes $call -> connected direct via parent $p") if isdbg('findroutes');
			$cand{$p} = 99;
			next;
		}

		my $r = Route::Node::get($p);
		if ($r) {
			my %r = $r->PC92C_dxchan;
			while (my ($k, $v) = each %r) {
				$cand{$k} = $v if $v > ($cand{$k} || 0);
			}
		}
	}

	# remove any dxchannels that have gone away
	while (my ($k, $v) = each %cand) {
		if (my $dxc = DXChannel::get($k)) {
			push @out, [$v, $dxc];
		}
	}

	# get a sorted list of dxchannels with the highest hop count first
	my @nout = sort {$b->[0] <=> $a->[0]} @out;
	if (isdbg('findroutes')) {
		if (@nout) {
			for (@nout) {
				dbg("ROUTE: findroutes $call -> $_->[0] " . $_->[1]->call);
			}
		}
	}

	return @nout;
}

# find all the possible dxchannels which this object might be on
sub alldxchan
{
	my $self = shift;
	my @dxchan = findroutes($self->{call});
	return map {$_->[1]} @dxchan;
}

sub dxchan
{
	my $self = shift;

	# ALWAYS return the locally connected channel if present;
	my $dxchan = DXChannel::get($self->call);
	return $dxchan if $dxchan;

	my @dxchan = $self->alldxchan;
	return undef unless @dxchan;

	# dxchannels are now returned in order of "closeness"
	return $dxchan[0];
}

sub delete_interface
{

}

#
# track destruction
#

sub DESTROY
{
	my $self = shift;
	my $pkg = ref $self;

	dbg("$pkg $self->{call} destroyed") if isdbg('routelow');
}

no strict;
#
# return a list of valid elements
#

sub fields
{
	my $pkg = shift;
	$pkg = ref $pkg if ref $pkg;
    my $val = "${pkg}::valid";
	my @out = keys %$val;
	push @out, keys %valid;
	return @out;
}

#
# return a prompt for a field
#

sub field_prompt
{
	my ($self, $ele) = @_;
	my $pkg = ref $self;
    my $val = "${pkg}::valid";
	return $val->{$ele} || $valid{$ele};
}

sub write_cache
{
	Route::Node::write_cache();
	Route::User::write_cache();
}

sub read_cache
{
	Route::Node::read_cache();
	Route::User::read_cache();
}

#
# generic AUTOLOAD for accessors
#
sub AUTOLOAD
{
	no strict;
	my $name = $AUTOLOAD;
	return if $name =~ /::DESTROY$/;
	$name =~ s/^.*:://o;

	confess "Non-existant field '$AUTOLOAD'" if !$valid{$name};

	# this clever line of code creates a subroutine which takes over from autoload
	# from OO Perl - Conway
	*{$AUTOLOAD} = sub {@_ > 1 ? $_[0]->{$name} = $_[1] : $_[0]->{$name}};
       goto &$AUTOLOAD;

}

1;
