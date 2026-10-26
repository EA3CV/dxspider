# List persisted isolation flags (DXUser is authoritative).
# Do not depend on DB_File or on a JSON substring search.
sub handle
{
    my ($self, $line) = @_;
    return (1, $self->msg('e5')) if $self->priv < 1;
    return (1, generate($self, $line));
}

sub generate
{
    my ($self, $line) = @_;
    $line = uc($line // '');
    my @requested = grep { length } split /\s+/, $line;
    my $all = !@requested || (@requested == 1 && $requested[0] eq 'ALL');
    my @calls = $all ? DXUser::get_all_calls() : @requested;
    my @isolated;
    for my $call (@calls) {
        my $user = DXUser::get_current($call);
        push @isolated, $call if $user && $user->isolate;
    }
    my @out;
    while (@isolated) {
        my @row = splice @isolated, 0, 5;
        push @row, '' while @row < 5;
        push @out, sprintf '%-12s %-12s %-12s %-12s %-12s', @row;
    }
    my $count = $all ? scalar(grep { length } @out) : 0;
    # Report number of calls, not number of rows.
    my @found = grep { my $u = DXUser::get_current($_); $u && $u->isolate } @calls;
    push @out, $self->msg('rec', scalar @found);
    return @out;
}
