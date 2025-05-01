#
# display the band data
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
#
#

sub print_entries
{
	my $name = shift;
	my $ref = shift;
	my $level = shift || '';

	my $s = sprintf "%s%10s: ", $level, $name;
	for (my $i = 0; $i < @$ref; $i += 2) {
		my $from = $ref->[$i];
		my $to = $ref->[$i+1];
		$s .= ", " if $i;
		$s .= "$from -> $to";
	}
	return $s;
}
	
sub handle
{
	my ($self, $line) = @_;

#	$DB::single = 1;
	my @f = split m|[\s,]|, $line;
	my @bands = grep {Bands::get($_)?$_:()} @f;
	my @regs = grep {Bands::get_region($_)?$_:()} @f;
	my $band;
	my @out;
	my $i;

	unless (@f) {
		@bands = Bands::get_keys();
		@regs =  Bands::get_region_keys();
	}
	if (@bands) {
		@bands = sort { Bands::get($a)->band->[0] <=> Bands::get($b)->band->[0] } @bands;
		push @out, @f ? "Band:-" : "Bands Available:-";
		foreach my $name (@bands) {
			my $band = Bands::get($name);
			my $ref = $band->band;
			my $s = print_entries($name, $ref);
			push @out, $s;
			
			# has it been specifically asked for on the command line
			# then show its subbands
			if (grep {$name eq $_} @f ) {
				my @subband = sort {$band->{$a}->[0] <=> $band->{$b}->[0]} keys %$band;
				foreach my $subband (@subband) {
					next if $subband eq 'band';
					$s = print_entries($subband, $band->{$subband}, ' ' x 8);
					push @out, $s;
				}
			}
		}
	}

	if (@regs) {
		push @out, "Regions Available:-";
		@regs = sort @regs;
		foreach my $region (@regs) {
			my $ref = Bands::get_region($region);
			my $s = sprintf("%10s: ", $region ) . join(' ', @{$ref});
			push @out, $s;
		}
	}

	return (1, @out);
}
