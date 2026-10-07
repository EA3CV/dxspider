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

} elsif ($what eq 'filtering') {
	@out = generate_filtering($self);
} elsif ($what eq 'diagnostics') {
	@out = generate_diagnostics($self);

} elsif ($what eq 'origins') {
	@out = generate_protocol_origins($self);

} elsif ($what eq 'bursts') {
	@out = generate_bursts($self);

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

	push @out, generate_filtering($self);
	push @out, " ", generate_diagnostics($self);
	push @out, " ";

	push @out, generate_protocol_origins($self);
	push @out, " ";

	push @out, generate_bursts($self);
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

	my $tot = $r->{connection_totals} || {};
	push @out, " ";
	push @out, sprintf "%-22s  %12s", "Connect events:", comma($tot->{connects});
	push @out, sprintf "%-22s  %12s", "Disconnect events:", comma($tot->{disconnects});
	push @out, sprintf "%-22s  %12s", "Too many events:", comma($tot->{too_many});
	my $login = $r->{incoming_login} || {};
	push @out, " ";
	push @out, sprintf "%-22s  %12s", "Login attempts:", comma($login->{attempts});
	push @out, sprintf "%-22s  %12s", "Login successful:", comma($login->{successful});
	push @out, sprintf "%-22s  %12s", "Rapid-login throttled:", comma($login->{rapid_throttled});

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


sub generate_filtering
{
    my ($self) = @_;
    my @out;
    my $r = get_snapshot('traffic');
    unless ($r) { push @out, "Unable to obtain filtering information"; return @out; }
    my $op = $r->{operator_events} || {};
    my $diag = (($r->{protocol} || {})->{input_diagnostics} || {});

    push @out, heading("Filtering / Rejects");
    push @out, sprintf "%-24s  %12s", "Reason", "Count";
    push @out, sprintf "%-24s  %12s", "-" x 24, "-" x 12;
    my @rows = (
        ['Bad DX',       $op->{badlist}{baddx}{total}],
        ['Bad spotter',  $op->{badlist}{badspotter}{total}],
        ['Bad node',     $op->{badlist}{badnode}{total}],
        ['Bad word',     $op->{badlist}{badword}{total}],
        ['PC61 badip',   $op->{pc61_drop}{badip}{total}],
        ['PC61 non-public IP', $op->{pc61_drop}{non_public_ip}{total}],
        ['Local spot duplicate', $op->{spots}{duplicate_local_user}{total}],
        ['Malformed protocol', $diag->{malformed}{packets}],
        ['Unknown protocol', $diag->{unknown_protocol}{packets}],
    );
    push @out, sprintf "%-24s  %12s", $_->[0], comma($_->[1]) for @rows;

    my %origin;
    my %peer;
    for my $family (qw(badlist pc61_drop)) {
        for my $reason (keys %{$op->{$family} || {}}) {
            my $e = $op->{$family}{$reason} || {};
            $origin{$_} += number($e->{by_origin}{$_}) for keys %{$e->{by_origin} || {}};
            my $neighbour = $e->{by_neighbour} || $e->{by_peer} || {};
            $peer{$_} += number($neighbour->{$_}) for keys %$neighbour;
        }
    }
    for my $set (["Top reject origins", \%origin], ["Top reject neighbours", \%peer]) {
        my ($title,$h)=@$set; my @k=sort { $h->{$b}<=>$h->{$a} || $a cmp $b } keys %$h;
        splice(@k,5) if @k>5; next unless @k;
        push @out, " ", $title, "-" x length($title);
        push @out, sprintf "%-16s  %12s", "Call", "Count";
        push @out, sprintf "%-16s  %12s", "-" x 16, "-" x 12;
        push @out, sprintf("%-16s  %12s", $_, comma($h->{$_})) for @k;
    }
    return @out;
}



sub generate_diagnostics
{
    my ($self) = @_;
    my @out;
    my $r = get_snapshot('traffic');
    unless ($r) { push @out, "Unable to obtain diagnostics information"; return @out; }
    my $op = $r->{operator_events} || {};
    my $diag = (($r->{protocol} || {})->{input_diagnostics} || {});

    push @out, heading("Diagnostics");
    push @out, "Protocol boundary rejects (origin unavailable at this boundary)";
    push @out, sprintf "%-18s  %12s  %14s", "Cause", "Packets", "Bytes";
    push @out, sprintf "%-18s  %12s  %14s", "-" x 18, "-" x 12, "-" x 14;
    push @out, sprintf "%-18s  %12s  %14s", "Malformed", comma($diag->{malformed}{packets}), comma($diag->{malformed}{bytes});
    push @out, sprintf "%-18s  %12s  %14s", "Unknown protocol", comma($diag->{unknown_protocol}{packets}), comma($diag->{unknown_protocol}{bytes});

    my $bypc = $diag->{malformed}{by_pc} || {};
    my @pcs = sort { number($bypc->{$b}{packets}) <=> number($bypc->{$a}{packets}) || $a cmp $b } keys %$bypc;
    if (@pcs) {
        push @out, " ", "Malformed by PC", "---------------";
        push @out, sprintf "%-6s  %12s  %14s  %-24s", "PC", "Packets", "Bytes", "Bad fields";
        push @out, sprintf "%-6s  %12s  %14s  %-24s", "-" x 6, "-" x 12, "-" x 14, "-" x 24;
        for my $pc (@pcs) {
            my $x=$bypc->{$pc}||{}; my $f=$x->{fields}||{};
            my $fields=join(',', map { $_ . ':' . number($f->{$_}) } sort {$a<=>$b} grep {/^[0-9]+$/} keys %$f);
            $fields='-' unless length $fields; $fields=substr($fields,0,24);
            push @out, sprintf "%-6s  %12s  %14s  %-24s", $pc, comma($x->{packets}), comma($x->{bytes}), $fields;
        }
    }

    my $peers=$diag->{peers}||{};
    my @peers=sort {
        my $at=number($peers->{$a}{malformed}{packets})+number($peers->{$a}{unknown_protocol}{packets});
        my $bt=number($peers->{$b}{malformed}{packets})+number($peers->{$b}{unknown_protocol}{packets});
        $bt<=>$at || $a cmp $b
    } keys %$peers;
    if (@peers) {
        splice(@peers,10) if @peers>10;
        push @out, " ", "Boundary rejects by neighbour", "-----------------------------";
        push @out, sprintf "%-16s  %12s  %12s  %12s", "Neighbour", "Malformed", "Unknown", "Total";
        push @out, sprintf "%-16s  %12s  %12s  %12s", "-" x 16, "-" x 12, "-" x 12, "-" x 12;
        for my $peer (@peers) {
            my $m=number($peers->{$peer}{malformed}{packets}); my $u=number($peers->{$peer}{unknown_protocol}{packets});
            push @out, sprintf "%-16s  %12s  %12s  %12s", $peer, comma($m), comma($u), comma($m+$u);
        }
    }

    push @out, " ", "Proven filtering/drop decisions", "-------------------------------";
    push @out, sprintf "%-20s  %-22s  %12s", "Family", "Reason", "Count";
    push @out, sprintf "%-20s  %-22s  %12s", "-" x 20, "-" x 22, "-" x 12;
    for my $spec ([badlist=>[qw(baddx badspotter badnode badword)]],[pc61_drop=>[qw(badip non_public_ip)]]) {
        my($fam,$reasons)=@$spec;
        for my $reason (@$reasons) { push @out, sprintf "%-20s  %-22s  %12s", $fam, $reason, comma($op->{$fam}{$reason}{total}); }
    }
    push @out, sprintf "%-20s  %-22s  %12s", 'spots', 'duplicate_local_user', comma($op->{spots}{duplicate_local_user}{total});
    push @out, sprintf "%-20s  %-22s  %12s", 'connections', 'badip', comma($op->{connections}{badip}{total});
    push @out, " ", "Scope: malformed/unknown have neighbour only; origin is not inferred.";
    push @out, "PC92 routing-policy returns are excluded from Diagnostics.";
    return @out;
}

sub generate_protocol_origins
{
    my ($self) = @_;
    my @out;
    my $r = get_snapshot('traffic');
    unless ($r) { push @out, "Unable to obtain protocol origin information"; return @out; }
    my $proto = $r->{protocol} || {};
    my $origins = $proto->{origins} || {};
    my $scope = $proto->{origin_scope} || {};

    push @out, heading("Logical Protocol Origins");
    push @out, "Coverage: PC11/61 field7; PC92 A/C/D/K pcall; PC93 validated onode";
    push @out, "Coverage is protocol-scoped; neighbour is never substituted for origin";
    push @out, sprintf "%-16s  %-5s  %10s  %12s", "Origin", "PC", "Accepted", "Forwarded";
    push @out, sprintf "%-16s  %-5s  %10s  %12s", "-" x 16, "-" x 5, "-" x 10, "-" x 12;
    my @rows;
    for my $origin (keys %$origins) {
        for my $pc (keys %{$origins->{$origin} || {}}) {
            my $x = $origins->{$origin}{$pc} || {};
            my $a = number($x->{accepted}{packets});
            my $f = number($x->{forwarded}{packets});
            push @rows, [$origin,$pc,$a,$f] if $a || $f;
        }
    }
    @rows = sort { ($b->[2]+$b->[3]) <=> ($a->[2]+$a->[3]) || $a->[0] cmp $b->[0] || $a->[1] cmp $b->[1] } @rows;
    splice(@rows,20) if @rows > 20;
    push @out, sprintf("%-16s  %-5s  %10s  %12s", $_->[0], $_->[1], comma($_->[2]), comma($_->[3])) for @rows;
    push @out, "(no protocol origins recorded yet)" unless @rows;
    return @out;
}

sub generate_bursts
{
    my ($self) = @_;
    my @out;
    my $path = '/spider/local_data/dxweb-bursts.json';
    push @out, heading("Traffic Rates / Bursts");
    unless (-f $path) { push @out, "Snapshot unavailable (dxweb-admin has not published it yet)"; return @out; }
    my @st=stat($path); my $size=$st[7]||0;
    if ($size <= 0 || $size > 65536) { push @out, "Snapshot invalid (size)"; return @out; }
    my $json='';
    my $fh;
    unless (open $fh,'<',$path) { push @out, "Snapshot unavailable (open failed)"; return @out; }
    binmode $fh; my $n=read($fh,$json,65537); close $fh;
    if (!defined($n) || $n>65536) { push @out, "Snapshot invalid (read)"; return @out; }
    my $r=eval { require JSON::PP; JSON::PP::decode_json($json) };
    unless (ref($r) eq 'HASH' && (($r->{schema_version}||0)==1 || ($r->{schema_version}||0)==2)) { push @out, "Snapshot invalid (schema/json)"; return @out; }
    my $age=time-number($r->{generated_at}); $age=0 if $age<0;
    push @out, sprintf "Snapshot age: %.0f s%s",$age,($age>90?'  STALE':'');
    if (($r->{schema_version}||0)>=2 && $r->{origin_available}) {
        push @out, "Primary dimension: logical origin";
        push @out, sprintf "%-15s  %8s  %8s  %6s  %-5s  %-5s",qw(Origin Latest Base Ratio Burst PC);
        push @out, sprintf "%-15s  %8s  %8s  %6s  %-5s  %-5s",'-'x15,'-'x8,'-'x8,'-'x6,'-'x5,'-'x5;
        my $oc=0; for my $x (@{$r->{origins}||[]}) { next unless ref($x) eq 'HASH'; $oc++; push @out,sprintf "%-15s  %8.2f  %8.2f  %6.2f  %-5s  %-5s",display_text($x->{origin}),number($x->{latest_pps}),number($x->{baseline_pps}),number($x->{deviation_ratio}),($x->{burst}?'YES':'no'),display_text($x->{dominant_pc}); last if $oc>=20 }
        push @out,"(no logical-origin rate data)" unless $oc;
        push @out,""; push @out,"Physical neighbour context (independent; no inferred join)";
    } else { push @out, "Origin: unavailable (not inferred)"; }
    push @out, sprintf "%-15s  %8s  %8s  %6s  %-5s  %-5s",qw(Neighbour Latest Base Ratio Burst PC);
    push @out, sprintf "%-15s  %8s  %8s  %6s  %-5s  %-5s",'-'x15,'-'x8,'-'x8,'-'x6,'-'x5,'-'x5;
    my $count=0;
    for my $x (@{$r->{neighbours}||[]}) {
        next unless ref($x) eq 'HASH'; $count++;
        push @out,sprintf "%-15s  %8.2f  %8.2f  %6.2f  %-5s  %-5s",
            display_text($x->{neighbour}),number($x->{latest_pps}),number($x->{baseline_pps}),number($x->{deviation_ratio}),($x->{burst}?'YES':'no'),display_text($x->{dominant_pc});
    }
    push @out,"(no neighbour rate data)" unless $count;
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
		"show/health [status|connections|traffic|filtering|diagnostics|origins|bursts|pc92|peers [CALL]|" .
		"queues|web|rbn|topology|self_health|all]"
	);
}
