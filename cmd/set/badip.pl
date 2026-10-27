my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd || $self->priv < 6;
return (1, 'Net::CIDR::Lite is required') unless $DXCIDR::active;

my @in = grep { length } split /\s+/, $line;
my $suffix = 'local';
$suffix = shift @in if @in && $in[0] =~ /^\w+$/;
return (1, 'set/badip: need [suffix] IP/CIDR/range') unless @in;
my ($changes,$files) = eval { DXCIDR::change_and_reload('set',$suffix,@in) };
return (1, "set/badip: $@") if $@;
return (1, "set/badip: changed $changes rules in $files files; memory reloaded if changed");
