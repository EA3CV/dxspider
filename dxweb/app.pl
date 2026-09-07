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
my $FEED_HUMAN = exists $ENV{FEED_HUMAN} ? !!$ENV{FEED_HUMAN} : 1;
my $FEED_RBN   = exists $ENV{FEED_RBN}   ? !!$ENV{FEED_RBN}   : 1;
my $RECONNECT  = $ENV{RECONNECT_SEC} // 3;

# All application-owned buffers are bounded. Web data is disposable by design:
# overload must drop web data or a slow browser, never pressure DXSpider.
my $MAX_INPUT_BYTES   = $ENV{MAX_INPUT_BYTES}   // (256 * 1024);
my $MAX_HISTORY       = $ENV{MAX_HISTORY}       // 250;
my $MAX_HISTORY_BYTES = $ENV{MAX_HISTORY_BYTES} // (512 * 1024);
my $MAX_FANOUT_ITEMS  = $ENV{MAX_FANOUT_ITEMS}  // 256;
my $MAX_FANOUT_BYTES  = $ENV{MAX_FANOUT_BYTES}  // (512 * 1024);
my $WS_HIGH_WATER     = $ENV{WS_HIGH_WATER}     // (64 * 1024);
my $REPLAY_BATCH      = $ENV{REPLAY_BATCH}      // 8;
my $FANOUT_BATCH      = $ENV{FANOUT_BATCH}      // 32;

for my $pair (
  [MAX_INPUT_BYTES   => $MAX_INPUT_BYTES],
  [MAX_HISTORY       => $MAX_HISTORY],
  [MAX_HISTORY_BYTES => $MAX_HISTORY_BYTES],
  [MAX_FANOUT_ITEMS  => $MAX_FANOUT_ITEMS],
  [MAX_FANOUT_BYTES  => $MAX_FANOUT_BYTES],
  [WS_HIGH_WATER     => $WS_HIGH_WATER],
  [REPLAY_BATCH      => $REPLAY_BATCH],
  [FANOUT_BATCH      => $FANOUT_BATCH],
) {
  die "$pair->[0] must be a positive integer\n"
    unless defined($pair->[1]) && $pair->[1] =~ /^\d+$/ && $pair->[1] > 0;
}

app->static->paths->[0] = app->home->rel_file('public');
app->secrets(['dxspider-rx-reference-only']);

my %state = (
  state => 'disconnected',
  web_call => undef,
  error => undef,
  connected_since => undef,
);
my @history;             # [object, encoded_json, encoded_bytes]
my $history_bytes = 0;
my @fanout;
my $fanout_bytes = 0;
my $fanout_scheduled = 0;
my %clients;
my $next_client_id = 1;
my $stream;
my $buffer = '';
my $request_id = 1;
my $reconnect_timer;
my %counters = (
  human => 0, rbn => 0, total => 0, reconnects => 0,
  input_overflow => 0,
  fanout_dropped => 0,
  ws_sent => 0, ws_dropped => 0, ws_slow_disconnects => 0,
);
my $last_feed_at;

sub ws_stream ($tx) {
  return unless $tx && $tx->can('connection');
  my $id = $tx->connection;
  return unless defined $id;
  return Mojo::IOLoop->stream($id);
}

sub status_obj {
  return {
    type => 'status',
    %state,
    dxs_host => $DXS_HOST,
    dxs_port => 0 + $DXS_PORT,
    feeds => { human => $FEED_HUMAN ? \1 : \0, rbn => $FEED_RBN ? \1 : \0 },
    counters => { %counters },
    last_feed_at => $last_feed_at,
    websocket_clients => scalar(keys %clients),
    history_items => scalar(@history),
    history_bytes => $history_bytes,
    fanout_items => scalar(@fanout),
    fanout_bytes => $fanout_bytes,
  };
}

sub drop_slow_client ($id) {
  my $tx = delete $clients{$id} or return;
  $counters{ws_slow_disconnects}++;
  eval { $tx->finish(1013 => 'slow consumer') };
}

sub ws_send_guarded ($id, $json) {
  my $tx = $clients{$id};
  return 0 unless $tx && $tx->is_websocket;

  my $s = ws_stream($tx);

  # If the socket cannot be inspected, do not enqueue blindly.
  # Sacrifice the browser, never the DXSpider receive path.
  unless ($s && $s->can('can_write') && $s->can('bytes_waiting')) {
    $counters{ws_dropped}++;
    drop_slow_client($id);
    return 0;
  }

  my $waiting = $s->bytes_waiting;
  my $bytes = length($json);

  if (!$s->can_write || $bytes > $WS_HIGH_WATER ||
      $waiting + $bytes > $WS_HIGH_WATER) {
    $counters{ws_dropped}++;
    drop_slow_client($id);
    return 0;
  }

  my $ok = eval { $tx->send($json); 1 };
  unless ($ok) {
    $counters{ws_dropped}++;
    delete $clients{$id};
    return 0;
  }

  $counters{ws_sent}++;
  return 1;
}

sub pump_fanout {
  $fanout_scheduled = 0;
  my $budget = $FANOUT_BATCH;

  while ($budget-- > 0 && @fanout) {
    my $json = shift @fanout;
    $fanout_bytes -= length($json);
    ws_send_guarded($_, $json) for keys %clients;
  }

  if (@fanout && !$fanout_scheduled) {
    $fanout_scheduled = 1;
    Mojo::IOLoop->next_tick(\&pump_fanout);
  }
}

sub queue_fanout_json ($json) {
  # No browser means no fanout allocations/work. History is separate.
  return 1 unless %clients;

  my $len = length($json);
  if (@fanout >= $MAX_FANOUT_ITEMS || $fanout_bytes + $len > $MAX_FANOUT_BYTES) {
    $counters{fanout_dropped}++;
    return 0;
  }

  push @fanout, $json;
  $fanout_bytes += $len;

  unless ($fanout_scheduled) {
    $fanout_scheduled = 1;
    Mojo::IOLoop->next_tick(\&pump_fanout);
  }
  return 1;
}

sub queue_status {
  return unless %clients;
  queue_fanout_json(encode_json(status_obj()));
}

sub set_state ($name, $error = undef) {
  $state{state} = $name;
  $state{error} = $error;
  $state{web_call} = undef if $name eq 'disconnected' || $name eq 'connecting';
  $state{connected_since} = time if $name eq 'tcp_connected';
  queue_status();
}

sub history_add ($obj, $encoded) {
  my $len = length($encoded);
  push @history, [$obj, $encoded, $len];
  $history_bytes += $len;

  while (@history > $MAX_HISTORY || $history_bytes > $MAX_HISTORY_BYTES) {
    my $old = shift @history;
    $history_bytes -= $old->[2];
  }
}

sub push_feed ($kind, $raw) {
  my $payload = $raw;
  my $decoded;
  eval { $decoded = decode_json($raw) };
  if (!$@ && ref($decoded) eq 'HASH' && exists $decoded->{payload}) {
    $payload = $decoded->{payload};
  }

  $counters{$kind}++ if exists $counters{$kind};
  $counters{total}++;
  $last_feed_at = scalar gmtime() . 'Z';

  my $obj = {
    type => 'feed',
    feed => $kind,
    received_at => scalar gmtime() . 'Z',
    payload => $payload,
    raw => $raw,
    counters => { %counters },
  };
  my $encoded = encode_json($obj);
  history_add($obj, $encoded);
  queue_fanout_json($encoded);
}

sub send_line ($line) {
  return unless $stream;
  $stream->write($line . "\n");
}

sub send_json ($obj) {
  return unless $state{web_call};
  send_line('I' . $state{web_call} . '|' . encode_json($obj));
}

sub handle_line ($line) {
  $line =~ s/\r$//;
  return if $line eq '';

  if (!$state{web_call} && $line =~ /^C(#WEB-\d+)\s*$/) {
    $state{web_call} = $1;
    set_state('wait_prompt');
    return;
  }

  if ($state{web_call} && $line =~ /^D\Q$state{web_call}\E\|(.*)$/s) {
    my $body = $1;
    if ($state{state} eq 'wait_prompt') {
      if ($body =~ /dxspider\s*>\s*$/i) {
        set_state('wait_hello');
        send_json({ type => 'hello', role => 'webcluster', version => 1 });
      }
      return;
    }

    my $msg;
    eval { $msg = decode_json($body) };
    return if $@ || ref($msg) ne 'HASH';

    if (($msg->{type} // '') eq 'spot') {
      push_feed('human', $body);
      return;
    }
    if (($msg->{type} // '') eq 'rbn') {
      push_feed('rbn', $body);
      return;
    }

    if (($msg->{type} // '') eq 'hello' && ($msg->{role} // '') eq 'webcluster') {
      if (($msg->{status} // '') eq 'ok') {
        set_state('configuring_feeds');
        my $id = $request_id++;
        send_json({
          type => 'feed', id => $id,
          human => $FEED_HUMAN ? \1 : \0,
          rbn => $FEED_RBN ? \1 : \0,
          ann => \0,
        });
      } else {
        set_state('hello_error', $msg->{error} // 'hello failed');
      }
      return;
    }

    if (($msg->{type} // '') eq 'response' && (($msg->{op} // $msg->{action} // '') eq 'feed')) {
      if (($msg->{status} // '') eq 'ok') {
        set_state('ready');
      } else {
        set_state('feed_error', $msg->{error} // 'feed configuration failed');
      }
    }
    return;
  }

  # Compatibility with enhanced framing.
  if ($state{web_call} && $line =~ /^X\Q$state{web_call}\E\|(.*)$/s) {
    push_feed('human', $1);
    return;
  }
  if ($state{web_call} && $line =~ /^R\Q$state{web_call}\E\|(.*)$/s) {
    push_feed('rbn', $1);
    return;
  }
}

sub schedule_reconnect;
sub connect_dxs {
  return if $stream;
  set_state('connecting');
  Mojo::IOLoop->client({address => $DXS_HOST, port => $DXS_PORT} => sub ($loop, $err, $s) {
    if ($err) {
      set_state('disconnected', $err);
      schedule_reconnect();
      return;
    }

    $stream = $s;
    $s->timeout(0);
    $buffer = '';
    set_state('tcp_connected');
    send_line('A#WEB|{"role":"webcluster","version":1}');
    set_state('wait_assignment');

    $s->on(read => sub ($this, $bytes) {
      return unless $stream && $this == $stream;
      $buffer .= $bytes;

      # A peer that never terminates a line cannot grow memory indefinitely.
      if (length($buffer) > $MAX_INPUT_BYTES && index($buffer, "\n") < 0) {
        $counters{input_overflow}++;
        $buffer = '';
        $this->close;
        return;
      }

      while (1) {
        my $nl = index($buffer, "\n");
        last if $nl < 0;
        my $line = substr($buffer, 0, $nl, '');
        substr($buffer, 0, 1, '');

        if (length($line) > $MAX_INPUT_BYTES) {
          $counters{input_overflow}++;
          next;
        }
        handle_line($line);
      }
    });

    $s->on(close => sub ($this) {
      return unless $stream && $this == $stream;
      $stream = undef;
      $buffer = '';
      $counters{reconnects}++;
      set_state('disconnected', 'DXSpider connection closed');
      schedule_reconnect();
    });

    $s->on(error => sub ($this, $err) {
      return unless $stream && $this == $stream;
      set_state('transport_error', $err);
      $this->close;
    });
  });
}

sub schedule_reconnect {
  return if $reconnect_timer;
  $reconnect_timer = Mojo::IOLoop->timer($RECONNECT => sub {
    undef $reconnect_timer;
    connect_dxs();
  });
}

sub replay_history ($id, $pos = 0) {
  return unless exists $clients{$id};
  return if $pos > $#history;

  my $end = $pos + $REPLAY_BATCH - 1;
  $end = $#history if $end > $#history;

  for my $i ($pos .. $end) {
    return unless exists $clients{$id};
    return unless ws_send_guarded($id, $history[$i][1]);
  }

  my $next = $end + 1;
  Mojo::IOLoop->next_tick(sub { replay_history($id, $next) })
    if $next <= $#history && exists $clients{$id};
}

hook before_server_start => sub ($server, $app) {
  Mojo::IOLoop->next_tick(sub { connect_dxs() });
};

get '/' => sub ($c) { $c->reply->static('index.html') };

get '/healthz' => sub ($c) {
  my $ok = $state{state} eq 'ready';
  $c->render(status => $ok ? 200 : 503, json => status_obj());
};

any [qw(POST PUT PATCH DELETE)] => '/*whatever' => sub ($c) {
  $c->render(status => 405, json => {error => 'read_only_service'});
};

websocket '/ws' => sub ($c) {
  my $id = $next_client_id++;
  my $tx = $c->tx;
  my $s = ws_stream($tx);

  # If backpressure cannot be inspected/enforced, refuse the browser.
  unless ($s && $s->can('high_water_mark') &&
          $s->can('can_write') && $s->can('bytes_waiting')) {
    $c->finish(1011 => 'backpressure unavailable');
    return;
  }

  $s->high_water_mark($WS_HIGH_WATER);
  $clients{$id} = $tx;
  $c->inactivity_timeout(0);

  ws_send_guarded($id, encode_json(status_obj()));
  Mojo::IOLoop->next_tick(sub { replay_history($id, 0) });

  # Strict RX-only browser surface: incoming WS messages are ignored.
  $c->on(message => sub ($c, $msg) { });
  $c->on(finish => sub { delete $clients{$id} });
};

app->start;
