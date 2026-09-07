#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_RCVBUF);

my $host = shift // '127.0.0.1';
my $port = shift // 27754;
my $seconds = shift // 30;

my $sock = IO::Socket::INET->new(
	PeerHost => $host, PeerPort => $port, Proto => 'tcp', Timeout => 5
) or die "connect $host:$port failed: $!\n";
$sock->autoflush(1);
setsockopt($sock, SOL_SOCKET, SO_RCVBUF, pack('i', 1024));

sub send_line { print {$sock} $_[0], "\n"; }
sub read_line_timeout {
	local $SIG{ALRM} = sub { die "timeout waiting for DXSpider\n" };
	alarm 10;
	my $line = <$sock>;
	alarm 0;
	die "DXSpider closed connection\n" unless defined $line;
	$line =~ s/[\r\n]+$//;
	return $line;
}

send_line('A#WEB|{"role":"webcluster","version":1}');

my ($call, $prompt);
while (!$call || !$prompt) {
	my $line = read_line_timeout();
	$call = $1 if !$call && $line =~ /^C(#WEB-\d+)\s*$/;
	$prompt = 1 if $call && $line =~ /^D\Q$call\E\|.*dxspider\s*>\s*$/i;
}

send_line('I' . $call . '|{"type":"hello","role":"webcluster","version":1}');
my $hello_ok;
while (!$hello_ok) {
	my $line = read_line_timeout();
	$hello_ok = 1 if $line =~ /^D\Q$call\E\|.*"type":"hello".*"status":"ok"/;
}

send_line('I' . $call . '|{"type":"feed","id":1,"human":1,"rbn":1,"ann":0}');
my $feed_ok;
while (!$feed_ok) {
	my $line = read_line_timeout();
	$feed_ok = 1 if $line =~ /^D\Q$call\E\|.*"type":"response".*"status":"ok".*"action":"feed"/;
}

print "Negotiated $call HUMAN/RBN. Not reading any further DXSpider data for ${seconds}s.\n";
sleep $seconds;
close $sock;
print "Slow #WEB peer test finished.\n";
