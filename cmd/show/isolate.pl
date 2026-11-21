# List isolated DXUsers from the authoritative SQL store.
# Avoid decoding every DXUser and a second full scan.
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
    my @isolated;

    if ($all && DXUser::using_database() && $main::userdsn =~ /:sqlite:/i) {
        # Match Perl truth: undef, empty string and "0" are false.
        # JSON booleans and numeric values are handled by SQLite JSON1.
        my $sth = $DXUser::dbh->prepare(q{
            SELECT call FROM users
            WHERE json_extract(data, '$.isolate') IS NOT NULL
              AND CAST(json_extract(data, '$.isolate') AS TEXT) NOT IN ('', '0')
            ORDER BY call
        });
        $sth->execute;
        while (my ($call) = $sth->fetchrow_array) {
            push @isolated, $call;
        }
        $sth->finish;
    } else {
        # Explicit calls and non-SQLite installations retain existing semantics.
        my @calls = $all ? DXUser::get_all_calls() : @requested;
        for my $call (@calls) {
            my $user = DXUser::get_current($call);
            push @isolated, $call if $user && $user->isolate;
        }
    }

    my $count = scalar @isolated;
    my @out;
    while (@isolated) {
        my @row = splice @isolated, 0, 5;
        push @row, '' while @row < 5;
        push @out, sprintf '%-12s %-12s %-12s %-12s %-12s', @row;
    }
    push @out, $self->msg('rec', $count);
    return @out;
}
