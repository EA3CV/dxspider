#
# unset IPs from bad dx node list
#
# Adapted for DXCIDR SQL compatibility - 2025
#

my ($self, $line) = @_;

return (1, $self->msg('e5')) if $self->remotecmd;
return (1, $self->msg('e5')) if $self->priv < 6;
return (1, q{Please install Net::CIDR::Lite or libnet-cidr-lite-perl to use this command}) unless $DXCIDR::active;

my @in = split /\s+/, $line;
my $suffix = 'local';
$suffix = shift @in if $in[0] =~ /^[_\d\w]+$/;

return (1, "unset/badip: need [suffix (def: local)] IP(s)") unless @in;

my @removed;
for my $ip (@in) {
    unless (is_ipaddr($ip)) {
        push @removed, "unset/badip: '$ip' is not a valid IP, ignored";
        next;
    }

    if (!DXCIDR::find($ip)) {
        push @removed, "unset/badip: '$ip' not found in badip.$suffix";
        next;
    }

    DXCIDR::remove($suffix, $ip);
    push @removed, "unset/badip: '$ip' removed from badip.$suffix";
}

DXCIDR::reload();

return (1, @removed);
