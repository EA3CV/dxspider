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

my $app = File::Spec->catfile( $FindBin::Bin, 'app.pl' );
exec {$^X} $^X, $app, 'daemon', '-l', "http://$ENV{HTTP_HOST}:$ENV{HTTP_PORT}";
die "Cannot execute DXWeb: $!";
