#
# a class for setting 'bad' (or good) things
#
# This is really a general purpose list handling 
# thingy for determining good or bad objects like
# callsigns. It is for storing things "For Ever".
#
# Things entered into the list are always upper
# cased.
# 
# The files that are created live in /spider/local_data (was data)
# 
# Dunno why I didn't do this earlier but heyho..
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
#
#

package DXHash;

use DXVars;
use DXUtil;
use DXDebug;

use strict;

sub new
{
	my ($pkg, $name) = @_;

	# move existing file
	localdata_mv($name);
	my $s = readfilestr($main::local_data, $name);
	my $self = undef;
	$self = eval $s if $s;
	dbg("error in reading $name in DXHash $@") if $@;
	$self = bless({name => $name}, $pkg) unless defined $self;
	return $self;
}

sub put
{
	my $self = shift;
	writefilestr($main::local_data, $self->{name}, undef, $self);
}

sub add
{
	my $self = shift;
	my $n = uc shift;
	my $t = shift || $main::systime;
	$self->{$n} = $t;

	# also add the base version if it has some ssid on it
	my $nn = $n;
	$nn =~ s|(?:-\d+)?(?:/\w)?$||;
	$self->{$nn} = $t unless exists $self->{$nn} || $n eq $nn;
}

sub del
{
	my $self = shift;
	my $n = uc shift;
	my $exact = shift;
	delete $self->{$n};
	return if $exact;

	my $nn = $n;
	$nn =~ s|(?:-\d+)?(?:/\w)?$||;
	my @ssid = (0..99);
	delete $self->{"$nn-$_"} for @ssid;
}


sub in
{
	my $self = shift;
	my $n = uc shift;
	my $exact = shift;
	
	return 1 if exists $self->{$n};
	return 0 if $exact;
	$n =~ s/-\d+$//;
	return exists $self->{$n};
}

# this is really just a general shortcut for all commands to
# set and unset values 
sub set
{
	my ($self, $priv, $noline, $dxchan, $line) = @_;
	return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
	my @f = split /\s+/, $line;
	return (1, $noline) unless @f;
	my $f;
	my @out;
	
	foreach $f (@f) {

		if ($self->in($f, 1)) {
			push @out, $dxchan->msg('hasha',uc $f, $self->{name});
			next;
		}
		$self->add($f, $main::systime);
		push @out, $dxchan->msg('hashb', uc $f, $self->{name});
	}
	$self->put;
	return (1, @out);
}

# this is really just a general shortcut for all commands to
# set and unset values 
sub unset
{
	my ($self, $priv, $noline, $dxchan, $line) = @_;
	return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
	my @f = split /\s+/, $line;
	return (1, $noline) unless @f;
	my $f;
	my @out;
	
	foreach $f (@f) {

		unless ($self->in($f, 1)) {
			push @out, $dxchan->msg('hashd', uc $f, $self->{name});
			next;
		}
		$self->del($f, 1);
		push @out, $dxchan->msg('hashc', uc $f, $self->{name});
	}
	$self->put;
	return (1, @out);
}

sub show
{
	my ($self, $priv, $dxchan) = @_;
	return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
	
	my @out;
	for (sort keys %{$self}) {
		next if $_ eq 'name';
		push @out, $dxchan->msg('hashe', $_, cldatetime($self->{$_}));
	}
	return (1, @out);
}

1;
