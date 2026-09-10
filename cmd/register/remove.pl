#
# register/remove.pl - Remove DXSpider registration for a callsign family
#
# SYSOP only.
#
# Usage:
#   register/remove <call> [note]
#
# Removes passwd and sets registered=0 on the base callsign and every
# existing CALL-SSID from 1 to 99. DXUser records are preserved.
# Connected affected users are disconnected after persistence.
#

my ($self, $line) = @_;

return (1, $self->msg('e5'))
    if $self->priv < 9;

unless ($main::reg_enable && DXReg::ready()) {
    return (1, ' ', 'Registration subsystem is not enabled', ' ');
}

if ($self->remotecmd || $self->inscript) {
    Log('DXCommand', $self->call . ' attempted register/remove remotely');
    return (1, $self->msg('e5'));
}

$line //= '';
$line =~ s/^\s+//;
$line =~ s/\s+$//;

my ($call, $note) = split /\s+/, $line, 2;

return (
    1,
    ' ',
    'Usage: register/remove <call> [note]',
    ' '
) unless defined $call && length $call;

my $ip;
if ($self->conn) {
    $ip = $self->conn->{peerhost}
        || $self->conn->{ip}
        || $self->conn->{addr};
}

my ($ok, $result) = DXReg::remove_registration(
    $call,
    $self->call,
    $note,
    $ip
);

unless ($ok) {
    Log(
        'DXCommand',
        sprintf(
            '%s register/remove %s failed: %s',
            $self->call,
            uc($call),
            $result
        )
    );

    return (1, ' ', $result, ' ');
}

my $r = $result->{record};

Log(
    'DXCommand',
    sprintf(
        '%s removed registration for %s (%d DXUser records)',
        $self->call,
        $r->{call},
        scalar @{ $result->{affected_calls} }
    )
);

my $ssids = @{ $r->{affected_ssids} || [] }
    ? join(',', @{ $r->{affected_ssids} })
    : '-';

my $disconnected = @{ $result->{disconnected} || [] }
    ? join(',', @{ $result->{disconnected} })
    : '-';

my @out;

push @out, ' ';
push @out, 'Registration removed:';
push @out, sprintf('%16s %s', 'Record:', '#' . $r->{id} . ' - ' . $r->{call});
push @out, sprintf('%16s %s', 'Status:', 'REMOVED');
push @out, sprintf('%16s %s', 'Affected SSIDs:', $ssids);
push @out, sprintf('%16s %d', 'DXUser records:', scalar @{ $result->{affected_calls} });
push @out, sprintf('%16s %s', 'Disconnected:', $disconnected);
push @out, sprintf('%16s %s', 'Processed by:', $r->{processed_by});

push @out, sprintf('%16s %s', 'Note:', $r->{note})
    if defined $r->{note} && length $r->{note};

if (@{ $result->{disconnect_failed} || [] }) {
    push @out, sprintf(
        '%16s %s',
        'Disconnect errors:',
        join(',', @{ $result->{disconnect_failed} })
    );
}

push @out, ' ';

return (1, @out);
