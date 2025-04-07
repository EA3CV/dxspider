
sub extract_ip
{
	my ($conn, $body, $self) = @_;
	my @out;

#	$DB::single = 1;
	
	my $new = $body;
	dbg("set/external_ip: received: $new") if dbg('external_ip');
	
	my $chan = DXChannel::get($main::mycall);
	my $old = $chan->hostname;
	$old = '127.0.0.1' if $old =~/localhost/;
	
	if ($new =~ /\./ && is_ipaddr($new)) {
		if ($new ne $chan->hostname) {
			LogDbg("Changing IP address of node from $old to $new");
			$chan->hostname($new);
			$main::me->hostname($new);
			push @out, "set/external_ip: Changed $main::mycall IP address from $old -> $new";
		} else {
			push @out, "set/external_ip: no IP address change for $main::mycall required";
		} 			
	} else {
		if ($old =~ /\:/) {
			push @out, "set/external_ip: $main::mycall has IPV6 ip address $old, cannot change it here";
		} else {
			push @out, "set/external_ip: unknown error $main::mycall hostname old = $old, new = $new, ignored";
		}
	}
	unless ($self == $main::me) {
		$self->send($_) for @out;
	}
}

sub handle
{
	my $self = shift;
	return (1, $self->msg('e5')) if $self->priv < 8 && $self != $main::me;
	my @out;
	

	my $host = $Internet::ipaddr_host || 'ipinfo.io';
	my $url = $Internet::ipaddr_url  || "/ip";
	
	dbg("set/external_ip: sending request $url to $host") if isdbg('external_ip');

#	$DB::single = 1;
	
	my $r = AsyncMsg::get('AsyncMsg', $self->{call}, $host, $url, prefix=>'',  filter=>\&extract_ip);
	if ($r) {
		push @out, $self->msg('m21', "set/external_ip");
	}
	else {
		push @out, $self->msg('e18', $host);
	}

	return (1, @out);
}
