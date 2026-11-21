#
# set list of bad dx nodes
#
# Copyright (c) 2021 - Dirk Koopman G1TLH
#
#
#
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
# are we permitted?
return (1, $self->msg('e5')) if $self->priv < 6;
return (1, q{Please install Net::CIDR::Lite or libnet-cidr-lite-perl to use this command}) unless $DXCIDR::active;

my @out;
my @added;
my @in = split /\s+/, $line;
my $suffix = 'local';
if ($in[0] =~ /^[_\d\w]+$/) {
	$suffix = shift @in;
}
return (1, "testbadip: need [suffix (def: local])] IP, IP-IP or IP/24") unless @in;
for my $ip (@in) {
	my $r;
	unless (is_ipaddr($ip)) {
		push @out, "set/badip: '$ip' is not an ip address, ignored";
		next;
	}
	eval{ $r = DXCIDR::find($ip); };
	push @added, $ip . ($r ? '(1)' : '(0)');
}
my $count = @added;
my $list = join '  ', @added;
return (1, $list);
