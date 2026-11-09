# PC92 v0.42 read-only route snapshot; emits compact TSV lines for offline SQL comparison.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->priv < 9;
my @out = ('PC92 SNAPSHOT v0.42 READ ONLY', 'FORMAT: KIND CALL PARENTS');
my ($nc,$uc)=(0,0);
for my $call (sort keys %Route::Node::list) {
    my $n=$Route::Node::list{$call};
    next unless $n && ref($n->{parent}) eq 'ARRAY';
    push @out, join("\t", 'NODE', $call, join(',', sort @{$n->{parent}}));
    ++$nc;
}
for my $call (sort keys %Route::User::list) {
    my $u=$Route::User::list{$call};
    next unless $u && ref($u->{parent}) eq 'ARRAY';
    push @out, join("\t", 'USER', $call, join(',', sort @{$u->{parent}}));
    ++$uc;
}
push @out, "END nodes=$nc users=$uc";
return (1,@out);
