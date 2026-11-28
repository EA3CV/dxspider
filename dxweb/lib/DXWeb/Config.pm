package DXWeb::Config;

# Configuration schema, file loading and validation for DXWeb and DXWeb Admin.
#
# Precedence (highest first):
#   1. environment variables
#   2. local_data/dxweb.conf (flat JSON object keyed by variable name)
#   3. defaults in this module
#
# The file is optional. Existing systemd units that only set Environment=
# variables keep working unchanged.

use strict;
use warnings;

use Exporter 'import';
use File::Basename ();
use File::Spec ();
use File::Temp ();
use JSON::PP ();

our @EXPORT_OK = qw(schema defaults load_file effective validate report
  apply_env config_path save_file check_value);

my %SCHEMA = (
    DXS_HOST => { type => 'host', default => '127.0.0.1' },
    DXS_PORT => { type => 'port', default => 27754 },

    HTTP_HOST => { type => 'host', default => '0.0.0.0' },
    HTTP_PORT => { type => 'port', default => 7380 },

    DXWEB_HOST => { type => 'host', default => '0.0.0.0' },
    DXWEB_PORT => { type => 'port', default => 7381 },

    DXWEB_CLIENT_HOST   => { type => 'host',   default => '127.0.0.1' },
    DXWEB_CLIENT_PORT   => { type => 'port',   default => 7380 },
    DXWEB_CLIENT_SCHEME => { type => 'scheme', default => 'http' },

    DXWEB_SCHEME => { type => 'scheme', default => 'http' },
    MOJO_REVERSE_PROXY => { type => 'bool', default => 0 },

    DXSPIDER_ROOT => { type => 'dir', default => '/spider' },

    DXWEB_TLS_CERT => { type => 'file', default => '' },
    DXWEB_TLS_KEY  => { type => 'file', default => '' },

    DXWEB_TURNSTILE_CONFIG => { type => 'file', default => '' },

    DXWEB_HISTORY_DB           => { type => 'path', default => '' },
    DXWEB_HISTORY_INTERVAL_SEC => { type => 'int',  default => 30 },

    DXWEB_WS_PER_IP_LIMIT   => { type => 'int', default => 12 },
    DXWEB_WS_UNVERIFIED_SEC => { type => 'int', default => 90 },
    DXWEB_WS_AUTH_PER_MIN   => { type => 'int', default => 12 },

    MAX_WS_CLIENTS    => { type => 'int', default => 2000 },
    MAX_WS_MSG_BYTES  => { type => 'int', default => 65536 },
    MAX_CLIENTS       => { type => 'int', default => 64 },
    MAX_WS_MESSAGE_BYTES      => { type => 'int', default => 524288 },
    MAX_BROWSER_MESSAGE_BYTES => { type => 'int', default => 65536 },
    MAX_PENDING_TOTAL         => { type => 'int', default => 256 },
    MAX_PENDING_PER_CLIENT    => { type => 'int', default => 16 },
    RECONNECT_SEC     => { type => 'int', default => 3 },
    REQUEST_TIMEOUT_SEC => { type => 'int', default => 30 },
);

sub schema { return \%SCHEMA }

sub defaults {
    my %d;
    for my $k ( keys %SCHEMA ) {
        $d{$k} = $SCHEMA{$k}{default};
    }
    return \%d;
}

sub config_path {
    my ($explicit) = @_;
    return $explicit if defined $explicit && length $explicit;

    return $ENV{DXWEB_CONFIG}
      if defined $ENV{DXWEB_CONFIG} && length $ENV{DXWEB_CONFIG};

    my $root =
         ( defined $ENV{DXSPIDER_ROOT} && length $ENV{DXSPIDER_ROOT} )
      ? $ENV{DXSPIDER_ROOT}
      : '/spider';
    return File::Spec->catfile( $root, 'local_data', 'dxweb.conf' );
}

sub load_file {
    my ($path) = @_;
    $path = config_path($path);
    return {} unless defined $path && length $path && -e $path;

    open my $fh, '<:raw', $path
      or die "Cannot read configuration $path: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $data = eval { JSON::PP->new->decode($raw) };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+\z//;
        die "Invalid JSON in $path: $err\n";
    }
    die "Configuration $path must contain a JSON object\n"
      unless ref $data eq 'HASH';

    return $data;
}

sub effective {
    my (%opt) = @_;
    my $file = load_file( $opt{path} );
    my $out  = defaults();
    my @unknown;

    for my $k ( sort keys %$file ) {
        if ( exists $SCHEMA{$k} ) {
            $out->{$k} = $file->{$k};
        }
        else {
            push @unknown, $k;
        }
    }

    for my $k ( keys %SCHEMA ) {
        next unless defined $ENV{$k} && length $ENV{$k};
        $out->{$k} = $ENV{$k};
    }

    $out->{_unknown}     = \@unknown;
    $out->{_config_file} = defined $opt{path} ? $opt{path} : config_path();
    $out->{_file_exists} =
      ( $out->{_config_file} && -e $out->{_config_file} ) ? 1 : 0;
    return $out;
}

sub _is_int {
    my ($v) = @_;
    return 0 unless defined $v && !ref $v;
    return $v =~ /\A-?\d+\z/ ? 1 : 0;
}

sub _same_host {
    my ( $a, $b ) = @_;
    return 0 unless defined $a && defined $b;
    $a = lc $a;
    $b = lc $b;
    return 1 if $a eq $b;
    return 1
      if ( $a eq '::1' || $a eq '::' )
      && ( $b eq '::1' || $b eq '::' )
      && $a eq $b;
    return 0;
}

sub validate {
    my ($cfg) = @_;
    $cfg ||= effective();
    my @errors;
    my @warnings;

    my %seen;
    for my $k ( @{ $cfg->{_unknown} || [] } ) {
        next if $seen{$k}++;
        push @warnings, "unknown configuration key '$k' (ignored)";
    }

    for my $k ( sort keys %SCHEMA ) {
        my $v  = $cfg->{$k};
        my $t  = $SCHEMA{$k}{type};
        my $ok = 1;

        if ( $t eq 'port' ) {
            $ok = _is_int($v) && $v >= 1 && $v <= 65535;
            push @errors, "$k must be an integer between 1 and 65535"
              unless $ok;
        }
        elsif ( $t eq 'int' ) {
            $ok = _is_int($v) && $v >= 0;
            push @errors, "$k must be a non-negative integer" unless $ok;
        }
        elsif ( $t eq 'bool' ) {
            $ok = defined $v && $v =~ /\A(?:0|1|true|false|yes|no|on|off)\z/i;
            push @errors, "$k must be 0 or 1" unless $ok;
        }
        elsif ( $t eq 'scheme' ) {
            $ok = defined $v && $v =~ /\A(?:http|https)\z/i;
            push @errors, "$k must be http or https" unless $ok;
        }
        elsif ( $t eq 'host' ) {
            $ok = defined $v && !ref $v && length $v && $v !~ /\s/;
            push @errors, "$k must be a host name or address" unless $ok;
        }
        elsif ( $t eq 'dir' ) {
            $ok = defined $v && length $v && -d $v;
            push @errors, "$k points to a missing directory: " . ( $v // '' )
              unless $ok;
        }
        elsif ( $t eq 'file' ) {
            next unless defined $v && length $v;
            $ok = -f $v && -r $v;
            push @errors, "$k is not a readable file: $v" unless $ok;
        }
        elsif ( $t eq 'path' ) {
            next unless defined $v && length $v;
            my $parent = File::Basename::dirname($v);
            push @warnings, "$k directory does not exist: $parent"
              unless -d $parent;
        }
    }

    if ( _is_int( $cfg->{HTTP_PORT} ) && _is_int( $cfg->{DXWEB_PORT} )
        && $cfg->{HTTP_PORT} == $cfg->{DXWEB_PORT}
        && _same_host( $cfg->{HTTP_HOST}, $cfg->{DXWEB_HOST} ) )
    {
        push @errors,
          "HTTP_PORT and DXWEB_PORT are the same on the same host; DXWeb and DXWeb Admin cannot share a port";
    }

    my $tls = lc( $cfg->{DXWEB_SCHEME} // 'http' ) eq 'https';
    my $proxy = $cfg->{MOJO_REVERSE_PROXY}
      && $cfg->{MOJO_REVERSE_PROXY} =~ /\A(?:1|true|yes|on)\z/i;
    if ($tls && !$proxy) {
        for my $k (qw(DXWEB_TLS_CERT DXWEB_TLS_KEY)) {
            my $v = $cfg->{$k};
            if ( !defined $v || !length $v ) {
                push @errors, "$k is required when DXWEB_SCHEME is https";
            }
        }
    }

    if ( defined $cfg->{DXSPIDER_ROOT} && -d $cfg->{DXSPIDER_ROOT} ) {
        my $cluster = File::Spec->catfile( $cfg->{DXSPIDER_ROOT}, 'perl',
            'cluster.pl' );
        push @warnings, "DXSPIDER_ROOT does not contain perl/cluster.pl: $cfg->{DXSPIDER_ROOT}"
          unless -f $cluster;
    }

    if (   _same_host( $cfg->{HTTP_HOST}, $cfg->{DXWEB_CLIENT_HOST} )
        && _is_int( $cfg->{HTTP_PORT} )
        && _is_int( $cfg->{DXWEB_CLIENT_PORT} )
        && $cfg->{HTTP_PORT} != $cfg->{DXWEB_CLIENT_PORT} )
    {
        push @warnings,
          "DXWEB_CLIENT_PORT ($cfg->{DXWEB_CLIENT_PORT}) differs from HTTP_PORT ($cfg->{HTTP_PORT}); check the Admin to DXWeb link";
    }

    return ( \@errors, \@warnings );
}

sub report {
    my (%opt) = @_;
    my $cfg = effective(%opt);
    my ( $errors, $warnings ) = validate($cfg);
    return ( $cfg, $errors, $warnings );
}

sub check_value {
    my ( $key, $value ) = @_;
    return "Unknown configuration key '$key'"
      unless defined $key && exists $SCHEMA{$key};
    return "Empty value for $key"
      unless defined $value && length $value;

    my $cand = defaults();
    $cand->{$key} = $value;
    my ($errors) = validate($cand);
    for my $e ( @$errors ) {
        return $e if $e =~ /^\Q$key\E\b/;
    }
    return;
}

sub save_file {
    my ( $path, $data ) = @_;
    $path = config_path($path);
    die "Refusing to write an empty configuration path\n"
      unless defined $path && length $path;
    die "save_file requires a hash reference\n" unless ref $data eq 'HASH';

    my $dir = File::Basename::dirname($path);
    die "Configuration directory does not exist: $dir\n" unless -d $dir;
    die "Configuration directory is not writable: $dir\n" unless -w $dir;

    my $json = JSON::PP->new->canonical(1)->pretty(1)->encode($data);
    my ( $fh, $tmp ) =
      File::Temp::tempfile( '.dxweb-conf-XXXXXX', DIR => $dir, UNLINK => 0 );
    die "Cannot create temporary configuration in $dir: $!\n" unless $fh;
    print {$fh} $json or die "Cannot write $tmp: $!\n";
    close $fh or die "Cannot close $tmp: $!\n";
    chmod 0640, $tmp or die "Cannot set permissions on $tmp: $!\n";
    rename $tmp, $path or die "Cannot replace $path: $!\n";
    return $path;
}

# Apply the resolved configuration to the process environment without
# overriding values that are already set. Returns the config hash.
sub apply_env {
    my (%opt) = @_;
    my $cfg = effective(%opt);
    my %no_env = map { $_ => 1 } qw(DXSPIDER_ROOT);
    for my $k ( sort keys %SCHEMA ) {
        next if $no_env{$k};
        next if defined $ENV{$k} && length $ENV{$k};
        my $v = $cfg->{$k};
        next unless defined $v && length $v;
        $ENV{$k} = "$v";
    }
    return $cfg;
}

1;
