use IO::Socket::IP -register;

sub handle
{
	my $self = shift;
	return (1, $self->msg('e5')) if $self->priv < 8 && $self != $main::me;
	my @out;

	my $new;
	
	#	my $new =  find_external_ipaddr();
	my $ua = Mojo::UserAgent->new(socket_options => { Domain => PF_INET })->insecure(1)->max_redirects(5);
	my $res = $ua->get('http://ifconfig.me/ip')->result;
	if ($res->is_success) {
		$new = $res->body;
		dbg("get success: $new");
	}
	elsif ($res->is_error)    { push @out, "set/external_ip: error getting http://ifconfig.me/ip " . res->message }
    elsif ($res->code == 301) { dbg($res->headers->location); }

	if ($new) {
		my $chan = DXChannel::get($main::mycall);
		my $old = $chan->hostname;
		$old = '127.0.0.1' if $old =~/localhost/;
		
		dbg("set/external_ip: host: $old new: $new") if dbg('external_ip');
		
		if ($new =~ /\./ && is_ipaddr($new)) {
			if ($new ne $chan->hostname) {
				LogDbg("Changing IP address of node from $old to $new");
				$chan->hostname($new);
				$main::me->hostname($new);
				push @out, "set/external_ip: Changed $main::mycall IP address from $old -> $new";
			} else {
				push @out, "set/external_ip: $old no IP address change for $main::mycall required";
			} 			
		} else {
			if ($old =~ /\:/) {
				push @out, "set/external_ip: $main::mycall has IPV6 ip address $old, cannot change it here";
			} else {
				push @out, "set/external_ip: unknown error $main::mycall hostname old = $old, new = $new, ignored";
			}
		}
	}
	unless ($self == $main::me) {
		$self->send($_) for @out;
	}
}
