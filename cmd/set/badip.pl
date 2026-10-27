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
return (1, "set/badip: need [suffix (def: local])] IP, IP-IP or IP/24") unless @in;
for my $ip (@in) {
    unless (DXCIDR::valid_spec($ip)) {
        push @out, "set/badip: '$ip' is not an ip address, ignored";
        next;
    }
    my $covered = eval { DXCIDR::covered_suffix($suffix, $ip) };
    return (1, "set/badip: $ip $@") if $@;
    if ($covered) {
        push @out, "set/badip: $ip exists, not added";
        next;
    }
    if (DXCIDR::append($suffix, $ip) != 1) {
        push @out, "set/badip: $ip could not be written to badip.$suffix";
        next;
    }
    push @added, $ip;
    # Rebuild from durable sources: the selected file and all other suffixes.
    DXCIDR::reload();
}
my $count = @added;
my $list = join ' ', @in;
if ($count) {
    push @out, "set/badip: added $count entries to badip.$suffix : '$list'";
}

return (1, @out);
