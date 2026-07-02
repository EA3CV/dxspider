use IO::Socket::IP -register;

sub handle
{
	my $self = shift;
	return (1, $self->msg('e5')) if $self->priv < 8 && $self != $main::me;
	my @out;

	my $new = shift;

	push @out, "$new is not a valid IP address (DNS names not allowed), ignored" if $new && !is_ipaddr($new);
	push @out, "$new is a local address, ignored" if is_rfc1918($new);
	if (@out) {
		unless ($self == $main::me) {
			$self->send($_) for @out;
		}
		return;
	}
	
	unless ($new) {
		#	my $new =  find_external_ipaddr();
		my $ua = Mojo::UserAgent->new(socket_options => { Domain => PF_INET })->insecure(1)->max_redirects(5);
		my $res = $ua->get('http://ifconfig.me/ip')->result;
		if ($res->is_success) {
			$new = $res->body;
			dbg("get success: $new");
		}
		elsif ($res->is_error) {
			push @out, "set/external_ip: error getting http://ifconfig.me/ip " . res->message;
		}
		elsif ($res->code == 301) {
			dbg($res->headers->location);
		}
	} 

	my $chan = $main::me;
	my $old = $chan->hostname;
	if ($new) {
		$old = '127.0.0.1' if $old =~/localhost/;
		dbg("set/external_ip: host: $old new: $new") if dbg('external_ip');

		if ($new ne $chan->hostname) {
			LogDbg("Changing IP address of node from $old to $new");
			$chan->hostname($new);
			push @out, "set/external_ip: Changed $main::mycall IP address from $old -> $new";
		} elsif ($self != $main::me) {
			push @out, "set/external_ip: $old no IP address change for $main::mycall required";
		}
	} 
	unless ($self == $main::me) {
		$self->send($_) for @out;
	}
	return;
}

