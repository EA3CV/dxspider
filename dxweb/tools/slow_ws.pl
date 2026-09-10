#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use MIME::Base64 qw(encode_base64);
use Socket qw(SOL_SOCKET SO_RCVBUF);

my $host = shift // '127.0.0.1';
my $port = shift // 8080;
my $seconds = shift // 30;

my $sock = IO::Socket::INET->new(
	PeerHost => $host, PeerPort => $port, Proto => 'tcp', Timeout => 5
) or die "connect $host:$port failed: $!\n";
$sock->autoflush(1);
setsockopt($sock, SOL_SOCKET, SO_RCVBUF, pack('i', 1024));

my $key = encode_base64(join('', map { chr(int(rand(256))) } 1..16), '');
print {$sock}
	"GET /ws HTTP/1.1\r\n",
	"Host: $host:$port\r\n",
	"Upgrade: websocket\r\n",
	"Connection: Upgrade\r\n",
	"Sec-WebSocket-Key: $key\r\n",
	"Sec-WebSocket-Version: 13\r\n\r\n";

my $headers = '';
while ($headers !~ /\r\n\r\n/s) {
	my $buf = '';
	my $n = sysread($sock, $buf, 1024);
	die "WebSocket handshake closed\n" unless defined($n) && $n > 0;
	$headers .= $buf;
	die "WebSocket handshake too large\n" if length($headers) > 16384;
}
die "WebSocket upgrade failed:\n$headers\n"
	unless $headers =~ m{^HTTP/1\.[01]\s+101\b}m;

print "WebSocket upgraded. Not reading any further data for ${seconds}s.\n";
sleep $seconds;
close $sock;
print "Slow WebSocket test finished.\n";
