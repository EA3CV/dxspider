#
# show/health
#
# Show DXSpider health and supervision information
#
# Uses DXSupervisor / DXHealth in-memory telemetry.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

my ($self, $line) = @_;

return (1, $self->msg('e5')) unless $self->priv >= 9;

$line ||= '';
$line =~ s/^\s+|\s+$//g;

my ($what, $arg) = split /\s+/, $line, 2;

$what = lc($what || 'status');
$arg  = uc($arg || '');
$arg =~ s/[^\w\-\/]+//g;

my @out;

if ($what eq 'status') {
	@out = generate_status($self);

} elsif ($what eq 'connections') {
	@out = generate_connections($self);

} elsif ($what eq 'traffic') {
	@out = generate_traffic($self);

} elsif ($what eq 'pc92') {
	@out = generate_pc92($self);

} elsif ($what eq 'peers') {
	@out = generate_peers($self, $arg);

} elsif ($what eq 'queues') {
	@out = generate_queues($self);

} elsif ($what eq 'web') {
	@out = generate_web($self);

} elsif ($what eq 'rbn') {
	@out = generate_rbn($self);

} elsif ($what eq 'topology') {
	@out = generate_topology($self);

} elsif ($what eq 'self_health') {
	@out = generate_self_health($self);

} elsif ($what eq 'all') {

	push @out, generate_status($self);
	push @out, " ";

	push @out, generate_connections($self);
	push @out, " ";

	push @out, generate_traffic($self);
	push @out, " ";

	push @out, generate_pc92($self);
	push @out, " ";

	push @out, generate_peers($self, '');
	push @out, " ";

	push @out, generate_queues($self);
	push @out, " ";

	push @out, generate_web($self);
	push @out, " ";

	push @out, generate_rbn($self);
	push @out, " ";

	push @out, generate_topology($self);
	push @out, " ";

	push @out, generate_self_health($self);

} else {
	@out = usage();
}

return (1, @out);


sub get_snapshot
{
	my $name = shift;

	my ($ok, $r) = DXSupervisor::snapshot($name);

	return unless $ok && ref($r) eq 'HASH';

	return $r;
}


sub number
{
	my $v = shift;

	return 0 unless defined $v && !ref($v);

	return 0 + $v;
}


sub display_text
{
	my $v = shift;

	return '-' unless defined $v && !ref($v) && length($v);

	return $v;
}


sub comma
{
	my $v = int(number(shift));

	my $sign = $v < 0 ? '-' : '';
	$v = abs($v);

	my $s = "$v";

	1 while $s =~ s/^(\d+)(\d{3})/$1,$2/;

	return $sign . $s;
}


sub yesno
{
	my $v = shift;

	return $v ? 'Yes' : 'No';
}


sub format_age
{
	my $s = int(number(shift));

	$s = 0 if $s < 0;

	my $d = int($s / 86400);
	$s %= 86400;

	my $h = int($s / 3600);
	$s %= 3600;

	my $m = int($s / 60);
	$s %= 60;

	return $d
		? sprintf("%dd %02d:%02d:%02d", $d, $h, $m, $s)
		: sprintf("%02d:%02d:%02d", $h, $m, $s);
}


sub format_since
{
	my $t = shift;

	return '-' unless defined $t &&
		!ref($t) &&
		$t =~ /^\d+(?:\.\d+)?$/;

	my $age = time() - $t;

	$age = 0 if $age < 0;

	return format_age($age);
}


sub short_state
{
	my $s = display_text(shift);

	return 'indiff' if lc($s) eq 'indifferent';

	return $s;
}


sub heading
{
	my $s = shift;

	return ($s, '=' x length($s));
}


#
# Determine update state from the same local and cached remote Git data
# used by dxweb-admin.  No fetch or network access is performed here.
#
# dxweb-admin maintains:
#
#     /spider/local_data/dxweb-update-check.git
#
# with refs/heads/mojo refreshed from the primary repository and, only
# on failure, from the EA3CV fallback.
#
# UPDATED has exactly the same semantics as dxweb-admin:
#
#     local branch == mojo
#     local version == remote version
#     local build == remote build
#     local full commit == remote full commit
#
sub git_capture
{
	my @cmd = @_;

	my $pid = open my $fh, '-|', @cmd;

	return unless defined $pid;

	local $/;

	my $out = <$fh>;

	close $fh;

	return if $? != 0;

	$out = '' unless defined $out;
	$out =~ s/\s+\z//;

	return $out;
}


sub update_parse_desc
{
	my $desc = shift;

	$desc = '' unless defined $desc;
	chomp $desc;

	return unless
		$desc =~ /^([\d.]+)(?:\.(\d+))?-(\d+)-g([0-9a-f]+)/;

	return {
		version    => $1,
		subversion => 0 + ($2 || 0),
		build      => 0 + $3,
		git        => $4,
	};
}


sub get_update_status
{
	my $cache  = '/spider/local_data/dxweb-update-check.git';
	my $branch = 'mojo';

	return {
		status => 'CHECK FAILED',
	} unless -d $cache;

	my $local_commit = git_capture(
		'git',
		'-C',
		'/spider',
		'rev-parse',
		'--verify',
		'HEAD^{commit}'
	);

	my $local_branch = git_capture(
		'git',
		'-C',
		'/spider',
		'symbolic-ref',
		'--quiet',
		'--short',
		'HEAD'
	);

	my $local_desc = git_capture(
		'git',
		'-C',
		'/spider',
		'describe',
		'--long'
	);

	my $remote_commit = git_capture(
		'git',
		'--git-dir=' . $cache,
		'rev-parse',
		'--verify',
		'refs/heads/' . $branch . '^{commit}'
	);

	my $remote_desc = git_capture(
		'git',
		'--git-dir=' . $cache,
		'describe',
		'--long',
		'refs/heads/' . $branch
	);

	return {
		status => 'CHECK FAILED',
	} unless
		defined $local_commit &&
		defined $local_branch &&
		defined $local_desc &&
		defined $remote_commit &&
		defined $remote_desc;

	my $ld = update_parse_desc($local_desc);
	my $rd = update_parse_desc($remote_desc);

	return {
		status => 'CHECK FAILED',
	} unless $ld && $rd;

	my $updated =
		$local_branch eq $branch &&
		$ld->{version} eq $rd->{version} &&
		$ld->{build} == $rd->{build} &&
		lc($local_commit) eq lc($remote_commit);

	return {
		status         => $updated ? 'UPDATED' : 'NOT UPDATED',
		branch         => $branch,
		local_branch   => $local_branch,
		local_version  => $ld->{version},
		local_build    => $ld->{build},
		local_commit   => $local_commit,
		remote_version => $rd->{version},
		remote_build   => $rd->{build},
		remote_commit  => $remote_commit,
	};
}

sub generate_status
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('status');

	unless ($r) {
		push @out, "Unable to obtain DXSpider health status";
		return @out;
	}

	my $update = get_update_status();

	push @out,
		heading(
			"DXSpider Health - " .
			display_text($r->{node})
		);

	push @out, "Git:";

	push @out, sprintf "  %-19s %s",
		"Branch:",
		display_text(
			exists $update->{local_branch}
				? $update->{local_branch}
				: $r->{git_branch}
		);

	push @out, sprintf "  %-19s %s",
		"Version:",
		display_text(
			exists $update->{local_version}
				? $update->{local_version}
				: (
					exists $r->{version}
						? $r->{version}
						: $r->{git_version_number}
				)
		);

	push @out, sprintf "  %-19s %s",
		"Build:",
		display_text(
			exists $update->{local_build}
				? $update->{local_build}
				: $r->{build}
		);

	my $commit =
		exists $update->{local_commit}
			? substr($update->{local_commit}, 0, 8)
			: $r->{git_version};

	push @out, sprintf "  %-19s %s",
		"Commit:",
		display_text($commit);

	push @out, sprintf "  %-19s %s",
		"State:",
		display_text($update->{status});

	push @out, sprintf "%-22s %s",
		"Uptime:",
		format_age($r->{uptime_seconds});

	push @out, sprintf "%-22s %s",
		"Channels:",
		comma($r->{channels});

	push @out, sprintf "%-22s %s",
		"Direct users:",
		comma(
			exists $r->{direct_users}
				? $r->{direct_users}
				: $r->{users}
		);

	push @out, sprintf "%-22s %s",
		"Network users:",
		comma($r->{network_users})
		if exists $r->{network_users};

	push @out, sprintf "%-22s %s",
		"Direct nodes:",
		comma(
			exists $r->{direct_nodes}
				? $r->{direct_nodes}
				: $r->{nodes}
		);

	push @out, sprintf "%-22s %s",
		"Network nodes:",
		comma($r->{network_nodes})
		if exists $r->{network_nodes};

	push @out, sprintf "%-22s %s",
		"RBN:",
		comma($r->{rbn});

	push @out, sprintf "%-22s %s",
		"Web:",
		comma($r->{web});

	push @out, sprintf "%-22s %s",
		"Pending connects:",
		comma($r->{pending_connects});

	push @out, sprintf "%-22s %s",
		"Input queue total:",
		comma($r->{input_queue_total});

	push @out, sprintf "%-22s %s",
		"Input queue max:",
		comma($r->{input_queue_max});

	push @out, sprintf "%-22s %s",
		"Queues non-empty:",
		comma($r->{input_queue_nonempty});

	return @out;
}


sub generate_connections
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('connections');

	unless ($r) {
		push @out, "Unable to obtain connection information";
		return @out;
	}

	my $rows = $r->{connections} || $r->{rows} || [];

	push @out, heading("DXSpider Connections");

	push @out,
		sprintf "%-10s  %-5s  %-7s  %-3s  %4s  %-11s  %-3s  %-3s  %-15s",
			"Call",
			"Type",
			"State",
			"Dir",
			"cnum",
			"State Age",
			"Reg",
			"Pwd",
			"Remote IP";

	push @out,
		sprintf "%-10s  %-5s  %-7s  %-3s  %4s  %-11s  %-3s  %-3s  %-15s",
			"-" x 10,
			"-" x 5,
			"-" x 7,
			"-" x 3,
			"-" x 4,
			"-" x 11,
			"-" x 3,
			"-" x 3,
			"-" x 15;

	my $count = 0;

	foreach my $x (@$rows) {

		next unless ref($x) eq 'HASH';

		++$count;

		my $call  = display_text($x->{call});
		my $kind  = display_text($x->{kind});
		my $state = short_state($x->{state});
		my $dir   = $x->{outbound} ? 'OUT' : 'IN';

		my $cnum =
			defined $x->{cnum} && !ref($x->{cnum})
				? $x->{cnum}
				: '-';

		my $age = '-';

		if (exists $x->{state_age}) {
			$age = format_age($x->{state_age});

		} elsif (exists $x->{connected_since}) {
			$age = format_since($x->{connected_since});
		}

		my $reg =
			exists $x->{registered}
				? yesno($x->{registered})
				: '-';

		my $pwd =
			exists $x->{password_configured}
				? yesno($x->{password_configured})
				: '-';

		my $ip = display_text(
			exists $x->{ip}
				? $x->{ip}
				: $x->{remote_ip}
		);

		if (length($ip) <= 15) {

			push @out,
				sprintf "%-10s  %-5s  %-7s  %-3s  %4s  %-11s  %-3s  %-3s  %-15s",
					$call,
					$kind,
					$state,
					$dir,
					$cnum,
					$age,
					$reg,
					$pwd,
					$ip;

		} else {

			push @out,
				sprintf "%-10s  %-5s  %-7s  %-3s  %4s  %-11s  %-3s  %-3s",
					$call,
					$kind,
					$state,
					$dir,
					$cnum,
					$age,
					$reg,
					$pwd;

			push @out,
				sprintf "  Remote IP: %s", $ip;
		}
	}

	push @out, "(no connections)" unless $count;

	return @out;
}


sub generate_traffic
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('traffic');

	unless ($r) {
		push @out, "Unable to obtain protocol traffic";
		return @out;
	}

	my $protocols =
		($r->{protocol} || {})->{protocols} || {};

	push @out, heading("Physical Protocol Traffic");

	push @out,
		sprintf "%-4s  %11s  %11s  %15s  %15s",
			"PC",
			"IN pkt",
			"OUT pkt",
			"IN bytes",
			"OUT bytes";

	push @out,
		sprintf "%-4s  %11s  %11s  %15s  %15s",
			"-" x 4,
			"-" x 11,
			"-" x 11,
			"-" x 15,
			"-" x 15;

	my $count = 0;

	foreach my $pc (sort keys %$protocols) {

		my $x = $protocols->{$pc};

		next unless ref($x) eq 'HASH';

		++$count;

		my $name = $pc;
		$name =~ s/^PC//i;

		push @out,
			sprintf "%-4s  %11s  %11s  %15s  %15s",
				$name,
				comma($x->{in}{packets}),
				comma($x->{out}{packets}),
				comma($x->{in}{bytes}),
				comma($x->{out}{bytes});
	}

	push @out,
		"(no protocol traffic recorded)"
		unless $count;

	return @out;
}


sub generate_pc92
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('traffic');

	unless ($r) {
		push @out, "Unable to obtain PC92 traffic";
		return @out;
	}

	my $p = $r->{pc92} || {};

	push @out, heading("PC92 Traffic");

	push @out,
		sprintf "%-13s  %9s  %9s  %9s  %9s  %11s",
			"Direction",
			"A",
			"C",
			"D",
			"K",
			"Total";

	push @out,
		sprintf "%-13s  %9s  %9s  %9s  %9s  %11s",
			"-" x 13,
			"-" x 9,
			"-" x 9,
			"-" x 9,
			"-" x 9,
			"-" x 11;

	foreach my $kind (qw(generated received forwarded)) {

		my $b = $p->{logical}{$kind} || {};

		my @v =
			map {
				number($b->{$_}{packets})
			} qw(A C D K);

		my $total = 0;
		$total += $_ for @v;

		push @out,
			sprintf "%-13s  %9s  %9s  %9s  %9s  %11s",
				ucfirst($kind),
				(map { comma($_) } @v),
				comma($total);
	}

	foreach my $dir (qw(in out)) {

		my $b = $p->{totals}{$dir} || {};

		my @v =
			map {
				number($b->{$_}{packets})
			} qw(A C D K);

		my $total = 0;
		$total += $_ for @v;

		push @out,
			sprintf "%-13s  %9s  %9s  %9s  %9s  %11s",
				"Physical " . uc($dir),
				(map { comma($_) } @v),
				comma($total);
	}

	return @out;
}


sub generate_peers
{
	my ($self, $call) = @_;

	my @out;

	my $r = get_snapshot('traffic');

	unless ($r) {
		push @out, "Unable to obtain peer traffic";
		return @out;
	}

	my $peers =
		($r->{protocol} || {})->{peers} || {};

	my @names =
		grep {
			!$call || uc($_) eq $call
		} sort keys %$peers;

	push @out,
		heading(
			$call
				? "Direct Peer - $call"
				: "Direct Peer Traffic"
		);

	unless (@names) {
		push @out, "(no matching peer telemetry)";
		return @out;
	}

	my $multi = @names > 1 ? 1 : 0;

	my $n = 0;

	foreach my $peer (@names) {

		++$n;

		push @out, " " if $n > 1;

		push @out, $peer if $multi || !$call;

		push @out,
			sprintf "%-6s  %16s  %16s",
				"PC",
				"IN pkt",
				"OUT pkt";

		push @out,
			sprintf "%-6s  %16s  %16s",
				"-" x 6,
				"-" x 16,
				"-" x 16;

		foreach my $pc (
			sort keys %{$peers->{$peer} || {}}
		) {

			my $x = $peers->{$peer}{$pc};

			next unless ref($x) eq 'HASH';

			my $name = $pc;
			$name =~ s/^PC//i;

			push @out,
				sprintf "%-6s  %16s  %16s",
					$name,
					comma($x->{in}{packets}),
					comma($x->{out}{packets});
		}
	}

	return @out;
}


sub generate_queues
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('status');

	unless ($r) {
		push @out, "Unable to obtain queue information";
		return @out;
	}

	push @out, heading("DXSpider Queues");

	push @out, sprintf "%-25s %s",
		"Input queue total:",
		comma($r->{input_queue_total});

	push @out, sprintf "%-25s %s",
		"Input queue maximum:",
		comma($r->{input_queue_max});

	push @out, sprintf "%-25s %s",
		"Non-empty input queues:",
		comma($r->{input_queue_nonempty});

	push @out, sprintf "%-25s %s",
		"Pending connects:",
		comma($r->{pending_connects});

	return @out;
}


sub generate_web
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('web');

	unless ($r) {
		push @out, "Unable to obtain web transport information";
		return @out;
	}

	my $rows = $r->{channels} || [];

	push @out, heading("Web Transport");

	push @out,
		sprintf "%-10s  %-12s  %5s  %10s  %10s",
			"Call",
			"Role",
			"Users",
			"TX queue",
			"Dropped";

	push @out,
		sprintf "%-10s  %-12s  %5s  %10s  %10s",
			"-" x 10,
			"-" x 12,
			"-" x 5,
			"-" x 10,
			"-" x 10;

	my $count = 0;

	foreach my $x (
		sort {
			display_text($a->{call})
				cmp
			display_text($b->{call})
		} @$rows
	) {

		next unless ref($x) eq 'HASH';

		++$count;

		push @out,
			sprintf "%-10s  %-12s  %5s  %10s  %10s",
				display_text($x->{call}),
				display_text($x->{role}),
				comma($x->{logical_users}),
				comma($x->{bytes_waiting}),
				comma($x->{feed_dropped});
	}

	push @out,
		"(no #WEB channels)"
		unless $count;

	my @users;

	foreach my $x (@$rows) {

		next unless ref($x) eq 'HASH';

		my $channel = display_text($x->{call});
		my $u = $x->{users};

		next unless ref($u) eq 'ARRAY';

		foreach my $user (@$u) {

			next unless ref($user) eq 'HASH';

			push @users, {
				channel => $channel,
				%$user,
			};
		}
	}

	if (@users) {

		push @out, " ";

		push @out, "Logical Web Users";
		push @out, "-" x length("Logical Web Users");

		push @out,
			sprintf "%-8s  %-10s  %-3s  %-3s  %4s  %-11s  %-15s",
				"Channel",
				"Call",
				"Reg",
				"Pwd",
				"Priv",
				"State Age",
				"Real IP";

		push @out,
			sprintf "%-8s  %-10s  %-3s  %-3s  %4s  %-11s  %-15s",
				"-" x 8,
				"-" x 10,
				"-" x 3,
				"-" x 3,
				"-" x 4,
				"-" x 11,
				"-" x 15;

		foreach my $u (
			sort {
				display_text($a->{channel})
					cmp
				display_text($b->{channel})
				||
				display_text($a->{call})
					cmp
				display_text($b->{call})
			} @users
		) {

			my $age = '-';

			if (exists $u->{state_age}) {
				$age = format_age($u->{state_age});

			} elsif (exists $u->{startt}) {
				$age = format_since($u->{startt});

			} elsif (exists $u->{connected_since}) {
				$age = format_since($u->{connected_since});
			}

			my $reg =
				exists $u->{registered}
					? yesno($u->{registered})
					: '-';

			my $pwd =
				exists $u->{password_configured}
					? yesno($u->{password_configured})
					: '-';

			my $priv =
				defined $u->{priv} &&
				!ref($u->{priv})
					? $u->{priv}
					: '-';

			my $ip = display_text(
				exists $u->{ip}
					? $u->{ip}
					: $u->{real_ip}
			);

			if (length($ip) <= 15) {

				push @out,
					sprintf "%-8s  %-10s  %-3s  %-3s  %4s  %-11s  %-15s",
						display_text($u->{channel}),
						display_text($u->{call}),
						$reg,
						$pwd,
						$priv,
						$age,
						$ip;

			} else {

				push @out,
					sprintf "%-8s  %-10s  %-3s  %-3s  %4s  %-11s",
						display_text($u->{channel}),
						display_text($u->{call}),
						$reg,
						$pwd,
						$priv,
						$age;

				push @out,
					sprintf "  Real IP: %s",
						$ip;
			}
		}
	}

	return @out;
}


sub generate_rbn
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('rbn');

	unless ($r) {
		push @out, "Unable to obtain RBN information";
		return @out;
	}

	my $rows = $r->{channels} || [];

	push @out, heading("RBN");

	push @out,
		sprintf "%-10s  %6s  %9s  %10s  %10s  %7s",
			"Call",
			"Queue",
			"Raw",
			"Retrieved",
			"Delivered",
			"Users";

	push @out,
		sprintf "%-10s  %6s  %9s  %10s  %10s  %7s",
			"-" x 10,
			"-" x 6,
			"-" x 9,
			"-" x 10,
			"-" x 10,
			"-" x 7;

	my $count = 0;

	foreach my $x (
		sort {
			display_text($a->{call})
				cmp
			display_text($b->{call})
		} @$rows
	) {

		next unless ref($x) eq 'HASH';

		++$count;

		my $m = $x->{minute} || {};

		push @out,
			sprintf "%-10s  %6s  %9s  %10s  %10s  %7s",
				display_text($x->{call}),
				comma($x->{queue_depth}),
				comma($m->{raw}),
				comma($m->{retrieved}),
				comma($m->{delivered}),
				comma($m->{users});
	}

	push @out,
		"(no RBN channels)"
		unless $count;

	return @out;
}


sub generate_topology
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('status');

	unless ($r) {
		push @out, "Unable to obtain topology information";
		return @out;
	}

	push @out, heading("Topology");

	push @out, sprintf "%-22s %s",
		"Direct users:",
		comma(
			exists $r->{direct_users}
				? $r->{direct_users}
				: $r->{users}
		);

	push @out, sprintf "%-22s %s",
		"Network users:",
		comma($r->{network_users})
		if exists $r->{network_users};

	push @out, sprintf "%-22s %s",
		"Direct nodes:",
		comma(
			exists $r->{direct_nodes}
				? $r->{direct_nodes}
				: $r->{nodes}
		);

	push @out, sprintf "%-22s %s",
		"Network nodes:",
		comma($r->{network_nodes})
		if exists $r->{network_nodes};

	return @out;
}


sub generate_self_health
{
	my ($self) = @_;

	my @out;

	my $r = get_snapshot('self_health');

	unless ($r) {
		push @out,
			"Unable to obtain DXSupervisor self health";

		return @out;
	}

	my $h = $r->{health} || {};

	push @out,
		heading("DXSupervisor Self Health");

	push @out, sprintf "%-25s %s",
		"Requests:",
		comma($h->{requests});

	push @out, sprintf "%-25s %s",
		"Errors:",
		comma($h->{errors});

	push @out, sprintf "%-25s %.3f ms",
		"Last generation:",
		number($h->{last_generation_ms});

	push @out, sprintf "%-25s %.3f ms",
		"Maximum generation:",
		number($h->{max_generation_ms});

	return @out;
}


sub usage
{
	return (
		"show/health [status|connections|traffic|pc92|peers [CALL]|" .
		"queues|web|rbn|topology|self_health|all]"
	);
}
