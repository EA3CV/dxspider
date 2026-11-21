my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd || $self->priv < 6;
my @out;
for my $word (split /\s+/, uc $line) {
    my @errors = BadWords::add_word($word);
    push @out, @errors ? "BadWord $word: " . join('; ', @errors) : "BadWord $word added";
}
return (1, @out);
