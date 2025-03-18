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
	$user->ftx(1);
	$user->put;
	return (1, $self->msg('ftxe'));
} else {
	return (1, $self->msg('namee2', $call));
}


