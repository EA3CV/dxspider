# Explicit badip reload, preserving active memory on failure.
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd || $self->priv < 6;
return (1, 'Net::CIDR::Lite is required') unless $DXCIDR::active;
my $count = eval { DXCIDR::reload() };
return (1, "load/badip: reload failed; old tables retained: $@") if $@;
return (1, 'load/badip: reload failed; old tables retained') unless defined $count;
return (1, "load/badip: loaded $count entries");
