# PC92 live route integrity read only, SYSOP only.
# Runs inside the existing DXSpider command context. No SQL reads here.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->priv < 9;
my @out = ('PC92 ROUTE AUDIT v0.40 (LIVE / READ ONLY)');
my ($errors, $warnings, $checks) = (0, 0, 0);
my @issues;
my $limit = 30;
my $report = sub {
    my ($severity, $msg) = @_;
    ++$errors if $severity eq 'FAIL';
    ++$warnings if $severity eq 'WARN';
    push @issues, "$severity $msg" if @issues < $limit;
};
my %nodes = %Route::Node::list;
my %users = %Route::User::list;
for my $call (sort keys %nodes) {
    my $n = $nodes{$call};
    ++$checks;
    unless (ref($n) && ($n->{call} || '') eq $call) {
        $report->('FAIL', "node key/call mismatch $call"); next;
    }
    for my $field (qw(parent nodes users)) {
        unless (ref($n->{$field}) eq 'ARRAY') {
            $report->('FAIL', "node $call invalid $field array");
        }
    }
    next unless ref($n->{parent}) eq 'ARRAY' && ref($n->{nodes}) eq 'ARRAY' && ref($n->{users}) eq 'ARRAY';
    for my $field (qw(parent nodes users)) {
        my %seen;
        for my $v (@{$n->{$field}}) {
            $report->('FAIL', "node $call repeated $field $v") if ++$seen{$v} > 1;
        }
    }
    for my $parent (@{$n->{parent}}) {
        ++$checks;
        $report->('FAIL', "node $call self-parent") if $parent eq $call;
        my $p = $nodes{$parent};
        if (!$p) { $report->('FAIL', "node $call missing parent $parent"); next; }
        $report->('FAIL', "node $call parent $parent lacks reverse child")
            unless ref($p->{nodes}) eq 'ARRAY' && grep { $_ eq $call } @{$p->{nodes}};
    }
    for my $child (@{$n->{nodes}}) {
        ++$checks;
        my $c = $nodes{$child};
        if (!$c) { $report->('FAIL', "node $call missing child $child"); next; }
        $report->('FAIL', "node $call child $child lacks reverse parent")
            unless ref($c->{parent}) eq 'ARRAY' && grep { $_ eq $call } @{$c->{parent}};
    }
    for my $ucall (@{$n->{users}}) {
        ++$checks;
        my $u = $users{$ucall};
        if (!$u) { $report->('FAIL', "node $call missing user $ucall"); next; }
        $report->('FAIL', "node $call user $ucall lacks reverse parent")
            unless ref($u->{parent}) eq 'ARRAY' && grep { $_ eq $call } @{$u->{parent}};
    }
    if (defined($n->{usercount}) && $n->{usercount} =~ /^\d+$/ && $n->{usercount} != @{$n->{users}}) {
        $report->('WARN', "node $call usercount=$n->{usercount} list=" . scalar(@{$n->{users}}));
    }
}
for my $call (sort keys %users) {
    my $u = $users{$call};
    ++$checks;
    unless (ref($u) && ($u->{call} || '') eq $call) {
        $report->('FAIL', "user key/call mismatch $call"); next;
    }
    unless (ref($u->{parent}) eq 'ARRAY') {
        $report->('FAIL', "user $call invalid parent array"); next;
    }
    my %seen;
    for my $parent (@{$u->{parent}}) {
        ++$checks;
        $report->('FAIL', "user $call repeated parent $parent") if ++$seen{$parent} > 1;
        my $p = $nodes{$parent};
        if (!$p) { $report->('FAIL', "user $call missing parent $parent"); next; }
        $report->('FAIL', "user $call parent $parent lacks reverse user")
            unless ref($p->{users}) eq 'ARRAY' && grep { $_ eq $call } @{$p->{users}};
    }
    $report->('WARN', "user $call has no parent") unless @{$u->{parent}};
}
push @out, 'Node records: ' . scalar(keys %nodes) . '  User records: ' . scalar(keys %users);
push @out, "Checks: $checks  FAIL: $errors  WARN: $warnings";
push @out, @issues;
push @out, 'Additional issues omitted: ' . ($errors + $warnings - @issues) if $errors + $warnings > @issues;
push @out, $errors ? 'RESULT: FAIL (live route integrity)' : $warnings ? 'RESULT: WARN (inspect warnings)' : 'RESULT: PASS (live route structural integrity)';
push @out, 'NOTE: SQLite is audited separately; PASS is not a PC92 atomicity proof.';
return (1, @out);
