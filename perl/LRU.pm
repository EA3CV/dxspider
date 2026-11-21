#
# A class implimenting LRU sematics with hash look up
#
# Copyright (c) 2002 Dirk Koopman, Tobit Computer Co Ltd 
#
#
#
# The structure of the objects stored are:-
#
#  [next, prev, obj, callsign]
#
# The structure of the base is:-
#
#  [next, prev, max objects, count ]
#
#

package LRU;


use strict;
use Chain;
use DXVars;
use DXDebug;
use DXUtil;
use DXLog;

use vars qw(@ISA);
@ISA = qw(Chain);

use constant OBJ => 2;
use constant MAX => 3;
use constant INUSE => 4;
use constant NAME => 5;
use constant CALLBACK => 6;

sub newbase
{
	my $pkg = shift;
	my $name = shift;
	my $max = shift;
	my $callback = shift;
	confess "LRU->newbase requires a name and maximal count" unless $name && $max;
	return $pkg->SUPER::new({ }, $max, 0, $name, $callback);
}

sub get
{
	my ($self, $call) = @_;
	$call = "$call" ;
	
	if (my $p = $self->obj->{$call}) {
		dbg("LRU $self->[NAME] cache hit $call") if isdbg('lru');
		$self->rechain($p);
		return $p->obj;
	}
	return undef;
}

sub put
{
	my ($self, $call,$ref) = @_;
	confess("need a call and a reference") unless defined $call && $ref;
	$call = "$call" ;
	
	my $p = $self->obj->{$call};
	if ($p) {
		# update the reference and rechain it
		dbg("LRU $self->[NAME] cache update $call") if isdbg('lru');
		$p->obj($ref);
		$self->rechain($p);
	} else {
		# delete one of the end of the chain if required
		while ($self->[INUSE] >= $self->[MAX] ) {
			$p = $self->prev;
			my $call = $p->[MAX];
			dbg("LRU $self->[NAME] cache LRUed out $call now $self->[INUSE]/$self->[MAX]") if isdbg('lru');
			$self->remove($call);
		}

		# add a new one
		dbg("LRU $self->[NAME] cache add $call now $self->[INUSE]/$self->[MAX]") if isdbg('lru');
		$p = $self->new($ref, $call);
		$self->add($p);
		$self->obj->{$call} = $p;
		$self->[INUSE]++;
	}
}

sub remove
{
	my ($self, $call) = @_;
	$call = "$call";
	
	my $p = $self->obj->{$call};
	if ($p) {
		dbg("LRU $self->[NAME] cache remove $call now $self->[INUSE]/$self->[MAX]") if isdbg('lru');
		&{$self->[CALLBACK]}($p->obj) if $self->[CALLBACK];        # call back if required
		$p->obj(1);
		$p->SUPER::del;
		delete $self->obj->{$call} ;
		$self->[INUSE]--;
	} else {
		LogDbg("lru","LRU $call is already removed") if $call;
	}
}

sub count
{
	return $_[0]->[INUSE];
}

1;
