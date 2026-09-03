#
# register/request.pl - Create a DXSpider registration request
#
# Normal user:
#   register/request <email> <EN|ES> [ssid-list]
#
# SYSOP:
#   register/request <call> <email> <EN|ES> [ssid-list]
#
# SSID examples:
#   1
#   1,2,5
#   1-5
#   1,3-5,10
#

my ($self, $line) = @_;
my @out;

unless ($main::reg_enable && DXReg::ready()) {
    return (1, 'Registration subsystem is not enabled');
}

if ($self->remotecmd || $self->inscript) {
    Log('DXCommand', $self->call . ' attempted register/request remotely');
    return (1, $self->msg('e5'));
}

my @args = grep { length $_ } split /\s+/, ($line // '');

my ($call, $email, $language, $ssid_spec, $source);

if ($self->priv >= 9) {
    return (1, 'Usage: register/request <call> <email> <EN|ES> [ssid-list]')
        unless @args >= 3;

    ($call, $email, $language, $ssid_spec) = @args;
    $call   = uc $call;
    $source = 'SYSOP';
} else {
    return (1, 'Usage: register/request <email> <EN|ES> [ssid-list]')
        unless @args >= 2;

    ($email, $language, $ssid_spec) = @args;
    $call   = uc $self->call;
    $source = 'USER';
}

my ($ssid_ok, $ssids_or_error) = parse_ssids($ssid_spec);

return (1, $ssids_or_error) unless $ssid_ok;

my $ip;
if ($self->conn) {
    # Keep this deliberately tolerant because connection implementations
    # do not all expose the peer address in exactly the same way.
    $ip = $self->conn->{peerhost}
        || $self->conn->{ip}
        || $self->conn->{addr};
}

my ($ok, $result) = DXReg::create_request(
    call     => $call,
    email    => $email,
    language => $language,
    ssids    => $ssids_or_error,
    source   => $source,
    ip       => $ip,
);

unless ($ok) {
    Log('DXCommand', $self->call . " register/request failed for $call: $result");
    return (1, $result);
}

my $r = $result;

Log(
    'DXCommand',
    sprintf(
        '%s created registration request #%d for %s',
        $self->call,
        $r->{id},
        $r->{call}
    )
);

my $ssid_text = @{ $r->{requested_ssids} }
    ? join(',', @{ $r->{requested_ssids} })
    : '-';

push @out, sprintf('Registration request #%d - %s', $r->{id}, $r->{call});
push @out, "Email: $r->{email}";
push @out, "Language: $r->{language}";
push @out, "SSIDs: $ssid_text";
push @out, 'Status: PENDING';

return (1, @out);

sub parse_ssids
{
    my ($spec) = @_;

    return (1, []) unless defined $spec && length $spec;

    my @result;

    for my $part (split /,/, $spec) {
        if ($part =~ /^(\d+)-(\d+)$/) {
            my ($from, $to) = ($1, $2);

            return (0, "Invalid SSID range '$part'")
                if $from > $to;

            push @result, ($from .. $to);
        } elsif ($part =~ /^\d+$/) {
            push @result, $part;
        } else {
            return (0, "Invalid SSID specification '$part'");
        }
    }

    return (1, \@result);
}
