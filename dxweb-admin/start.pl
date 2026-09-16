#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);

# The administrative process may be reached by a SYSOP browser according to
# the HTTP bind below, but its privileged DXSpider transport is hard-wired in
# admin.pl to 127.0.0.1.  It cannot be redirected to a remote DXSpider host.
my $port = $ENV{ADMIN_HTTP_PORT} // 7381;
chdir $Bin or die "chdir $Bin: $!\n";
exec $^X, "$Bin/admin.pl", 'daemon', '-l', "http://0.0.0.0:$port";
die "exec admin.pl failed: $!\n";
