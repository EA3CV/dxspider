#!/usr/bin/env perl
#
# DXSpider Web Supervision
#
# Web interface for monitoring and administering a DXSpider node,
# including supervision, historical metrics, diagnostics and controlled
# maintenance functions.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#
# DXSpider Web Admin 0.78.3
# Date: 2026-10-05
use strict;
use warnings;
use utf8;
use Mojolicious::Lite -signatures;
use POSIX ();
use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess;
use Mojo::JSON  qw(encode_json decode_json);
use Time::HiRes qw(time);
use FindBin;
use lib "$FindBin::Bin/lib";
use DXWebHistory;
use DXWebBurstSnapshot;

my $DXS_HOST   = '127.0.0.1'; # security boundary: admin transport is local-only
my $DXS_PORT   = $ENV{DXS_PORT}      // 27754;
my $DXWEB_HOST = $ENV{DXWEB_HOST}    // '0.0.0.0';
my $DXWEB_PORT = $ENV{DXWEB_PORT}    // 7481;        # definitive Admin UI port
my $RECONNECT  = $ENV{RECONNECT_SEC} // 3;
my $MAX_INPUT_BYTES           = $ENV{MAX_INPUT_BYTES}           // 262144;
my $MAX_HISTORY               = $ENV{MAX_HISTORY}               // 250;
my $MAX_HISTORY_BYTES         = $ENV{MAX_HISTORY_BYTES}         // 524288;
my $MAX_FANOUT_ITEMS          = $ENV{MAX_FANOUT_ITEMS}          // 256;
my $MAX_FANOUT_BYTES          = $ENV{MAX_FANOUT_BYTES}          // 524288;
my $WS_HIGH_WATER             = $ENV{WS_HIGH_WATER}             // 65536;
my $MAX_WS_MESSAGE_BYTES      = $ENV{MAX_WS_MESSAGE_BYTES}      // 524288;
my $REPLAY_BATCH              = $ENV{REPLAY_BATCH}              // 8;
my $FANOUT_BATCH              = $ENV{FANOUT_BATCH}              // 32;
my $REQUEST_TIMEOUT           = $ENV{REQUEST_TIMEOUT_SEC}       // 10;
my $MAX_BROWSER_MESSAGE_BYTES = $ENV{MAX_BROWSER_MESSAGE_BYTES} // 65536;
my $MAX_PENDING_TOTAL         = $ENV{MAX_PENDING_TOTAL}         // 256;
my $MAX_PENDING_PER_CLIENT    = $ENV{MAX_PENDING_PER_CLIENT}    // 16;
my $MAX_CLIENTS               = $ENV{MAX_CLIENTS}               // 64;
my $MAX_COMMAND_BYTES         = $ENV{MAX_COMMAND_BYTES}         // 4096;
my $HISTORY_DB = $ENV{DXWEB_HISTORY_DB} // '/spider/local_data/dxhistory.db';
my $HISTORY_INTERVAL = $ENV{DXWEB_HISTORY_INTERVAL_SEC} // 30;
my @HISTORY_KINDS = qw(status connections traffic spot_ranks rbn self_health);
my ( $history_timer, $history_inflight ) = ( undef, 0 );
my $maintenance_action_inflight = 0;
my ( %clients, %pending );

my %MAINT_UPDATE_ACTION = (
    download_usdb => [
        'wget', '-N', '-P', '/spider/local_data',
        'ftp://ftp.w1nr.net/usdbraw.gz'
    ],
    prepare_usdb =>
      [ '/spider/perl/create_usdb.pl', '/spider/local_data/usdbraw.gz' ],
    prepare_keps =>
      [ '/spider/perl/convkeps.pl', '-p', '/spider/local_data/nasabare.txt' ],
    prepare_prefix => ['/spider/perl/create_prefix.pl'],
);

sub maintenance_update_action( $cid, $action ) {
    my $cmd = $MAINT_UPDATE_ACTION{$action};
    unless ($cmd) {
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type   => 'maintenance_update_action_result',
                    status => 'error',
                    action => $action,
                    error  => 'invalid_action'
                }
            )
        );
        return;
    }
    my @cmd = @$cmd;
    my $sp  = Mojo::IOLoop::Subprocess->new;
    $sp->run(
        sub {
            my $sub = shift;
            my @out;
            open my $fh, '-|', @cmd or die "exec failed: $!";
            while ( my $line = <$fh> ) {
                chomp $line;
                push @out, $line if length $line;
            }
            close $fh;
            my $rc = $? >> 8;
            return { rc => $rc, output => \@out };
        },
        sub {
            my ( $sub, $err, $res ) = @_;
            return unless $clients{$cid} && $clients{$cid}{authenticated};
            my $ok  = !$err && ref($res) eq 'HASH' && ( $res->{rc} // 1 ) == 0;
            my @out = $ok ? @{ $res->{output} || [] } : ();
            push @out, join( ' ', @cmd ) unless @out;
            ws_send_guarded(
                $cid,
                encode_json(
                    {
                        type   => 'maintenance_update_action_result',
                        status => $ok ? 'ok' : 'error',
                        action => $action,
                        output => \@out,
                        error  => $ok
                        ? undef
                        : ( $err || ( 'exit ' . ( $res->{rc} // '?' ) ) )
                    }
                )
            );
        }
    );
}
app->static->paths->[0] = app->home->rel_file('admin');
app->secrets(
    [
        $ENV{DXWEB_ADMIN_SECRET} // $ENV{DXWEB_SECRET}
          // 'dxspider-dxweb-admin-v1'
    ]
);

my %state = (
    state           => 'disconnected',
    web_call        => undef,
    error           => undef,
    connected_since => undef
);
my ( $stream, $buffer, $reconnect_timer ) = ( undef, '', undef );
my $request_id     = 1;
my $next_client_id = 1;
my ( @history, @fanout );
my ( $history_bytes, $fanout_bytes, $fanout_scheduled ) = ( 0, 0, 0 );
my %counters = map { $_ => 0 }
  qw(human rbn ann wwv wcy wx total reconnects input_overflow fanout_dropped ws_sent ws_dropped ws_slow_disconnects auth_ok auth_failed commands);
my $last_feed_at;
my $history_store = DXWebHistory->new(
    path            => $HISTORY_DB,
    local_data_root => '/spider/local_data'
);
my $burst_snapshot = DXWebBurstSnapshot->new(
    history  => $history_store,
    path     => '/spider/local_data/dxweb-bursts.json',
    interval => $HISTORY_INTERVAL,
    window   => '1h'
);

sub ws_stream($tx) {
    return unless $tx && $tx->can('connection');
    my $id = $tx->connection;
    return defined($id) ? Mojo::IOLoop->stream($id) : undef;
}

sub public_status() {
    return {
        type => 'status',
        %state,
        dxs_host            => $DXS_HOST,
        dxs_port            => 0 + $DXS_PORT,
        counters            => {%counters},
        last_feed_at        => $last_feed_at,
        websocket_clients   => scalar( keys %clients ),
        history_items       => scalar(@history),
        history_bytes       => $history_bytes,
        fanout_items        => scalar(@fanout),
        fanout_bytes        => $fanout_bytes,
        pending_requests    => scalar( keys %pending ),
        supervision_history => $history_store->status()
    };
}

sub browser_client_snapshot() {
    my $total = scalar( keys %clients );
    my $auth  = grep { $clients{$_}{authenticated} } keys %clients;
    return {
        clients       => $total,
        authenticated => 0 + $auth,
        anonymous     => $total - $auth
    };
}

sub client_status($id) {
    my $o  = public_status();
    my $cl = $clients{$id};
    $o->{authenticated} = ( $cl && $cl->{authenticated} ) ? \1 : \0;
    if ( $cl && $cl->{authenticated} ) {
        $o->{call}          = $cl->{call};
        $o->{priv}          = 0 + ( $cl->{priv} // 0 );
        $o->{registered}    = $cl->{registered}    ? \1 : \0;
        $o->{password_used} = $cl->{password_used} ? \1 : \0;
    }
    return $o;
}

sub release_client( $id, $reason = 'browser_disconnect' ) {
    my $cl = $clients{$id} or return;
    if ( $cl->{authenticated} && $cl->{call} && $state{state} eq 'ready' ) {
        send_dxs(
            { type => 'user_del', id => $request_id++, call => $cl->{call} } );
    }
    delete $clients{$id};
    for my $rid ( keys %pending ) {
        if ( $pending{$rid}{client} == $id ) {
            my $p = delete $pending{$rid};
            Mojo::IOLoop->remove( $p->{timer} ) if $p && $p->{timer};
        }
    }
    return $cl;
}

sub drop_slow_client($id) {
    my $cl = release_client( $id, 'slow_consumer' ) or return;
    $counters{ws_slow_disconnects}++;
    eval { $cl->{tx}->finish( 1013 => 'slow consumer' ) }
}

sub ws_send_guarded( $id, $json ) {
    my $cl = $clients{$id} or return 0;
    my $tx = $cl->{tx};
    return 0 unless $tx && $tx->is_websocket;
    my $s = ws_stream($tx);
    unless ( $s && $s->can('can_write') && $s->can('bytes_waiting') ) {
        $counters{ws_dropped}++;
        drop_slow_client($id);
        return 0;
    }
    my $w = $s->bytes_waiting;
    my $n = length($json);
    if ( $n > $MAX_WS_MESSAGE_BYTES ) {
        $counters{ws_dropped}++;
        app->log->error(
"refusing oversized websocket message bytes=$n max=$MAX_WS_MESSAGE_BYTES"
        );
        return 0;
    }
    if (  !$s->can_write
        || $w >= $WS_HIGH_WATER
        || ( $w > 0 && $w + $n > $WS_HIGH_WATER ) )
    {
        $counters{ws_dropped}++;
        drop_slow_client($id);
        return 0;
    }
    my $ok = eval { $tx->send($json); 1 };
    if ( !$ok ) { release_client( $id, 'send_failed' ); return 0 }
    $counters{ws_sent}++;
    1;
}

# Control/request replies are not a live feed.  A temporarily busy browser socket
# must not be treated as a slow consumer and logged out merely because the user
# changes panels.  Queue the reply after the socket drains; DXSpider remains
# completely asynchronous and is never blocked.
sub ws_send_response( $id, $json, $tries = 0 ) {
    my $cl = $clients{$id} or return 0;
    my $tx = $cl->{tx};
    return 0 unless $tx && $tx->is_websocket;
    my $s = ws_stream($tx);
    return 0 unless $s && $s->can('can_write') && $s->can('bytes_waiting');
    my $n = length($json);
    if ( $n > $MAX_WS_MESSAGE_BYTES ) {
        $counters{ws_dropped}++;
        app->log->error(
"refusing oversized websocket response bytes=$n max=$MAX_WS_MESSAGE_BYTES"
        );
        return 0;
    }
    my $w = $s->bytes_waiting;
    if (  !$s->can_write
        || $w >= $WS_HIGH_WATER
        || ( $w > 0 && $w + $n > $WS_HIGH_WATER ) )
    {
        return 0
          if $tries >= 200 || !$clients{$id} || !$clients{$id}{authenticated};
        Mojo::IOLoop->timer( 0.05,
            sub { ws_send_response( $id, $json, $tries + 1 ) } );
        return 1;
    }
    my $ok = eval { $tx->send($json); 1 };
    unless ($ok) { release_client( $id, 'send_failed' ); return 0 }
    $counters{ws_sent}++;
    return 1;
}

sub client_can_receive_feed( $id, $targets = undef ) {
    my $cl = $clients{$id} or return 0;
    return 0 unless $cl->{authenticated};
    return 1 unless ref($targets) eq 'ARRAY';
    my $call = uc( $cl->{call} // '' );
    return scalar grep { uc( $_ // '' ) eq $call } @$targets;
}

sub pump_fanout {
    $fanout_scheduled = 0;
    my $b = $FANOUT_BATCH;
    while ( $b-- > 0 && @fanout ) {
        my $e = shift @fanout;
        my ( $j, $targets ) = ref($e) eq 'ARRAY' ? @$e : ( $e, undef );
        $fanout_bytes -= length $j;
        for my $id ( keys %clients ) {
            next unless client_can_receive_feed( $id, $targets );
            ws_send_guarded( $id, $j );
        }
    }
    if ( @fanout && !$fanout_scheduled ) {
        $fanout_scheduled = 1;
        Mojo::IOLoop->next_tick( \&pump_fanout );
    }
}

sub queue_fanout( $j, $targets = undef ) {
    return 1 unless grep { $clients{$_}{authenticated} } keys %clients;
    my $n = length $j;
    if (   @fanout >= $MAX_FANOUT_ITEMS
        || $fanout_bytes + $n > $MAX_FANOUT_BYTES )
    {
        $counters{fanout_dropped}++;
        return 0;
    }
    push @fanout, [ $j, $targets ];
    $fanout_bytes += $n;
    unless ($fanout_scheduled) {
        $fanout_scheduled = 1;
        Mojo::IOLoop->next_tick( \&pump_fanout );
    }
    1;
}

sub set_state( $n, $e = undef ) {
    $state{state}    = $n;
    $state{error}    = $e;
    $state{web_call} = undef if $n eq 'disconnected' || $n eq 'connecting';
    $state{connected_since} = time if $n eq 'tcp_connected';
    for my $id ( keys %clients ) {
        ws_send_guarded( $id, encode_json( client_status($id) ) );
    }
}

sub history_add( $o, $j ) {
    my $n = length $j;
    push @history, [ $o, $j, $n ];
    $history_bytes += $n;
    while ( @history > $MAX_HISTORY || $history_bytes > $MAX_HISTORY_BYTES ) {
        my $x = shift @history;
        $history_bytes -= $x->[2];
    }
}

sub push_feed( $kind, $raw ) {
    my $payload = $raw;
    my ( $d, $targets );
    eval { $d = decode_json($raw) };
    if ( !$@ && ref $d eq 'HASH' ) {
        $payload = $d->{payload} if exists $d->{payload};
        $targets = $d->{targets} if ref( $d->{targets} ) eq 'ARRAY';
    }
    $counters{$kind}++ if exists $counters{$kind};
    $counters{total}++;
    $last_feed_at = scalar( gmtime() ) . 'Z';
    my $o = {
        type        => 'feed',
        feed        => $kind,
        received_at => $last_feed_at,
        payload     => $payload,
        counters    => {%counters}
    };
    my $j = encode_json $o;
    history_add( { %$o, _targets => $targets }, $j );
    queue_fanout( $j, $targets );
}
sub send_line($l) { return unless $stream; $stream->write( $l . "\n" ) }

sub send_dxs($o) {
    return unless $state{web_call};
    send_line( 'I' . $state{web_call} . '|' . encode_json($o) );
}

sub pending_timeout($id) {
    my $p   = delete $pending{$id} or return;
    my $cid = $p->{client};
    my $cl  = $clients{$cid} or return;
    my $a   = $p->{action} || '';
    if ( $a eq 'logout' ) {
        my $x = release_client( $cid, 'logout_timeout' );
        eval { $x->{tx}->finish( 1011 => 'logout timeout' ) } if $x;
        return;
    }
    if ( $a eq 'auth' ) {
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type   => 'auth',
                    status => 'error',
                    error  => 'request_timeout'
                }
            )
        );
        return;
    }
    ws_send_guarded(
        $cid,
        encode_json(
            {
                type   => $a . '_result',
                status => 'error',
                error  => 'request_timeout'
            }
        )
    );
}

sub dxs_request( $cid, $action, $o ) {
    return unless $stream && $state{web_call};
    return if scalar( keys %pending ) >= $MAX_PENDING_TOTAL;
    if ($cid) {
        my $n = 0;
        for my $p ( values %pending ) {
            $n++ if defined( $p->{client} ) && $p->{client} == $cid;
        }
        return if $n >= $MAX_PENDING_PER_CLIENT;
    }
    my $id = $request_id++;
    $o->{id} = $id;
    my $t =
      Mojo::IOLoop->timer( $REQUEST_TIMEOUT => sub { pending_timeout($id) } );
    $pending{$id} = { client => $cid, action => $action, timer => $t };
    send_dxs($o);
    return $id;
}

sub history_next( $idx = 0 ) {
    $history_inflight = 0;
    return history_schedule()
      unless $state{state} eq 'ready' && $stream && $state{web_call};
    if ( $idx > $#HISTORY_KINDS ) {
        $history_store->enqueue( 'system', local_system_snapshot() );
        return history_schedule();
    }
    my $what = $HISTORY_KINDS[$idx];
    my $id   = $request_id++;
    my $t    = Mojo::IOLoop->timer(
        $REQUEST_TIMEOUT => sub {
            my $p = delete $pending{$id} or return;
            $history_inflight = 0;
            history_next( $idx + 1 );
        }
    );
    $pending{$id} = {
        internal_history => 1,
        history_idx      => $idx,
        history_kind     => $what,
        action           => "supervisor_$what",
        timer            => $t
    };
    $history_inflight = 1;
    send_dxs( { type => 'supervisor', id => $id, what => $what } );
}

sub history_schedule( $delay = $HISTORY_INTERVAL ) {
    Mojo::IOLoop->remove($history_timer) if $history_timer;
    $history_timer = Mojo::IOLoop->timer(
        $delay => sub { undef $history_timer; history_next(0) } );
}

sub replay_history( $id, $pos = 0 ) {
    return unless $clients{$id} && $clients{$id}{authenticated};
    return if $pos > $#history;

    my $cl = $clients{$id}          or return;
    my $s  = ws_stream( $cl->{tx} ) or return;

    # History replay is optional/catch-up traffic.  Never let it trip the
    # slow-consumer disconnect used for live WebSocket traffic.  Only queue
    # another replay batch while there is enough room in the socket buffer.
    # If the socket is still busy, yield to the event loop and retry the same
    # position later; DXSpider input/feed processing remains fully asynchronous.
    if ( !$s->can_write || $s->bytes_waiting >= int( $WS_HIGH_WATER / 2 ) ) {
        Mojo::IOLoop->timer( 0.05, sub { replay_history( $id, $pos ) } )
          if $clients{$id} && $clients{$id}{authenticated};
        return;
    }

    my $end = $pos + $REPLAY_BATCH - 1;
    $end = $#history if $end > $#history;

    for my $i ( $pos .. $end ) {
        return unless $clients{$id} && $clients{$id}{authenticated};
        next   unless client_can_receive_feed( $id, $history[$i][0]{_targets} );
        my $json = $history[$i][1];
        my $n    = length $json;

        # Do not call ws_send_guarded() when this optional replay item would
        # cross the high-water mark: yield and retry this item later instead.
        my $cur = $s->bytes_waiting;

        # Message size and queue occupancy are separate limits.  A valid message
        # larger than the normal queue HWM may be sent when the queue is empty;
        # otherwise yield until it drains.  Permanently oversized replay items
        # are skipped instead of creating an endless retry timer.
        if ( $n > $MAX_WS_MESSAGE_BYTES ) {
            $counters{ws_dropped}++;
            next;
        }
        if (  !$s->can_write
            || $cur >= $WS_HIGH_WATER
            || ( $cur > 0 && $cur + $n > $WS_HIGH_WATER ) )
        {
            Mojo::IOLoop->timer( 0.05, sub { replay_history( $id, $i ) } )
              if $clients{$id} && $clients{$id}{authenticated};
            return;
        }

        return unless ws_send_guarded( $id, $json );
    }

    my $next = $end + 1;
    Mojo::IOLoop->next_tick( sub { replay_history( $id, $next ) } )
      if $next <= $#history && $clients{$id} && $clients{$id}{authenticated};
}

sub handle_response($msg) {
    my $id = $msg->{id};
    my $p  = delete $pending{$id} or return;
    Mojo::IOLoop->remove( $p->{timer} ) if $p->{timer};
    if ( $p->{internal_history} ) {
        $history_inflight = 0;
        my $result = $msg->{result};
        if ( ( ( $msg->{status} // '' ) eq 'ok' ) && ref($result) eq 'HASH' ) {
            my $ok = $history_store->enqueue( $p->{history_kind}, $result );
            app->log->error("history enqueue rejected kind=$p->{history_kind}")
              unless $ok;
        }
        else {
            app->log->error(
                    "history sampler failed kind=$p->{history_kind} status="
                  . ( $msg->{status} // '' )
                  . " error="
                  . ( $msg->{error} // '' ) );
        }
        history_next( ( $p->{history_idx} // 0 ) + 1 );
        return;
    }
    my $cid = $p->{client};
    my $cl  = $clients{$cid} or return;
    if ( $p->{action} eq 'auth' ) {
        if ( ( $msg->{status} // '' ) eq 'ok' ) {
            my $priv = 0 + ( $msg->{priv} // 0 );
            my $pw   = $msg->{password_used} ? 1 : 0;
            if ( !$pw || $priv < 1 ) {
                $counters{auth_failed}++;
                send_dxs(
                    {
                        type => 'user_del',
                        id   => $request_id++,
                        call => $msg->{call}
                    }
                ) if $msg->{call};
                ws_send_guarded(
                    $cid,
                    encode_json(
                        {
                            type   => 'auth',
                            status => 'error',
                            error  => $pw
                            ? 'admin_privilege_required'
                            : 'password_required'
                        }
                    )
                );
                return;
            }
            $cl->{authenticated} = 1;
            $cl->{call}          = $msg->{call};
            $cl->{priv}          = $priv;
            $cl->{registered}    = $msg->{registered} ? 1 : 0;
            $cl->{password_used} = 1;
            $counters{auth_ok}++;
            ws_send_guarded(
                $cid,
                encode_json(
                    {
                        type          => 'auth',
                        status        => 'ok',
                        call          => $msg->{call},
                        priv          => $priv,
                        registered    => $msg->{registered} ? \1 : \0,
                        password_used => \1
                    }
                )
            );
            ws_send_guarded( $cid, encode_json( client_status($cid) ) );
            Mojo::IOLoop->next_tick( sub { replay_history( $cid, 0 ) } );
        }
        else {
            $counters{auth_failed}++;
            ws_send_guarded(
                $cid,
                encode_json(
                    {
                        type   => 'auth',
                        status => 'error',
                        error  => $msg->{error} // 'authentication_failed'
                    }
                )
            );
        }
        return;
    }
    if ( $p->{action} eq 'command' ) {
        $counters{commands}++;
        my @m = @{ $msg->{messages} || [] };
        my @chunks;
        my @cur;
        my $bytes = 0;
        for my $line (@m) {
            my $n = length( defined($line) ? $line : '' ) + 8;
            if ( @cur && $bytes + $n > 4096 ) {
                push @chunks, [@cur];
                @cur   = ();
                $bytes = 0;
            }
            push @cur, $line;
            $bytes += $n;
        }
        push @chunks, [@cur] if @cur;
        @chunks = ( [] ) unless @chunks;
        my $i = 0;
        my $send_chunk;
        $send_chunk = sub {
            return unless $clients{$cid};
            my $json = encode_json(
                {
                    type     => 'command_result',
                    status   => $msg->{status} // 'error',
                    messages => $chunks[$i],
                    error    => $msg->{error},
                    final    => ( $i == $#chunks ? \1 : \0 )
                }
            );
            return unless ws_send_guarded( $cid, $json );
            $i++;
            Mojo::IOLoop->timer( 0.02, $send_chunk ) if $i < @chunks;
        };
        $send_chunk->();
        return;
    }
    if ( $p->{action} eq 'logout' ) {
        my $ok = ( ( $msg->{status} // '' ) eq 'ok'
              || ( $msg->{error} // '' ) eq 'not_owned' );
        if ($ok) {
            $cl->{authenticated} = 0;
            delete $cl->{call};
            delete $cl->{priv};
            delete $cl->{registered};
            delete $cl->{password_used};
        }
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type   => 'logout_result',
                    status => $ok ? 'ok'  : 'error',
                    error  => $ok ? undef : ( $msg->{error} // 'logout_failed' )
                }
            )
        );
        ws_send_guarded( $cid, encode_json( client_status($cid) ) );
        return;
    }
    if ( $p->{action} eq 'spot' ) {
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type     => 'spot_result',
                    status   => $msg->{status} // 'error',
                    messages => $msg->{messages} || [],
                    error    => $msg->{error},
                    result   => $msg->{result}
                }
            )
        );
        return;
    }
    if ( $p->{action} eq 'ann' ) {
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type     => 'ann_result',
                    status   => $msg->{status} // 'error',
                    messages => $msg->{messages} || [],
                    error    => $msg->{error},
                    result   => $msg->{result},
                    scope    => $msg->{scope}
                }
            )
        );
        return;
    }
    if ( $p->{action} =~
        /^reg_(?:pending|history|search|accept|reject|delete_user)$/ )
    {
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type     => $p->{action} . '_result',
                    status   => $msg->{status} // 'error',
                    messages => $msg->{messages} || [],
                    error    => $msg->{error},
                    result   => $msg->{result}
                }
            )
        );
        return;
    }
    if ( $p->{action} =~
/^supervisor_(?:status|connections|traffic|web|rbn|self_health|topology)$/
      )
    {
        my $result = $msg->{result};
        if ( $p->{action} eq 'supervisor_web' && ref($result) eq 'HASH' ) {
            $result = { %$result, browser_clients => browser_client_snapshot() };
        }
        my $json = encode_json(
            {
                type   => $p->{action} . '_result',
                status => $msg->{status} // 'error',
                error  => $msg->{error},
                result => $result
            }
        );
        if ( length($json) > $MAX_WS_MESSAGE_BYTES ) {
            app->log->error(
                "oversized supervisor response action=$p->{action} bytes="
                  . length($json) );
            $json = encode_json(
                {
                    type   => $p->{action} . '_result',
                    status => 'error',
                    error  => 'response_too_large'
                }
            );
        }
        ws_send_guarded( $cid, $json );
        return;
    }
    ws_send_guarded( $cid, encode_json($msg) );
}

sub handle_line($line) {
    $line =~ s/\r$//;
    return if $line eq '';
    if ( !$state{web_call} && $line =~ /^C(#WEB-\d+)\s*$/ ) {
        $state{web_call} = $1;
        set_state('wait_prompt');
        return;
    }
    if ( $state{web_call} && $line =~ /^D\Q$state{web_call}\E\|(.*)$/s ) {
        my $body = $1;
        if ( $body =~ /^Hello\s+web,\s+this\s+is\s+([A-Z0-9-]+)/i ) {
            $state{node_call} = uc $1;
            for my $id ( keys %clients ) {
                ws_send_guarded( $id, encode_json( client_status($id) ) );
            }
        }
        if ( $state{state} eq 'wait_prompt' ) {
            if ( $body =~ /dxspider\s*>\s*$/i ) {
                set_state('wait_hello');
                send_dxs(
                    {
                        type    => 'hello',
                        role    => 'dxweb-admin',
                        auth    => 'dxspider',
                        version => 2
                    }
                );
            }
            return;
        }
        my $m;
        eval { $m = decode_json $body };
        return if $@ || ref($m) ne 'HASH';
        if ( ( $m->{type} // '' ) eq 'hello' ) {
            if (   ( $m->{status} // '' ) eq 'ok'
                && ( $m->{role} // '' ) eq 'dxweb-admin'
                && ( $m->{auth} // '' ) eq 'dxspider' )
            {
                set_state('configuring_feeds');
                dxs_request(
                    0, 'feed',
                    {
                        type  => 'feed',
                        human => \1,
                        rbn   => \1,
                        ann   => \1,
                        wwv   => \1,
                        wcy   => \1,
                        wx    => \1
                    }
                );
            }
            else { set_state( 'hello_error', $m->{error} // 'hello failed' ); }
            return;
        }
        if ( ( $m->{type} // '' ) eq 'response' ) {
            if ( ( $m->{action} // '' ) eq 'feed'
                && $state{state} eq 'configuring_feeds' )
            {
                my $p = delete $pending{ $m->{id} };
                Mojo::IOLoop->remove( $p->{timer} ) if $p && $p->{timer};
                my $ok = ( ( $m->{status} // '' ) eq 'ok' );
                set_state( $ok ? 'ready' : 'feed_error', $m->{error} );
                history_schedule(2) if $ok;
                return;
            }
            handle_response($m);
            return;
        }
        return;
    }
    my %map = (
        X => 'human',
        R => 'rbn',
        N => 'ann',
        V => 'wwv',
        Y => 'wcy',
        W => 'wx'
    );
    for my $let ( keys %map ) {
        if ( $state{web_call} && $line =~ /^\Q$let$state{web_call}\E\|(.*)$/s )
        {
            push_feed( $map{$let}, $1 );
            return;
        }
    }
}
sub schedule_reconnect;

sub connect_dxs() {
    return if $stream;
    set_state('connecting');
    Mojo::IOLoop->client(
        { address => $DXS_HOST, port => $DXS_PORT } => sub( $loop, $err, $s ) {
            if ($err) {
                set_state( 'disconnected', $err );
                schedule_reconnect();
                return;
            }
            $stream = $s;
            $s->timeout(0);
            $buffer = '';
            set_state('tcp_connected');
            send_line('A#WEB|dxweb enhanced');
            set_state('wait_assignment');
            $s->on(
                read => sub( $this, $bytes ) {
                    return unless $stream && $this == $stream;
                    $buffer .= $bytes;
                    if ( length $buffer > $MAX_INPUT_BYTES ) {
                        $counters{input_overflow}++;
                        $buffer = '';
                        $this->close;
                        return;
                    }
                    while (1) {
                        my $n = index( $buffer, "\n" );
                        last if $n < 0;
                        my $l = substr( $buffer, 0, $n, '' );
                        substr( $buffer, 0, 1, '' );
                        handle_line($l);
                    }
                }
            );
            $s->on(
                close => sub($this) {
                    return unless $stream && $this == $stream;
                    $stream           = undef;
                    $buffer           = '';
                    $history_inflight = 0;
                    for my $p ( values %pending ) {
                        Mojo::IOLoop->remove( $p->{timer} ) if $p->{timer};
                    }
                    %pending = ();
                    for my $id ( keys %clients ) {
                        $clients{$id}{authenticated} = 0;
                        delete $clients{$id}{call};
                    }
                    $counters{reconnects}++;
                    set_state( 'disconnected', 'DXSpider connection closed' );
                    schedule_reconnect();
                }
            );
            $s->on(
                error => sub( $this, $err ) {
                    set_state( 'transport_error', $err );
                    $this->close;
                }
            );
        }
    );
}

sub schedule_reconnect {
    return if $reconnect_timer;
    $reconnect_timer = Mojo::IOLoop->timer(
        $RECONNECT => sub { undef $reconnect_timer; connect_dxs() } );
}

sub history_summary_compact($r) {
    my %out = (
        schema_version          => 1,
        window                  => $r->{window},
        window_seconds          => $r->{window_seconds},
        window_coverage_seconds => $r->{window_coverage_seconds},
        window_coverage_ratio   => $r->{window_coverage_ratio},
        kinds                   => {}
    );
    for my $kind ( sort keys %{ $r->{kinds} || {} } ) {
        my $k  = $r->{kinds}{$kind};
        my %ko = (
            boot_count                    => $k->{boot_count},
            boot_changed                  => $k->{boot_changed},
            latest_boot_id                => $k->{latest_boot_id},
            samples                       => $k->{samples},
            window_samples                => $k->{window_samples},
            current_boot_coverage_seconds =>
              $k->{current_boot_coverage_seconds},
            current_boot_coverage_ratio => $k->{current_boot_coverage_ratio},
            counters                    => {},
            gauges                      => {}
        );
        for my $path ( sort keys %{ $k->{counters} || {} } ) {
            my $c = $k->{counters}{$path};
            next unless ( $c->{delta} // 0 ) != 0 || ( $c->{resets} // 0 ) != 0;
            $ko{counters}{$path} = { map { $_ => $c->{$_} }
                  qw(delta rate_per_second samples span_seconds resets valid) };
        }
        for my $path ( sort keys %{ $k->{gauges} || {} } ) {
            my $g = $k->{gauges}{$path};
            next
              if defined( $g->{min} )
              && defined( $g->{max} )
              && $g->{min} == $g->{max};
            $ko{gauges}{$path} =
              { map { $_ => $g->{$_} } qw(first last min max samples) };
        }
        $out{kinds}{$kind} = \%ko;
    }
    return \%out;
}

sub send_overview_snapshot($id) {
    $history_store->latest_snapshots_async(
        cb => sub( $err, $latest ) {
            return unless $clients{$id} && $clients{$id}{authenticated};
            if ($err) {
                ws_send_guarded(
                    $id,
                    encode_json(
                        {
                            type   => 'supervisor_overview_result',
                            status => 'error',
                            error  => "$err"
                        }
                    )
                );
                return;
            }
            $history_store->semantic_window_async(
                window => '15m',
                cb     => sub( $serr, $hist ) {
                    return unless $clients{$id} && $clients{$id}{authenticated};
                    if ($serr) {
                        ws_send_guarded(
                            $id,
                            encode_json(
                                {
                                    type   => 'supervisor_overview_result',
                                    status => 'error',
                                    error  => "$serr"
                                }
                            )
                        );
                        return;
                    }
                    my %snap =
                      map  { $_ => $latest->{$_}{payload} }
                      grep { ref( $latest->{$_}{payload} ) eq 'HASH' }
                      keys %$latest;
                    my %ages = map {
                        $_ => time - ( $latest->{$_}{collected_at} // time )
                    } keys %$latest;
                    my $result = {
                        schema_version       => 1,
                        collected_at         => time,
                        source               => 'dxhistory.db',
                        snapshots            => \%snap,
                        snapshot_age_seconds => \%ages,
                        history              => history_summary_compact($hist),
                        system               => local_system_snapshot()
                    };
                    my $json = encode_json(
                        {
                            type   => 'supervisor_overview_result',
                            status => 'ok',
                            result => $result
                        }
                    );
                    if ( length($json) > $MAX_WS_MESSAGE_BYTES ) {
                        $json = encode_json(
                            {
                                type   => 'supervisor_overview_result',
                                status => 'error',
                                error  => 'response_too_large'
                            }
                        );
                    }
                    ws_send_guarded( $id, $json );
                }
            );
        }
    );
}

sub send_history_summary( $id, $window = '15m' ) {
    $window = '15m' unless $window =~ /^(?:5m|15m|1h|6h|24h)$/;
    $history_store->semantic_window_async(
        window => $window,
        cb     => sub( $err, $r ) {
            return unless $clients{$id} && $clients{$id}{authenticated};
            my $o = $err
              ? {
                type   => 'supervisor_history_result',
                status => 'error',
                error  => "$err"
              }
              : {
                type   => 'supervisor_history_result',
                status => 'ok',
                result => history_summary_compact($r)
              };
            my $json = encode_json($o);
            if ( length($json) > $MAX_WS_MESSAGE_BYTES ) {
                $json = encode_json(
                    {
                        type   => 'supervisor_history_result',
                        status => 'error',
                        error  => 'response_too_large'
                    }
                );
            }
            ws_send_guarded( $id, $json );
        }
    );
}

sub local_system_snapshot {
    my %r = ( collected_at => time, admin_pid => 0 + $$ );
    if ( open my $fh, '<', '/proc/uptime' ) {
        my $line = <$fh> // '';
        $r{host_uptime_seconds} = 0 + $1 if $line =~ /^([0-9.]+)/;
        close $fh;
    }
    if ( open my $fh, '<', '/proc/loadavg' ) {
        my $line = <$fh> // '';
        @r{qw(load1 load5 load15)} = map { 0 + $_ } ( $1, $2, $3 )
          if $line =~ /^([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)/;
        close $fh;
    }
    my %m;
    if ( open my $fh, '<', '/proc/meminfo' ) {
        while (<$fh>) {
            $m{$1} = 1024 * ( 0 + $2 )
              if /^(MemTotal|MemAvailable|SwapTotal|SwapFree):\s+(\d+)/;
        }
        close $fh;
    }
    $r{mem_total_bytes}     = $m{MemTotal}     || 0;
    $r{mem_available_bytes} = $m{MemAvailable} || 0;
    $r{mem_used_bytes}      = ( $m{MemTotal} || 0 ) - ( $m{MemAvailable} || 0 );
    $r{swap_total_bytes}    = $m{SwapTotal} || 0;
    $r{swap_used_bytes}     = ( $m{SwapTotal} || 0 ) - ( $m{SwapFree} || 0 );
    if ( open( my $df, '-|', 'df', '-Pk', '/spider' ) ) {
        my @l = <$df>;
        close $df;
        if ( @l > 1 ) {
            my @f = split /\s+/, $l[-1];
            if ( @f >= 6 ) {
                $r{fs_total_bytes}     = 1024 * ( 0 + $f[1] );
                $r{fs_used_bytes}      = 1024 * ( 0 + $f[2] );
                $r{fs_available_bytes} = 1024 * ( 0 + $f[3] );
                ( my $pct = $f[4] ) =~ s/%//;
                $r{fs_used_percent} = 0 + $pct;
            }
        }
    }

    if ( open my $fh, '<', '/proc/self/status' ) {
        while (<$fh>) {
            if (/^VmRSS:\s+(\d+)/) {
                $r{admin_rss_bytes} = 1024 * ( 0 + $1 );
                last;
            }
        }
        close $fh;
    }
    if ( opendir( my $dh, '/proc/self/fd' ) ) {
        my @fd = grep { /^\d+$/ } readdir($dh);
        closedir($dh);
        $r{admin_fds} = scalar @fd;
    }

    # Real dxweb-admin queue/backpressure gauges.  These are local to the web
    # transport and therefore sampled here, outside DXSpider's hot path.
    my $hs = $history_store->status();
    $r{history_queue_items}   = 0 + ( $hs->{queued}  // 0 );
    $r{history_dropped_total} = 0 + ( $hs->{dropped} // 0 );
    $r{fanout_queue_items}    = scalar @fanout;
    $r{fanout_queue_bytes}    = 0 + $fanout_bytes;
    $r{pending_requests}      = scalar keys %pending;
    my ( $browser_queue_bytes, $browser_queue_max, $browser_queued_clients ) =
      ( 0, 0, 0 );

    for my $cl ( values %clients ) {
        my $stream = eval { ws_stream( $cl->{tx} ) };
        next unless $stream && $stream->can('bytes_waiting');
        my $w = 0 + ( eval { $stream->bytes_waiting } || 0 );
        $browser_queue_bytes += $w;
        $browser_queue_max = $w   if $w > $browser_queue_max;
        $browser_queued_clients++ if $w > 0;
    }
    $r{browser_queue_bytes}       = $browser_queue_bytes;
    $r{browser_queue_max_bytes}   = $browser_queue_max;
    $r{browser_queued_clients}    = $browser_queued_clients;
    $r{ws_dropped_total}          = 0 + ( $counters{ws_dropped}          // 0 );
    $r{ws_slow_disconnects_total} = 0 + ( $counters{ws_slow_disconnects} // 0 );
    return \%r;
}

# DXSpider update reference check: official mojo first, EA3CV mirror only as fallback.
# Runs outside the event loop and keeps its Git cache isolated from /spider/.git.
my $UPDATE_PRIMARY       = 'git://scm.dxcluster.org/spider';
my $UPDATE_FALLBACK      = 'https://github.com/EA3CV/dxspider.git';
my $UPDATE_BRANCH        = 'mojo';
my $UPDATE_CACHE_REPO    = '/spider/local_data/dxweb-update-check.git';
my $UPDATE_CACHE_TTL     = 300;
my $UPDATE_FETCH_TIMEOUT = $ENV{DXWEB_UPDATE_FETCH_TIMEOUT} // 15;
my (
    $update_check_cache,   $update_check_at,
    $update_check_running, @update_check_waiters
);

sub _update_parse_desc($desc) {
    $desc //= '';
    chomp $desc;
    return unless $desc =~ /^([\d.]+)(?:\.(\d+))?-(\d+)-g([0-9a-f]+)/;
    return {
        version    => $1,
        subversion => 0 + ( $2 || 0 ),
        build      => 0 + $3,
        git        => $4
    };
}

sub _update_cmp( $local, $remote ) {
    my $comparable =
         defined($local)
      && defined($remote)
      && "$local" ne ''
      && "$remote" ne '' ? 1 : 0;
    return {
        comparable => $comparable                              ? \1 : \0,
        match      => ( $comparable && "$local" eq "$remote" ) ? \1 : \0,
        local      => $local,
        remote     => $remote
    };
}

sub _system_timeout( $seconds, @cmd ) {
    my $pid = fork();
    return 255 unless defined $pid;
    if ( !$pid ) { exec @cmd or POSIX::_exit(127) }
    my $timed_out = 0;
    local $SIG{ALRM} = sub { $timed_out = 1; kill 'TERM', $pid };
    alarm($seconds);
    waitpid( $pid, 0 );
    my $status = $?;
    alarm(0);
    if ($timed_out) { kill 'KILL', $pid; waitpid( $pid, 0 ); return 124 }
    return $status >> 8;
}

sub _run_update_check($done) {
    my $sp = Mojo::IOLoop::Subprocess->new;
    $sp->run(
        sub {
            my $capture = sub {
                my (@cmd) = @_;
                open my $fh, '-|', @cmd or return ( undef, 255 );
                local $/;
                my $out = <$fh> // '';
                close $fh;
                my $rc = $? >> 8;
                $out =~ s/\s+\z//;
                return ( $out, $rc );
            };
            my ( $local_commit, $lrc ) = $capture->(
                'git',      '-C', '/spider', 'rev-parse',
                '--verify', 'HEAD^{commit}'
            );
            my ( $local_branch, $brc ) = $capture->(
                'git',     '-C',      '/spider', 'symbolic-ref',
                '--quiet', '--short', 'HEAD'
            );
            my ( $local_desc, $drc ) =
              $capture->( 'git', '-C', '/spider', 'describe', '--long' );
            die "local_git_state_failed\n" if $lrc || $brc || $drc;
            my $ld = _update_parse_desc($local_desc)
              or die "local_git_describe_invalid\n";
            unless ( -d $UPDATE_CACHE_REPO ) {
                system( 'git', 'init', '--bare', '--quiet', $UPDATE_CACHE_REPO )
                  == 0
                  or die "cache_init_failed\n";
            }
            my ( $source, $remote_commit, $remote_desc, $last_error );
            for my $url ( $UPDATE_PRIMARY, $UPDATE_FALLBACK ) {
                my $rc = _system_timeout(
                    $UPDATE_FETCH_TIMEOUT,
                    'git',
                    '--git-dir=' . $UPDATE_CACHE_REPO,
                    'fetch',
                    '--quiet',
                    '--force',
                    '--tags',
                    $url,
                    '+refs/heads/'
                      . $UPDATE_BRANCH
                      . ':refs/heads/'
                      . $UPDATE_BRANCH
                );
                if ( $rc != 0 ) { $last_error = "fetch_failed:$url"; next }
                ( $remote_commit, my $rrc ) = $capture->(
                    'git',       '--git-dir=' . $UPDATE_CACHE_REPO,
                    'rev-parse', '--verify',
                    'refs/heads/' . $UPDATE_BRANCH . '^{commit}'
                );
                ( $remote_desc, my $rdrc ) = $capture->(
                    'git', '--git-dir=' . $UPDATE_CACHE_REPO,
                    'describe', '--long', 'refs/heads/' . $UPDATE_BRANCH
                );
                if ( !$rrc && !$rdrc && $remote_commit =~ /^[0-9a-f]{40,64}$/ )
                {
                    $source = $url;
                    last;
                }
                $last_error = "remote_git_state_failed:$url";
            }
            die( ( $last_error || 'both_repositories_failed' ) . "\n" )
              unless $source;
            my $rd = _update_parse_desc($remote_desc)
              or die "remote_git_describe_invalid\n";
            my $branch_cmp  = _update_cmp( $local_branch,    $UPDATE_BRANCH );
            my $version_cmp = _update_cmp( $ld->{version},   $rd->{version} );
            my $build_cmp   = _update_cmp( 0 + $ld->{build}, 0 + $rd->{build} );
            my $commit_cmp =
              _update_cmp( lc($local_commit), lc($remote_commit) );
            my $updated =
              (      $branch_cmp->{match}
                  && $version_cmp->{match}
                  && $build_cmp->{match}
                  && $commit_cmp->{match} ) ? 1 : 0;
            return {
                status         => $updated ? 'UPDATED' : 'NOT_UPDATED',
                source         => $source,
                branch         => $UPDATE_BRANCH,
                local_branch   => $local_branch,
                local_version  => $ld->{version},
                local_build    => 0 + $ld->{build},
                local_commit   => $local_commit,
                remote_version => $rd->{version},
                remote_build   => 0 + $rd->{build},
                remote_commit  => $remote_commit,
                comparisons    => {
                    branch  => $branch_cmp,
                    version => $version_cmp,
                    build   => $build_cmp,
                    commit  => $commit_cmp
                },
                checked_at => scalar( gmtime() ) . 'Z'
            };
        },
        sub( $sp, $err, $result ) {
            my $r = $err
              ? {
                status     => 'CHECK_FAILED',
                error      => "$err",
                branch     => $UPDATE_BRANCH,
                checked_at => scalar( gmtime() ) . 'Z'
              }
              : $result;
            $done->($r);
        }
    );
}

sub update_status_async($cb) {
    if ( $update_check_cache
        && time - ( $update_check_at || 0 ) < $UPDATE_CACHE_TTL )
    {
        $cb->($update_check_cache);
        return;
    }
    push @update_check_waiters, $cb;
    return if $update_check_running;
    $update_check_running = 1;
    _run_update_check(
        sub($r) {
            $update_check_cache   = $r;
            $update_check_at      = time;
            $update_check_running = 0;
            my @w = splice @update_check_waiters;
            $_->($r) for @w;
        }
    );
}

hook before_server_start => sub( $server, $app ) {
    v040_warm_caches();
    Mojo::IOLoop->next_tick( sub { connect_dxs(); $burst_snapshot->start } );
};
get '/'                   => sub($c) { $c->reply->static('index.html') };
get '/admin-version.json' => sub($c) {
    $c->render( json => { name => 'DXSpider Web Admin', version => '0.78.4' } );
};
get '/healthz' => sub($c) {
    $c->render(
        status => $state{state} eq 'ready' ? 200 : 503,
        json   => public_status()
    );
};
get '/update-status.json' => sub($c) {
    $c->render_later;
    update_status_async( sub($r) { $c->render( json => $r ) } );
};
any [qw(POST PUT PATCH DELETE)] => '/*whatever' => sub($c) {
    $c->render( status => 405, json => { error => 'websocket_api_only' } );
};

# v0.41 short-lived async cache/coalescing for expensive read-only history views.
# This lives entirely in dxweb-admin; DXSpider protocol paths are not involved.
my %v040_cache;
my %v040_cache_at;
my %v040_running;
my %v040_waiters;

sub v040_cached_async( $key, $ttl, $producer, $cb ) {
    my $now = time;
    if ( exists $v040_cache{$key}
        && $now - ( $v040_cache_at{$key} || 0 ) < $ttl )
    {
        Mojo::IOLoop->next_tick( sub { $cb->( undef, $v040_cache{$key} ) } );
        return;
    }
    push @{ $v040_waiters{$key} }, $cb;
    return if $v040_running{$key};
    $v040_running{$key} = 1;
    $producer->(
        sub( $err, $result ) {
            if ( !$err && defined $result ) {
                $v040_cache{$key}    = $result;
                $v040_cache_at{$key} = time;
            }
            $v040_running{$key} = 0;
            my @w = @{ delete( $v040_waiters{$key} ) || [] };
            $_->( $err, $result ) for @w;
        }
    );
}

sub v040_metrics_async( $window, $peer, $cb ) {
    $window ||= '24h';
    $peer //= '';
    my $key = "metrics:$window:$peer";
    v040_cached_async(
        $key, 60,
        sub($done) {
            $history_store->metrics_series_async(
                window  => $window,
                peer    => $peer,
                compact => 1,
                cb      => $done
            );
        },
        $cb
    );
}

sub v040_timeline_async( $window, $cb ) {
    $window ||= '15m';
    my $key = "timeline:$window";
    v040_cached_async(
        $key, 30,
        sub($done) {
            $history_store->timeline_async(
                window => $window,
                limit  => 300,
                cb     => $done
            );
        },
        $cb
    );
}

sub v040_maintenance_async( $path, $cb ) {
    my $p   = ref($path) eq 'ARRAY' ? $path : [];
    my $key = 'maintenance:' . join( '/', @$p );
    v040_cached_async(
        $key, 20,
        sub($done) {
            $history_store->maintenance_async(
                history_path => $p,
                cb           => $done
            );
        },
        $cb
    );
}

sub v040_warm_caches() {

# Rebuild the bounded prepared views from persistent dxhistory.db after an
# admin restart. Stagger work so startup and the DXSpider bridge stay responsive.
    my @w = qw(1h 6h 24h 7d 30d 1y);
    for my $i ( 0 .. $#w ) {
        my $win = $w[$i];
        Mojo::IOLoop->timer(
            0.5 + $i * 0.75 => sub {
                v040_metrics_async( $win, '', sub { } );
            }
        );
    }
    Mojo::IOLoop->timer(
        5.5 => sub {
            v040_timeline_async( '15m', sub { } );
        }
    );
    Mojo::IOLoop->timer(
        6.0 => sub {
            v040_maintenance_async( [], sub { } );
        }
    );
}

websocket '/ws' => sub($c) {
    if ( scalar( keys %clients ) >= $MAX_CLIENTS ) {
        $c->finish( 1013 => 'server busy' );
        return;
    }
    my $id = $next_client_id++;
    my $tx = $c->tx;
    my $s  = ws_stream($tx);
    unless ( $s
        && $s->can('high_water_mark')
        && $s->can('can_write')
        && $s->can('bytes_waiting') )
    {
        $c->finish( 1011 => 'backpressure unavailable' );
        return;
    }
    $s->high_water_mark($MAX_WS_MESSAGE_BYTES);
    my $ip = $tx->remote_address || '127.0.0.1';
    $ip =~ s/^::ffff://i;
    $clients{$id} = { tx => $tx, ip => $ip, authenticated => 0 };
    $c->inactivity_timeout(0);
    ws_send_guarded( $id, encode_json( client_status($id) ) );
    $c->on(
        message => sub( $c, $raw ) {
            if ( length($raw) > $MAX_BROWSER_MESSAGE_BYTES ) {
                $counters{ws_dropped}++;
                $c->finish( 1009 => 'message too large' );
                return;
            }
            my $m;
            eval { $m = decode_json $raw };
            return if $@ || ref $m ne 'HASH';
            my $t = lc( $m->{type} // '' );
            if ( $t eq 'auth' ) {
                return unless $state{state} eq 'ready';
                return if $clients{$id}{authenticated};
                my $call = $m->{call} // '';
                my $pass = exists $m->{password} ? $m->{password} : undef;
                dxs_request(
                    $id, 'auth',
                    {
                        type     => 'auth',
                        call     => $call,
                        password => $pass,
                        ip       => $clients{$id}{ip}
                    }
                );
                return;
            }
            if ( $t eq 'logout' ) {
                return unless $clients{$id}{authenticated};
                dxs_request( $id, 'logout',
                    { type => 'user_del', call => $clients{$id}{call} } );
                return;
            }
            return unless $clients{$id}{authenticated};
            if ( ( $clients{$id}{priv} // 0 ) < 9 && $t ne 'command' ) {
                ws_send_guarded(
                    $id,
                    encode_json(
                        {
                            type   => $t . '_result',
                            status => 'error',
                            error  => 'admin_privilege_required'
                        }
                    )
                );
                return;
            }
            if ( $t =~ /^reg_(?:pending|history)$/ ) {
                dxs_request( $id, $t,
                    { type => $t, call => $clients{$id}{call} } );
                return;
            }
            if ( $t eq 'reg_search' ) {
                dxs_request(
                    $id, $t,
                    {
                        type  => $t,
                        call  => $clients{$id}{call},
                        query => $m->{query} // ''
                    }
                );
                return;
            }
            if ( $t =~ /^reg_(?:accept|reject)$/ ) {
                dxs_request(
                    $id, $t,
                    {
                        type       => $t,
                        call       => $clients{$id}{call},
                        request_id => $m->{request_id},
                        note       => $m->{note} // ''
                    }
                );
                return;
            }
            if ( $t eq 'reg_delete_user' ) {
                dxs_request(
                    $id, $t,
                    {
                        type   => $t,
                        call   => $clients{$id}{call},
                        target => $m->{target} // '',
                        note   => $m->{note}   // '',
                        ip     => $clients{$id}{ip}
                    }
                );
                return;
            }
            if ( $t eq 'supervisor_overview' ) {
                send_overview_snapshot($id);
                return;
            }
            if ( $t eq 'supervisor_history' ) {
                send_history_summary( $id, $m->{window} // '15m' );
                return;
            }
            if ( $t eq 'history_metrics' ) {
                my $window = $m->{window} // '15m';
                v040_metrics_async(
                    $window,
                    ( $m->{peer} // '' ),
                    sub {
                        my ( $err, $result ) = @_;
                        return
                          unless $clients{$id} && $clients{$id}{authenticated};
                        my $o = $err
                          ? {
                            type   => 'history_metrics_result',
                            status => 'error',
                            error  => $err
                          }
                          : {
                            type   => 'history_metrics_result',
                            status => 'ok',
                            result => $result
                          };
                        my $j = encode_json($o);
                        $j = encode_json(
                            {
                                type   => 'history_metrics_result',
                                status => 'error',
                                error  => 'response_too_large'
                            }
                        ) if length($j) > $MAX_WS_MESSAGE_BYTES;
                        ws_send_response( $id, $j );
                    }
                );
                return;
            }
            if ( $t eq 'history_timeline' ) {
                my $window = $m->{window} // '15m';
                v040_timeline_async(
                    $window,
                    sub {
                        my ( $err, $result ) = @_;
                        return
                          unless $clients{$id} && $clients{$id}{authenticated};
                        my $o = $err
                          ? {
                            type   => 'history_timeline_result',
                            status => 'error',
                            error  => $err
                          }
                          : {
                            type   => 'history_timeline_result',
                            status => 'ok',
                            result => $result
                          };
                        my $j = encode_json($o);
                        $j = encode_json(
                            {
                                type   => 'history_timeline_result',
                                status => 'error',
                                error  => 'response_too_large'
                            }
                        ) if length($j) > $MAX_WS_MESSAGE_BYTES;
                        ws_send_response( $id, $j );
                    }
                );
                return;
            }
            if ( $t eq 'maintenance_update_action' ) {
                maintenance_update_action( $id, lc( $m->{action} // '' ) );
                return;
            }
            if ( $t eq 'maintenance_history_action' ) {
                my $action = lc( $m->{action} // '' );
                my $ids    = $m->{ids};
                if ($maintenance_action_inflight) {
                    ws_send_guarded(
                        $id,
                        encode_json(
                            {
                                type   => 'maintenance_history_action_result',
                                status => 'error',
                                error  => 'maintenance_action_busy'
                            }
                        )
                    );
                    return;
                }
                unless ( ( $action eq 'compress' || $action eq 'delete' )
                    && ref($ids) eq 'ARRAY'
                    && @$ids
                    && @$ids <= 100 )
                {
                    ws_send_guarded(
                        $id,
                        encode_json(
                            {
                                type   => 'maintenance_history_action_result',
                                status => 'error',
                                error  => 'invalid_request'
                            }
                        )
                    );
                    return;
                }
                $maintenance_action_inflight = 1;
                $history_store->history_maintenance_action_async(
                    action => $action,
                    ids    => $ids,
                    cb     => sub {
                        my ( $err, $result ) = @_;
                        $maintenance_action_inflight = 0;
                        return
                          unless $clients{$id} && $clients{$id}{authenticated};
                        my $o = $err
                          ? {
                            type   => 'maintenance_history_action_result',
                            status => 'error',
                            error  => $err
                          }
                          : {
                            type   => 'maintenance_history_action_result',
                            status => 'ok',
                            result => $result
                          };
                        my $j = encode_json($o);
                        $j = encode_json(
                            {
                                type   => 'maintenance_history_action_result',
                                status => 'error',
                                error  => 'response_too_large'
                            }
                        ) if length($j) > $MAX_WS_MESSAGE_BYTES;
                        ws_send_guarded( $id, $j );
                    }
                );
                return;
            }
            if ( $t eq 'maintenance_snapshot' ) {
                v040_maintenance_async(
                    $m->{history_path},
                    sub {
                        my ( $err, $result ) = @_;
                        return
                          unless $clients{$id} && $clients{$id}{authenticated};
                        if ( !$err && ref($result) eq 'HASH' ) {
                            $result->{system} = local_system_snapshot();
                        }
                        my $o = $err
                          ? {
                            type   => 'maintenance_snapshot_result',
                            status => 'error',
                            error  => $err
                          }
                          : {
                            type   => 'maintenance_snapshot_result',
                            status => 'ok',
                            result => $result
                          };
                        my $j = encode_json($o);
                        $j = encode_json(
                            {
                                type   => 'maintenance_snapshot_result',
                                status => 'error',
                                error  => 'response_too_large'
                            }
                        ) if length($j) > $MAX_WS_MESSAGE_BYTES;
                        ws_send_response( $id, $j );
                    }
                );
                return;
            }
            if ( $t eq 'supervisor_system' ) {
                ws_send_response(
                    $id,
                    encode_json(
                        {
                            type   => 'supervisor_system_result',
                            status => 'ok',
                            result => local_system_snapshot()
                        }
                    )
                );
                return;
            }
            if ( $t =~
/^supervisor_(status|connections|traffic|web|rbn|self_health|topology)$/
              )
            {
                my $what = $1;
                dxs_request(
                    $id, $t,
                    {
                        type => 'supervisor',
                        call => $clients{$id}{call},
                        what => $what
                    }
                );
                return;
            }
            if ( $t eq 'spot' ) {
                dxs_request(
                    $id, 'spot',
                    {
                        type    => 'spot',
                        call    => $clients{$id}{call},
                        freq    => $m->{freq}    // '',
                        dxcall  => $m->{dxcall}  // '',
                        comment => $m->{comment} // ''
                    }
                );
                return;
            }
            if ( $t eq 'command' ) {
                my $cmd = $m->{command} // '';
                if ( length($cmd) > $MAX_COMMAND_BYTES ) {
                    ws_send_guarded(
                        $id,
                        encode_json(
                            {
                                type     => 'command_result',
                                status   => 'error',
                                error    => 'command_too_large',
                                messages => [],
                                final    => \1
                            }
                        )
                    );
                    return;
                }
                dxs_request(
                    $id,
                    'command',
                    {
                        type    => 'command',
                        call    => $clients{$id}{call},
                        command => $cmd
                    }
                );
                return;
            }
        }
    );
    $c->on( finish => sub { release_client( $id, 'browser_finish' ) } );
};

# DXWeb Admin uses 7481 by default when started directly without an
# explicit Mojolicious command.  An explicit command line still wins, e.g.
#   perl admin.pl daemon -l http://127.0.0.1:7310
if ( !@ARGV ) {
    app->start( 'daemon', '-l', "http://$DXWEB_HOST:$DXWEB_PORT" );
}
else {
    app->start;
}
