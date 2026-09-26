#!/usr/bin/env perl
#
# Process and import for mail SIDC Ursagrams
#
# This program takes a mail message on its standard input
# and, if it is an URSIGRAM, imports it into the local
# spider msg queue.
#
# Copyright (c) 2004 Dirk Koopman G1TLH
#
#
#

use strict;
use Mail::Internet;
use Mail::Header;

our $root;

# search local then perl directories
BEGIN {
	# root of directory tree for this system
	$root = "/spider"; 
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};
	
	unshift @INC, "$root/perl";	# this IS the right way round!
	unshift @INC, "$root/local";
}

my $import = "$root/msg/import";
my $tmp = "$root/tmp";

my $msg = Mail::Internet->new(\*STDIN) or die "Mail::Internet $!";
my $head = $msg->head->header_hashref;
my $fromcall = shift || 'G1TLH';

if ($head && $head->{From}->[0] =~ /sidc/i && $head->{Subject}->[0] =~ /Ursigram/i) {
	my $body = $msg->body;
	my $title = 'SIDC Ursigram';
	my $date = '';
	foreach my $l (@$body) {
		if ($l =~ /SIDC\s+SOLAR\s+BULLETIN\s+(\d+)\s+(\w+)\s+20(\d\d)/) {
			$date = "$1$2$3";
			$title .= " $date";
			last;
		}
	}
	my $fn = "ursigram$date.txt.$$"; 
	open OUT, ">$tmp/$fn" or die "import $tmp/$fn $!";
	print OUT "SB ALL < $fromcall\n$title\n";
	print OUT map {s/\r\n$/\n/; $_} @$body;
	print OUT "/ex\n";
	close OUT;
	link "$tmp/$fn", "$import/$fn";
	unlink "$tmp/$fn";
}

exit(0);
