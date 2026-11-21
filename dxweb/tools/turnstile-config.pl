#!/usr/bin/env perl

#
# DXSpider Web - Maintenance or test tool
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

use strict;
use warnings;
use Getopt::Long   qw(GetOptions);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use File::Temp     qw(tempfile);
use JSON::PP       qw(encode_json decode_json);
use Fcntl          qw(:flock);

my ( $status, $configure, $enable, $disable, $path, $site, $secret );
$path = $ENV{DXWEB_TURNSTILE_CONFIG} // '/etc/dxweb/turnstile.json';
GetOptions(
    'status'    => \$status,
    'configure' => \$configure,
    'enable'    => \$enable,
    'disable'   => \$disable,
    'path=s'    => \$path
) or die "Invalid options\n";
die "Choose --status or --configure\n"
  unless ( $status ? 1 : 0 ) +
  ( $configure ? 1 : 0 ) +
  ( $enable    ? 1 : 0 ) +
  ( $disable   ? 1 : 0 ) == 1;
die "Unsafe configuration path\n"
  unless $path =~ m{\A/[A-Za-z0-9_./-]+\z} && $path !~ m{(?:\A|/)\.\.?(/|\z)};

sub safe_read {
    return undef unless -e $path;
    die "Symlink configuration rejected\n" if -l $path;
    my @st = stat($path);
    die "Not a regular file\n" unless -f _;
    die "Insecure permissions on configuration\n" if $st[2] & 0077;
    open my $f, '<', $path or die "Open: $!\n";
    local $/;
    my $raw = <$f>;
    close $f;
    my $data = decode_json($raw);
    die "Invalid config\n" unless ref($data) eq 'HASH';
    return $data;
}
if ($status) {
    my $d = safe_read();
    print $d
      ? "Turnstile credentials: CONFIGURED\n"
      : "Turnstile credentials: NOT CONFIGURED\n";
    print "CAPTCHA protection: ",
      ( $d && $d->{enabled}
        ? "ENABLED (server restart required if code just installed)"
        : "DISABLED" ), "\n";
    exit 0;
}
die "Configuration requires root\n"
  unless $> == 0 || $ENV{DXWEB_TURNSTILE_TEST_MODE};
my $dir = dirname($path);
die "Symlink directory rejected\n" if -l $dir;
if ( !-d $dir ) {
    make_path( $dir, { mode => 0700 } ) or die "Create directory: $!\n";
}
die "Unsafe directory\n" unless -d $dir && !-l $dir;
my $old = safe_read();
if ( $enable || $disable ) {
    die "Configure keys first\n"
      if $enable && ( !$old || !$old->{site_key} || !$old->{secret_key} );
    my $data = $old || { version => 1 };
    $data->{enabled} = $enable ? JSON::PP::true : JSON::PP::false;
    my ( $f, $tmp ) = tempfile( '.turnstile-XXXXXX', DIR => $dir, UNLINK => 0 );
    chmod 0600, $tmp or die "chmod: $!\n";
    print {$f} encode_json($data), "\n" or die "Write: $!\n";
    close $f or die "Close: $!\n";
    rename $tmp, $path or die "Rename: $!\n";
    print "Turnstile ", ( $enable ? 'ENABLED' : 'DISABLED' ), ".\n";
    exit 0;
}
print "Site Key: ";
chomp( $site = <STDIN> // die "No input\n" );
print "Secret Key (hidden): ";
my $tty = -t STDIN;
system( 'stty', '-echo' ) == 0 or die "Cannot hide secret input\n" if $tty;
my $line = <STDIN>;
system( 'stty', 'echo' ) if $tty;
print "\n"               if $tty;
die "No secret input\n" unless defined $line;
chomp( $secret = $line );
die "Invalid Site Key\n"   unless $site   =~ /\A[A-Za-z0-9_-]{8,256}\z/;
die "Invalid Secret Key\n" unless $secret =~ /\A[A-Za-z0-9_-]{8,256}\z/;
my $data = {
    site_key   => $site,
    secret_key => $secret,
    enabled    => JSON::PP::false,
    version    => 1
};
my ( $f, $tmp ) = tempfile( '.turnstile-XXXXXX', DIR => $dir, UNLINK => 0 );
chmod 0600, $tmp or die "chmod: $!\n";
print {$f} encode_json($data), "\n" or die "Write: $!\n";
close $f or die "Close: $!\n";
if ( -e $path ) { die "Symlink target rejected\n" if -l $path; }
rename $tmp, $path or die "Rename: $!\n";
print "Keys stored; CAPTCHA DISABLED until explicitly enabled.\n";
