#
# show (or find) list of bad dx nodes
#
# Copyright (c) 2021-2023 - Dirk Koopman G1TLH
#
#
#
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
# are we permitted?
return (1, $self->msg('e5')) if $self->priv < 6;
return (1, q{Please install Net::CIDR::Lite or libnet-cidr-lite-perl to use this command}) unless $DXCIDR::active;

my @out;
my @added;
my @in = grep { length } split /\s+/, $line;
my $maxlth = 0;
my $width = $self->width // 80;
my $count = 0;

#$DB::single = 1;

# query
if (@in) {
	
	foreach my $ip (@in) {
		my $state = eval { DXCIDR::coverage($ip) };
		return (1, "show/badip: $@") if $@;
		push @out, "$ip $state";
		++$count if $state ne 'CLEAN';
	}
	return (1, @out);
} else {
# list
	my @list = map {my $s = $_; $s =~ s!/(?:32|128)$!!; $maxlth = length $s if length $s > $maxlth; $s =~ /^1$/?undef:$s} DXCIDR::list();
	my @l;
	$maxlth //= 20;
	my $n = int ($width/($maxlth+1));
	my $format = "\%-${maxlth}s " x $n;
	chop $format;

	foreach my $list (@list) {
		++$count;
		if (@l > $n) {
			push @out, sprintf $format, @l;
			@l = ();
		}
		push @l, $list;
	}	
	push @l, "" while @l < $n;
	push @out, sprintf $format, @l;
}

push @out, "show/badip: $count records found";
return (1, @out);
