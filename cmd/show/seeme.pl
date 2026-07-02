#
# show/registered
#
# show all registered users 
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
#
#

sub handle
{
	my ($self, $line) = @_;
	return (1, $self->msg('e5')) unless $self->priv >= 9;

	my @out;

	use DB_File;

	if ($line) {
		$line =~ s/[^\w\-\/]+//g;
		$line = "\U\Q$line";
	}

	if ($self->{_nospawn} || $main::is_win == 1 || DXUser::using_database()) {
		@out = generate($self, $line);
	} else {
		@out = $self->spawn_cmd("show/seeme $line", sub { return (generate($self, $line)); });
	}

	return (1, @out);
}

sub generate
{
	my $self = shift;
	my $line = shift;
	my @out;
	my @val;

#	dbg("set/register line: $line");

	my %call = ();
	$call{$_} = 1 for split /\s+/, $line;
	delete $call{'ALL'};

	my ($action, $count, $key, $data) = (0,0,0,0);
	if (DXUser::using_database()) {
		my $sth = $DXUser::dbh->prepare(q{select * from users where data not like '%"rbnseeme":"%'});
		my $r;
		$r = $sth->execute;
		while ($r =$sth->fetch) {
			my ($k, $d) =@$r;
			if ($d =~ m{"rbnseeme":}) {
				$call{$k} = 1;       # possible candidate
			}
		}
	}
	else {
		unless (keys %call) {
			for ($action = DXUser::R_FIRST, $count = 0; !$DXUser::dbm->seq($key, $data, $action); $action = DXUser::R_NEXT) {
				if ($data =~ m{rbnseeme}) {
					$call{$key} = 1; # possible candidate
				}
			}
		}
	}
	
	foreach $key (sort keys %call) {
		my $u = DXUser::get_current($key);
		if ($u && defined (my $r = $u->rbnseeme)) {
			my $o = DXChannel::get($key);
			push @val, "${key}($r)" . ($o ? '+' : '');
			++$count;
		}
	}

	my @l;
	push @out, "RBN See Me Users";
	foreach my $call (@val) {
		if (@l >= 5) {
			push @out, sprintf "%-14s %-14s %-14s %-14s %-14s", @l;
			@l = ();
		}
		push @l, $call;
	}
	if (@l) {
		push @l, "" while @l < 5;
		push @out, sprintf "%-14s %-14s %-14s %-14s %-14s", @l;
	}

	push @out, $self->msg('rec', $count);
	return @out;
	
}

