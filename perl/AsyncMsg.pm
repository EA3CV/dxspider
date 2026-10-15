#
# This class is the internal subclass that does various Async connects and
# retreivals of info. Typical uses (and specific support) include http get and
# post.
# 
# This merely starts up a Msg handler (and no DXChannel) ($conn in other words)
# does the GET, parses out the result and the data and then (assuming a positive
# result and that the originating callsign is still online) punts out the data
# to the caller.
#
# It isn't designed to be very clever.
#
# Copyright (c) 2013 - Dirk Koopman G1TLH
#

package AsyncMsg;

use Msg;
use DXDebug;
use DXUtil;
use DXChannel;

use vars qw(@ISA $deftimeout);

@ISA = qw(Msg);
$deftimeout = 15;

my %outstanding;

sub new 
{
	my $pkg = shift;
	my $call = shift;
	my $handler = shift;
	my $actor = ref($call) && $call->isa('Web::Actor') ? $call : undef;
	
	my $conn = $pkg->SUPER::new($handler);
	$conn->{caller} = ref $call ? $call->call : $call;
	$conn->{web_actor} = $actor if $actor;

	# make it persistent
	$outstanding{$conn} = $conn;
	
	return $conn;
}

sub handle_getpost
{
	my ($conn, $ua, $tx) = @_;

	# no point in going on if there is no-one wanting the output anymore
	my $dxchan = $conn->{web_actor} || DXChannel::get($conn->{caller});
	unless ($dxchan && !$dxchan->{_disconnected}) {
		$conn->disconnect;
		return;
	}
	
	my @lines = split qr{\r?\n}, $tx->res->body;
	
	foreach my $msg(@lines) {
		dbg("AsyncMsg: $conn->{_asstate} $msg") if isdbg('async');
		
		if (my $filter = $conn->{_asfilter}) {
			no strict 'refs';
			# this will crash if the command has been redefined and the filter is a
			# function defined there whilst the request is in flight,
			# but this isn't exactly likely in a production environment.
			$filter->($conn, $msg, $dxchan);
		} else {
			my $prefix = $conn->{prefix} || '';
			$dxchan->send("$prefix$msg");
		}
	}
	
	$conn->disconnect;
}

# This does a http get on a path on a host and
# returns the result (through an optional filter)
#
# expects to be called something like from a cmd.pl file:
#
# AsyncMsg->get($self, <host>, <port>, <path>, [<key=>value>...]
# 
# Standard key => value pairs are:
#
# filter => CODE ref (e.g. sub { ... })
# prefix => <string>                 prefix output with this string
#
# Anything else is taken and sent as (extra) http header stuff e.g:
#
# 'User-Agent' => qq{DXSpider;$main::version;$main::build;$^O}
# 'Content-Type' => q{text/xml; charset=utf-8}
# 'Content-Length' => $lth
#
# Host: is always set to the name of the host (unless overridden)
# User-Agent: is set to default above (unless overridden)
#
sub _getpost
{
	my $pkg = shift;
	my $sort = shift;
	my $call = shift;
	my $host = shift;
	my $path = shift;
	my %args = @_;
	

	my $conn = $pkg->new($call);
	if ($conn->{web_actor}) {
		$conn->{web_actor}{_async_pending}++;
	}
	$conn->{_asargs} = [@_];
	$conn->{_asstate} = 'waitreply';
	$conn->{_asfilter} = delete $args{filter} if exists $args{filter};
	$conn->{prefix} = delete $args{prefix} if exists $args{prefix};
	$conn->{prefix} ||= '';
	$conn->{on_disconnect} = delete $args{on_disc} || delete $args{on_disconnect};
	$conn->{path} = $path;
	$conn->{host} = $conn->{peerhost} = $host;
	$conn->{port} = $conn->{peerport} = delete $args{port} || 80;
	$conn->{sort} = 'outgoing';
	$conn->{_assort} = $sort;
	$conn->{csort} = 'http';

	my $data = delete $args{data};

	my $ua =  Mojo::UserAgent->new;
	my $s;
	$s .= $host;
	$s .= ":$port" unless $conn->{port} == 80;
	$s .= $path;
	dbg("AsyncMsg: $sort $s") if isdbg('async');
	
	my $tx = $ua->build_tx($sort => $s);
	$ua->on(error => sub { $conn->_error(@_); });
#	$tx->on(error => sub { $conn->_error(@_); });
#	$tx->on(finish => sub { $conn->disconnect; });

	$ua->on(start => sub {
				my ($ua, $tx) = @_;
				while (my ($k, $v) = each %args) {
					dbg("AsyncMsg: attaching header $k: $v") if isdbg('async');
					$tx->req->headers->header($k => $v);
				}
				if (defined $data) {
					dbg("AsyncMsg: body ='$data'") if isdbg('async'); 
					$tx->req->body($data);
				}
			});
	

	$ua->start($tx => sub { $conn->handle_getpost(@_) }); 

	
	$conn->{mojo} = $ua;
	return $conn if $tx;

	$conn->disconnect;
	return undef;
}

sub _dxchan_send
{
	my $conn = shift;
	my $msg = shift;
	my $dxchan = $conn->{web_actor} || DXChannel::get($conn->{caller});
	$dxchan->send($msg) if $dxchan && !$dxchan->{_disconnected};
}

sub _error
{
	my ($conn, $ua, $err) = @_;
	$err = "HTTP request failed" unless defined $err && length $err;
	dbg("AsyncMsg: $conn->{host}:$conn->{port} path $conn->{path} error $err") if isdbg('async');
	$conn->_dxchan_send("$conn->{prefix}$err");
	$conn->disconnect;
}
	
sub get
{
	my $pkg = shift;
	_getpost($pkg, "GET", @_);
}

sub post
{
	my $pkg = shift;
	_getpost($pkg, "POST", @_);
}

# do a raw connection
#
# Async->raw($self, <host>, <port>, [handler => CODE ref], [prefix => <string>]);
#
# With no handler defined, everything sent by the connection will be sent to
# the caller.
#
# One can send stuff out on the connection by doing a standard "$conn->send_later(...)" 
# inside the (custom) handler.

sub raw
{
	my $pkg = shift;
	my $call = shift;
	my $host = shift;
	my $port = shift;

	my %args = @_;

	my $handler = delete $args{handler} || \&handle_raw;
	
	my $conn = $pkg->new($call, $handler);
	$conn->{prefix} = delete $args{prefix} if exists $args{prefix};
	$conn->{prefix} ||= '';
	$conn->{on_disconnect} = delete $args{on_disc} || delete $args{on_disconnect};
	$r = $conn->connect($host, $port, on_connect => &_on_raw_connect);
	return $r ? $conn : undef;
}

# 
# simple raw handler
#
# Just outputs everything
#
sub handle_raw
{
	my $conn = shift;
	my $msg = shift;

	# no point in going on if there is no-one wanting the output anymore
	my $dxchan = DXChannel::get($conn->{caller});
	unless ($dxchan) {
		$conn->disconnect;
		return;
	}

	# send out the data
	$dxchan->send("$conn->{prefix}$msg");
}


sub _on_raw_connect
{
	my $conn = shift;
	my $handle = shift;
	dbg("AsyncMsg: Connected $conn->{cnum} to $conn->{host}:$conn->{port}") if isdbg('async');
}

sub _on_error
{
	my $conn = shift;
	my $msg = shift;
	dbg("AsyncMsg: ***Connect $conn->{cnum} Failed to $conn->{host}:$conn->{port} $!") if isdbg('async');	
}

sub connect
{
	my $conn = shift;
	my $host = shift;
	my $port = shift;
	
	# start a connection
	my $r = $conn->SUPER::connect($host, $port, @_);

	return $r;
}

sub disconnect
{
	my $conn = shift;
	return if $conn->{_asyncmsg_closed}++;
	my $actor = delete $conn->{web_actor};

	if (my $ondisc = $conn->{on_disconnect}) {
		my $dxchan = DXChannel::get($conn->{caller});
		if ($dxchan) {
			no strict 'refs';
			$ondisc->($conn, $dxchan);
			delete $conn->{on_disconnect};
		}
	}
	delete $conn->{mojo};
	delete $outstanding{$conn};
	$conn->SUPER::disconnect;
	$actor->_async_finished if $actor;
}

sub _send_later
{
	my $conn = shift;
	my $m = shift;
	
	if (isdbg('async')) {
		my $s = $m;
		$s =~ s/([\%\x00-\x1f\x7f-\xff])/sprintf("%%%02X", ord($1))/eg;
		dbg("AsyncMsg: send $s");
	}
	$conn->send_later($m);
}

sub DESTROY
{
	my $conn = shift;
	delete $outstanding{$conn};
	$conn->SUPER::DESTROY;
}

1;

