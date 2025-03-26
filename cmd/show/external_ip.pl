sub handle
{
	my $self = shift;
	return (1, $self->msg('e5')) if $self->priv < 8;

	my @out;
	my $chan = DXChannel::get($main::mycall);
	
	push @out, "me: $main::me->{hostname} node: $chan->{hostname}";
	return (1, @out);
}
