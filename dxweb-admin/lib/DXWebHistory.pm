#
# DXWebHistory - DXSpider web supervision history and maintenance
#
# Historical metrics, semantic queries, timeline data and controlled
# local historical-data maintenance for DXSpider Web Administration.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#
package DXWebHistory;
use strict;
use warnings;
use utf8;
use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess;
use Mojo::JSON qw(encode_json decode_json);
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Find qw(find);
use Time::HiRes qw(time);
use Time::Local qw(timegm);

our $VERSION = '0.11.0';

sub new {
    my ($class, %opt) = @_;
    my $self = bless {
        path       => $opt{path},
        local_data_root => $opt{local_data_root} // '/spider/local_data',
        max_queue  => $opt{max_queue} // 256,
        max_rows   => $opt{max_rows} // 300000,
        retention  => $opt{retention_seconds} // 31 * 86400,
        queue      => [],
        busy       => 0,
        enabled    => 1,
        error      => undef,
        written    => 0,
        dropped    => 0,
        last_write => undef,
    }, $class;
    unless ($self->{path}) { $self->{enabled}=0; $self->{error}='no_history_path'; return $self }
    return $self;
}

sub status {
    my ($self) = @_;
    return {
        enabled    => $self->{enabled} ? 1 : 0,
        path       => $self->{path},
        queued     => scalar @{$self->{queue}},
        busy       => $self->{busy} ? 1 : 0,
        written    => 0 + $self->{written},
        dropped    => 0 + $self->{dropped},
        last_write => $self->{last_write},
        error      => $self->{error},
    };
}

sub enqueue {
    my ($self, $kind, $payload) = @_;
    return 0 unless $self->{enabled};
    return 0 unless defined $kind && ref($payload) eq 'HASH';
    return 0 unless $kind =~ /^(?:status|traffic|self_health|system)$/;
    my $json = eval { encode_json($payload) };
    return 0 if $@ || !defined $json;
    if (@{$self->{queue}} >= $self->{max_queue}) {
        shift @{$self->{queue}};
        $self->{dropped}++;
    }
    push @{$self->{queue}}, {
        kind => $kind,
        collected_at => 0 + ($payload->{collected_at} // time),
        payload_json => $json,
    };
    $self->_flush_async;
    return 1;
}

sub _flush_async {
    my ($self) = @_;
    return unless $self->{enabled};
    return if $self->{busy};
    return unless @{$self->{queue}};
    my @batch = splice @{$self->{queue}}, 0, 32;
    my ($path,$max_rows,$retention)=@$self{qw(path max_rows retention)};
    $self->{busy}=1;
    my $sp = Mojo::IOLoop::Subprocess->new;
    $sp->run(
        sub {
            my ($subprocess) = @_;
            require DBI;
            my $dir = dirname($path);
            make_path($dir) unless -d $dir;
            my $dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
                RaiseError=>1, PrintError=>0, AutoCommit=>1,
                sqlite_busy_timeout=>1000,
            });
            $dbh->do('PRAGMA journal_mode=WAL');
            $dbh->do('PRAGMA synchronous=NORMAL');
            $dbh->do('CREATE TABLE IF NOT EXISTS samples (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, collected_at REAL NOT NULL, payload_json TEXT NOT NULL)');
            $dbh->do('CREATE INDEX IF NOT EXISTS samples_kind_time ON samples(kind,collected_at)');
            my $sth=$dbh->prepare('INSERT INTO samples(kind,collected_at,payload_json) VALUES(?,?,?)');
            $dbh->begin_work;
            $sth->execute($_->{kind},$_->{collected_at},$_->{payload_json}) for @batch;
            my $cut=time-$retention;
            $dbh->do('DELETE FROM samples WHERE collected_at < ?',undef,$cut);
            my ($count)=$dbh->selectrow_array('SELECT COUNT(*) FROM samples');
            if ($count > $max_rows) {
                my $n=$count-$max_rows;
                $dbh->do("DELETE FROM samples WHERE id IN (SELECT id FROM samples ORDER BY id ASC LIMIT $n)");
            }
            $dbh->commit;
            $dbh->disconnect;
            return scalar @batch;
        },
        sub {
            my ($subprocess,$err,$written) = @_;
            $self->{busy}=0;
            if ($err) {
                $self->{error}="$err";
                $self->{dropped} += scalar @batch;
            } else {
                $self->{error}=undef;
                $self->{written} += 0 + ($written // 0);
                $self->{last_write}=time;
            }
            Mojo::IOLoop->next_tick(sub { $self->_flush_async }) if @{$self->{queue}};
        }
    );
}



sub latest_snapshots_async {
    my ($self,%opt)=@_;
    my $cb=delete $opt{cb};
    die 'latest_snapshots_async requires cb' unless ref($cb) eq 'CODE';
    my $path=$self->{path};
    my $sp=Mojo::IOLoop::Subprocess->new;
    $sp->run(
        sub {
            require DBI;
            my $dbh=DBI->connect("dbi:SQLite:dbname=$path",'', '', {
                RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_busy_timeout=>1000,
                sqlite_open_flags=>0x00000001,
            });
            my %out;
            for my $kind (qw(status traffic self_health)) {
                my $r=$dbh->selectrow_arrayref(
                    'SELECT collected_at,payload_json FROM samples WHERE kind=? ORDER BY collected_at DESC,id DESC LIMIT 1',
                    undef,$kind
                );
                next unless $r;
                my $payload=eval { decode_json($r->[1]) };
                next unless ref($payload) eq 'HASH';
                $out{$kind}={collected_at=>0+$r->[0],payload=>$payload};
            }
            $dbh->disconnect;
            return \%out;
        },
        sub { my($subprocess,$err,$result)=@_; $cb->($err ? "$err" : undef,$result); }
    );
}

sub query_window_async {
    my ($self, %opt) = @_;
    my $cb = delete $opt{cb};
    die 'query_window_async requires cb' unless ref($cb) eq 'CODE';
    my %windows = ( '5m'=>300, '15m'=>900, '1h'=>3600, '6h'=>21600, '24h'=>86400 );
    my $window = $opt{window} // '15m';
    return $cb->('invalid_window', undef) unless exists $windows{$window};
    my $path = $self->{path};
    my $seconds = $windows{$window};
    my $sp = Mojo::IOLoop::Subprocess->new;
    $sp->run(
        sub {
            require DBI;
            my $now = time;
            my $from = $now - $seconds;
            my $dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
                RaiseError=>1, PrintError=>0, AutoCommit=>1,
                sqlite_busy_timeout=>1000,
                sqlite_open_flags=>0x00000001, # SQLITE_OPEN_READONLY
            });
            my $rows = $dbh->selectall_arrayref(
                'SELECT kind, COUNT(*) AS n, MIN(collected_at), MAX(collected_at) FROM samples WHERE collected_at >= ? GROUP BY kind ORDER BY kind',
                undef, $from
            );
            my %kinds;
            for my $r (@$rows) {
                my ($kind,$n,$first,$last)=@$r;
                $kinds{$kind}={
                    samples=>0+$n,
                    first_at=>defined($first)?0+$first:undef,
                    last_at=>defined($last)?0+$last:undef,
                    span_seconds=>($n>1 && defined($first) && defined($last)) ? 0+($last-$first) : 0,
                    mean_interval_seconds=>($n>1 && defined($first) && defined($last)) ? 0+(($last-$first)/($n-1)) : undef,
                };
            }
            my ($total)=$dbh->selectrow_array('SELECT COUNT(*) FROM samples');
            my ($oldest,$newest)=$dbh->selectrow_array('SELECT MIN(collected_at),MAX(collected_at) FROM samples');
            $dbh->disconnect;
            my $coverage_start = defined($oldest) && $oldest > $from ? $oldest : $from;
            my $coverage_end   = defined($newest) && $newest < $now ? $newest : $now;
            my $coverage_seconds = (defined($oldest) && defined($newest) && $coverage_end > $coverage_start)
                ? 0 + ($coverage_end - $coverage_start) : 0;
            my $coverage_ratio = $seconds > 0 ? $coverage_seconds / $seconds : 0;
            $coverage_ratio = 1 if $coverage_ratio > 1;
            my $mean_interval;
            my @intervals = map { $kinds{$_}{mean_interval_seconds} }
                            grep { defined $kinds{$_}{mean_interval_seconds} } keys %kinds;
            if (@intervals) { my $sum=0; $sum += $_ for @intervals; $mean_interval=$sum/@intervals; }
            my $tolerance = defined($mean_interval) ? $mean_interval * 1.5 : 0;
            my $complete = ($coverage_seconds + $tolerance >= $seconds) ? 1 : 0;
            return {
                window=>$window,
                window_seconds=>$seconds,
                from_at=>$from,
                to_at=>$now,
                coverage_seconds=>$coverage_seconds,
                coverage_ratio=>0+$coverage_ratio,
                complete=>$complete,
                kinds=>\%kinds,
                database=>{
                    rows=>0+($total//0),
                    oldest_at=>defined($oldest)?0+$oldest:undef,
                    newest_at=>defined($newest)?0+$newest:undef,
                    path=>$path,
                },
            };
        },
        sub {
            my ($subprocess,$err,$result)=@_;
            $cb->($err ? "$err" : undef, $result);
        }
    );
}


# Historical semantics are deliberately explicit.  A path not matched here is
# metadata/structural data and is never aggregated numerically by accident.
sub _semantic_class {
    my ($kind,$path) = @_;
    return 'counter' if $kind eq 'status' && $path =~ /^(?:cpu_self_seconds|cpu_children_seconds)$/;
    return 'gauge'   if $kind eq 'status' && $path =~ /^(?:uptime_seconds|channels|nodes|users|web|rbn|other|direct_nodes|network_nodes|network_users|local_users|pending_connects|input_queue_max|input_queue_nonempty|input_queue_total|generation_ms)$/;
    return 'counter' if $kind eq 'self_health' && $path =~ /^health\.(?:requests|errors)$/;
    return 'gauge'   if $kind eq 'self_health' && $path =~ /^(?:generation_ms|health\.last_generation_ms|health\.max_generation_ms)$/;
    if ($kind eq 'traffic') {
        return 'counter' if $path =~ /^transport\.(?:bytes_in|bytes_out|lines_in|lines_out)$/;
        return 'counter' if $path =~ /^spots\.(?:hf|vhf|total|local_generated)$/;
        return 'counter' if $path eq 'protocol.local_spots_generated';
        return 'counter' if $path =~ /^protocol\.protocols\.PC\d+\.(?:in|out)\.(?:packets|bytes)$/;
        return 'counter' if $path =~ /^protocol\.peers\.[^.]+\.PC\d+\.(?:in|out)\.(?:packets|bytes)$/;
        return 'counter' if $path =~ /^protocol\.logical\.PC\d+\.(?:accepted|forwarded|generated|reply)\.(?:packets|bytes)$/;
        return 'counter' if $path =~ /^protocol\.input_diagnostics\.(?:malformed|unknown_protocol)\.(?:packets|bytes)$/;
        return 'counter' if $path =~ /^protocol\.input_diagnostics\.malformed\.by_pc\.[^.]+\.(?:packets|bytes)$/;
        return 'counter' if $path =~ /^protocol\.input_diagnostics\.peers\.[^.]+\.(?:packets|bytes)$/;
        return 'counter' if $path =~ /^pc92\.(?:physical\.(?:in|out)\.[^.]+|totals\.(?:in|out))\.[ACDK]\.(?:packets|bytes)$/;
        return 'counter' if $path =~ /^pc92\.logical\.(?:received|generated|forwarded)\.[ACDK]\.(?:packets|bytes)$/;
        return 'counter' if $path =~ /^pc_spots\.(?:pc11_received|pc61_received|pc11_promotions|pc11_promoted_by_pc61|pc11_promoted_by_route)$/;
    }
    return undef;
}

sub _flatten_numeric {
    my ($value,$prefix,$out) = @_;
    if (ref($value) eq 'HASH') {
        for my $k (keys %$value) {
            my $p = length($prefix) ? "$prefix.$k" : $k;
            _flatten_numeric($value->{$k},$p,$out);
        }
        return;
    }
    return if ref($value) || !defined($value);
    # Accept JSON numbers and numeric strings (notably local_spots_generated).
    return unless "$value" =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
    $out->{$prefix}=0+$value;
}

sub semantic_window_async {
    my ($self,%opt)=@_;
    my $cb=delete $opt{cb};
    die 'semantic_window_async requires cb' unless ref($cb) eq 'CODE';
    my %windows=( '5m'=>300, '15m'=>900, '1h'=>3600, '6h'=>21600, '24h'=>86400 );
    my $window=$opt{window}//'15m';
    return $cb->('invalid_window',undef) unless exists $windows{$window};
    my $seconds=$windows{$window};
    my $path=$self->{path};
    my $sp=Mojo::IOLoop::Subprocess->new;
    $sp->run(
        sub {
            require DBI;
            my $now=time; my $from=$now-$seconds;
            my $dbh=DBI->connect("dbi:SQLite:dbname=$path",'', '', {
                RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_busy_timeout=>1000,
                sqlite_open_flags=>0x00000001,
            });
            my $rows=$dbh->selectall_arrayref(
                'SELECT kind,collected_at,payload_json FROM samples WHERE collected_at >= ? ORDER BY kind,collected_at,id',
                undef,$from
            );
            my ($oldest,$newest)=$dbh->selectrow_array('SELECT MIN(collected_at),MAX(collected_at) FROM samples');
            $dbh->disconnect;
            my %series;
            for my $r (@$rows) {
                my ($kind,$at,$json)=@$r;
                my $payload=eval { decode_json($json) };
                next unless ref($payload) eq 'HASH';
                push @{$series{$kind}}, { at=>0+$at, payload=>$payload, boot_id=>$payload->{boot_id} };
            }
            my %result;
            for my $kind (sort keys %series) {
                my $all=$series{$kind};
                next unless @$all;
                my $latest_boot=$all->[-1]{boot_id};
                my @cur=grep { defined($_->{boot_id}) && defined($latest_boot) && $_->{boot_id} eq $latest_boot } @$all;
                @cur=@$all unless defined $latest_boot;
                my %boots; $boots{defined($_->{boot_id}) ? $_->{boot_id} : '<undef>'}++ for @$all;
                my (%values,%classes);
                for my $s (@cur) {
                    my %flat; _flatten_numeric($s->{payload},'',\%flat);
                    for my $p (keys %flat) {
                        my $class=_semantic_class($kind,$p); next unless $class;
                        $classes{$p}=$class;
                        push @{$values{$p}}, [$s->{at},$flat{$p}];
                    }
                }
                my (%counters,%gauges);
                for my $p (sort keys %values) {
                    my $v=$values{$p}; next unless @$v;
                    if ($classes{$p} eq 'counter') {
                        my $resets=0;
                        for(my $i=1;$i<@$v;$i++){ $resets++ if $v->[$i][1] < $v->[$i-1][1] }
                        my $span=@$v>1 ? $v->[-1][0]-$v->[0][0] : 0;
                        my $delta=@$v>1 ? $v->[-1][1]-$v->[0][1] : 0;
                        my $valid=(@$v>1 && !$resets) ? 1 : 0;
                        $counters{$p}={ samples=>scalar(@$v), first=>0+$v->[0][1], last=>0+$v->[-1][1],
                            delta=>$valid ? 0+$delta : undef, rate_per_second=>($valid && $span>0) ? 0+($delta/$span) : undef,
                            span_seconds=>0+$span, resets=>$resets, valid=>$valid };
                    } else {
                        my @n=map { $_->[1] } @$v; my ($min,$max)=($n[0],$n[0]);
                        for(@n){$min=$_ if $_<$min;$max=$_ if $_>$max}
                        $gauges{$p}={ samples=>scalar(@$v), first=>0+$n[0], last=>0+$n[-1], min=>0+$min, max=>0+$max };
                    }
                }
                my $boot_coverage = @cur > 1 ? $cur[-1]{at} - $cur[0]{at} : 0;
                $result{$kind}={
                    samples=>scalar(@cur), window_samples=>scalar(@$all), latest_boot_id=>$latest_boot,
                    boot_count=>scalar(keys %boots), boot_changed=>(keys(%boots)>1?1:0),
                    first_at=>0+$cur[0]{at}, last_at=>0+$cur[-1]{at},
                    current_boot_coverage_seconds=>0+$boot_coverage,
                    current_boot_coverage_ratio=>$seconds>0 ? 0+($boot_coverage/$seconds) : 0,
                    counters=>\%counters, gauges=>\%gauges,
                };
            }
            my $coverage_start=defined($oldest)&&$oldest>$from?$oldest:$from;
            my $coverage_end=defined($newest)&&$newest<$now?$newest:$now;
            my $coverage=(defined($oldest)&&defined($newest)&&$coverage_end>$coverage_start)?$coverage_end-$coverage_start:0;
            my $ratio=$seconds>0?$coverage/$seconds:0; $ratio=1 if $ratio>1;
            return { schema_version=>1, window=>$window, window_seconds=>$seconds, from_at=>$from,to_at=>$now,
                window_coverage_seconds=>0+$coverage,window_coverage_ratio=>0+$ratio,
                coverage_seconds=>0+$coverage,coverage_ratio=>0+$ratio,kinds=>\%result,
                semantics=>{ counter_delta=>'latest boot only; invalid if counter decreases', coverage=>'window coverage is distinct from current-boot and per-series span', gauge=>'first/last/min/max', metadata=>'not aggregated' } };
        },
        sub { my($subprocess,$err,$result)=@_; $cb->($err?"$err":undef,$result); }
    );
}


sub metrics_series_async {
    my ($self,%opt)=@_; my $cb=delete $opt{cb};
    die 'metrics_series_async requires cb' unless ref($cb) eq 'CODE';
    my %windows=('1h'=>3600,'6h'=>21600,'24h'=>86400,'7d'=>604800,'30d'=>2592000,'1y'=>31536000);
    my $window=$opt{window}//'24h'; return $cb->('invalid_window',undef) unless exists $windows{$window};
    my $selected_peer=$opt{peer}//''; return $cb->('invalid_peer',undef) if ref($selected_peer) || length($selected_peer)>128 || $selected_peer =~ /[\x00-\x1f]/;
    my($seconds,$path)=($windows{$window},$self->{path}); my $sp=Mojo::IOLoop::Subprocess->new;
    $sp->run(sub {
        require DBI; my$now=time;my$from=$now-$seconds;my$bucket=$seconds/120;$bucket=5 if$bucket<5;
        my$dbh=DBI->connect("dbi:SQLite:dbname=$path",'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_busy_timeout=>1000,sqlite_open_flags=>0x00000001});
        my$rows=$dbh->selectall_arrayref('SELECT kind,collected_at,payload_json FROM samples WHERE collected_at>=? ORDER BY collected_at,id',undef,$from);
        my($oldest,$newest)=$dbh->selectrow_array('SELECT MIN(collected_at),MAX(collected_at) FROM samples');$dbh->disconnect;
        my@fixed=(['traffic','transport.bytes_in','counter','transport_rx_bps'],['traffic','transport.bytes_out','counter','transport_tx_bps'],['traffic','spots.total','counter','spots_per_s'],['status','cpu_self_seconds','counter','cpu_self_ratio'],['status','channels','gauge','channels'],['status','nodes','gauge','nodes'],['status','users','gauge','users'],['status','direct_nodes','gauge','direct_nodes'],['status','network_nodes','gauge','network_nodes'],['status','network_users','gauge','network_users'],['status','local_users','gauge','local_users'],['status','rbn','gauge','rbn'],['status','web','gauge','web'],['status','input_queue_total','gauge','input_queue_total'],['status','input_queue_max','gauge','input_queue_max'],['status','input_queue_nonempty','gauge','input_queue_nonempty'],['status','pending_connects','gauge','pending_connects'],['self_health','generation_ms','gauge','health_generation_ms'],['system','mem_used_bytes','gauge','host_mem_used'],['system','mem_total_bytes','gauge','host_mem_total'],['system','fs_used_percent','gauge','fs_used_percent'],['system','history_queue_items','gauge','web_history_queue'],['system','fanout_queue_items','gauge','web_fanout_queue'],['system','pending_requests','gauge','web_pending_requests'],['system','browser_queued_clients','gauge','web_queued_clients'],['system','browser_queue_bytes','gauge','web_queue_bytes'],['system','browser_queue_max_bytes','gauge','web_queue_max_bytes'],['system','history_dropped_total','counter','web_history_dropped'],['system','ws_dropped_total','counter','web_ws_dropped'],['system','ws_slow_disconnects_total','counter','web_slow_disconnects']);
        push@fixed,['traffic','protocol.input_diagnostics.malformed.packets','counter','reject_malformed'],['traffic','protocol.input_diagnostics.unknown_protocol.packets','counter','reject_unknown'],['traffic','pc_spots.pc11_received','counter','spot_pc11'],['traffic','pc_spots.pc61_received','counter','spot_pc61'];
        for my$sub(qw(A C D K)){push@fixed,['traffic',"pc92.logical.received.$sub.packets",'counter',"pc92_received_$sub"],['traffic',"pc92.logical.generated.$sub.packets",'counter',"pc92_generated_$sub"],['traffic',"pc92.logical.forwarded.$sub.packets",'counter',"pc92_forwarded_$sub"]}
        my %want = map { ("$_->[0]\0$_->[1]" => $_) } @fixed;my(%raw,%peer,%peers,%boots);
        for my$r(@$rows){my($kind,$at,$json)=@$r;my$x=eval{decode_json($json)};next unless ref$x eq'HASH';my$boot=defined$x->{boot_id}?"$x->{boot_id}":'';$boots{$boot}=1 if length$boot;my%flat;_flatten_numeric($x,'',\%flat);
          for my$k(keys%flat){if(my$w=$want{"$kind\0$k"}){push@{$raw{$w->[3]}},[0+$at,0+$flat{$k},$boot,$w->[2]]}
            if($kind eq'traffic'&&$k=~/^protocol\.protocols\.(PC\d+)\.(in|out)\.packets$/){my($pc,$d)=($1,$2);my$n='protocol_'.$pc.'_'.$d;push@{$raw{$n}},[0+$at,0+$flat{$k},$boot,'counter']}
            if($kind eq'traffic'&&$k=~/^protocol\.logical\.(PC\d+)\.forwarded\.packets$/){my$pc=$1;push@{$raw{'forwarded_'.$pc}},[0+$at,0+$flat{$k},$boot,'counter']}
            if($kind eq'traffic'&&$k=~/^protocol\.peers\.([^.]+)\.(PC\d+)\.(in|out)\.packets$/){my($pn,$pc,$d)=($1,$2,$3);$peers{$pn}=1;next if length($selected_peer)&&$pn ne$selected_peer;my$key=length($selected_peer)?$selected_peer:'__all__';$peer{$key}{$d}{$at}{v}+=0+$flat{$k};$peer{$key}{$d}{$at}{boot}=$boot;if(length($selected_peer)){push@{$raw{'peer_'.$pc.'_'.$d}},[0+$at,0+$flat{$k},$boot,'counter']}}}}
        if(length($selected_peer)&&!$peers{$selected_peer}){die "unknown_peer\n"}
        my$key=length($selected_peer)?$selected_peer:'__all__';for my$d(qw(in out)){my@a=map{[0+$_,0+$peer{$key}{$d}{$_}{v},$peer{$key}{$d}{$_}{boot},'counter']}sort{$a<=>$b}keys%{$peer{$key}{$d}||{}};$raw{$d eq'in'?'peer_in_bps':'peer_out_bps'}=\@a if@a}
        my%series;for my$name(keys%raw){my$samples=$raw{$name};next unless@$samples;my%b;
          if($samples->[0][3]eq'counter'){for(my$i=1;$i<@$samples;$i++){my($t0,$v0,$b0)=@{$samples->[$i-1]};my($t1,$v1,$b1)=@{$samples->[$i]};next if length$b0&&length$b1&&$b0 ne$b1;my$dt=$t1-$t0;my$dv=$v1-$v0;next if$dt<=0||$dv<0;my$n=int(($t1-$from)/$bucket);next if$n<0;$b{$n}{dv}+=$dv;$b{$n}{dt}+=$dt;$b{$n}{t}=$from+($n+.5)*$bucket}$series{$name}=[map{my$x=$b{$_};{t=>0+$x->{t},v=>$name eq 'cpu_self_ratio' ? ($x->{dt}>0?0+$x->{dv}/$x->{dt}:undef) : 0+$x->{dv}}}sort{$a<=>$b}keys%b]}
          else{for my$x(@$samples){my($t,$v)=@$x;my$n=int(($t-$from)/$bucket);next if$n<0;$b{$n}={t=>$from+($n+.5)*$bucket,v=>0+$v}}$series{$name}=[map{{t=>0+$b{$_}{t},v=>0+$b{$_}{v}}}sort{$a<=>$b}keys%b]}}
        my$cs=defined$oldest&&$oldest>$from?$oldest:$from;my$ce=defined$newest&&$newest<$now?$newest:$now;my$cov=(defined$oldest&&defined$newest&&$ce>$cs)?$ce-$cs:0;my$ratio=$seconds?$cov/$seconds:0;$ratio=1 if$ratio>1;
        return{schema_version=>2,window=>$window,window_seconds=>$seconds,from_at=>0+$from,to_at=>0+$now,bucket_seconds=>0+$bucket,coverage_seconds=>0+$cov,coverage_ratio=>0+$ratio,boot_count=>scalar(keys%boots),selected_peer=>$selected_peer,peers=>[sort keys%peers],series=>\%series,semantics=>{counters=>'non-decreasing delta total per displayed bucket within one boot; cpu_self_ratio remains a per-second ratio for percent display',gauges=>'last observed value in each bucket',missing=>'missing buckets are not zero'}};
    },sub{my($sp,$err,$r)=@_;$cb->($err?"$err":undef,$r)});
}


sub timeline_async {
    my ($self,%opt)=@_; my $cb=delete $opt{cb};
    die 'timeline_async requires cb' unless ref($cb) eq 'CODE';
    my %windows=('5m'=>300,'15m'=>900,'1h'=>3600,'6h'=>21600,'24h'=>86400);
    my $window=$opt{window}//'15m'; return $cb->('invalid_window',undef) unless exists $windows{$window};
    my $limit=0+($opt{limit}//300); $limit=1 if $limit<1; $limit=1000 if $limit>1000;
    my($seconds,$path)=($windows{$window},$self->{path}); my $sp=Mojo::IOLoop::Subprocess->new;
    $sp->run(sub {
        require DBI; my$now=time; my$from=$now-$seconds;
        my$dbh=DBI->connect("dbi:SQLite:dbname=$path",'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_busy_timeout=>1000,sqlite_open_flags=>0x00000001});
        my$rows=$dbh->selectall_arrayref("SELECT kind,collected_at,payload_json FROM samples WHERE collected_at>=? AND kind IN ('status','self_health') ORDER BY collected_at,id",undef,$from);
        my($oldest,$newest)=$dbh->selectrow_array('SELECT MIN(collected_at),MAX(collected_at) FROM samples'); $dbh->disconnect;
        my(%prev,@events); my@state=qw(channels users nodes rbn web pending_connects);
        for my$r(@$rows){my($kind,$at,$json)=@$r;my$x=eval{decode_json($json)};next unless ref$x eq'HASH';my$p=$prev{$kind};
            if($p){my$pb=defined$p->{boot_id}?"$p->{boot_id}":'';my$cb=defined$x->{boot_id}?"$x->{boot_id}":'';my$boot_change=length($pb)&&length($cb)&&$pb ne$cb;
                if($boot_change&&$kind eq'status'){push@events,{at=>0+$at,kind=>'boot',field=>'boot_id',label=>'DXSpider restarted',before=>'previous boot',after=>'new boot'};}
                if($kind eq'status'){
                    if(!$boot_change){for my$f(@state){next unless defined$p->{$f}&&defined$x->{$f};next if"$p->{$f}" eq"$x->{$f}";push@events,{at=>0+$at,kind=>'state',field=>$f,label=>ucfirst($f).' changed',before=>$p->{$f},after=>$x->{$f}}}}
                    for my$f(qw(version build git_branch git_version)){next unless defined$p->{$f}&&defined$x->{$f};next if"$p->{$f}" eq"$x->{$f}";push@events,{at=>0+$at,kind=>'software',field=>$f,label=>ucfirst($f).' changed',before=>$p->{$f},after=>$x->{$f}}}
                } elsif($kind eq'self_health'&&!$boot_change){my$a=ref($p->{health})eq'HASH'?$p->{health}{errors}:undef;my$b=ref($x->{health})eq'HASH'?$x->{health}{errors}:undef;if(defined$a&&defined$b&&"$a"ne"$b"){push@events,{at=>0+$at,kind=>'health',field=>'errors',label=>'Supervisor errors changed',before=>$a,after=>$b}}}
            }
            $prev{$kind}=$x;
        }
        @events=sort{$b->{at}<=>$a->{at}}@events; splice(@events,$limit) if @events>$limit;
        my$cs=defined$oldest&&$oldest>$from?$oldest:$from;my$ce=defined$newest&&$newest<$now?$newest:$now;my$cov=(defined$oldest&&defined$newest&&$ce>$cs)?$ce-$cs:0;my$ratio=$seconds?$cov/$seconds:0;$ratio=1 if$ratio>1;
        return{schema_version=>1,window=>$window,window_seconds=>$seconds,from_at=>0+$from,to_at=>0+$now,coverage_seconds=>0+$cov,coverage_ratio=>0+$ratio,event_count=>scalar(@events),events=>\@events,semantics=>{source=>'derived from consecutive dxhistory.db status/self_health samples',traffic=>'traffic counters are intentionally excluded',boot=>'state deltas are not inferred across boot boundaries'}};
    },sub{my($sp,$err,$r)=@_;$cb->($err?"$err":undef,$r)});
}


sub _history_active_basename {
    my ($family,$year,$name)=@_;
    return 0 unless defined $year && defined $name;
    my @g=gmtime(time);
    my $cy=$g[5]+1900;
    return 0 unless 0+$year == $cy;
    my $doy=sprintf('%03d',$g[7]+1);   # DXSpider daily files: nnn (day of year)
    my $mon=sprintf('%02d',$g[4]+1);  # DXSpider monthly files: nn
    # Daily families use Julian day nnn; monthly families use month nn.
    return 1 if ($family eq 'debug' || $family eq 'spots')
             && $name =~ /^\Q$doy\E(?:\.|$)/;
    return 1 if ($family eq 'log' || $family eq 'wcy' || $family eq 'wwv')
             && $name =~ /^\Q$mon\E(?:\.|$)/;
    return 0;
}
sub _history_scan_item {
    my ($path,$family,$year)=@_; my($bytes,$files,$dirs,$active)=(0,0,0,0);
    my @z=lstat($path); return(0,0,0,0) unless @z; return(0,0,0,1) if -l _;
    if(-f _){my($name)=$path=~m{/([^/]+)$};return(0+$z[7],1,0,_history_active_basename($family,$year,$name)?1:0)}
    if(-d _){find({wanted=>sub{my@a=lstat($_);return unless@a;if(-l _){return}if(-f _){$bytes+=$a[7];$files++;my($name)=$_=~m{/([^/]+)$};$active=1 if _history_active_basename($family,$year,$name)}elsif(-d _){$dirs++}},no_chdir=>1},$path)}
    return($bytes,$files,$dirs,$active);
}
sub _history_tree_snapshot {
    my ($root,$parts)=@_; $parts=[] unless ref($parts) eq 'ARRAY';
    my @families=qw(debug log spots wcy wwv); my %family=map{$_=>1}@families; my $active=(gmtime(time))[5]+1900;
    die 'invalid_history_path' if @$parts>64;
    my($year,$fam,@rest)=@$parts;
    die 'invalid_history_year' if defined($year) && "$year" !~ /^\d{4}$/;
    die 'invalid_history_family' if defined($fam) && !$family{$fam};
    for my$n(@rest){die'invalid_history_component' if !defined($n)||$n eq''||$n eq'.'||$n eq'..'||$n=~/[\x00\/]/}
    my @items;
    if(!defined $year){
        my %years;for my$f(@families){my$b="$root/$f";next unless-d$b;opendir(my$dh,$b)or next;while(my$y=readdir$dh){next unless$y=~/^\d{4}$/&&-d"$b/$y"&&!-l"$b/$y";$years{$y}=1}closedir$dh}
        for my$y(sort{$b<=>$a}keys%years){my($bytes,$files,$dirs,$hasactive)=(0,0,0,0);for my$f(@families){my$q="$root/$f/$y";next unless-d$q&&!-l$q;my($b,$fi,$di,$ac)=_history_scan_item($q,$f,$y);$bytes+=$b;$files+=$fi;$dirs+=$di;$hasactive||=$ac}push@items,{id=>"year:$y",name=>"$y",kind=>'year',year=>0+$y,bytes=>$bytes,files=>$files,dirs=>$dirs,protected=>0,contains_active=>$hasactive?1:0,navigable=>1}}
    } elsif(!defined $fam){
        for my$f(@families){my$q="$root/$f/$year";next unless-d$q&&!-l$q;my($bytes,$files,$dirs,$hasactive)=_history_scan_item($q,$f,$year);push@items,{id=>"family:$year:$f",name=>$f,kind=>'directory',year=>0+$year,family=>$f,bytes=>$bytes,files=>$files,dirs=>$dirs,protected=>0,contains_active=>$hasactive?1:0,navigable=>1}}
    } else {
        my$base=join('/',"$root/$fam/$year",@rest);die'history_path_not_found' unless-d$base&&!-l$base;
        opendir(my$dh,$base)or die"history_open_failed:$!";my@names=grep{$_ ne'.'&&$_ ne'..'}readdir$dh;closedir$dh;
        for my$n(sort@names){next if$n=~/[\x00\/]/;my$q="$base/$n";my@z=lstat($q);next unless@z;next if-l _;my$isdir=-d _;next unless$isdir||-f _;my($bytes,$files,$dirs,$hasactive)=_history_scan_item($q,$fam,$year);my@rel=(@rest,$n);my$id='entry:'.$year.':'.$fam.':'.join('/',@rel);my$prot=(!$isdir&&_history_active_basename($fam,$year,$n))?1:0;push@items,{id=>$id,name=>$n,kind=>($isdir?'directory':'file'),year=>0+$year,family=>$fam,relative=>join('/',@rel),bytes=>$bytes,files=>$files,dirs=>$dirs,protected=>$prot,contains_active=>$hasactive?1:0,navigable=>($isdir?1:0)}}
    }
    return{active_year=>0+$active,path=>$parts,items=>\@items,families=>\@families,protection=>'active files are identified by DXSpider filename semantics: nnn = current UTC day-of-year, nn = current UTC month. Parents remain selectable and actions exclude active files'};
}

sub _history_assert_no_symlink_path {
    my ($root,$rel)=@_;
    die 'invalid_history_relative_path' unless defined $rel && !ref($rel) && length($rel);
    my @c=split m{/},$rel,-1;
    die 'invalid_history_relative_path' if !@c || grep { !defined($_) || $_ eq '' || $_ eq '.' || $_ eq '..' || /\x00/ } @c;
    my $p=$root;
    for my $c(@c){
        $p.="/$c";
        my @st=lstat($p);
        die "history_path_not_found:$rel" unless @st;
        die "symlink_rejected:$rel" if -l _;
    }
    return $p;
}

sub _history_collect_safe_files {
    my($root,$family,$year,$rel)=@_; my$path=_history_assert_no_symlink_path($root,$rel); my@out;
    if(-f$path){my($name)=$path=~m{/([^/]+)$};return () if _history_active_basename($family,$year,$name);return($rel)}
    return() unless-d$path;
    find({wanted=>sub{my@a=lstat($_);return unless@a;die"symlink_rejected:$_" if-l _;return unless-f _;my($name)=$_=~m{/([^/]+)$};return if _history_active_basename($family,$year,$name);my$r=$_; $r=~s/^\Q$root\E\///;push@out,$r},no_chdir=>1},$path);
    return@out;
}


sub _gzip_file_safe {
    my ($src,$dst,$label)=@_;
    require Fcntl;
    require IO::Compress::Gzip;
    my $nofollow=eval { Fcntl::O_NOFOLLOW() } || 0;
    my ($in,$out);
    sysopen($in,$src,Fcntl::O_RDONLY()|$nofollow) or die "compress_open_failed:$label:$!";
    my @before=stat($in); die "compress_stat_failed:$label" unless @before;
    sysopen($out,$dst,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL()|$nofollow,0600) or die "compress_create_failed:$label.gz:$!";
    my $ok=IO::Compress::Gzip::gzip($in=>$out,-Level=>9);
    my $gzerr=$IO::Compress::Gzip::GzipError;
    close($out) or $ok=0; close($in);
    unless($ok){unlink($dst);die "compress_failed:$label:$gzerr"}
    my @after=lstat($src);
    unless(@after && !-l _ && $after[0]==$before[0] && $after[1]==$before[1]){unlink($dst);die "compress_source_changed:$label"}
    unlink($src) or do{unlink($dst);die "compress_unlink_failed:$label:$!"};
    return 1;
}

sub maintenance_async {
    my ($self,%opt)=@_; my $cb=delete $opt{cb}; die 'maintenance_async requires cb' unless ref($cb) eq 'CODE';
    my $path=$self->{path}; my $root=$self->{local_data_root}; my $parts=$opt{history_path}; my $sp=Mojo::IOLoop::Subprocess->new;
    $sp->run(sub { require DBI; my%r=(schema_version=>2,collected_at=>time,history_db=>$path);my@st=stat($path);$r{db_bytes}=@st?0+$st[7]:0;for my$s(qw(-wal -shm)){my@x=stat($path.$s);$r{$s eq'-wal'?'wal_bytes':'shm_bytes'}=@x?0+$x[7]:0}my$dbh=DBI->connect("dbi:SQLite:dbname=$path",'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_busy_timeout=>1000,sqlite_open_flags=>0x00000001});my($count,$oldest,$newest)=$dbh->selectrow_array('SELECT COUNT(*),MIN(collected_at),MAX(collected_at) FROM samples');$r{samples}=0+($count||0);$r{oldest_at}=defined$oldest?0+$oldest:undef;$r{newest_at}=defined$newest?0+$newest:undef;my($qc)=$dbh->selectrow_array('PRAGMA quick_check');$r{quick_check}=defined$qc?"$qc":'unknown';$dbh->disconnect;
        if(open(my$df,'-|','df','-Pk',$root)){my@l=<$df>;close$df;if(@l>1){my@f=split/\s+/,$l[-1];if(@f>=6){$r{fs_total_bytes}=1024*(0+$f[1]);$r{fs_used_bytes}=1024*(0+$f[2]);$r{fs_available_bytes}=1024*(0+$f[3]);$r{fs_used_percent}=0+($f[4]=~s/%//r)}}}
        my@backups;if(opendir(my$dh,$root)){while(my$n=readdir$dh){next unless$n=~/^dxweb-admin.*-backup-/;my@x=stat("$root/$n");push@backups,{name=>$n,mtime=>0+($x[9]||0)}if@x}closedir$dh}@backups=sort{$b->{mtime}<=>$a->{mtime}}@backups;$r{backup_count}=scalar@backups;$r{latest_backup}=$backups[0]if@backups;
        $r{history_browser}=_history_tree_snapshot($root,$parts);$r{archive_dir}="$root/archives";return\%r;
    },sub{my($sp,$err,$r)=@_;$cb->($err?"$err":undef,$r)});
}

sub history_maintenance_action_async {
    my ($self,%opt)=@_;my$cb=delete$opt{cb};die'history_maintenance_action_async requires cb'unless ref($cb)eq'CODE';my$action=lc($opt{action}//'');my$ids=$opt{ids};return$cb->('invalid_action',undef)unless$action eq'compress'||$action eq'delete';return$cb->('invalid_targets',undef)unless ref($ids)eq'ARRAY'&&@$ids&&@$ids<=100;my$root=$self->{local_data_root};my$sp=Mojo::IOLoop::Subprocess->new;
    $sp->run(sub{my@families=qw(debug log spots wcy wwv);my%family=map{$_=>1}@families;my@targets;my%seen;
        for my$id(@$ids){die'invalid_target'unless defined$id&&!ref$id;next if$seen{$id}++;my($kind,$year,$fam,$tail)=split/:/,$id,4;die'invalid_target_year'unless defined$year&&$year=~/^\d{4}$/;my@roots;
            if($kind eq'year'&&!defined$fam){for my$f(@families){my$p="$root/$f/$year";die"symlink_rejected:$f/$year"if-l$p;push@roots,[$f,"$f/$year"]if-d$p}}
            elsif($kind eq'family'&&defined$fam&&$family{$fam}&&!defined$tail){my$p="$root/$fam/$year";die"symlink_rejected:$fam/$year"if-l$p;push@roots,[$fam,"$fam/$year"]if-d$p}
            elsif($kind eq'entry'&&defined$fam&&$family{$fam}&&defined$tail){my@c=split m{/},$tail,-1;die'invalid_target' if !@c||grep{!defined($_)||$_ eq''||$_ eq'.'||$_ eq'..'||/\x00/}@c;my$rel="$fam/$year/$tail";my$p=_history_assert_no_symlink_path($root,$rel);push@roots,[$fam,$rel]if-f$p||-d$p}
            else{die'invalid_target'}die"target_not_found:$id"unless@roots;my@files;for my$r(@roots){push@files,_history_collect_safe_files($root,$r->[0],$year,$r->[1])}my%f;@files=grep{!$f{$_}++}@files;die"active_item_only:$id"unless@files;push@targets,{id=>$id,year=>0+$year,files=>\@files};
        }
        # Full batch preflight before the first destructive mutation.  This cannot make
        # filesystem operations transactional, but predictable missing/replaced targets
        # and gzip collisions fail before any selected file is changed.
        for my$t(@targets){for my$rel(@{$t->{files}}){my$p=_history_assert_no_symlink_path($root,$rel);my@st=lstat($p);die"target_changed_before_action:$rel" unless @st && !-l _ && -f _;if($action eq'compress'&&$rel!~/\.gz\z/i){my$dest="$p.gz";die"compressed_target_exists:$rel.gz" if -e$dest||-l$dest}}}
        my@results;
        for my$t(@targets){if($action eq'compress'){my(@compressed,@skipped);for my$rel(@{$t->{files}}){my$p=_history_assert_no_symlink_path($root,$rel);die"target_changed_during_action:$rel" unless -f$p;if($p=~/\.gz\z/i){push@skipped,$rel;next}my$dest="$p.gz";die"compressed_target_exists:$rel.gz"if-e$dest;_gzip_file_safe($p,$dest,$rel);die"compress_output_missing:$rel.gz"unless-f$dest;my$new=$rel.'.gz';push@compressed,{from=>$rel,to=>$new}}push@results,{id=>$t->{id},action=>'compress',compressed=>\@compressed,skipped=>\@skipped,files=>scalar@compressed}}
            else{my@removed;for my$rel(@{$t->{files}}){my$p=_history_assert_no_symlink_path($root,$rel);die"target_changed_during_action:$rel" unless -f$p;my@before=lstat($p);die"delete_stat_failed:$rel" unless @before && !-l _;unlink$p or die"delete_failed:$rel:$!";push@removed,$rel}my%dirs;for my$rel(@removed){my@p=split m{/},$rel;pop@p;while(@p>=2){$dirs{join('/',@p)}=1;pop@p}}for my$d(sort{length($b)<=>length($a)}keys%dirs){my$p="$root/$d";next unless-d$p&&!-l$p;rmdir$p}push@results,{id=>$t->{id},action=>'delete',removed=>\@removed}}
        }
        return{schema_version=>5,collected_at=>time,action=>$action,results=>\@results};
    },sub{my($sp,$err,$r)=@_;$cb->($err?"$err":undef,$r)});
}

1;
