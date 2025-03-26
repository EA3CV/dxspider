#
# This has been taken from the 'Advanced Perl Programming' book by Sriram Srinivasan 
#
# I am presuming that the code is distributed on the same basis as perl itself.
#
# I have modified it to suit my devious purposes (Dirk Koopman G1TLH)
#
#
#

package Msg;

use strict;

use DXUtil;

use Mojo::IOLoop;
use Mojo::IOLoop::Stream;

use DXDebug;
use DXTimer;

use vars qw($now %conns $noconns $cnum $total_in $total_out $total_lines_in $total_lines_out $connect_timeout $disc_waittime);

$total_in = $total_out = 0;
$total_lines_in = $total_lines_out = 0;

$now = time;

$cnum = 0;
$connect_timeout = 5;
$disc_waittime = 1.5;

our %delqueue;

#
#-----------------------------------------------------------------
# Generalised initializer

sub new
{
    my ($pkg, $rproc) = @_;
	my $obj = ref($pkg);
	my $class = $obj || $pkg;

    my $conn = {
				rproc => $rproc,
				inqueue => [],
				outqueue => [],
				state => 0,
				lineend => "\r\n",
				csort => 'telnet',
				timeval => 60,
				blocking => 0,
				cnum => (($cnum < 999) ? (++$cnum) : ($cnum = 1)),
				linesin => 0,
				linesout => 0,
				datain => 0,
				dataout => 0,
    };

	$noconns++;
	
	dbg("$class Connection created (total $noconns)") if isdbg('connll');
	return bless $conn, $class;
}

sub set_error
{
	my $conn = shift;
	my $callback = shift;
	$conn->{sock}->on(error => sub {$callback->($_[1]);});
}

sub set_on_eof
{
	my $conn = shift;
	my $callback = shift;
	$conn->{sock}->on(close => sub {$callback->()});
}

sub set_rproc
{
	my $conn = shift;
	my $callback = shift;
	$conn->{rproc} = $callback;
}

# save it
sub conns
{
	my $pkg = shift;
	my $call = shift;
	my $ref;
	
	if (ref $pkg) {
		$call = $pkg->{call} unless $call;
		return undef unless $call;
		dbg((ref $pkg) . " changing $pkg->{call} to $call") if isdbg('connll') && exists $pkg->{call} && $call ne $pkg->{call};
		delete $conns{$pkg->{call}} if exists $pkg->{call} && exists $conns{$pkg->{call}} && $pkg->{call} ne $call; 
		$pkg->{call} = $call;
		$ref = $conns{$call} = $pkg;
		dbg((ref $pkg) . " Connection $pkg->{cnum} $call stored") if isdbg('connll');
	} else {
		$ref = $conns{$call};
	}
	return $ref;
}

# this is only called by any dependent processes going away unexpectedly
sub pid_gone
{
	my ($pkg, $pid) = @_;
	
	my @pid = grep {$_->{pid} == $pid} values %conns;
	foreach my $p (@pid) {
		&{$p->{eproc}}($p, "$pid has gorn") if exists $p->{eproc};
		$p->disconnect;
	}
}

sub ax25
{
	my $conn = shift;
	return $conn->{csort} eq 'ax25';
}

sub peerhost
{
	my $conn = shift;
	unless ($conn->{peerhost}) {
		$conn->{peerhost} ||= 'ax25' if $conn->ax25;
		$conn->{peerhost} ||= $conn->{sock}->handle->peerhost if $conn->{sock};
		$conn->{peerhost} ||= 'UNKNOWN';
	}
	$conn->{peerhost} =~ s/^::ffff://;
	return $conn->{peerhost};
}

sub sockhost
{
	my $conn = shift;
	unless ($conn->{sockhost}) {
		$conn->{sockhost} ||= 'ax25' if $conn->ax25;
		$conn->{sockhost} ||= $conn->{sock}->handle->sockhost if $conn->{sock};
		$conn->{sockhost} ||= 'UNKNOWN';
	}
	$conn->{sockhost} =~ s/^::ffff://;
#	if (! defined $main::localhost_alias_ipv4 && $conn->{sockhost} =~ /\./ && $conn->{sockhost} !~ /^127\./) {
#		$main::localhost_alias_ipv4 = $conn->{sockhost};
#		dbg("Msg: localhost_alias_ipv4 = '$main::localhost_alias_ipv4'");
#	} elsif (! defined $main::localhost_alias_ipv6 && $conn->{sockhost} =~ /:/ && $conn->{sockhost} !~ /^::1$/) {#
#		$main::localhost_alias_ipv6 = $conn->{sockhost};
#		dbg("Msg: localhost_alias_ipv6 = '$main::localhost_alias_ipv6'");
#	}
	return $conn->{sockhost};
}
#-----------------------------------------------------------------
# Send side routines

sub _on_connect
{
	my $conn = shift;
	my $handle = shift;
	undef $conn->{sock};
	my $sock = $conn->{sock} = Mojo::IOLoop::Stream->new($handle);
	$sock->on(read => sub {$conn->_rcv($_[1]);} );
	$sock->on(error => sub {delete $conn->{sock}; $conn->disconnect;});
	$sock->on(close => sub {delete $conn->{sock}; $conn->disconnect;});
	$sock->timeout(0);
	$sock->start;
	$conn->{peerhost} = eval { $handle->peerhost; };
	$conn->{sockhost} = eval { $handle->sockhost; };
	dbg((ref $conn) . " connected $conn->{cnum}:$conn->{sockhost} to $conn->{peerhost}:$conn->{peerport}") if isdbg('conn') || isdbg ('connect');
	if ($conn->{on_connect}) {
		&{$conn->{on_connect}}($conn, $handle);
	}
}

sub is_connected
{
	my $conn = shift;
	my $sock = $conn->{sock};
	return ref $sock && $sock->isa('Mojo::IOLoop::Stream');
}

sub connect {
    my ($pkg, $to_host, $to_port, %args) = @_;
	my $timeout = delete $args{timeout} || $connect_timeout;
	
    # Create a connection end-point object
    my $conn = $pkg;
	unless (ref $pkg) {
		my $rproc = delete $args{rproc}; 
		$conn = $pkg->new($rproc);
	}
	$conn->{peerhost} = $to_host;
	$conn->{peerport} = $to_port;
	$conn->{sort} = 'Outgoing';

	dbg((ref $conn) . " connecting $conn->{cnum} to $to_host:$to_port") if isdbg('connll');
	
	my $sock;
	$conn->{sock} = $sock = Mojo::IOLoop::Client->new;
	$sock->on(connect => sub {
				  $conn->_on_connect($_[1])
			  } );
	$sock->on(error => sub {
				  &{$conn->{eproc}}($conn, $_[1]) if exists $conn->{eproc};
				  delete $conn->{sock};
				  $conn->disconnect
			  });
	$sock->on(close => sub {
				  delete $conn->{sock};
				  $conn->disconnect}
			 );

	# copy any args like on_connect, on_disconnect etc
	while (my ($k, $v) = each %args) {
		$conn->{$k} = $v;
	}
	
	$sock->connect(address => $to_host, port => $to_port, timeout => $timeout);
	
    return $conn;
}

sub start_program
{
	my ($conn, $line, $sort) = @_;
	my $pid;
	
#	local $^F = 10000;		# make sure it ain't closed on exec
#	my ($a, $b) = $io_socket->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC);
#	if ($a && $b) {
#		$a->autoflush(1);
#		$b->autoflush(1);
#		$pid = fork;
#		if (defined $pid) {
#			if ($pid) {
#				close $b;
#				$conn->{sock} = $a;
#				$conn->{csort} = $sort;
#				$conn->{lineend} = "\cM" if $sort eq 'ax25';
#				$conn->{pid} = $pid;
#				if ($conn->{rproc}) {
#					my $callback = sub {$conn->_rcv};
#					Msg::set_event_handler ($a, read => $callback);
#				}
#				dbg("connect $conn->{cnum}: started pid: $conn->{pid} as $line") if isdbg('connect');
#			} else {
#				$^W = 0;
#				dbgclose();
#				STDIN->close;
#				STDOUT->close;
#				STDOUT->close;
#				*STDIN = IO::File->new_from_fd($b, 'r') or die;
#				*STDOUT = IO::File->new_from_fd($b, 'w') or die;
#				*STDERR = IO::File->new_from_fd($b, 'w') or die;
#				close $a;
#				unless ($main::is_win) {
#					#						$SIG{HUP} = 'IGNORE';
#					$SIG{HUP} = $SIG{CHLD} = $SIG{TERM} = $SIG{INT} = 'DEFAULT';
#					alarm(0);
#				}
#				exec "$line" or dbg("exec '$line' failed $!");
#			} 
#		} else {
#			dbg("cannot fork for $line");
#		}
#	} else {
#		dbg("no socket pair $! for $line");
#	}
	return $pid;
}

sub disconnect
{
	my $conn = shift;
	my $count = $conn->{disconnecting}++;
	my $dbg = isdbg('connll');
	my ($pkg, $fn, $line) = caller if $dbg;

	if ($count >= 2) {
		dbgtrace((ref $conn) . "::disconnect on call $conn->{call} attempt $conn->{disconnecting} called from ${pkg}::${fn} line $line FORCING CLOSE ") if $dbg;
		_close_it($conn);
		return;
	}
	dbg((ref $conn) . "::disconnect on call $conn->{call} attempt $conn->{disconnecting} called from ${pkg}::${fn} line $line ") if $dbg;
	return if $count;

	# remove this conn from the active queue
	# be careful to delete the correct one
	my $call;
	if ($call = $conn->{call}) {
		my $ref = $conns{$call};
		delete $conns{$call} if $ref && $ref == $conn;
	}
	$call ||= 'unallocated';

	$delqueue{$conn} = $conn; # save this connection until everything is finished
	my $sock = $conn->{sock};
	if ($sock) {
		if ($sock->{buffer}) {
			my $lth = length $sock->{buffer};
			Mojo::IOLoop->timer($disc_waittime, sub {
									dbg("Buffer contained $lth characters, coordinated for $disc_waittime secs, now disconnecting $call") if $dbg;
									_close_it($conn);
								});
		} else {
			dbg("Buffer empty, just close $call") if $dbg;
			_close_it($conn);
		}
	}
	else {
		dbg((ref $conn) . " socket missing on $conn->{call}") if $dbg;
		_close_it($conn);
	}
}

sub _close_it
{
    my $conn = shift;
    my $sock = delete $conn->{sock};
	$conn->{state} = 'E';
	$conn->{timeout}->del if $conn->{timeout};

	my $call = $conn->{call};

	if (isdbg('connll')) {
		my ($pkg, $fn, $line) = caller;
		dbg((ref $conn) . "::_close_it on call $conn->{call} attempt $conn->{disconnecting} called from ${pkg}::${fn} line $line ");
	}


	dbg((ref $conn) . " Connection $conn->{cnum} $call starting to close") if isdbg('connll');
	
	if ($conn->{on_disconnect}) {
		&{$conn->{on_disconnect}}($conn);
	}

	if ($sock) {
		dbg((ref $conn) . " Connection $conn->{cnum} $call closing gracefully") if isdbg('connll');
		$sock->close_gracefully if $sock->can('close_gracefully');
	}
	
	# get rid of any references
	for (keys %$conn) {
		if (ref($conn->{$_})) {
			delete $conn->{$_};
		}
	}

	delete $delqueue{$conn};	# finally remove the $conn
	
	unless ($main::is_win) {
		kill 'TERM', $conn->{pid} if exists $conn->{pid};
	}
}

sub _send_stuff
{
	my $conn = shift;
	my $rq = $conn->{outqueue};
    my $sock = $conn->{sock};
	return unless defined $sock;
	return if $conn->{disconnecting};
	
	while (@$rq) {
		my $data = shift @$rq;
		my $lth = length $data;
		my $call = $conn->{call} || 'none';
		if (isdbg('raw')) {
			dbgdump('raw', "$call send $lth:", $data);
		}
		if (defined $sock) {
			$sock->write($data);
			$total_out += $lth;
			$conn->{dataout} += $lth;
			++$conn->{linesout};
			++$total_lines_out;
		} else {
			dbg("_send_stuff $call ending data ignored: $data");
		}
	}
}

sub send_now {
    my ($conn, $msg) = @_;
    $conn->enqueue($msg);
    _send_stuff($conn);
}

sub send_later {
	goto &send_now;
}

sub send_raw
{
    my ($conn, $msg) = @_;
	push @{$conn->{outqueue}}, $msg;
	_send_stuff($conn);
}

sub enqueue {
    my $conn = shift;
    push @{$conn->{outqueue}}, defined $_[0] ? $_[0] : '';
}

sub _err_will_block 
{
	return 0;
}

sub close_on_empty
{
	my $conn = shift;
	$conn->{sock}->on(drain => sub {$conn->disconnect;});
}

#-----------------------------------------------------------------
# Receive side routines

sub new_server 
{
#    @_ == 4 || die "Msg->new_server (myhost, myport, login_proc)\n";
	my ($pkg, $my_host, $my_port, $login_proc) = @_;
	my $conn = $pkg->new($login_proc);
	
    my $sock = $conn->{sock} = Mojo::IOLoop::Server->new;
	$sock->on(accept=>sub{$conn->new_client($_[1]);});
	$sock->listen(address=>$my_host, port=>$my_port);
	$sock->start;
	
    die "Could not create socket: $! \n" unless $conn->{sock};
	return $conn;
}


sub nolinger
{
	my $conn = shift;
}

sub dequeue
{
	my $conn = shift;
	return if $conn->{disconnecting};
	
	if ($conn->{msg} =~ /\cJ/) {
		my @lines = split /\cM?\cJ/, $conn->{msg};
		if ($conn->{msg} =~ /\cM?\cJ$/) {
			delete $conn->{msg};
		} else {
			$conn->{msg} = pop @lines;
		}
		$conn->{linesin} += @lines;
		$total_lines_in += @lines;
		for (@lines) {
			last if $conn->{disconnecting};
			&{$conn->{rproc}}($conn, defined $_ ? $_ : '');
		}
	}
}

sub _rcv {                     # Complement to _send
    my $conn = shift; # $rcv_now complement of $flush
	my $msg = shift;
    my $sock = $conn->{sock};
    return unless defined($sock);
	return if $conn->{disonnecting};

	$total_in += length $msg;
	$conn->{datain} += length $msg;

	if (isdbg('raw')) {
		my $call = $conn->{call} || 'none';
		my $lth = length $msg;
		dbgdump('raw', "$call read $lth: ", $msg);
	}
	if ($conn->{echo}) {
		my @ch = split //, $msg;
			my $out;
			for (@ch) {
				if (/[\cH\x7f]/) {
					$out .= "\cH \cH";
					$conn->{msg} =~ s/.$//;
				} else {
					$out .= $_;
					$conn->{msg} .= $_;
				}
			}
			if (defined $out) {
				$conn->send_raw($out);
			}
	} else {
		$conn->{msg} .= $msg;
	}

	unless ($conn->{disable_read}) {
		$conn->dequeue if exists $conn->{msg};
	}
}

sub new_client {
	my $server_conn = shift;
	my $handle = shift;
	
	my $conn = $server_conn->new($server_conn->{rproc});
	my $sock = $conn->{sock} = Mojo::IOLoop::Stream->new($handle);
	$sock->on(read => sub {$conn->_rcv($_[1])});
	$sock->timeout(0);
	$sock->start;
	$conn->{peerhost} = $handle->peerhost || 'unknown';
	$conn->{peerport} = $handle->peerport || 0;
	$conn->{sockhost} = $handle->sockhost || '';
	dbg((ref $conn) . " accept $conn->{cnum}:$conn->{sockhost} from $conn->{peerhost}:$conn->{peerport}") if isdbg('conn') || isdbg('connect');
	my ($rproc, $eproc) = &{$server_conn->{rproc}} ($conn, $conn->{peerhost}, $conn->{peerport});
	$conn->{sort} = 'Incoming';
	if ($eproc) {
		$conn->{eproc} = $eproc;
	}
	if ($rproc) {
		$conn->{rproc} = $rproc;
	} else {  # Login failed
		&{$conn->{eproc}}($conn, undef) if exists $conn->{eproc};
		$conn->disconnect();
	}
	return $conn;
}

sub close_server
{
	my $conn = shift;
	delete $conn->{sock};
}

# close all clients (this is for forking really)
sub close_all_clients
{
	foreach my $conn (values %conns) {
		$conn->disconnect;
	}
}

sub disable_read
{
	my $conn = shift;
	return defined $_[0] ? $conn->{disable_read} = $_[0] : $_[0];
}


#
#----------------------------------------------------
# Event loop routines used by both client and server

sub set_event_handler {
	my $sock = shift;
	my %args = @_;
	my ($pkg, $fn, $line) = caller;
	my $s;
	foreach (my ($k,$v) = each %args) {
		$s .= "$k => $v, ";
	}
	$s =~ s/[\s,]$//;
	dbg("Msg::set_event_handler called from ${pkg}::${fn} line $line doing $s");
}

sub sleep
{
	my ($pkg, $interval) = @_;
	my $now = time;
	while (time - $now < $interval) {
		sleep 1;
	}
}

sub DESTROY
{
	my $conn = shift;
	my $call = $conn->{call} || 'unallocated';

	if (isdbg('connll')) {
		my ($pkg, $fn, $line) = caller;
		dbgtrace((ref $conn) . "::DESTROY on call $call called from ${pkg}::${fn} line $line ");
	}

	my $host = $conn->{peerhost} || '';
	my $port = $conn->{peerport} || '';
	my $sock = $conn->{sock};

	if ($sock) {
		$sock->close_gracefully if $sock->can('close_gracefully');
		delete $conn->{sock};
	}
	
	$noconns--;
	dbg((ref $conn) . " Connection $conn->{cnum} $call [$host $port] being destroyed (total $noconns)") if isdbg('connll');
}

1;

__END__

