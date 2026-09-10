#
# register/accept.pl - Accept a DXSpider registration request
#
# SYSOP only.
#
# Usage:
#   register/accept <request-id|call> [note]
#

my ($self, $line) = @_;

return (1, $self->msg('e5'))
    if $self->priv < 9;

unless ($main::reg_enable && DXReg::ready()) {
    return (1, ' ', 'Registration subsystem is not enabled', ' ');
}

if ($self->remotecmd || $self->inscript) {
    Log('DXCommand', $self->call . ' attempted register/accept remotely');
    return (1, $self->msg('e5'));
}

$line //= '';
$line =~ s/^\s+//;
$line =~ s/\s+$//;

my ($target, $note) = split /\s+/, $line, 2;

return (
    1,
    ' ',
    'Usage: register/accept <request-id|call> [note]',
    ' '
) unless defined $target && length $target;

my ($resolved, $request_or_error)
    = DXReg::resolve_pending_request($target);

return (1, ' ', $request_or_error, ' ')
    unless $resolved;

my $request = $request_or_error;

my ($ok, $result) = DXReg::accept_request(
    $request->{id},
    $self->call,
    $note
);

unless ($ok) {
    Log(
        'DXCommand',
        sprintf(
            '%s register/accept #%d %s failed: %s',
            $self->call,
            $request->{id},
            $request->{call},
            $result
        )
    );

    return (1, ' ', $result, ' ');
}

my $r = $result->{request};

Log(
    'DXCommand',
    sprintf(
        '%s accepted registration request #%d for %s',
        $self->call,
        $r->{id},
        $r->{call}
    )
);

my $accepted = @{ $r->{accepted_ssids} || [] }
    ? join(',', @{ $r->{accepted_ssids} })
    : '-';

my @out;

push @out, ' ';
push @out, 'Registration accepted:';

push @out, sprintf('%16s %s', 'Request:', '#' . $r->{id} . ' - ' . $r->{call});
push @out, sprintf('%16s %s', 'Status:', 'ACCEPTED');
push @out, sprintf('%16s %s', 'Email:', $r->{email} // '-');
push @out, sprintf('%16s %s', 'Accepted SSIDs:', $accepted);
push @out, sprintf('%16s %s', 'Password:', $result->{password});
push @out, sprintf('%16s %s', 'Password source:', $result->{password_source});
push @out, sprintf('%16s %s', 'Processed by:', $r->{processed_by});

push @out, sprintf('%16s %s', 'Note:', $r->{note})
    if defined $r->{note} && length $r->{note};

push @out, ' ';

return (1, @out);
