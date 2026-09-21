package DXWebHistory;
use strict;
use warnings;
use utf8;
use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess;
use Mojo::JSON qw(encode_json decode_json);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Time::HiRes qw(time);

our $VERSION = '0.5.0';

sub new {
    my ($class, %opt) = @_;
    my $self = bless {
        path       => $opt{path},
        max_queue  => $opt{max_queue} // 256,
        max_rows   => $opt{max_rows} // 100000,
        retention  => $opt{retention_seconds} // 7 * 86400,
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
    return 0 unless $kind =~ /^(?:status|traffic|self_health)$/;
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
    return 'gauge'   if $kind eq 'status' && $path =~ /^(?:uptime_seconds|channels|nodes|users|web|rbn|other|pending_connects|input_queue_max|input_queue_nonempty|input_queue_total|generation_ms)$/;
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
    my %windows=('5m'=>300,'15m'=>900,'1h'=>3600,'6h'=>21600,'24h'=>86400);
    my $window=$opt{window}//'15m'; return $cb->('invalid_window',undef) unless exists $windows{$window};
    my($seconds,$path)=($windows{$window},$self->{path}); my $sp=Mojo::IOLoop::Subprocess->new;
    $sp->run(sub {
        require DBI; my$now=time;my$from=$now-$seconds;my$bucket=$seconds/120;$bucket=5 if$bucket<5;
        my$dbh=DBI->connect("dbi:SQLite:dbname=$path",'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_busy_timeout=>1000,sqlite_open_flags=>0x00000001});
        my$rows=$dbh->selectall_arrayref('SELECT kind,collected_at,payload_json FROM samples WHERE collected_at>=? ORDER BY collected_at,id',undef,$from);
        my($oldest,$newest)=$dbh->selectrow_array('SELECT MIN(collected_at),MAX(collected_at) FROM samples');$dbh->disconnect;
        my@fixed=(['traffic','transport.bytes_in','counter','transport_rx_bps'],['traffic','transport.bytes_out','counter','transport_tx_bps'],['traffic','spots.total','counter','spots_per_s'],['status','cpu_self_seconds','counter','cpu_self_ratio'],['status','channels','gauge','channels'],['status','nodes','gauge','nodes'],['status','users','gauge','users'],['status','rbn','gauge','rbn'],['status','web','gauge','web'],['self_health','generation_ms','gauge','health_generation_ms']);
        for my$sub(qw(A C D K)){push@fixed,['traffic',"pc92.logical.received.$sub.packets",'counter',"pc92_received_$sub"],['traffic',"pc92.logical.generated.$sub.packets",'counter',"pc92_generated_$sub"]}
        my %want = map { ("$_->[0]\0$_->[1]" => $_) } @fixed;my(%raw,%peer,%peers,%boots);
        for my$r(@$rows){my($kind,$at,$json)=@$r;my$x=eval{decode_json($json)};next unless ref$x eq'HASH';my$boot=defined$x->{boot_id}?"$x->{boot_id}":'';$boots{$boot}=1 if length$boot;my%flat;_flatten_numeric($x,'',\%flat);
          for my$k(keys%flat){if(my$w=$want{"$kind\0$k"}){push@{$raw{$w->[3]}},[0+$at,0+$flat{$k},$boot,$w->[2]]}
            if($kind eq'traffic'&&$k=~/^protocol\.peers\.([^.]+)\.PC\d+\.(in|out)\.packets$/){my($pn,$d)=($1,$2);$peers{$pn}=1;$peer{$pn}{$d}{$at}{v}+=0+$flat{$k};$peer{$pn}{$d}{$at}{boot}=$boot}}}
        for my$pn(keys%peer){for my$d(qw(in out)){my@a=map{[0+$_,0+$peer{$pn}{$d}{$_}{v},$peer{$pn}{$d}{$_}{boot},'counter']}sort{$a<=>$b}keys%{$peer{$pn}{$d}||{}};$raw{"peer:$pn:$d"}=\@a if@a}}
        my%series;for my$name(keys%raw){my$samples=$raw{$name};next unless@$samples;my%b;
          if($samples->[0][3]eq'counter'){for(my$i=1;$i<@$samples;$i++){my($t0,$v0,$b0)=@{$samples->[$i-1]};my($t1,$v1,$b1)=@{$samples->[$i]};next if length$b0&&length$b1&&$b0 ne$b1;my$dt=$t1-$t0;my$dv=$v1-$v0;next if$dt<=0||$dv<0;my$n=int(($t1-$from)/$bucket);next if$n<0;$b{$n}{dv}+=$dv;$b{$n}{dt}+=$dt;$b{$n}{t}=$from+($n+.5)*$bucket}$series{$name}=[map{my$x=$b{$_};{t=>0+$x->{t},v=>$x->{dt}>0?0+$x->{dv}/$x->{dt}:undef}}sort{$a<=>$b}keys%b]}
          else{for my$x(@$samples){my($t,$v)=@$x;my$n=int(($t-$from)/$bucket);next if$n<0;$b{$n}={t=>$from+($n+.5)*$bucket,v=>0+$v}}$series{$name}=[map{{t=>0+$b{$_}{t},v=>0+$b{$_}{v}}}sort{$a<=>$b}keys%b]}}
        my$cs=defined$oldest&&$oldest>$from?$oldest:$from;my$ce=defined$newest&&$newest<$now?$newest:$now;my$cov=(defined$oldest&&defined$newest&&$ce>$cs)?$ce-$cs:0;my$ratio=$seconds?$cov/$seconds:0;$ratio=1 if$ratio>1;
        return{schema_version=>1,window=>$window,window_seconds=>$seconds,from_at=>0+$from,to_at=>0+$now,bucket_seconds=>0+$bucket,coverage_seconds=>0+$cov,coverage_ratio=>0+$ratio,boot_count=>scalar(keys%boots),peers=>[sort keys%peers],series=>\%series,semantics=>{counters=>'per-second rate from non-decreasing deltas within one boot',gauges=>'last observed value in each bucket',missing=>'missing buckets are not zero'}};
    },sub{my($sp,$err,$r)=@_;$cb->($err?"$err":undef,$r)});
}

1;
