#!/usr/bin/env perl
#
# Get the TOR exit and relay lists from the net, extract the exit and relay
# node IP addresses and store them, one per line, in the standard places
# in /spider/local_data.
#

use 5.16.1;

use strict;
use warnings;

BEGIN {
	# root of directory tree for this system
	our $root = "/spider";
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};

	mkdir "$root/local_data", 02777 unless -d "$root/local_data";

	unshift @INC, "$root/perl";	# this IS the right way round!
	unshift @INC, "$root/local";
	our $data = "$root/data";
}

use DXVars;
use SysVar;

use DXDebug;
use DXUtil;

use JSON;
use Date::Parse;
use File::Copy;
use HTTP::Tiny;

DXDebug::dbginit();

$ENV{PERL_JSON_BACKEND} = "JSON::XS,JSON::PP";

my $debug;

if (@ARGV && $ARGV[0] eq '-x') {
	shift;
	$debug = 1;
}

# Onionoo official TOR Project API.
# Request only the fields required to build badip.torrelay and badip.torexit.
my $url = "https://onionoo.torproject.org/details?type=relay&running=true&fields=or_addresses,exit_addresses,last_seen,nickname";

my $relayfn = localdata('badip.torrelay');
my $exitfn  = localdata('badip.torexit');

my $last_seen_window = 10800;
my $content;

if (@ARGV) {
	local $/ = undef;
	my $fn = shift;
	open IN, $fn or die "$0 cannot open file $fn, $!";
	$content = <IN>;
	close IN;
} else {
	$content = fetch_url($url);
	die "$0: connect error on $url\n" unless defined $content && length $content;
}

die "No TOR content available $!\n" unless $content;

my $l = length $content;
dbg("$0: downloaded $l bytes from Onionoo") if $debug;

my $data = eval { decode_json($content) };
if ($@ || !$data || ref $data ne 'HASH') {
	die "$0: invalid JSON from $url: $@\n";
}

die "$0: Onionoo response does not contain relays[]\n"
	unless exists $data->{relays} && ref $data->{relays} eq 'ARRAY';

my $now = time;
my $ecount = 0;
my $rcount = 0;
my $error = 0;

my $rand = rand;
open RELAY, ">$relayfn.$rand" or die "$0: cannot open $relayfn.$rand $!";
open EXIT,  ">$exitfn.$rand"  or die "$0: cannot open $exitfn.$rand $!";

foreach my $e (@{$data->{relays}}) {
	next unless ref $e eq 'HASH';

	my $seen = $e->{last_seen} ? str2time($e->{last_seen}) : 0;
	next unless $seen && $seen >= $now - $last_seen_window;

	my @exit = exists $e->{exit_addresses} && ref $e->{exit_addresses} eq 'ARRAY'
		? clean_addr(@{$e->{exit_addresses}})
		: ();

	my @or = exists $e->{or_addresses} && ref $e->{or_addresses} eq 'ARRAY'
		? clean_addr(@{$e->{or_addresses}})
		: ();

	my $ors = join ', ', @or;
	my $es  = join ', ', @exit;
	dbg "$0: $e->{nickname} $e->{last_seen} relays: [$ors] exits: [$es]" if $debug;

	for (@exit) {
		if (is_ipaddr($_)) {
			print EXIT "$_\n";
			++$ecount;
		} else {
			print STDERR "$_\n";
			++$error;
		}
	}

	for (@or) {
		if (is_ipaddr($_)) {
			print RELAY "$_\n";
			++$rcount;
		} else {
			print STDERR "$_\n";
			++$error;
		}
	}
}

close RELAY;
close EXIT;

dbg("$0: $rcount relays $ecount exits $error error(s) found.");

move "$relayfn.$rand", $relayfn if $rcount;
move "$exitfn.$rand",  $exitfn  if $ecount;

unlink "$relayfn.$rand";
unlink "$exitfn.$rand";

exit $error;

my %addr;

sub fetch_url
{
	my $url = shift;

	# Prefer curl because it avoids broken Perl SSL stacks in some minimal containers.
	my $curl = which_cmd('curl');
	if ($curl) {
		my $cmd = "$curl -fsSL " . shell_quote($url);
		my $out = `$cmd`;
		return $out if defined $out && length $out;
	}

	# Fallback for systems without curl.
	my $ua = HTTP::Tiny->new(
		timeout => 60,
		agent   => "DXSpider badip updater"
	);

	my $res = eval { $ua->get($url) };
	if ($res && $res->{success} && defined $res->{content}) {
		return $res->{content};
	}

	return undef;
}

sub which_cmd
{
	my $cmd = shift;

	for my $dir (split /:/, $ENV{PATH} || '') {
		my $path = "$dir/$cmd";
		return $path if -x $path;
	}

	return;
}

sub shell_quote
{
	my $s = shift;
	$s =~ s/'/'\\''/g;
	return "'$s'";
}

sub clean_addr
{
	my @out;

	foreach (@_) {
		next unless defined $_;

		# Onionoo OR addresses are usually:
		#   1.2.3.4:9001
		#   [2001:db8::1]:9001
		# Exit addresses are normally:
		#   1.2.3.4
		my ($ipv4) = /^((?:\d+\.){3}\d+)/;
		if ($ipv4) {
			next if exists $addr{$ipv4};
			push @out, $ipv4;
			$addr{$ipv4}++;
			next;
		}

		my ($ipv6) = /^\[([:a-fA-F\d]+)\]/;
		if ($ipv6) {
			next if exists $addr{$ipv6};
			push @out, $ipv6;
			$addr{$ipv6}++;
			next;
		}

		# Accept bare IPv6 too, just in case Onionoo ever returns it without port.
		($ipv6) = /^([:a-fA-F\d]+)$/;
		if ($ipv6 && $ipv6 =~ /:/) {
			next if exists $addr{$ipv6};
			push @out, $ipv6;
			$addr{$ipv6}++;
			next;
		}
	}

	return @out;
}
