#
# DXSpider - The Web Interface Helper Routines
#
# Copyright (c) 2015-2026 Dirk Koopman G1TLH
#
# This is a 

use strict;

package Web;

use DXDebug;
use DXChannel;
use DXLog;

require Exporter;
our @ISA = qw(DXCommandmode Exporter);
our @EXPORT = qw(is_webcall find_next_webcall);

our $maxssid = 64;				# the maximum number of bare @WEB connections we will allow - this is really to stop runaway connections from the dxweb app

sub is_webcall
{
	return $_[0] =~ /^\#WEB/;
}

sub find_next_webcall
{
	foreach my $i (1 .. $maxssid) {
		next if DXChannel::get("\#WEB-$i");
		return "\#WEB-$i";
	}
	return undef;
}

sub new 
{
	my $self = (@_);
	
	return $self;
}

sub disconnect
{
	my $self = shift;
	my $call = $self->call;
	
	return if $self->{disconnecting}++;

	delete $self->{senddbg};
	
	LogDbg('DXCommand', "Web $call disconnected");

	# this done to avoid any routing or remembering of unwanted stuff
	DXChannel::disconnect($self);
}
1;
