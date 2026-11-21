#
# show active connections
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
#
#

my $self = shift;
return (1, $self->msg('e5')) if $self->priv < 1;
my @out;
my $count;

push @out, "Cnum Call      Address/Port              State  Type   Dir.     Module";

foreach my $call (sort keys %Msg::conns) {
	my $r = $Msg::conns{$call};
	my $c = $call;
	my $addr;
	
	if ($c =~ /^Server\s+(\S+)/) {
		$addr = $1;
		$c = "Server";
	} else {
		$addr = "AGW Port ($r->{agwport})" if exists $r->{agwport};
		$addr = "BPQ Stream ($r->{bpqstream})" if exists $r->{bpqstream};

		$addr ||= "$r->{peerhost}/$r->{peerport}";
		$addr ||= "Unknown";
	}
	my $csort = $r->{csort} || '';
	my $sort = $r->{sort} || '';
	push @out, 	sprintf(" %3d %-9s %-27.27s %3s %7s %8s %-8s", 
						$r->{cnum}, $c, 
						$addr, $r->{state}, 
						$csort, $sort, ref $r);

	$count++;
}
push @out, "$count Connections ($Msg::noconns Allocated)";
# Logical web users are excluded from physical connection counts.
# Read the same snapshot as show/health web.
my $web = DXSupervisor::web();
my @web_rows;
for my $channel (@{$web->{channels} || []}) {
    for my $user (@{$channel->{users} || []}) {
        my $call = $user->{call} || next;
        push @web_rows, sprintf "%-12s %-10s %s", $call,
            ($channel->{call} || ''), ($user->{ip} || '');
    }
}
if (@web_rows) {
    push @out, '';
    push @out, 'Logical Web Users';
    push @out, 'Call         Channel    Remote IP';
    push @out, '------------ ---------- ---------------------------------------';
    push @out, @web_rows;
    push @out, scalar(@web_rows) . ' Logical Web Users';
}
return (1, @out);
