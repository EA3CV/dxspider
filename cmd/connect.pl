#
# connect a cluster station
#
my $self = shift;
my $call = uc shift;
my $lccall = lc $call;

return (1, $self->msg('e5')) if $self->priv < 5;
return (1, $self->msg('e6')) unless $call gt ' ';
return (1, $self->msg('already', $call)) if DXChannel::get($call);
return (1, $self->msg('outconn', $call)) if grep {$_->{call} eq $call} @main::outstanding_connects;
return (1, $self->msg('conscript', $lccall)) unless -e "$main::root/connect/$lccall";

my $user = DXUser::get($call);
return (1, $self->msg('lockout', $call)) if $user && $user->lockout;

my @out;
push @out, $self->msg('constart', $call);
# During scripts/startup the event loop is not running yet. Starting an
# asynchronous TCP connection here consumes its timeout before the loop starts.
# Defer only the outbound connection; leave all earlier startup commands intact.
my $connect_script = "$main::root/connect/$lccall";
if (ref($self) && ref($main::me) && $self == $main::me && !Mojo::IOLoop->is_running) {
    dbg("startup connect $call queued until event loop starts");
    Mojo::IOLoop->next_tick(sub {
        dbg("startup connect $call starting on event loop");
        ExtMsg::start_connect($call, $connect_script);
    });
} else {
    ExtMsg::start_connect($call, $connect_script);
}
return (1, @out);




