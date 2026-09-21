#!/usr/bin/env perl
# DXSpider Web Administration 0.34.0
# Date: 2026-09-16
use strict;
use warnings;
use utf8;
use Mojolicious::Lite -signatures;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json decode_json);
use Time::HiRes qw(time);
use FindBin;
use lib "$FindBin::Bin/lib";
use DXWebHistory;

my $DXS_HOST = '127.0.0.1'; # security boundary: admin transport is local-only
my $DXS_PORT = $ENV{DXS_PORT} // 27754;
my $RECONNECT = $ENV{RECONNECT_SEC} // 3;
my $MAX_INPUT_BYTES = $ENV{MAX_INPUT_BYTES} // 262144;
my $MAX_HISTORY = $ENV{MAX_HISTORY} // 250;
my $MAX_HISTORY_BYTES = $ENV{MAX_HISTORY_BYTES} // 524288;
my $MAX_FANOUT_ITEMS = $ENV{MAX_FANOUT_ITEMS} // 256;
my $MAX_FANOUT_BYTES = $ENV{MAX_FANOUT_BYTES} // 524288;
my $WS_HIGH_WATER = $ENV{WS_HIGH_WATER} // 65536;
my $REPLAY_BATCH = $ENV{REPLAY_BATCH} // 8;
my $FANOUT_BATCH = $ENV{FANOUT_BATCH} // 32;
my $REQUEST_TIMEOUT = $ENV{REQUEST_TIMEOUT_SEC} // 10;
my $HISTORY_DB = $ENV{DXWEB_HISTORY_DB} // '/spider/local_data/dxhistory.db';
my $HISTORY_INTERVAL = $ENV{DXWEB_HISTORY_INTERVAL_SEC} // 30;
my @HISTORY_KINDS = qw(status traffic self_health);
my ($history_timer,$history_inflight)=(undef,0);

app->static->paths->[0] = app->home->rel_file('admin');
app->secrets([$ENV{DXWEB_ADMIN_SECRET} // $ENV{DXWEB_SECRET} // 'dxspider-dxweb-admin-v1']);

my %state=(state=>'disconnected',web_call=>undef,error=>undef,connected_since=>undef);
my ($stream,$buffer,$reconnect_timer)=(undef,'',undef);
my $request_id=1; my $next_client_id=1;
my (%clients,%pending); my (@history,@fanout); my ($history_bytes,$fanout_bytes,$fanout_scheduled)=(0,0,0);
my %counters=map {$_=>0} qw(human rbn ann wwv wcy wx total reconnects input_overflow fanout_dropped ws_sent ws_dropped ws_slow_disconnects auth_ok auth_failed commands);
my $last_feed_at;
my $history_store = DXWebHistory->new(path => $HISTORY_DB);

sub ws_stream($tx){ return unless $tx && $tx->can('connection'); my $id=$tx->connection; return defined($id)?Mojo::IOLoop->stream($id):undef }
sub public_status(){ return {type=>'status',%state,dxs_host=>$DXS_HOST,dxs_port=>0+$DXS_PORT,counters=>{%counters},last_feed_at=>$last_feed_at,websocket_clients=>scalar(keys %clients),history_items=>scalar(@history),history_bytes=>$history_bytes,fanout_items=>scalar(@fanout),fanout_bytes=>$fanout_bytes,supervision_history=>$history_store->status()} }
sub browser_client_snapshot(){ my$total=scalar(keys %clients);my$auth=grep{$clients{$_}{authenticated}}keys%clients;return{clients=>$total,authenticated=>0+$auth,anonymous=>$total-$auth} }
sub client_status($id){ my $o=public_status(); my $cl=$clients{$id}; $o->{authenticated}=($cl&&$cl->{authenticated})?\1:\0; if($cl&&$cl->{authenticated}){$o->{call}=$cl->{call};$o->{priv}=0+($cl->{priv}//0);$o->{registered}=$cl->{registered}?\1:\0;$o->{password_used}=$cl->{password_used}?\1:\0} return $o }
sub release_client($id,$reason='browser_disconnect'){ my$cl=$clients{$id} or return; if($cl->{authenticated}&&$cl->{call}&&$state{state}eq'ready'){send_dxs({type=>'user_del',id=>$request_id++,call=>$cl->{call}})} delete$clients{$id}; for my$rid(keys%pending){if($pending{$rid}{client}==$id){my$p=delete$pending{$rid};Mojo::IOLoop->remove($p->{timer}) if$p&&$p->{timer}}} return$cl }
sub drop_slow_client($id){ my $cl=release_client($id,'slow_consumer') or return; $counters{ws_slow_disconnects}++; eval{$cl->{tx}->finish(1013=>'slow consumer')} }
sub ws_send_guarded($id,$json){ my $cl=$clients{$id} or return 0; my $tx=$cl->{tx}; return 0 unless $tx&&$tx->is_websocket; my $s=ws_stream($tx); unless($s&&$s->can('can_write')&&$s->can('bytes_waiting')){$counters{ws_dropped}++;drop_slow_client($id);return 0} my $w=$s->bytes_waiting; my $n=length($json); if($n>$WS_HIGH_WATER){$counters{ws_dropped}++;app->log->error("refusing oversized websocket message bytes=$n hwm=$WS_HIGH_WATER");return 0} if(!$s->can_write||$w+$n>$WS_HIGH_WATER){$counters{ws_dropped}++;drop_slow_client($id);return 0} my $ok=eval{$tx->send($json);1}; if(!$ok){release_client($id,'send_failed');return 0} $counters{ws_sent}++;1 }
sub pump_fanout { $fanout_scheduled=0; my $b=$FANOUT_BATCH; while($b-->0&&@fanout){my $j=shift@fanout;$fanout_bytes-=length$j; for my $id(keys%clients){next unless $clients{$id}{authenticated};ws_send_guarded($id,$j)}} if(@fanout&&!$fanout_scheduled){$fanout_scheduled=1;Mojo::IOLoop->next_tick(\&pump_fanout)} }
sub queue_fanout($j){ return 1 unless grep {$clients{$_}{authenticated}} keys%clients; my $n=length$j; if(@fanout>=$MAX_FANOUT_ITEMS||$fanout_bytes+$n>$MAX_FANOUT_BYTES){$counters{fanout_dropped}++;return 0} push@fanout,$j;$fanout_bytes+=$n; unless($fanout_scheduled){$fanout_scheduled=1;Mojo::IOLoop->next_tick(\&pump_fanout)} 1 }
sub set_state($n,$e=undef){$state{state}=$n;$state{error}=$e;$state{web_call}=undef if $n eq 'disconnected'||$n eq 'connecting';$state{connected_since}=time if $n eq 'tcp_connected'; for my $id(keys%clients){ws_send_guarded($id,encode_json(client_status($id)))}}
sub history_add($o,$j){my$n=length$j;push@history,[$o,$j,$n];$history_bytes+=$n;while(@history>$MAX_HISTORY||$history_bytes>$MAX_HISTORY_BYTES){my$x=shift@history;$history_bytes-=$x->[2]}}
sub push_feed($kind,$raw){my$payload=$raw;my$d;eval{$d=decode_json($raw)};$payload=$d->{payload} if !$@&&ref$d eq 'HASH'&&exists$d->{payload};$counters{$kind}++ if exists$counters{$kind};$counters{total}++;$last_feed_at=scalar(gmtime()).'Z';my$o={type=>'feed',feed=>$kind,received_at=>$last_feed_at,payload=>$payload,counters=>{%counters}};my$j=encode_json$o;history_add($o,$j);queue_fanout($j)}
sub send_line($l){return unless$stream;$stream->write($l."\n")}
sub send_dxs($o){return unless$state{web_call};send_line('I'.$state{web_call}.'|'.encode_json($o))}
sub pending_timeout($id){my$p=delete$pending{$id} or return;my$cid=$p->{client};my$cl=$clients{$cid} or return;my$a=$p->{action}||'';if($a eq 'logout'){my$x=release_client($cid,'logout_timeout');eval{$x->{tx}->finish(1011=>'logout timeout')} if$x;return}if($a eq 'auth'){ws_send_guarded($cid,encode_json({type=>'auth',status=>'error',error=>'request_timeout'}));return}ws_send_guarded($cid,encode_json({type=>$a.'_result',status=>'error',error=>'request_timeout'}))}
sub dxs_request($cid,$action,$o){return unless$stream&&$state{web_call};my$id=$request_id++;$o->{id}=$id;my$t=Mojo::IOLoop->timer($REQUEST_TIMEOUT=>sub{pending_timeout($id)});$pending{$id}={client=>$cid,action=>$action,timer=>$t};send_dxs($o);return$id}
sub history_next($idx=0){
    $history_inflight=0;
    return history_schedule() unless $state{state} eq 'ready' && $stream && $state{web_call};
    return history_schedule() if $idx > $#HISTORY_KINDS;
    my $what=$HISTORY_KINDS[$idx];
    my $id=$request_id++;
    my $t=Mojo::IOLoop->timer($REQUEST_TIMEOUT=>sub{
        my $p=delete $pending{$id} or return;
        $history_inflight=0;
        history_next($idx+1);
    });
    $pending{$id}={internal_history=>1,history_idx=>$idx,history_kind=>$what,action=>"supervisor_$what",timer=>$t};
    $history_inflight=1;
    send_dxs({type=>'supervisor',id=>$id,what=>$what});
}
sub history_schedule($delay=$HISTORY_INTERVAL){
    Mojo::IOLoop->remove($history_timer) if $history_timer;
    $history_timer=Mojo::IOLoop->timer($delay=>sub{undef $history_timer;history_next(0)});
}
sub replay_history($id,$pos=0){
	return unless $clients{$id} && $clients{$id}{authenticated};
	return if $pos > $#history;

	my $cl = $clients{$id} or return;
	my $s = ws_stream($cl->{tx}) or return;

	# History replay is optional/catch-up traffic.  Never let it trip the
	# slow-consumer disconnect used for live WebSocket traffic.  Only queue
	# another replay batch while there is enough room in the socket buffer.
	# If the socket is still busy, yield to the event loop and retry the same
	# position later; DXSpider input/feed processing remains fully asynchronous.
	if (!$s->can_write || $s->bytes_waiting >= int($WS_HIGH_WATER / 2)) {
		Mojo::IOLoop->timer(0.05, sub { replay_history($id,$pos) })
			if $clients{$id} && $clients{$id}{authenticated};
		return;
	}

	my $end = $pos + $REPLAY_BATCH - 1;
	$end = $#history if $end > $#history;

	for my $i ($pos .. $end) {
		return unless $clients{$id} && $clients{$id}{authenticated};
		my $json = $history[$i][1];
		my $n = length $json;

		# Do not call ws_send_guarded() when this optional replay item would
		# cross the high-water mark: yield and retry this item later instead.
		my $cur = $s->bytes_waiting;
		if (!$s->can_write || $n > $WS_HIGH_WATER || $cur + $n > $WS_HIGH_WATER) {
			Mojo::IOLoop->timer(0.05, sub { replay_history($id,$i) })
				if $clients{$id} && $clients{$id}{authenticated};
			return;
		}

		return unless ws_send_guarded($id,$json);
	}

	my $next = $end + 1;
	Mojo::IOLoop->next_tick(sub { replay_history($id,$next) })
		if $next <= $#history && $clients{$id} && $clients{$id}{authenticated};
}
sub handle_response($msg){my$id=$msg->{id};my$p=delete$pending{$id} or return;Mojo::IOLoop->remove($p->{timer}) if$p->{timer};if($p->{internal_history}){$history_inflight=0;my$result=$msg->{result};$history_store->enqueue($p->{history_kind},$result) if (($msg->{status}//'') eq 'ok' && ref($result) eq 'HASH');history_next(($p->{history_idx}//0)+1);return}my$cid=$p->{client};my$cl=$clients{$cid} or return;if($p->{action} eq 'auth'){if(($msg->{status}//'')eq 'ok'){my$priv=0+($msg->{priv}//0);my$pw=$msg->{password_used}?1:0;if(!$pw||$priv<9){$counters{auth_failed}++;send_dxs({type=>'user_del',id=>$request_id++,call=>$msg->{call}}) if $msg->{call};ws_send_guarded($cid,encode_json({type=>'auth',status=>'error',error=>$pw?'admin_privilege_required':'password_required'}));return}$cl->{authenticated}=1;$cl->{call}=$msg->{call};$cl->{priv}=$priv;$cl->{registered}=$msg->{registered}?1:0;$cl->{password_used}=1;$counters{auth_ok}++;ws_send_guarded($cid,encode_json({type=>'auth',status=>'ok',call=>$msg->{call},priv=>$priv,registered=>$msg->{registered}?\1:\0,password_used=>\1}));ws_send_guarded($cid,encode_json(client_status($cid)));Mojo::IOLoop->next_tick(sub{replay_history($cid,0)})}else{$counters{auth_failed}++;ws_send_guarded($cid,encode_json({type=>'auth',status=>'error',error=>$msg->{error}//'authentication_failed'}))}return} if($p->{action} eq 'command'){
  $counters{commands}++; my @m=@{$msg->{messages}||[]}; my @chunks; my @cur; my $bytes=0;
  for my $line(@m){my$n=length(defined($line)?$line:'')+8;if(@cur&&$bytes+$n>4096){push@chunks,[@cur];@cur=();$bytes=0}push@cur,$line;$bytes+=$n}
  push@chunks,[@cur] if @cur; @chunks=([]) unless @chunks;
  my$i=0;my$send_chunk;$send_chunk=sub{return unless$clients{$cid};my$json=encode_json({type=>'command_result',status=>$msg->{status}//'error',messages=>$chunks[$i],error=>$msg->{error},final=>($i==$#chunks?\1:\0)});return unless ws_send_guarded($cid,$json);$i++;Mojo::IOLoop->timer(0.02,$send_chunk) if$i<@chunks};$send_chunk->();return
}
if($p->{action} eq 'logout'){
  my$ok=(($msg->{status}//'')eq'ok'||($msg->{error}//'')eq'not_owned');
  if($ok){$cl->{authenticated}=0;delete$cl->{call};delete$cl->{priv};delete$cl->{registered};delete$cl->{password_used}}
  ws_send_guarded($cid,encode_json({type=>'logout_result',status=>$ok?'ok':'error',error=>$ok?undef:($msg->{error}//'logout_failed')}));
  ws_send_guarded($cid,encode_json(client_status($cid)));return
}
if($p->{action} eq 'spot'){ws_send_guarded($cid,encode_json({type=>'spot_result',status=>$msg->{status}//'error',messages=>$msg->{messages}||[],error=>$msg->{error},result=>$msg->{result}}));return}
if($p->{action} eq 'ann'){ws_send_guarded($cid,encode_json({type=>'ann_result',status=>$msg->{status}//'error',messages=>$msg->{messages}||[],error=>$msg->{error},result=>$msg->{result},scope=>$msg->{scope}}));return}
if($p->{action}=~/^reg_(?:pending|history|search|accept|reject|delete_user)$/){ws_send_guarded($cid,encode_json({type=>$p->{action}.'_result',status=>$msg->{status}//'error',messages=>$msg->{messages}||[],error=>$msg->{error},result=>$msg->{result}}));return}
if($p->{action}=~/^supervisor_(?:status|connections|traffic|web|rbn|self_health|topology)$/){my$result=$msg->{result};if($p->{action} eq 'supervisor_web'&&ref($result) eq 'HASH'){$result={%$result,browser_clients=>browser_client_snapshot()}}my$json=encode_json({type=>$p->{action}.'_result',status=>$msg->{status}//'error',error=>$msg->{error},result=>$result});if(length($json)>$WS_HIGH_WATER){app->log->error("oversized supervisor response action=$p->{action} bytes=".length($json));$json=encode_json({type=>$p->{action}.'_result',status=>'error',error=>'response_too_large'})}ws_send_guarded($cid,$json);return}
ws_send_guarded($cid,encode_json($msg))}
sub handle_line($line) {
  $line =~ s/\r$//;
  return if $line eq '';
  if (!$state{web_call} && $line =~ /^C(#WEB-\d+)\s*$/) {
    $state{web_call}=$1; set_state('wait_prompt'); return;
  }
  if ($state{web_call} && $line =~ /^D\Q$state{web_call}\E\|(.*)$/s) {
    my $body=$1;
    if ($body =~ /^Hello\s+web,\s+this\s+is\s+([A-Z0-9-]+)/i) {
      $state{node_call}=uc $1;
      for my $id (keys %clients) { ws_send_guarded($id,encode_json(client_status($id))) }
    }
    if ($state{state} eq 'wait_prompt') {
      if ($body =~ /dxspider\s*>\s*$/i) { set_state('wait_hello'); send_dxs({type=>'hello',role=>'dxweb-admin',auth=>'dxspider',version=>2}); }
      return;
    }
    my $m; eval { $m=decode_json $body }; return if $@ || ref($m) ne 'HASH';
    if (($m->{type}//'') eq 'hello') {
      if (($m->{status}//'') eq 'ok' && ($m->{role}//'') eq 'dxweb-admin' && ($m->{auth}//'') eq 'dxspider') {
        set_state('configuring_feeds');
        dxs_request(0,'feed',{type=>'feed',human=>\1,rbn=>\1,ann=>\1,wwv=>\1,wcy=>\1,wx=>\1});
      } else { set_state('hello_error',$m->{error}//'hello failed'); }
      return;
    }
    if (($m->{type}//'') eq 'response') {
      if (($m->{action}//'') eq 'feed' && $state{state} eq 'configuring_feeds') {
        my$p=delete $pending{$m->{id}};Mojo::IOLoop->remove($p->{timer}) if$p&&$p->{timer}; my$ok=(($m->{status}//'') eq 'ok'); set_state($ok ? 'ready' : 'feed_error',$m->{error}); history_schedule(2) if $ok; return;
      }
      handle_response($m); return;
    }
    return;
  }
  my %map=(X=>'human',R=>'rbn',N=>'ann',V=>'wwv',Y=>'wcy',W=>'wx');
  for my $let (keys %map) {
    if ($state{web_call} && $line =~ /^\Q$let$state{web_call}\E\|(.*)$/s) { push_feed($map{$let},$1); return; }
  }
}
sub schedule_reconnect;sub connect_dxs(){return if$stream;set_state('connecting');Mojo::IOLoop->client({address=>$DXS_HOST,port=>$DXS_PORT}=>sub($loop,$err,$s){if($err){set_state('disconnected',$err);schedule_reconnect();return}$stream=$s;$s->timeout(0);$buffer='';set_state('tcp_connected');send_line('A#WEB|dxweb enhanced');set_state('wait_assignment');$s->on(read=>sub($this,$bytes){return unless$stream&&$this==$stream;$buffer.=$bytes;if(length$buffer>$MAX_INPUT_BYTES){$counters{input_overflow}++;$buffer='';$this->close;return}while(1){my$n=index($buffer,"\n");last if$n<0;my$l=substr($buffer,0,$n,'');substr($buffer,0,1,'');handle_line($l)}});$s->on(close=>sub($this){return unless$stream&&$this==$stream;$stream=undef;$buffer='';$history_inflight=0;for my$p(values%pending){Mojo::IOLoop->remove($p->{timer}) if$p->{timer}}%pending=();for my$id(keys%clients){$clients{$id}{authenticated}=0;delete$clients{$id}{call}}$counters{reconnects}++;set_state('disconnected','DXSpider connection closed');schedule_reconnect()});$s->on(error=>sub($this,$err){set_state('transport_error',$err);$this->close})})}
sub schedule_reconnect{return if$reconnect_timer;$reconnect_timer=Mojo::IOLoop->timer($RECONNECT=>sub{undef$reconnect_timer;connect_dxs()})}

sub history_summary_compact($r) {
    my %out=(schema_version=>1,window=>$r->{window},window_seconds=>$r->{window_seconds},window_coverage_seconds=>$r->{window_coverage_seconds},window_coverage_ratio=>$r->{window_coverage_ratio},kinds=>{});
    for my $kind (sort keys %{$r->{kinds}||{}}) {
        my $k=$r->{kinds}{$kind}; my %ko=(boot_count=>$k->{boot_count},boot_changed=>$k->{boot_changed},latest_boot_id=>$k->{latest_boot_id},samples=>$k->{samples},window_samples=>$k->{window_samples},current_boot_coverage_seconds=>$k->{current_boot_coverage_seconds},current_boot_coverage_ratio=>$k->{current_boot_coverage_ratio},counters=>{},gauges=>{});
        for my $path (sort keys %{$k->{counters}||{}}) { my $c=$k->{counters}{$path}; next unless ($c->{delta}//0)!=0 || ($c->{resets}//0)!=0; $ko{counters}{$path}={map {$_=>$c->{$_}} qw(delta rate_per_second samples span_seconds resets valid)} }
        for my $path (sort keys %{$k->{gauges}||{}}) { my $g=$k->{gauges}{$path}; next if defined($g->{min}) && defined($g->{max}) && $g->{min}==$g->{max}; $ko{gauges}{$path}={map {$_=>$g->{$_}} qw(first last min max samples)} }
        $out{kinds}{$kind}=\%ko;
    }
    return \%out;
}
sub send_overview_snapshot($id) {
    $history_store->latest_snapshots_async(cb=>sub($err,$latest){
        return unless $clients{$id} && $clients{$id}{authenticated};
        if ($err) { ws_send_guarded($id,encode_json({type=>'supervisor_overview_result',status=>'error',error=>"$err"})); return }
        $history_store->semantic_window_async(window=>'15m',cb=>sub($serr,$hist){
            return unless $clients{$id} && $clients{$id}{authenticated};
            if ($serr) { ws_send_guarded($id,encode_json({type=>'supervisor_overview_result',status=>'error',error=>"$serr"})); return }
            my %snap = map { $_ => $latest->{$_}{payload} } grep { ref($latest->{$_}{payload}) eq 'HASH' } keys %$latest;
            my %ages = map { $_ => time-($latest->{$_}{collected_at}//time) } keys %$latest;
            my $result={schema_version=>1,collected_at=>time,source=>'dxhistory.db',snapshots=>\%snap,snapshot_age_seconds=>\%ages,history=>history_summary_compact($hist),system=>local_system_snapshot()};
            my $json=encode_json({type=>'supervisor_overview_result',status=>'ok',result=>$result});
            if(length($json)>$WS_HIGH_WATER){$json=encode_json({type=>'supervisor_overview_result',status=>'error',error=>'response_too_large'})}
            ws_send_guarded($id,$json);
        });
    });
}

sub send_history_summary($id,$window='15m') {
    $window='15m' unless $window =~ /^(?:5m|15m|1h|6h|24h)$/;
    $history_store->semantic_window_async(window=>$window,cb=>sub($err,$r){
        return unless $clients{$id} && $clients{$id}{authenticated};
        my $o=$err ? {type=>'supervisor_history_result',status=>'error',error=>"$err"} : {type=>'supervisor_history_result',status=>'ok',result=>history_summary_compact($r)};
        my $json=encode_json($o); if(length($json)>$WS_HIGH_WATER){$json=encode_json({type=>'supervisor_history_result',status=>'error',error=>'response_too_large'})} ws_send_guarded($id,$json);
    });
}

sub local_system_snapshot {
    my %r = (collected_at => time);
    if (open my $fh, '<', '/proc/uptime') {
        my $line = <$fh> // '';
        $r{host_uptime_seconds} = 0 + $1 if $line =~ /^([0-9.]+)/;
        close $fh;
    }
    if (open my $fh, '<', '/proc/loadavg') {
        my $line = <$fh> // '';
        @r{qw(load1 load5 load15)} = map {0+$_} ($1,$2,$3) if $line =~ /^([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)/;
        close $fh;
    }
    my %m;
    if (open my $fh, '<', '/proc/meminfo') {
        while (<$fh>) { $m{$1}=1024*(0+$2) if /^(MemTotal|MemAvailable|SwapTotal|SwapFree):\s+(\d+)/ }
        close $fh;
    }
    $r{mem_total_bytes}=$m{MemTotal}||0;
    $r{mem_available_bytes}=$m{MemAvailable}||0;
    $r{mem_used_bytes}=($m{MemTotal}||0)-($m{MemAvailable}||0);
    $r{swap_total_bytes}=$m{SwapTotal}||0;
    $r{swap_used_bytes}=($m{SwapTotal}||0)-($m{SwapFree}||0);
    if (open my $fh, '<', '/proc/self/status') {
        while (<$fh>) { if (/^VmRSS:\s+(\d+)/) {$r{admin_rss_bytes}=1024*(0+$1);last} }
        close $fh;
    }
    return \%r;
}

hook before_server_start=>sub($server,$app){Mojo::IOLoop->next_tick(sub{connect_dxs()})};
get '/'=>sub($c){$c->reply->static('index.html')};
get '/healthz'=>sub($c){$c->render(status=>$state{state}eq 'ready'?200:503,json=>public_status())};
any [qw(POST PUT PATCH DELETE)]=>'/*whatever'=>sub($c){$c->render(status=>405,json=>{error=>'websocket_api_only'})};
websocket '/ws'=>sub($c){my$id=$next_client_id++;my$tx=$c->tx;my$s=ws_stream($tx);unless($s&&$s->can('high_water_mark')&&$s->can('can_write')&&$s->can('bytes_waiting')){$c->finish(1011=>'backpressure unavailable');return}$s->high_water_mark($WS_HIGH_WATER);my$ip=$tx->remote_address||'127.0.0.1';$ip=~s/^::ffff://i;$clients{$id}={tx=>$tx,ip=>$ip,authenticated=>0};$c->inactivity_timeout(0);ws_send_guarded($id,encode_json(client_status($id)));$c->on(message=>sub($c,$raw){my$m;eval{$m=decode_json$raw};return if$@||ref$m ne 'HASH';my$t=lc($m->{type}//'');if($t eq 'auth'){return unless$state{state}eq 'ready';return if$clients{$id}{authenticated};my$call=$m->{call}//'';my$pass=exists$m->{password}?$m->{password}:undef;dxs_request($id,'auth',{type=>'auth',call=>$call,password=>$pass,ip=>$clients{$id}{ip}});return}if($t eq 'logout'){return unless$clients{$id}{authenticated};dxs_request($id,'logout',{type=>'user_del',call=>$clients{$id}{call}});return}return unless$clients{$id}{authenticated};if($t=~/^reg_(?:pending|history)$/){dxs_request($id,$t,{type=>$t,call=>$clients{$id}{call}});return}if($t eq 'reg_search'){dxs_request($id,$t,{type=>$t,call=>$clients{$id}{call},query=>$m->{query}//''});return}if($t=~/^reg_(?:accept|reject)$/){dxs_request($id,$t,{type=>$t,call=>$clients{$id}{call},request_id=>$m->{request_id},note=>$m->{note}//''});return}if($t eq 'reg_delete_user'){dxs_request($id,$t,{type=>$t,call=>$clients{$id}{call},target=>$m->{target}//'',note=>$m->{note}//'',ip=>$clients{$id}{ip}});return}if($t eq 'supervisor_overview'){send_overview_snapshot($id);return}if($t eq 'supervisor_history'){send_history_summary($id,$m->{window}//'15m');return}if($t eq 'history_metrics'){my$window=$m->{window}//'15m';$history_store->metrics_series_async(window=>$window,cb=>sub{my($err,$result)=@_;return unless$clients{$id}&&$clients{$id}{authenticated};my$o=$err?{type=>'history_metrics_result',status=>'error',error=>$err}:{type=>'history_metrics_result',status=>'ok',result=>$result};my$j=encode_json($o);$j=encode_json({type=>'history_metrics_result',status=>'error',error=>'response_too_large'}) if length($j)>$WS_HIGH_WATER;ws_send_guarded($id,$j)});return}if($t eq 'supervisor_system'){ws_send_guarded($id,encode_json({type=>'supervisor_system_result',status=>'ok',result=>local_system_snapshot()}));return}if($t=~/^supervisor_(status|connections|traffic|web|rbn|self_health|topology)$/){my$what=$1;dxs_request($id,$t,{type=>'supervisor',call=>$clients{$id}{call},what=>$what});return}if($t eq 'command'){my$cmd=$m->{command}//'';dxs_request($id,'command',{type=>'command',call=>$clients{$id}{call},command=>$cmd});return}});$c->on(finish=>sub{release_client($id,'browser_finish')})};
app->start;
