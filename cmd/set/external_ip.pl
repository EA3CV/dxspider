# DXSpider core public IP refresh. The command may also be called from the
# native crontab: run_cmd("set/external_ip")
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->priv < 8 && $self != $main::me;
require DXPublicIP;
my ($arg) = split /\s+/, ($line || '');
if ($arg) {
    return (1, 'set/external_ip: invalid public IP') unless is_public_ip($arg);
    my $changed = DXPublicIP::set_explicit($arg);
    return (1, $changed ? "set/external_ip: public IP set to $arg" : "set/external_ip: unchanged $arg");
}
my $accepted = DXPublicIP::refresh(sub {
    my ($ip, $changed) = @_;
    my $message = defined $ip
        ? "set/external_ip: " . ($changed ? "public IP changed to $ip" : "public IP unchanged $ip")
        : 'set/external_ip: all public IP providers unavailable; keeping configured/last valid IP';
    LogDbg($message);
    $self->send($message) if $self != $main::me && DXChannel::get($self->call);
});
return (1, $accepted ? 'set/external_ip: discovery started' : 'set/external_ip: discovery already in progress');
