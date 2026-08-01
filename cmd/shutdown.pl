#
# the shutdown command
# 
#
#
my $self = shift;
my $call = $self->call;
my $ref;
return (1, $self->msg('e5')) unless $self->priv >= 5;
foreach $ref (DXChannel::get_all()) {
	$ref->send($self->msg('shutting')) if $ref->is_user;
}
    
++$main::ending;

return (1);
