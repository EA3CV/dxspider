#
# show either the current user or a nominated set
#
#
#

my ($self, $line) = @_;
my @list = split /\s+/, $line;	# generate a list of callsigns
@list = ($self->call) if !@list; # my channel if no callsigns

my $call;
my @out;
foreach $call (@list) {
	$call = uc $call;
	my $ref = DXUser::get_current($call);
	if ($ref) {
		if ($self->consort eq 'ax25') {
			@out = grep { !/(Password|Privilege)/ } print_all_fields($self, $ref, "User Information $call");
		} else {
			@out = print_all_fields($self, $ref, "User Information $call");
		}
		# Display live session transport without changing persistent DXUser fields.
		# A logical WebChannel user has its own DXChannel identity but shares
		# the technical #WEB-n socket; do not confuse the two.
		my $active = DXChannel::get($call);
		my ($connection, $transport) = ('Offline', '-');
		if ($active) {
			if ($active->isa('Web::UserChannel') && !$active->{web_released}
			    && !$active->{web_disconnecting} && $active->{web_owner}
			    && $active->{web_owner}{web_users}{$call}
			    && $active->{web_owner}{web_users}{$call}{authenticated}
			    && $active->{web_owner}{web_users}{$call}{channel}
			       == $active) {
				$connection = 'WebChannel';
				$transport = $active->{web_owner}{call} || '-';
			} elsif ($active->is_web) {
				$connection = 'WebChannel';
				$transport = $active->call;
			} elsif ($active->is_user && $active->{conn}) {
				$connection = 'Telnet';
				$transport = 'TCP';
			} else {
				$connection = 'Other';
				$transport = '-';
			}
		}
		my @session = (sprintf('   Connection: %s', $connection),
		               sprintf('    Transport: %s', $transport));
		my $at = -1;
		for my $i (0 .. $#out) {
			if ($out[$i] =~ /^\s*Callsign\s*:/) { $at = $i; last; }
		}
		splice @out, ($at >= 0 ? $at + 1 : scalar @out), 0, @session;
	} else {
		push @out, "User: $call not found";
	}
	push @out, "" if @list > 1;
}

return (1, @out);
