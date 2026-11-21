#!/usr/bin/env perl

#
# DXSpider Web - Maintenance or test tool
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

my $menu    = "$FindBin::Bin/../dxweb-menu.pl";
my $manager = "$FindBin::Bin/../dxweb-manager.pl";
ok( -f $menu,    'menu exists' );
ok( -f $manager, 'existing manager exists' );
is( system( $^X, '-c', $menu ),    0, 'menu syntax' );
is( system( $^X, '-c', $manager ), 0, 'manager syntax' );
my $tmp  = tempdir( CLEANUP => 1 );
my $mock = "$tmp/mock-manager.pl";
open my $m, '>', $mock or die $!;
print {$m}
'use strict; use warnings; open my $f, ">>", $ENV{DXWEB_MENU_LOG} or die $!; print $f join(" ",@ARGV),"\n"; close $f; exit(($ENV{DXWEB_MENU_FAIL_PLAN} && scalar(grep { $_ eq "plan" } @ARGV)) ? 1 : 0);';
close $m;
my $log = "$tmp/calls.log";

sub scenario {
    my ( $input, $fail ) = @_;
    unlink $log;
    local %ENV = %ENV;
    $ENV{DXWEB_MENU_MANAGER}   = $mock;
    $ENV{DXWEB_MENU_ROOT}      = $tmp;
    $ENV{DXWEB_MENU_LOG}       = $log;
    $ENV{DXWEB_MENU_FAIL_PLAN} = $fail ? 1 : 0;
    open my $in, '>', "$tmp/input" or die $!;
    print {$in} $input;
    close $in;
    my $rc = system("$^X '$menu' < '$tmp/input' > '$tmp/output' 2>&1");
    open my $out, '<', "$tmp/output" or die $!;
    local $/;
    my $display = <$out>;
    close $out;
    my $calls = '';

    if ( -f $log ) {
        open my $l, '<', $log or die $!;
        $calls = <$l> // '';
        local $/;
        $calls .= <$l> // '';
        close $l;
    }
    return ( $rc, $display, $calls );
}
my ( $rc, $out, $calls ) = scenario( "6\n", 0 );
is( $rc, 0, 'exit succeeds' );
like( $out, qr/Bye\./, 'exit message' );
is( $calls, '', 'exit does not invoke manager' );
( $rc, $out, $calls ) = scenario( "2\n1\n3\n6\n", 0 );
like( $calls, qr/--components admin/, 'admin independently selected' );
unlike( $calls, qr/--apply/, 'status never applies' );
( $rc, $out, $calls ) = scenario( "1\n2\n1\n1\n2\n3\n6\n", 0 );
like( $calls, qr/--action plan.*--components dxweb/, 'DXWeb plan routed' );
unlike( $calls, qr/--apply/, 'default declines apply' );
( $rc, $out, $calls ) = scenario( "3\n2\n1\n1\n1\n3\n6\n", 0 );
like( $calls, qr/--components both/,         'both components routed' );
like( $calls, qr/--action install.*--apply/, 'confirmed install applies' );
( $rc, $out, $calls ) = scenario( "1\n2\n1\n1\n1\n3\n6\n", 1 );
unlike( $calls, qr/--action install/, 'failed plan blocks installation' );
( $rc, $out, $calls ) = scenario( "4\n1\n4\n6\n", 0 );
like( $out, qr/NOT ACTIVE/, 'no false Turnstile protection claim' );
( $rc, $out, $calls ) = scenario( "5\nrelative\n6\n", 0 );
like( $out, qr/Invalid transaction directory/,
    'unsafe rollback path rejected' );
( $rc, $out, $calls ) =
  scenario( "1\n2\n1\n2\nexample.org\n/no/such/cert\n/no/such/key\n3\n6\n", 0 );
like(
    $out,
    qr/Invalid hostname\/certificate\/key/,
    'invalid TLS paths rejected'
);
is( $calls, '', 'invalid TLS does not invoke manager' );
my $tool = "$FindBin::Bin/turnstile-config.pl";
is( system( $^X, '-c', $tool ), 0, 'Turnstile configuration tool syntax' );
my $cfg    = "$tmp/turnstile.json";
my $status = `$^X '$tool' --status --path '$cfg' 2>&1`;
like( $status, qr/NOT CONFIGURED/, 'initially unconfigured' );
my $input = "$tmp/keys.txt";
open my $k, '>', $input or die $!;
print {$k} "0123456789abcdefghij\n0x4AAAAAverylongtestsecret\n";
close $k;
my $res =
`DXWEB_TURNSTILE_TEST_MODE=1 $^X '$tool' --configure --path '$cfg' < '$input' 2>&1`;
like( $res, qr/Keys stored/, 'credentials staged' );
ok( -f $cfg, 'credential file created' );
my $mode = ( stat($cfg) )[2] & 0777;
is( $mode, 0600, 'secret file mode 0600' );
$status = `$^X '$tool' --status --path '$cfg' 2>&1`;
like(
    $status,
    qr/STAGED.*not active/,
    'staged credentials never claimed active'
);
unlike(
    $status,
    qr/0x4AAAAAverylongtestsecret/,
    'secret never exposed by status'
);
open my $bad, '>', $input or die $!;
print {$bad} "bad\nbad\n";
close $bad;
$res =
`DXWEB_TURNSTILE_TEST_MODE=1 $^X '$tool' --configure --path '$cfg' < '$input' 2>&1`;
like( $res, qr/Invalid Site Key/, 'invalid key rejected' );
$status = `$^X '$tool' --status --path '$cfg' 2>&1`;
like( $status, qr/STAGED/, 'invalid update preserves existing credentials' );
done_testing();
