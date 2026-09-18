#
# DXSpider read-only supervision facade
#
# Deliberately passive: no timers, no I/O, no persistence and no subprocesses.
# Data is collected only when an authenticated dxweb-admin client requests it.
#
package DXSupervisor;

use strict;
use DXHealth;
use Time::HiRes qw(time);
use DXChannel;
use Msg;
use Spot;
use Route::Node;
use DXUser;

our $VERSION = '0.3';
our $SCHEMA_VERSION = 1;
our $MAX_CONNECTIONS = 512;
our $boot_id = join('-', time(), $$, int(rand(0x7fffffff)));
our %self_health = (
    requests => 0,
    errors => 0,
    last_request => 0,
    last_generation_ms => 0,
    max_generation_ms => 0,
);

sub _num { return defined $_[0] && !ref($_[0]) && $_[0] =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/ ? 0 + $_[0] : 0 }
sub _qlen {
    my ($v) = @_;
    return 0 unless ref $v;
    return scalar(@$v) if ref($v) eq 'ARRAY';
    return scalar(keys %$v) if ref($v) eq 'HASH';
    return 0;
}
sub _bool { return $_[0] ? 1 : 0 }
sub _maybe_bool { return undef unless defined $_[0]; return $_[0] ? 1 : 0 }

# DXSpider deliberately stores a peer DXSpider software version in the
# historic protocol-normalised form (e.g. 1.57 -> 54.57).  Decode it only
# for channels which DXSpider itself classifies as DXSpider; never apply
# this transform to other cluster software.
sub _dxspider_version {
    my ($c, $raw) = @_;
    return undef unless defined $raw && !ref($raw) && $raw =~ /^\d+(?:\.\d+)?$/;
    return undef unless eval { $c->is_spider };
    my $v = 0 + $raw;
    return sprintf('%.2f', $v - 53) if $v >= 53 && $v < 59;
    return "$raw";
}
sub _kind {
    my ($c) = @_;
    return 'rbn'  if eval { $c->is_rbn };
    return 'web'  if eval { $c->is_web };
    return 'node' if eval { $c->is_node };
    return 'user' if eval { $c->is_user };
    return 'other';
}
sub _base {
    return {
        schema_version => $SCHEMA_VERSION,
        supervisor_version => $VERSION,
        boot_id => $boot_id,
        collected_at => time(),
    };
}
sub capabilities {
    return [qw(status connections traffic web rbn self_health)];
}
sub status {
    my @all = DXChannel::get_all();
    my %k = (user=>0,node=>0,rbn=>0,web=>0,other=>0);
    my ($qtotal,$qmax,$qnonempty)=(0,0,0);
    for my $c (@all) {
        my $kind = _kind($c); $k{$kind}++;
        my $q = _qlen($c->{inqueue});
        $qtotal += $q; $qmax = $q if $q > $qmax; $qnonempty++ if $q;
    }
    my $o = _base();
    $o->{node} = $main::mycall || '';
    $o->{version} = defined $main::version ? "$main::version" : '';
    $o->{build} = defined $main::build ? "$main::build" : '';
    $o->{git_branch} = defined $main::gitbranch ? "$main::gitbranch" : '';
    $o->{git_version} = defined $main::gitversion ? "$main::gitversion" : '';
    $o->{started_at} = _num($main::starttime);
    $o->{uptime_seconds} = $main::starttime ? int(time() - $main::starttime) : 0;
    $o->{cpu_self_seconds} = _num($main::clssecs);
    $o->{cpu_children_seconds} = _num($main::cldsecs);
    $o->{channels} = scalar @all;
    $o->{users} = $k{user}; $o->{nodes} = $k{node}; $o->{rbn} = $k{rbn}; $o->{web} = $k{web}; $o->{other} = $k{other};
    $o->{pending_connects} = scalar(@main::outstanding_connects);
    $o->{input_queue_total} = $qtotal; $o->{input_queue_max} = $qmax; $o->{input_queue_nonempty} = $qnonempty;
    return $o;
}
sub connections {
    my @all = sort { ($a->{call}||'') cmp ($b->{call}||'') } DXChannel::get_all();
    my $truncated = @all > $MAX_CONNECTIONS ? 1 : 0;
    splice(@all, $MAX_CONNECTIONS) if @all > $MAX_CONNECTIONS;
    my @rows;
    for my $c (@all) {
        my $conn = $c->{conn};
        my $user = $c->{user};
        my $rnode = eval { Route::Node::get($c->{call}) };
        push @rows, {
            call => $c->{call} || '', kind => _kind($c), sort => $c->{sort} || '', state => $c->{state} || '',
            connected_since => _num($c->{startt}), outbound => _bool($c->{outbound}), errors => _num($c->{errors}),
            ip => $c->{hostname} || ($conn ? ($conn->{peerhost} || '') : ''),
            registered => defined $c->{registered} ? _bool($c->{registered}) : undef,
            password_configured => $user ? ((eval { $user->passwd }) ? 1 : 0) : undef,
            # On a physical DXSpider connection usedpasswd means exactly
            # "password was used"; it is not the Web logical-user auth flag.
            password_used => $conn ? _maybe_bool($conn->{usedpasswd}) : undef,
            cnum => ($conn && defined $conn->{cnum}) ? _num($conn->{cnum}) : undef,
            queue_depth => _qlen($c->{inqueue}), lastping => _num($c->{lastping}), nopings => _num($c->{nopings}), pingave => _num($c->{pingave}),
            bytes_in => $conn ? _num($conn->{datain}) : 0, bytes_out => $conn ? _num($conn->{dataout}) : 0,
            lines_in => $conn ? _num($conn->{linesin}) : 0, lines_out => $conn ? _num($conn->{linesout}) : 0,
            protocol_version_raw => (defined $c->{version} && $c->{version} ne '') ? $c->{version} : ($rnode ? $rnode->version : undef),
            dxspider_version => _dxspider_version($c, (defined $c->{version} && $c->{version} ne '') ? $c->{version} : ($rnode ? $rnode->version : undef)),
            build => defined $c->{build} && $c->{build} ne '' ? $c->{build} : ($rnode ? $rnode->build : undef),
            git_branch => $rnode ? $rnode->gitbranch : undef,
            git_version => $rnode ? $rnode->gitversion : undef,
            do_pc9x => $rnode ? _maybe_bool($rnode->do_pc9x) : (defined $c->{do_pc9x} ? _maybe_bool($c->{do_pc9x}) : undef),
            via_pc92 => $rnode ? _maybe_bool($rnode->via_pc92) : undef,
            is_self => (($c->{call} || '') eq ($main::mycall || '')) ? 1 : 0,
        };
    }
    my $o=_base(); $o->{total}=scalar(DXChannel::get_all()); $o->{truncated}=$truncated; $o->{connections}=\@rows; return $o;
}
sub traffic {
    my $o=_base();
    $o->{transport}={bytes_in=>_num($Msg::total_in),bytes_out=>_num($Msg::total_out),lines_in=>_num($Msg::total_lines_in),lines_out=>_num($Msg::total_lines_out)};
    $o->{spots}={total=>_num($Spot::totalspots),hf=>_num($Spot::hfspots),vhf=>_num($Spot::vhfspots)};

    # DXProtHandle already maintains these counters for show/spotstats.
    # Reading the getter is passive: no command is executed, no packet is
    # generated and no additional hot-path instrumentation is introduced.
    # The counters describe logical spot reception/promotion, not physical
    # per-neighbour traffic, so no OUT or PC92 values are inferred here.
    if (defined &DXProt::get_pc11_61_stats) {
        my $r = eval { DXProt::get_pc11_61_stats() };
        if ($r && ref($r) eq 'HASH') {
            $o->{pc_spots} = {
                pc11_received => _num($r->{pc11_rx}),
                pc61_received => _num($r->{pc61_rx}),
                pc11_promoted_by_pc61 => _num($r->{pc11_to_61}),
                pc11_promoted_by_route => _num($r->{rpc11_to_61}),
                pc11_promotions => _num($r->{promotions}),
                pc11_percent => _num($r->{pc11_percent}),
                promotions_percent => _num($r->{promotions_percent}),
            };
        }
    }
    my $pc92 = eval { DXHealth::pc92_snapshot() };
    $o->{pc92} = $pc92 if $pc92 && ref($pc92) eq 'HASH';
    return $o;
}
sub web {
    my @rows;
    for my $c (DXChannel::get_all()) {
        next unless eval { $c->is_web };
        my $conn=$c->{conn};
        my ($waiting,$can_write)=(0,0);
        if ($conn) { $waiting=eval{$conn->bytes_waiting}||0 if $conn->can('bytes_waiting'); $can_write=eval{$conn->can_write}?1:0 if $conn->can('can_write'); }
        my @users;
        if (ref($c->{web_users}) eq 'HASH') {
            for my $call (sort keys %{$c->{web_users}}) {
                my $u = $c->{web_users}{$call} || {};
                my $dxu = eval { DXUser::get_current($call) };
                push @users, {
                    call => $call, ip => $u->{ip} || '', startt => _num($u->{startt}),
                    authenticated => _bool($u->{authenticated}), priv => _num($u->{priv}),
                    registered => _bool($u->{registered}), password_used => _bool($u->{password_used}),
                    password_configured => ($dxu && eval { $dxu->passwd }) ? 1 : 0,
                    auth_source => $u->{auth_source} || '',
                };
            }
        }
        push @rows, {call=>$c->{call}||'',role=>$c->{web_role}||'',version=>_num($c->{web_version}),logical_users=>scalar(@users),users=>\@users,
            feed_accepted=>_num($c->{web_feed_accepted}),feed_dropped=>_num($c->{web_feed_dropped}),feed_saturated=>_bool($c->{web_feed_saturated}),bytes_waiting=>_num($waiting),can_write=>$can_write};
    }
    my $o=_base(); $o->{channels}=\@rows; return $o;
}
sub rbn {
    my @rows;
    for my $c (DXChannel::get_all()) {
        next unless eval { $c->is_rbn };
        push @rows, {call=>$c->{call}||'',lasttime=>_num($c->{lasttime}),queue_depth=>_qlen($c->{queue}),inrush_until=>_num($c->{inrushpreventor}),
            minute=>{raw=>_num($c->{noraw}),retrieved=>_num($c->{norbn}),delivered=>_num($c->{nospot}),users=>_qlen($c->{nousers})},
            ten_minute=>{raw=>_num($c->{noraw10}),retrieved=>_num($c->{norbn10}),delivered=>_num($c->{nospot10}),users=>_qlen($c->{nousers10})},
            hour=>{raw=>_num($c->{norawhour}),retrieved=>_num($c->{norbnhour}),delivered=>_num($c->{nospothour}),users=>_qlen($c->{nousershour})}};
    }
    my $o=_base(); $o->{channels}=\@rows; return $o;
}
sub self_health { my $o=_base(); $o->{health}={%self_health}; return $o; }
sub snapshot {
    my ($what)=@_; $what=lc($what||'');
    my %allowed=(status=>\&status,connections=>\&connections,traffic=>\&traffic,web=>\&web,rbn=>\&rbn,self_health=>\&self_health);
    return (0,{error=>'unsupported_snapshot'}) unless $allowed{$what};
    my $t=time(); $self_health{requests}++; $self_health{last_request}=$t;
    my ($ok,$data); $ok=eval{$data=$allowed{$what}->();1};
    my $ms=(time()-$t)*1000; $self_health{last_generation_ms}=0+$ms; $self_health{max_generation_ms}=$ms if $ms>$self_health{max_generation_ms};
    unless($ok){$self_health{errors}++;return(0,{error=>'snapshot_failed'})}
    $data->{generation_ms}=0+$ms; $data->{capabilities}=capabilities() if $what eq 'status';
    return(1,$data);
}
1;
