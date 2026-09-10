#
# register/reject.pl - Reject a DXSpider registration request
#
# SYSOP only.
#
# Usage:
#   register/reject <request-id|call> [note]
#

my ($self, $line) = @_;

return (1, $self->msg('e5'))
    if $self->priv < 9;

unless ($main::reg_enable && DXReg::ready()) {
    return (1, ' ', 'Registration subsystem is not enabled', ' ');
}

if ($self->remotecmd || $self->inscript) {
    Log('DXCommand', $self->call . ' attempted register/reject remotely');
    return (1, $self->msg('e5'));
}

$line //= '';
$line =~ s/^\s+//;
$line =~ s/\s+$//;

my ($target, $note) = split /\s+/, $line, 2;

return (
    1,
    ' ',
    'Usage: register/reject <request-id|call> [note]',
    ' '
) unless defined $target && length $target;

my ($resolved, $request_or_error)
    = DXReg::resolve_pending_request($target);

return (1, ' ', $request_or_error, ' ')
    unless $resolved;

my $request = $request_or_error;

my ($ok, $result) = DXReg::reject_request(
    $request->{id},
    $self->call,
    $note
);

unless ($ok) {
    Log(
        'DXCommand',
        sprintf(
            '%s register/reject #%d %s failed: %s',
            $self->call,
            $request->{id},
            $request->{call},
            $result
        )
    );

    return (1, ' ', $result, ' ');
}

my $r = $result;

Log(
    'DXCommand',
    sprintf(
        '%s rejected registration request #%d for %s',
        $self->call,
        $r->{id},
        $r->{call}
    )
);

my @out;

push @out, ' ';
push @out, 'Registration rejected:';
push @out, sprintf('%16s %s', 'Request:', '#' . $r->{id} . ' - ' . $r->{call});
push @out, sprintf('%16s %s', 'Status:', 'REJECTED');
push @out, sprintf('%16s %s', 'Processed by:', $r->{processed_by});

push @out, sprintf('%16s %s', 'Note:', $r->{note})
    if defined $r->{note} && length $r->{note};

push @out, ' ';

return (1, @out);
