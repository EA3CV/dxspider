#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use File::Spec;

$ENV{DXS_HOST}           //= '127.0.0.1';
$ENV{DXS_PORT}           //= '27754';
$ENV{HTTP_HOST}          //= '0.0.0.0';
$ENV{HTTP_PORT}          //= '7380';
$ENV{MOJO_REVERSE_PROXY} //= '0';
$ENV{DXWEB_SCHEME}       //= 'http';
if ($ENV{DXWEB_SCHEME} eq 'https') {
    die "DXWEB_TLS_CERT and DXWEB_TLS_KEY required for HTTPS\n"
        unless $ENV{DXWEB_TLS_CERT} && $ENV{DXWEB_TLS_KEY};
}


my $app = File::Spec->catfile( $FindBin::Bin, 'app.pl' );
my $listen = "$ENV{DXWEB_SCHEME}://$ENV{HTTP_HOST}:$ENV{HTTP_PORT}";
if ($ENV{DXWEB_SCHEME} eq 'https') {
    $listen .= '?cert=' . $ENV{DXWEB_TLS_CERT} . '&key=' . $ENV{DXWEB_TLS_KEY};
}
exec {$^X} $^X, $app, 'daemon', '-l', $listen;
die "Cannot execute DXWeb: $!";
