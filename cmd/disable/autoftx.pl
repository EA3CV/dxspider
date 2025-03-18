#
# 
#
# Copyright (c) 2025 - Dirk Koopman G1TLH
#
#
#
my $self = shift;
my $call = $self->call;
my $user = DXUser::get_current($call);
if ($user) {
	$user->autoftx(0);
	$user->put;
	return (1, $self->msg('autoftxd'));
} else {
	return (1, $self->msg('namee2', $call));
}
