#!/usr/bin/env perl
use strict;
use warnings;

my @required = qw(
	app.pl public/index.html public/app.js public/style.css
	tools/ws_check.pl tools/slow_ws.pl tools/slow_dxs_peer.pl
	tools/check_rx_only.sh tools/check_backpressure.sh
	install-webpm-backpressure.sh rollback-webpm-backpressure.sh
);
die "missing $_\n" for grep { !-f $_ } @required;

open my $fh, '<', 'app.pl' or die $!;
local $/;
my $app = <$fh>;
close $fh;

die "browser message handler missing\n"
	unless $app =~ /on\(message\s*=>\s*sub\s*\(\$c,\s*\$msg\)\s*\{\s*\}\)/s;
die "mutating HTTP methods are not 405\n"
	unless $app =~ /any\s*\[qw\(POST PUT PATCH DELETE\)\].*?status\s*=>\s*405/s;
die "fanout queue not bounded\n"
	unless $app =~ /MAX_FANOUT_ITEMS/ && $app =~ /MAX_FANOUT_BYTES/;
die "history not byte bounded\n" unless $app =~ /MAX_HISTORY_BYTES/;
die "input not bounded\n" unless $app =~ /MAX_INPUT_BYTES/;
die "WS high-water guard missing\n"
	unless $app =~ /bytes_waiting/ && $app =~ /WS_HIGH_WATER/;
die "no-client fanout bypass missing\n"
	unless $app =~ /return 1 unless %clients/;

print "dxweb static safety self-test: PASS\n";
