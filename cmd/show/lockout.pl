#
# show/lockout
#
# show all excluded users 
#
# Copyright (c) 2000 Dirk Koopman G1TLH
#
#
#

sub handle
{
	my ($self, $line) = @_;
	return (1, $self->msg('e5')) unless $self->priv >= 9;
	return (1, $self->msg('lockoutuse')) unless $line;
	if ($self->{_nospawn} || $main::is_win == 1 || DXUser::using_database()) {
		return (1, generate($self, $line));
	}
	else {
		return (1, $self->spawn_cmd("show/lockout$line", sub { return (generate($self, $line)); }));
	}
}

sub generate
{
	my $self = shift;
	my $line = shift;
	
	my @out;
	my @val;
	my ($action, $count, $key, $data) = (0,0,0,0);

#	$DB::single = 1;
	push @val, split /\s+/, uc $line;
	if ($val[0] eq 'ALL') {
		shift @val;
		if (DXUser::using_database()) {
			my $sth = $DXUser::dbh->prepare(q{select * from users where data not like '%"lockout":"%'});
			my $r;
			$r = $sth->execute;
			while ($r =$sth->fetch) {
				my ($k, $d) =@$r;
				if ($d =~ m{"lockout":(\d)}) {
					push @val, "$k($1)";
				}
			}
		}
		else {
			for ($action = DXUser::R_FIRST, $count=0; !$DXUser::dbm->seq($key, $data, $action); $action = DXUser::R_NEXT) {
				if ($data =~ m{"lockout":}) {
					push @val, $key;
				}
			}
		}
	}	else {
		
	}
	
	my @l;
	foreach my $call (@val) {
		if (@l >= 5) {
			push @out, sprintf "%-12s %-12s %-12s %-12s %-12s", @l;
			@l = ();
		}
		push @l, $call;			
	}
	if (@l) {
		push @l, "" while @l < 5;
		push @out, sprintf "%-12s %-12s %-12s %-12s %-12s", @l;
	}
	
	push @out, $@ if $@;
	push @out, $self->msg('rec', $count);
	return @out;			
}


# @out = $self->spawn_cmd("show lockout $line", sub {
# 							my @out;
# 							my @val;
# 							my ($action, $count, $key, $data) = (0,0,0,0);
# 							eval qq{for (\$action = DXUser::R_FIRST, \$count = 0; !\$DXUser::dbm->seq(\$key, \$data, \$action); \$action = DXUser::R_NEXT) {
# 	if (\$data =~ m{lockout}) {
# 		if (\$line eq 'ALL' || \$key =~ /^$line/) {
# 			my \$ur = DXUser::get_current(\$key);
# 			if (\$ur && \$ur->lockout) {
# 				push \@val, \$key;
# 				++\$count;
# 			}
# 		}
# 	}
# } };

# 						});

# sub display
# {
# 	my @l;
# 	foreach my $call (@val) {
# 		if (@l >= 5) {
# 			push @out, sprintf "%-12s %-12s %-12s %-12s %-12s", @l;
# 			@l = ();
# 		}
# 		push @l, $call;
# 	}
# 	if (@l) {
# 		push @l, "" while @l < 5;
# 		push @out, sprintf "%-12s %-12s %-12s %-12s %-12s", @l;
# 	}
	
# 	push @out, $@ if $@;
# 	push @out, $self->msg('rec', $count);
# 	return @out;
# }

# return (1, @out);


