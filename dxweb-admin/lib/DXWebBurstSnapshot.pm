package DXWebBurstSnapshot;

use strict;
use warnings;
use utf8;
use Mojo::IOLoop;
use Mojo::JSON     qw(encode_json);
use Time::HiRes    qw(time);
use File::Basename qw(dirname);
use File::Path     qw(make_path);

our $VERSION        = '0.2.2';
our $SCHEMA_VERSION = 2;

sub new {
    my ( $class, %opt ) = @_;
    die 'history required' unless $opt{history};
    return bless {
        history    => $opt{history},
        path       => $opt{path} // ($ENV{DXSPIDER_ROOT} ? "$ENV{DXSPIDER_ROOT}/local_data/dxweb-bursts.json" : undef),
        interval   => 0 + ( $opt{interval} // 30 ),
        window     => $opt{window} // '1h',
        timer      => undef,
        inflight   => 0,
        last_write => undef,
        error      => undef,
        logger     => $opt{logger},
        last_logged_error => undef,
    }, $class;
}

sub _log_event {
    my ($s, $level, $message) = @_;
    return unless ref($s->{logger}) eq 'CODE';
    eval { $s->{logger}->($level, $message) };
}

sub _log_failure_once {
    my ($s, $level, $message) = @_;
    return if defined $s->{last_logged_error} && $s->{last_logged_error} eq $message;
    $s->{last_logged_error} = $message;
    $s->_log_event($level, $message);
}

sub status {
    my ($s) = @_;
    return {
        inflight   => $s->{inflight} ? 1 : 0,
        last_write => $s->{last_write},
        error      => $s->{error},
        path       => $s->{path}
    };
}
sub start { my ($s) = @_; $s->_schedule(1); return $s }

sub stop {
    my ($s) = @_;
    Mojo::IOLoop->remove( $s->{timer} ) if $s->{timer};
    $s->{timer} = undef;
    return $s;
}

sub _schedule {
    my ( $s, $delay ) = @_;
    Mojo::IOLoop->remove( $s->{timer} ) if $s->{timer};
    $s->{timer} =
      Mojo::IOLoop->timer( $delay => sub { $s->{timer} = undef; $s->refresh } );
}

sub refresh {
    my ($s) = @_;
    return $s->_schedule( $s->{interval} ) if $s->{inflight};
    $s->{inflight} = 1;
    $s->{history}->metrics_series_async(
        window => $s->{window},
        cb     => sub {
            my ( $err, $r ) = @_;
            $s->{inflight} = 0;
            if ( $err || ref($r) ne 'HASH' ) {
                $s->{error} = $err || 'invalid_metrics_result';
                $s->_log_failure_once('warn', "burst metrics failed: $s->{error}");
                $s->_schedule( $s->{interval} );
                return;
            }
            my $tr = $r->{traffic_rates} || {};
            my ( @neighbours, @origins );
            for my $x ( @{ $tr->{neighbour_summary} || [] } ) {
                next unless ref($x) eq 'HASH';
                push @neighbours,
                  { map { $_ => $x->{$_} }
                    grep { exists $x->{$_} }
                      qw(neighbour latest_pps baseline_pps baseline_samples deviation_ratio burst dominant_pc peak_pps peak_at peak_dominant_pc)
                  };
                last if @neighbours >= 64;
            }
            for my $x ( @{ $tr->{origin_summary} || [] } ) {
                next unless ref($x) eq 'HASH';
                push @origins,
                  { map { $_ => $x->{$_} }
                    grep { exists $x->{$_} }
                      qw(origin latest_pps baseline_pps baseline_samples deviation_ratio burst dominant_pc peak_pps peak_at peak_dominant_pc)
                  };
                last if @origins >= 64;
            }
            my $o = {
                schema_version   => $SCHEMA_VERSION,
                generated_at     => 0 + time,
                window           => $s->{window},
                origin_available => $tr->{origin_available} ? 1 : 0,
                origins          => \@origins,
                neighbours       => \@neighbours,
                semantics        =>
'precomputed by dxweb-admin from DXWebHistory; logical origin is primary burst dimension; neighbour is independent physical context; no origin-neighbour association is inferred'
            };
            my $ok = eval { $s->_write_atomic($o); 1 };
            if ($ok) {
                $s->{last_write} = $o->{generated_at};
                $s->{error}      = undef;
                $s->{last_logged_error} = undef;
            }
            else { $s->{error} = "$@"; $s->_log_failure_once('error', "burst snapshot write failed: $s->{error}") }
            $s->_schedule( $s->{interval} );
        }
    );
}

sub _write_atomic {
    my ( $s, $o ) = @_;
    my $json = encode_json($o);
    die 'snapshot_too_large' if length($json) > 65536;
    my $path = $s->{path};
    my $dir  = dirname($path);
    make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or die "snapshot_open_failed:$!";
    binmode $fh;
    print {$fh} $json, "\n" or die "snapshot_write_failed:$!";
    close $fh or die "snapshot_close_failed:$!";
    chmod 0644, $tmp or die "snapshot_chmod_failed:$!";
    rename $tmp, $path or die "snapshot_rename_failed:$!";
    return 1;
}
1;
