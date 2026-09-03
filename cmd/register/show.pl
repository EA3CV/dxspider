#
# register/show.pl - Show DXSpider registration requests/history
#
# SYSOP only.
#
# Usage:
#   register/show
#   register/show <call>
#   register/show <request-id>
#

my ($self, $line) = @_;
my @out;

return (1, $self->msg('e5'))
    if $self->priv < 9;

unless ($main::reg_enable && DXReg::ready()) {
    return (1, ' ', 'Registration subsystem is not enabled', ' ');
}

if ($self->remotecmd || $self->inscript) {
    Log('DXCommand', $self->call . ' attempted register/show remotely');
    return (1, $self->msg('e5'));
}

$line //= '';
$line =~ s/^\s+//;
$line =~ s/\s+$//;

if (!length $line) {
    my @pending = sort {
        ($a->{created_at} || 0) <=> ($b->{created_at} || 0)
    } DXReg::list_pending();

    return (1, ' ', 'No pending registration requests', ' ')
        unless @pending;

    push @out, ' ';
    push @out, 'Pending registration requests:';

    for my $r (@pending) {
        push @out, summary_line($r);
    }

    push @out, ' ';
    return (1, @out);
}

if ($line =~ /^\d+$/) {
    my $r = DXReg::get_request($line);

    return (1, ' ', "Registration request #$line not found", ' ')
        unless $r;

    push @out, ' ';
    push @out, 'Registration history for ' . $r->{call} . ':';
    push @out, format_request($r);
    push @out, ' ';

    return (1, @out);
}

my $call = uc $line;
my @history = DXReg::get_history($call);

return (1, ' ', "No registration history for $call", ' ')
    unless @history;

@history = sort {
    ($b->{id} || 0) <=> ($a->{id} || 0)
} @history;

push @out, ' ';
push @out, "Registration history for $call:";

for my $i (0 .. $#history) {
    push @out, format_request($history[$i]);
    push @out, ' ' if $i < $#history;
}

push @out, ' ';
return (1, @out);


sub summary_line
{
    my ($r) = @_;

    my $ssids = @{ $r->{requested_ssids} || [] }
        ? join(',', @{ $r->{requested_ssids} })
        : '-';

    return sprintf(
        '#%-4d %-12s %-9s SSIDs: %s',
        $r->{id},
        $r->{call},
        $r->{status} || '',
        $ssids
    );
}


sub format_request
{
    my ($r) = @_;
    my @lines;

    my $requested = @{ $r->{requested_ssids} || [] }
        ? join(',', @{ $r->{requested_ssids} })
        : '-';

    my $accepted = ref($r->{accepted_ssids}) eq 'ARRAY'
        && @{ $r->{accepted_ssids} }
        ? join(',', @{ $r->{accepted_ssids} })
        : '-';

    my $affected = ref($r->{affected_ssids}) eq 'ARRAY'
        && @{ $r->{affected_ssids} }
        ? join(',', @{ $r->{affected_ssids} })
        : '-';

    push @lines, sprintf('%16s %s', 'Request:', '#' . $r->{id} . ' - ' . $r->{call});
    push @lines, sprintf('%16s %s', 'Status:', $r->{status} // '-');
    push @lines, sprintf('%16s %s', 'Email:', $r->{email} // '-')
        if defined $r->{email} && length $r->{email};
    push @lines, sprintf('%16s %s', 'Language:', $r->{language} // '-')
        if defined $r->{language} && length $r->{language};

    push @lines, sprintf('%16s %s', 'Requested SSIDs:', $requested)
        unless ($r->{status} // '') eq 'REMOVED';

    push @lines, sprintf('%16s %s', 'Accepted SSIDs:', $accepted)
        unless ($r->{status} // '') eq 'REMOVED';

    push @lines, sprintf('%16s %s', 'Affected SSIDs:', $affected)
        if ($r->{status} // '') eq 'REMOVED';

    push @lines, sprintf('%16s %s', 'Source:', $r->{source} // '-');
    push @lines, sprintf('%16s %s', 'IP:', $r->{ip} // '-');
    push @lines, sprintf('%16s %s', 'Created:', fmt_time($r->{created_at}));

    if ($r->{processed_at}) {
        push @lines, sprintf('%16s %s', 'Processed:', fmt_time($r->{processed_at}));
        push @lines, sprintf('%16s %s', 'Processed by:', $r->{processed_by} // '-');
    }

    if (defined $r->{note} && length $r->{note}) {
        push @lines, sprintf('%16s %s', 'Note:', $r->{note});
    }

    return @lines;
}


sub fmt_time
{
    my ($t) = @_;
    return '-' unless $t;
    return cldatetime($t);
}
