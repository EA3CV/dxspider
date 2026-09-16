#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Mojolicious::Lite -signatures;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json decode_json);
use Time::HiRes qw(time);

my $DXS_HOST = $ENV{DXS_HOST} // '127.0.0.1';
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

app->static->paths->[0] = app->home->rel_file('public');
app->secrets([$ENV{DXWEB_SECRET} // 'dxspider-dxweb-v2']);

my %state=(state=>'disconnected',web_call=>undef,error=>undef,connected_since=>undef);
my ($stream,$buffer,$reconnect_timer)=(undef,'',undef);
my $request_id=1; my $next_client_id=1;
my (%clients,%pending); my (@history,@fanout); my ($history_bytes,$fanout_bytes,$fanout_scheduled)=(0,0,0);
my %counters=map {$_=>0} qw(human rbn ann wwv wcy wx total reconnects input_overflow fanout_dropped ws_sent ws_dropped ws_slow_disconnects auth_ok auth_failed commands);
my $last_feed_at;

sub ws_stream($tx){ return unless $tx && $tx->can('connection'); my $id=$tx->connection; return defined($id)?Mojo::IOLoop->stream($id):undef }
sub public_status(){ return {type=>'status',%state,dxs_host=>$DXS_HOST,dxs_port=>0+$DXS_PORT,counters=>{%counters},last_feed_at=>$last_feed_at,websocket_clients=>scalar(keys %clients),history_items=>scalar(@history),history_bytes=>$history_bytes,fanout_items=>scalar(@fanout),fanout_bytes=>$fanout_bytes} }
sub client_status($id){ my $o=public_status(); my $cl=$clients{$id}; $o->{authenticated}=($cl&&$cl->{authenticated})?\1:\0; if($cl&&$cl->{authenticated}){$o->{call}=$cl->{call};$o->{registered}=$cl->{registered}?\1:\0;$o->{password_used}=$cl->{password_used}?\1:\0} return $o }
sub drop_slow_client($id){ my $cl=delete $clients{$id} or return; $counters{ws_slow_disconnects}++; eval{$cl->{tx}->finish(1013=>'slow consumer')} }
sub ws_send_guarded($id,$json){ my $cl=$clients{$id} or return 0; my $tx=$cl->{tx}; return 0 unless $tx&&$tx->is_websocket; my $s=ws_stream($tx); unless($s&&$s->can('can_write')&&$s->can('bytes_waiting')){$counters{ws_dropped}++;drop_slow_client($id);return 0} my $w=$s->bytes_waiting; my $n=length($json); if($n>$WS_HIGH_WATER){$counters{ws_dropped}++;return 0} if(!$s->can_write||$w+$n>$WS_HIGH_WATER){$counters{ws_dropped}++;return -1} my $ok=eval{$tx->send($json);1}; if(!$ok){delete $clients{$id};return 0} $counters{ws_sent}++;1 }
sub client_can_receive_feed($id,$kind){my$cl=$clients{$id} or return 0;return 1}
sub pump_fanout { $fanout_scheduled=0; my $b=$FANOUT_BATCH; while($b-->0&&@fanout){my$e=shift@fanout;my($kind,$j,$n)=@$e;$fanout_bytes-=$n;for my$id(keys%clients){next unless client_can_receive_feed($id,$kind);ws_send_guarded($id,$j)}} if(@fanout&&!$fanout_scheduled){$fanout_scheduled=1;Mojo::IOLoop->next_tick(\&pump_fanout)} }
sub queue_fanout($kind,$j){return 1 unless keys%clients;my$n=length$j;if(@fanout>=$MAX_FANOUT_ITEMS||$fanout_bytes+$n>$MAX_FANOUT_BYTES){$counters{fanout_dropped}++;return 0}push@fanout,[$kind,$j,$n];$fanout_bytes+=$n;unless($fanout_scheduled){$fanout_scheduled=1;Mojo::IOLoop->next_tick(\&pump_fanout)}1}
sub set_state($n,$e=undef){$state{state}=$n;$state{error}=$e;$state{web_call}=undef if $n eq 'disconnected'||$n eq 'connecting';$state{connected_since}=time if $n eq 'tcp_connected'; for my $id(keys%clients){ws_send_guarded($id,encode_json(client_status($id)))}}
sub history_add($o,$j){my$n=length$j;push@history,[$o,$j,$n];$history_bytes+=$n;while(@history>$MAX_HISTORY||$history_bytes>$MAX_HISTORY_BYTES){my$x=shift@history;$history_bytes-=$x->[2]}}
sub push_feed($kind,$raw){my$payload=$raw;my$d;eval{$d=decode_json($raw)};$payload=$d->{payload} if !$@&&ref$d eq 'HASH'&&exists$d->{payload};$counters{$kind}++ if exists$counters{$kind};$counters{total}++;$last_feed_at=scalar(gmtime()).'Z';my$o={type=>'feed',feed=>$kind,received_at=>$last_feed_at,payload=>$payload,counters=>{%counters}};my$j=encode_json$o;history_add($o,$j);queue_fanout($kind,$j)}
sub send_line($l){return unless$stream;$stream->write($l."\n")}
sub send_dxs($o){return unless$state{web_call};send_line('I'.$state{web_call}.'|'.encode_json($o))}
sub dxs_request($cid,$action,$o){my$id=$request_id++;$o->{id}=$id;$pending{$id}={client=>$cid,action=>$action};send_dxs($o);return$id}
sub replay_history($id,$pos=0){return unless$clients{$id};return if$pos>$#history;my$end=$pos+$REPLAY_BATCH-1;$end=$#history if$end>$#history;for my$i($pos..$end){return unless$clients{$id};my$kind=$history[$i][0]{feed}//'';next unless client_can_receive_feed($id,$kind);my$ok=ws_send_guarded($id,$history[$i][1]);if($ok<0){Mojo::IOLoop->timer(0.05=>sub{replay_history($id,$i)}) if$clients{$id};return}return unless$ok}my$n=$end+1;Mojo::IOLoop->next_tick(sub{replay_history($id,$n)}) if$n<=$#history&&$clients{$id}}
sub handle_response($msg){my$id=$msg->{id};my$p=delete$pending{$id} or return;my$cid=$p->{client};my$cl=$clients{$cid} or return;if($p->{action} eq 'auth'){if(($msg->{status}//'')eq 'ok'){ $cl->{authenticated}=1;$cl->{call}=$msg->{call};$cl->{registered}=$msg->{registered}?1:0;$cl->{password_used}=$msg->{password_used}?1:0;$counters{auth_ok}++;ws_send_guarded($cid,encode_json({type=>'auth',status=>'ok',call=>$msg->{call},priv=>0+($msg->{priv}//0),registered=>$msg->{registered}?\1:\0,password_used=>$msg->{password_used}?\1:\0}));ws_send_guarded($cid,encode_json(client_status($cid)));Mojo::IOLoop->next_tick(sub{replay_history($cid,0)})}else{$counters{auth_failed}++;ws_send_guarded($cid,encode_json({type=>'auth',status=>'error',error=>$msg->{error}//'authentication_failed'}))}return} if($p->{action} eq 'command'){
  $counters{commands}++; my @m=@{$msg->{messages}||[]}; my @chunks; my @cur; my $bytes=0;
  for my $line(@m){my$n=length(defined($line)?$line:'')+8;if(@cur&&$bytes+$n>4096){push@chunks,[@cur];@cur=();$bytes=0}push@cur,$line;$bytes+=$n}
  push@chunks,[@cur] if @cur; @chunks=([]) unless @chunks;
  my$i=0;my$send_chunk;$send_chunk=sub{return unless$clients{$cid};my$json=encode_json({type=>'command_result',status=>$msg->{status}//'error',messages=>$chunks[$i],error=>$msg->{error},final=>($i==$#chunks?\1:\0)});return unless ws_send_guarded($cid,$json);$i++;Mojo::IOLoop->timer(0.02,$send_chunk) if$i<@chunks};$send_chunk->();return
}
if($p->{action} eq 'logout'){
  my$ok=(($msg->{status}//'')eq'ok'||($msg->{error}//'')eq'not_owned');
  if($ok){$cl->{authenticated}=0;delete$cl->{call};delete$cl->{registered};delete$cl->{password_used}}
  ws_send_guarded($cid,encode_json({type=>'logout_result',status=>$ok?'ok':'error',error=>$ok?undef:($msg->{error}//'logout_failed')}));
  ws_send_guarded($cid,encode_json(client_status($cid)));Mojo::IOLoop->next_tick(sub{replay_history($cid,0)}) if$ok;return
}
if($p->{action} eq 'spot'){ws_send_guarded($cid,encode_json({type=>'spot_result',status=>$msg->{status}//'error',messages=>$msg->{messages}||[],error=>$msg->{error},result=>$msg->{result}}));return}
if($p->{action} eq 'ann'){ws_send_guarded($cid,encode_json({type=>'ann_result',status=>$msg->{status}//'error',messages=>$msg->{messages}||[],error=>$msg->{error},result=>$msg->{result},scope=>$msg->{scope}}));return}
if($p->{action} eq 'reg_request'){ws_send_guarded($cid,encode_json({type=>'reg_request_result',status=>$msg->{status}//'error',messages=>$msg->{messages}||[],error=>$msg->{error},result=>$msg->{result}}));return}
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
      if ($body =~ /dxspider\s*>\s*$/i) { set_state('wait_hello'); send_dxs({type=>'hello',role=>'dxweb',auth=>'dxspider',version=>2}); }
      return;
    }
    my $m; eval { $m=decode_json $body }; return if $@ || ref($m) ne 'HASH';
    if (($m->{type}//'') eq 'hello') {
      if (($m->{status}//'') eq 'ok' && ($m->{role}//'') eq 'dxweb' && ($m->{auth}//'') eq 'dxspider') {
        set_state('configuring_feeds');
        dxs_request(0,'feed',{type=>'feed',human=>\1,rbn=>\1,ann=>\1,wwv=>\1,wcy=>\1,wx=>\1});
      } else { set_state('hello_error',$m->{error}//'hello failed'); }
      return;
    }
    if (($m->{type}//'') eq 'response') {
      if (($m->{action}//'') eq 'feed' && $state{state} eq 'configuring_feeds') {
        delete $pending{$m->{id}}; set_state(($m->{status}//'') eq 'ok' ? 'ready' : 'feed_error',$m->{error}); return;
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
sub schedule_reconnect;sub connect_dxs(){return if$stream;set_state('connecting');Mojo::IOLoop->client({address=>$DXS_HOST,port=>$DXS_PORT}=>sub($loop,$err,$s){if($err){set_state('disconnected',$err);schedule_reconnect();return}$stream=$s;$s->timeout(0);$buffer='';set_state('tcp_connected');send_line('A#WEB|dxweb enhanced');set_state('wait_assignment');$s->on(read=>sub($this,$bytes){return unless$stream&&$this==$stream;$buffer.=$bytes;if(length$buffer>$MAX_INPUT_BYTES){$counters{input_overflow}++;$buffer='';$this->close;return}while(1){my$n=index($buffer,"\n");last if$n<0;my$l=substr($buffer,0,$n,'');substr($buffer,0,1,'');handle_line($l)}});$s->on(close=>sub($this){return unless$stream&&$this==$stream;$stream=undef;$buffer='';%pending=();for my$id(keys%clients){$clients{$id}{authenticated}=0;delete$clients{$id}{call}}$counters{reconnects}++;set_state('disconnected','DXSpider connection closed');schedule_reconnect()});$s->on(error=>sub($this,$err){set_state('transport_error',$err);$this->close})})}
sub schedule_reconnect{return if$reconnect_timer;$reconnect_timer=Mojo::IOLoop->timer($RECONNECT=>sub{undef$reconnect_timer;connect_dxs()})}
hook before_server_start=>sub($server,$app){Mojo::IOLoop->next_tick(sub{connect_dxs()})};
get '/'=>sub($c){$c->reply->static('index.html')};
get '/healthz'=>sub($c){$c->render(status=>$state{state}eq 'ready'?200:503,json=>public_status())};
any [qw(POST PUT PATCH DELETE)]=>'/*whatever'=>sub($c){$c->render(status=>405,json=>{error=>'websocket_api_only'})};
websocket '/ws'=>sub($c){my$id=$next_client_id++;my$tx=$c->tx;my$s=ws_stream($tx);unless($s&&$s->can('high_water_mark')&&$s->can('can_write')&&$s->can('bytes_waiting')){$c->finish(1011=>'backpressure unavailable');return}$s->high_water_mark($WS_HIGH_WATER);my$ip=$tx->remote_address||'127.0.0.1';$ip=~s/^::ffff://i;$clients{$id}={tx=>$tx,ip=>$ip,authenticated=>0};$c->inactivity_timeout(0);ws_send_guarded($id,encode_json(client_status($id)));Mojo::IOLoop->next_tick(sub{replay_history($id,0)});$c->on(message=>sub($c,$raw){my$m;eval{$m=decode_json$raw};return if$@||ref$m ne 'HASH';my$t=lc($m->{type}//'');if($t eq 'auth'){return unless$state{state}eq 'ready';return if$clients{$id}{authenticated};my$call=$m->{call}//'';my$pass=exists$m->{password}?$m->{password}:undef;dxs_request($id,'auth',{type=>'auth',call=>$call,password=>$pass,ip=>$clients{$id}{ip}});return}if($t eq 'reg_request'){return unless$state{state}eq 'ready';my$call=$m->{call}//'';my$email=$m->{email}//'';my$name=$m->{name}//'';my$comment=$m->{comment}//'';my$ssids=ref($m->{ssids}) eq 'ARRAY'?$m->{ssids}:[];dxs_request($id,'reg_request',{type=>'reg_request',call=>$call,email=>$email,name=>$name,comment=>$comment,ssids=>$ssids,language=>$m->{language}//'EN',ip=>$clients{$id}{ip}});return}if($t eq 'logout'){return unless$clients{$id}{authenticated};dxs_request($id,'logout',{type=>'user_del',call=>$clients{$id}{call}});return}return unless$clients{$id}{authenticated};if($t eq 'command'){my$cmd=$m->{command}//'';dxs_request($id,'command',{type=>'command',call=>$clients{$id}{call},command=>$cmd});return}
if($t eq 'spot'){my$freq=$m->{freq}//'';my$dxcall=$m->{dxcall}//'';my$comment=$m->{comment}//'';dxs_request($id,'spot',{type=>'spot',call=>$clients{$id}{call},freq=>$freq,dxcall=>$dxcall,comment=>$comment});return}
if($t eq 'ann'){my$text=$m->{text}//'';my$scope=$m->{scope}//'local';dxs_request($id,'ann',{type=>'ann',call=>$clients{$id}{call},text=>$text,scope=>$scope});return}});$c->on(finish=>sub{my$cl=delete$clients{$id};if($cl&&$cl->{authenticated}&&$state{state}eq 'ready'){send_dxs({type=>'user_del',id=>$request_id++,call=>$cl->{call}})}for my$rid(keys%pending){delete$pending{$rid} if$pending{$rid}{client}==$id}})};
app->start;
