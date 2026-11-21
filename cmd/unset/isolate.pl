#
# set user type BACK TO  'U' (user)
#
# Please note that this is only effective if the user is not on-line
#
# Copyright (c) 1998 - Dirk Koopman
#
#
#

my ($self, $line) = @_;
my @args = split /\s+/, $line;
my $call;
my @out;
my $user;
my $create;

return (1, $self->msg('e5')) if $self->priv < 5;

foreach $call (@args) {
    $call = uc $call;
    $user = DXUser::get($call);
    unless ($user) {
        push @out, $self->msg('usernf', $call);
        next;
    }
    my $chan = DXChannel::get($call);
    $chan->disconnect() if $chan;
    $user = DXUser::get($call) || $user;
    $user->isolate(0);
    $user->put();
    push @out, $self->msg('isou', $call);
    Log('DXCommand', $self->msg('isou', $call));
}
return (1, @out);
