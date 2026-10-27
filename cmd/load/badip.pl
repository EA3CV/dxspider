#
# load list of bad dx nodes
#
# Copyright (c) 2023 - Dirk Koopman G1TLH
#
#
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
# are we permitted?
return (1, $self->msg('e5')) if $self->priv < 6;
return (1, q{Please install Net::CIDR::Lite or libnet-cidr-lite-perl to use this command}) unless $DXCIDR::active;

my @out;

my $count = 0;
eval{ $count += DXCIDR::reload(); };
return (1, "load/badip: $_ $@") if $@;

push @out, "load/badip: added $count entries";
return (1, @out);
