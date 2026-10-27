my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd || $self->priv < 6;
return (1, 'Net::CIDR::Lite is required') unless $DXCIDR::active;

my @in = grep { length } split /\s+/, $line;
# Optional suffix is accepted for syntax compatibility, but removal must
# cover ALL badip.* sources to unblock the requested address effectively.
shift @in if @in && $in[0] =~ /^\w+$/;
return (1, 'unset/badip: need IP/CIDR/range') unless @in;
my ($changes,$files) = eval { DXCIDR::change_and_reload('unset',undef,@in) };
return (1, "unset/badip: $@") if $@;
return (1, "unset/badip: changed $changes rules in $files files; memory reloaded if changed");
