#!/usr/bin/env perl

#
# DXSpider Web
#
# Non-blocking web client gateway for DXSpider user access.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

use strict;
use warnings;
use utf8;
use Mojolicious::Lite -signatures;
use Mojo::IOLoop;
use Mojo::URL;
use Socket      qw(AF_INET AF_INET6 inet_pton);
use Mojo::JSON  qw(encode_json decode_json);
use Time::HiRes qw(time);
use Scalar::Util qw(weaken);

$SIG{HUP} = 'IGNORE';

my $DXS_HOST                = $ENV{DXS_HOST}                // '127.0.0.1';
my $DXS_PORT                = $ENV{DXS_PORT}                // 27754;
my $RECONNECT               = $ENV{RECONNECT_SEC}           // 3;
my $MAX_INPUT_BYTES         = $ENV{MAX_INPUT_BYTES}         // 262144;
my $MAX_HISTORY             = $ENV{MAX_HISTORY}             // 250;
my $MAX_HISTORY_BYTES       = $ENV{MAX_HISTORY_BYTES}       // 524288;
my $MAX_FANOUT_ITEMS        = $ENV{MAX_FANOUT_ITEMS}        // 256;
my $MAX_FANOUT_BYTES        = $ENV{MAX_FANOUT_BYTES}        // 524288;
my $WS_HIGH_WATER           = $ENV{WS_HIGH_WATER}           // 65536;
my $REPLAY_BATCH            = $ENV{REPLAY_BATCH}            // 8;
# Replay is paced independently of the live WebSocket slow-consumer guard.
my $REPLAY_POLL_SEC         = 0.05;
my $REPLAY_STALL_SEC        = 10;
my $REPLAY_BUFFER_LIMIT     = int($WS_HIGH_WATER / 4);
my $FANOUT_BATCH            = $ENV{FANOUT_BATCH}            // 32;
my $MAX_WS_CLIENTS          = $ENV{MAX_WS_CLIENTS}          // 2000;
my $MAX_WS_MSG_BYTES        = $ENV{MAX_WS_MSG_BYTES}        // 65536;
my $MAX_PENDING_GLOBAL      = $ENV{MAX_PENDING_GLOBAL}      // 8192;
my $MAX_PENDING_CLIENT      = $ENV{MAX_PENDING_CLIENT}      // 32;
my $REQUEST_TIMEOUT_SEC     = $ENV{REQUEST_TIMEOUT_SEC}     // 30;
my $ORPHAN_AUTH_TIMEOUT_SEC = $ENV{ORPHAN_AUTH_TIMEOUT_SEC} // 120;
# Finite idle timeout closes abandoned WebSockets and triggers USER_DEL.
my $WS_IDLE_TIMEOUT_SEC = $ENV{WS_IDLE_TIMEOUT_SEC} // 600;

app->static->paths->[0] = app->home->rel_file('public');
app->secrets( [ $ENV{DXWEB_SECRET} // 'dxspider-dxweb-v2' ] );

my %state = (
    state           => 'disconnected',
    web_call        => undef,
    error           => undef,
    connected_since => undef
);
my ( $stream, $buffer, $reconnect_timer ) = ( undef, '', undef );
my $request_id     = 1;
my $next_client_id = 1;
my ( %clients,       %pending );
my ( @history,       @fanout );
my ( $history_bytes, $fanout_bytes, $fanout_scheduled ) = ( 0, 0, 0 );
my %counters = map { $_ => 0 }
  qw(human rbn ann wwv wcy wx total reconnects input_overflow fanout_dropped ws_sent ws_dropped ws_slow_disconnects replay_pauses replay_stalls replay_completed auth_ok auth_failed commands);
my $last_feed_at;

sub ws_stream($tx) {
    return unless $tx && $tx->can('connection');
    my $id = $tx->connection;
    return defined($id) ? Mojo::IOLoop->stream($id) : undef;
}

sub public_status() {
    return {
        type => 'status',
        %state,
        dxs_host          => $DXS_HOST,
        dxs_port          => 0 + $DXS_PORT,
        counters          => {%counters},
        last_feed_at      => $last_feed_at,
        websocket_clients => scalar( keys %clients ),
        history_items     => scalar(@history),
        history_bytes     => $history_bytes,
        fanout_items      => scalar(@fanout),
        fanout_bytes      => $fanout_bytes
    };
}

sub client_status($id) {
    my $o  = public_status();
    my $cl = $clients{$id};
    $o->{authenticated} = ( $cl && $cl->{authenticated} ) ? \1 : \0;
    if ( $cl && $cl->{authenticated} ) {
        $o->{call}          = $cl->{call};
        $o->{registered}    = $cl->{registered}    ? \1 : \0;
        $o->{password_used} = $cl->{password_used} ? \1 : \0;
    }
    return $o;
}

sub drop_slow_client($id) {
    my $cl = $clients{$id} or return;
    return if $cl->{closing};

    $cl->{closing} = 1;
    $counters{ws_slow_disconnects}++;

    eval { $cl->{tx}->finish( 1013 => 'slow consumer' ) };
}

sub ws_send_guarded( $id, $json ) {
    my $cl = $clients{$id} or return 0;
    return 0 if $cl->{closing};
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
    if ( $n > $WS_HIGH_WATER ) {
        $counters{ws_dropped}++;
        drop_slow_client($id);
        return 0;
    }
    if ( !$s->can_write || $w + $n > $WS_HIGH_WATER ) {
        $counters{ws_dropped}++;
        drop_slow_client($id);
        return 0;
    }
    my $ok = eval { $tx->send($json); 1 };
    if ( !$ok ) {
        eval { $tx->finish( 1011 => 'send failure' ) };
        return 0;
    }
    $counters{ws_sent}++;
    1;
}

sub client_can_receive_feed( $id, $kind, $targets = undef ) {
    my $cl = $clients{$id} or return 0;
    return 1                     unless ref($targets) eq 'ARRAY';
    return !$cl->{authenticated} unless @$targets;
    return 0                     unless $cl->{authenticated};
    my $call = uc( $cl->{call} // '' );
    return scalar grep { uc( $_ // '' ) eq $call } @$targets;
}

sub pump_fanout {
    $fanout_scheduled = 0;
    my $b = $FANOUT_BATCH;
    while ( $b-- > 0 && @fanout ) {
        my $e = shift @fanout;
        my ( $kind, $j, $n, $targets ) = @$e;
        $fanout_bytes -= $n;
        for my $id ( keys %clients ) {
            next unless client_can_receive_feed( $id, $kind, $targets );
            ws_send_guarded( $id, $j );
        }
    }
    if ( @fanout && !$fanout_scheduled ) {
        $fanout_scheduled = 1;
        Mojo::IOLoop->next_tick( \&pump_fanout );
    }
}

sub queue_fanout( $kind, $j, $targets = undef ) {
    return 1 unless keys %clients;
    my $n = length $j;
    if (   @fanout >= $MAX_FANOUT_ITEMS
        || $fanout_bytes + $n > $MAX_FANOUT_BYTES )
    {
        $counters{fanout_dropped}++;
        return 0;
    }
    push @fanout, [ $kind, $j, $n, $targets ];
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
    queue_fanout( $kind, $j, $targets );
}
sub send_line($l) { return unless $stream; $stream->write( $l . "\n" ) }

sub send_dxs($o) {
    return unless $state{web_call};
    send_line( 'I' . $state{web_call} . '|' . encode_json($o) );
}

sub has_pending_action( $cid, $action ) {
    for my $p ( values %pending ) {
        return 1
          if defined( $p->{client} )
          && $p->{client} == $cid
          && ( $p->{action} // '' ) eq $action;
    }
    return 0;
}

# Count only browser-originated work. Internal feed configuration and
# presence-release messages must never compete for this budget.
sub browser_pending_count($cid) {
    my $count = 0;
    for my $p ( values %pending ) {
        $count++ if defined( $p->{client} ) && $p->{client} == $cid;
    }
    return $count;
}

sub browser_request_allowed($cid) {

    # Internal feed setup uses client 0 and must not consume the browser
    # request budget. Count only live browser-originated requests.
    my $browser_total = 0;
    for my $p ( values %pending ) {
        $browser_total++ if defined( $p->{client} ) && $p->{client} > 0;
    }
    return 0 if $browser_total >= $MAX_PENDING_GLOBAL;
    return browser_pending_count($cid) < $MAX_PENDING_CLIENT;
}

sub dxs_request( $cid, $action, $o ) {
    my $id = $request_id++;
    $o->{id} = $id;
    $pending{$id} = {
        client     => $cid,
        action     => $action,
        created_at => time,
        call       => ( $action eq 'auth' ? $o->{call} : undef )
    };
    send_dxs($o);
    return $id;
}

# Expire only operations that do not change authentication or presence.
# Auth/logout/feed require separate ownership-aware reconciliation; never
# discard those IDs merely because a timer fired.
sub cancel_pending_auth($rid) {
    my $p = delete $pending{$rid} or return;
    return unless ( $p->{action} // '' ) eq 'auth';
    send_dxs(
        {
            type    => 'auth_cancel',
            id      => $request_id++,
            auth_id => 0 + $rid,
            call    => $p->{call}
        }
    ) if $p->{call} && $stream;
}

sub expire_safe_requests() {
    my $now = time;

    # Cancellation is ordered after the original auth on the same DXS stream.
    # Never close the shared technical link to recover one browser session.
    for my $rid ( keys %pending ) {
        my $p = $pending{$rid};
        next unless $p && ( $p->{action} // '' ) eq 'auth';

        # An unanswered login must not hold a browser slot indefinitely.
        if (   $clients{ $p->{client} }
            && $now - ( $p->{created_at} // $now ) >= $REQUEST_TIMEOUT_SEC )
        {
            my $cl = $clients{ $p->{client} };
            eval { $cl->{tx}->finish( 1011 => 'auth timeout' ) } if $cl;
            cancel_pending_auth($rid);
            next;
        }
        next if $clients{ $p->{client} };
        next if $now - ( $p->{created_at} // $now ) < $ORPHAN_AUTH_TIMEOUT_SEC;
        cancel_pending_auth($rid);
    }
    for my $rid ( keys %pending ) {
        my $p = $pending{$rid};
        next unless $p && defined $p->{created_at};
        next if $p->{action} =~ /\A(?:auth|logout|feed)\z/;
        next if $now - $p->{created_at} < $REQUEST_TIMEOUT_SEC;
        delete $pending{$rid};
        my $cid = $p->{client};
        next unless defined $cid && $clients{$cid};
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type => (
                        $p->{action} eq 'profile' ? 'profile_result' : 'error'
                    ),
                    status     => 'error',
                    action     => $p->{action},
                    error      => 'request_timeout',
                    request_id => 0 + $rid
                }
            )
        );
    }
}
Mojo::IOLoop->recurring( 1 => sub { expire_safe_requests() } );

# Snapshot each replay: the live history ring can shift while a client drains.
# The generation invalidates callbacks from an earlier replay (auth/logout).
sub replay_history( $id, $pos = 0 ) {
    my $cl = $clients{$id} or return;
    return if $cl->{closing};
    my $generation = ++$cl->{replay_generation};
    my @snapshot = @history;
    my $last_progress = time;
    my $pump;
    $pump = sub {
        my $current = $clients{$id} or return;
        return if $current->{closing};
        return if ($current->{replay_generation} // 0) != $generation;
        my $tx = $current->{tx};
        my $s = ws_stream($tx);
        return unless $tx && $tx->is_websocket && $s;
        my $sent = 0;
        while ($pos < @snapshot && $sent < $REPLAY_BATCH) {
            my $entry = $snapshot[$pos];
            my $kind = $entry->[0]{feed} // '';
            my $targets = $entry->[0]{_targets};
            unless (client_can_receive_feed($id, $kind, $targets)) {
                $pos++;
                next;
            }
            my $n = length($entry->[1]);
            # Oversized messages are a genuine violation of the WS budget.
            if ($n > $WS_HIGH_WATER) {
                $counters{ws_dropped}++;
                drop_slow_client($id);
                return;
            }
            my $waiting = $s->bytes_waiting;
            if (!$s->can_write || $waiting + $n > $REPLAY_BUFFER_LIMIT) {
                if (time - $last_progress >= $REPLAY_STALL_SEC) {
                    $counters{replay_stalls}++;
                    $counters{ws_dropped}++;
                    drop_slow_client($id);
                    return;
                }
                $counters{replay_pauses}++;
                Mojo::IOLoop->timer($REPLAY_POLL_SEC => $pump);
                return;
            }
            return unless ws_send_guarded($id, $entry->[1]);
            $pos++;
            $sent++;
            $last_progress = time;
        }
        if ($pos < @snapshot) {
            Mojo::IOLoop->next_tick($pump);
        } else {
            $counters{replay_completed}++;
        }
    };
    Mojo::IOLoop->next_tick($pump);
    weaken($pump);  # scheduled callbacks own the pump; no self-reference leak
}

sub handle_response($msg) {
    my $id  = $msg->{id};
    my $p   = delete $pending{$id} or return;
    my $cid = $p->{client};
    my $cl  = $clients{$cid};
    if (   !$cl
        && ( $p->{action}   // '' ) eq 'auth'
        && ( $msg->{status} // '' ) eq 'ok'
        && defined( $msg->{generation} )
        && defined( $msg->{call} ) )
    {
        send_dxs(
            {
                type       => 'user_del',
                id         => $request_id++,
                call       => $msg->{call},
                generation => $msg->{generation}
            }
        );
        return;
    }
    return unless $cl;
    if ( $p->{action} eq 'auth' ) {
        if ( ( $msg->{status} // '' ) eq 'ok' ) {
            $cl->{authenticated} = 1;
            $cl->{call}          = $msg->{call};
            $cl->{generation}    = $msg->{generation};
            $cl->{registered}    = $msg->{registered}    ? 1 : 0;
            $cl->{password_used} = $msg->{password_used} ? 1 : 0;
            $counters{auth_ok}++;
            ws_send_guarded(
                $cid,
                encode_json(
                    {
                        type          => 'auth',
                        status        => 'ok',
                        call          => $msg->{call},
                        priv          => 0 + ( $msg->{priv} // 0 ),
                        registered    => $msg->{registered}    ? \1 : \0,
                        password_used => $msg->{password_used} ? \1 : \0
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
    if ( $p->{action} eq 'profile' ) {
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type         => 'profile_result',
                    status       => $msg->{status} // 'error',
                    error        => $msg->{error},
                    action       => $msg->{action},
                    fields       => $msg->{fields},
                    password_set => $msg->{password_set},
                    call         => $msg->{call}
                }
            )
        );
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
        Mojo::IOLoop->next_tick( sub { replay_history( $cid, 0 ) } ) if $ok;
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
    if ( $p->{action} eq 'reg_request' ) {
        ws_send_guarded(
            $cid,
            encode_json(
                {
                    type     => 'reg_request_result',
                    status   => $msg->{status} // 'error',
                    messages => $msg->{messages} || [],
                    error    => $msg->{error},
                    result   => $msg->{result}
                }
            )
        );
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
                        role    => 'dxweb',
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
                && ( $m->{role} // '' ) eq 'dxweb'
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
                delete $pending{ $m->{id} };
                set_state(
                    ( $m->{status} // '' ) eq 'ok' ? 'ready' : 'feed_error',
                    $m->{error} );
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
                    $stream  = undef;
                    $buffer  = '';
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
hook before_server_start => sub( $server, $app ) {
    Mojo::IOLoop->next_tick( sub { connect_dxs() } );
};
# Capture the running release once, rather than rereading it after deployment.
my $DXWEB_RUNNING_VERSION = do {
    my $file = app->home->rel_file('VERSION');
    open my $fh, '<', $file or die "Cannot read $file: $!";
    my $v = <$fh> // die "Empty $file";
    close $fh;
    $v =~ s/\s+\z//;
    $v =~ /\A\d+(?:\.\d+)+\z/ or die "Invalid version in $file";
    $v;
};
get '/software-version.json' => sub($c) {
    $c->res->headers->cache_control('no-store');
    $c->render(json => { running => $DXWEB_RUNNING_VERSION });
};
get '/' => sub($c) {
    my $path = app->home->rel_file('public/index.html');
    open my $fh, '<:raw', $path or return $c->reply->not_found;
    local $/;
    my $html = <$fh>;
    close $fh;
    # Render the release of the running process, never a hard-coded HTML version.
    $html =~ s{(DXSpider Web v)\d+(?:\.\d+)+}{$1 . $DXWEB_RUNNING_VERSION}ge;
    $html =~
      s{(\b(?:src|href)=["'](?:\./|/)?(?:app\.js|style\.css)\?v=)[^"']+}{$1 . $DXWEB_RUNNING_VERSION}ge;
    $c->res->headers->cache_control('no-cache, must-revalidate');
    $c->res->headers->header( 'Pragma' => 'no-cache' );
    $c->render( data => $html, format => 'html' );
};
get '/healthz' => sub($c) {
    $c->render(
        status => $state{state} eq 'ready' ? 200 : 503,
        json   => public_status()
    );
};
any [qw(POST PUT PATCH DELETE)] => '/*whatever' => sub($c) {
    $c->render( status => 405, json => { error => 'websocket_api_only' } );
};

# Browser WebSocket handshake: reject cross-origin requests before allocating
# a client slot. Nginx forwards the original Host header to Mojolicious.
# Compare scheme, hostname and port, not suffixes or substring matches.
sub websocket_origin_allowed($c) {
    my $origin = $c->req->headers->origin // '';
    return 0 if !$origin || $origin eq 'null';
    return 0 if $origin =~ /[\s,]/;
    my $url = Mojo::URL->new($origin);
    return 0 unless $url->scheme && $url->host;
    return 0
      if $url->userinfo
      || $url->path->to_string ne ''
      || defined( $url->query ) && $url->query->to_string ne ''
      || defined( $url->fragment );
    my $host = $c->req->headers->host // '';
    return 0 unless $host;
    my $expected_scheme = $c->req->is_secure ? 'https' : 'http';

    # Only the trusted local reverse proxy may supply X-Forwarded-Proto.
    my $remote = $c->tx->remote_address // '';
    if ( $remote eq '127.0.0.1' || $remote eq '::1' ) {
        my $forwarded = $c->req->headers->header('X-Forwarded-Proto') // '';
        $expected_scheme = lc($forwarded) if $forwarded =~ /\Ahttps?\z/i;
    }
    return 0 unless lc( $url->scheme ) eq $expected_scheme;
    my $authority = lc( $url->host );
    $authority = "[$authority]" if $authority =~ /:/;
    $authority .= ':' . $url->port if defined $url->port;

    # Explicit default ports are equivalent to their implicit form.
    my $expected = lc($host);
    $authority =~ s/:443\z// if $expected_scheme eq 'https';
    $authority =~ s/:80\z//  if $expected_scheme eq 'http';
    $expected  =~ s/:443\z// if $expected_scheme eq 'https';
    $expected  =~ s/:80\z//  if $expected_scheme eq 'http';
    return $authority eq $expected;
}

# Only Nginx on loopback may supply the browser address. Never trust
# X-Forwarded-For from an arbitrary WebSocket client (or its first hop).
sub websocket_client_ip($c) {
    my $remote = $c->tx->remote_address // '';
    $remote =~ s/^::ffff://i;
    if ( $remote eq '127.0.0.1' || $remote eq '::1' ) {
        my $real = $c->req->headers->header('X-Real-IP') // '';
        if (
               $real
            && $real !~ /[\s,]/
            && (   defined inet_pton( AF_INET, $real )
                || defined inet_pton( AF_INET6, $real ) )
          )
        {
            return $real;
        }
    }
    return $remote;
}

websocket '/ws' => sub($c) {
    unless ( websocket_origin_allowed($c) ) {
        $c->render( status => 403, text => 'WebSocket origin forbidden' );
        return;
    }

    if ( scalar( keys %clients ) >= $MAX_WS_CLIENTS ) {
        $c->finish( 1013 => 'client limit' );
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
    $s->high_water_mark($WS_HIGH_WATER);
    my $ip = websocket_client_ip($c);
    $ip =~ s/^::ffff://i;
    $clients{$id} = { tx => $tx, ip => $ip, authenticated => 0 };
    $c->inactivity_timeout($WS_IDLE_TIMEOUT_SEC);
    ws_send_guarded( $id, encode_json( client_status($id) ) );
    Mojo::IOLoop->next_tick( sub { replay_history( $id, 0 ) } );
    $c->on(
        message => sub( $c, $raw ) {
            if ( length($raw) > $MAX_WS_MSG_BYTES ) {
                $c->finish( 1009 => 'message too large' );
                return;
            }
            my $m;
            eval { $m = decode_json $raw };
            return if $@ || ref $m ne 'HASH';
            my $t = lc( $m->{type} // '' );
            if ( $t eq 'auth' ) {
                unless ( browser_request_allowed($id) ) {
                    $c->finish( 1013 => 'too many pending requests' );
                    return;
                }
                return unless $state{state} eq 'ready';
                return if $clients{$id}{authenticated};

                # Only one in-flight authentication per browser connection.
                # Reuse the authoritative pending-request registry; a separate
                # flag could become stale after disconnect or DXS reconnect.
                return if has_pending_action( $id, 'auth' );
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
            if ( $t eq 'reg_request' ) {
                unless ( browser_request_allowed($id) ) {
                    $c->finish( 1013 => 'too many pending requests' );
                    return;
                }
                return unless $state{state} eq 'ready';
                my $call    = $m->{call}    // '';
                my $email   = $m->{email}   // '';
                my $name    = $m->{name}    // '';
                my $comment = $m->{comment} // '';
                my $ssids   = ref( $m->{ssids} ) eq 'ARRAY' ? $m->{ssids} : [];
                dxs_request(
                    $id,
                    'reg_request',
                    {
                        type     => 'reg_request',
                        call     => $call,
                        email    => $email,
                        name     => $name,
                        comment  => $comment,
                        ssids    => $ssids,
                        language => $m->{language} // 'EN',
                        ip       => $clients{$id}{ip}
                    }
                );
                return;
            }
            if ( $t eq 'logout' ) {
                return unless $clients{$id}{authenticated};
                return if has_pending_action( $id, 'logout' );
                dxs_request(
                    $id, 'logout',
                    {
                        type       => 'user_del',
                        call       => $clients{$id}{call},
                        generation => $clients{$id}{generation}
                    }
                );
                return;
            }
            return unless $clients{$id}{authenticated};

           # Do not issue new user operations while ownership is being released.
            return if has_pending_action( $id, 'logout' );
            if ( $t eq 'command' ) {
                unless ( browser_request_allowed($id) ) {
                    $c->finish( 1013 => 'too many pending requests' );
                    return;
                }
                my $cmd = $m->{command} // '';
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
            if ( $t eq 'profile' ) {
                unless ( browser_request_allowed($id) ) {
                    $c->finish( 1013 => 'too many pending requests' );
                    return;
                }
                if ( has_pending_action( $id, 'profile' ) ) {
                    ws_send_guarded(
                        $id,
                        encode_json(
                            {
                                type   => 'profile_result',
                                status => 'error',
                                action => ( $m->{action} // 'get' ),
                                error  => 'profile_request_pending'
                            }
                        )
                    );
                    return;
                }
                my $action = $m->{action} // 'get';
                unless ( $action =~ /\A(?:get|save|password)\z/ ) {
                    ws_send_guarded(
                        $id,
                        encode_json(
                            {
                                type   => 'profile_result',
                                status => 'error',
                                action => $action,
                                error  => 'invalid_action'
                            }
                        )
                    );
                    return;
                }
                dxs_request(
                    $id,
                    'profile',
                    {
                        type             => 'profile',
                        call             => $clients{$id}{call},
                        action           => $action,
                        fields           => $m->{fields},
                        current_password => $m->{current_password},
                        new_password     => $m->{new_password}
                    }
                );
                return;
            }
            if ( $t eq 'spot' ) {
                unless ( browser_request_allowed($id) ) {
                    $c->finish( 1013 => 'too many pending requests' );
                    return;
                }
                my $freq    = $m->{freq}    // '';
                my $dxcall  = $m->{dxcall}  // '';
                my $comment = $m->{comment} // '';
                dxs_request(
                    $id, 'spot',
                    {
                        type    => 'spot',
                        call    => $clients{$id}{call},
                        freq    => $freq,
                        dxcall  => $dxcall,
                        comment => $comment
                    }
                );
                return;
            }
            if ( $t eq 'ann' ) {
                unless ( browser_request_allowed($id) ) {
                    $c->finish( 1013 => 'too many pending requests' );
                    return;
                }
                my $text  = $m->{text}  // '';
                my $scope = $m->{scope} // 'local';
                dxs_request(
                    $id, 'ann',
                    {
                        type  => 'ann',
                        call  => $clients{$id}{call},
                        text  => $text,
                        scope => $scope
                    }
                );
                return;
            }
        }
    );
    $c->on(
        finish => sub {
            my $cl = delete $clients{$id};
            if ( $cl && $cl->{authenticated} && $state{state} eq 'ready' ) {
                send_dxs(
                    {
                        type       => 'user_del',
                        id         => $request_id++,
                        call       => $cl->{call},
                        generation => $cl->{generation}
                    }
                );
            }
            for my $rid ( keys %pending ) {
                next unless $pending{$rid}{client} == $id;
                if ( ( $pending{$rid}{action} // '' ) eq 'auth' ) {
                    cancel_pending_auth($rid);
                }
                else {
                    delete $pending{$rid};
                }
            }
        }
    );
};

# Default standalone listener; explicit Mojolicious arguments take precedence.
if ( !@ARGV ) {
    my $host = $ENV{DXWEB_HOST} // '127.0.0.1';
    my $port = $ENV{DXWEB_PORT} // 7380;
    app->start( 'daemon', '-l', "http://$host:$port" );
}
else {
    app->start;
}
