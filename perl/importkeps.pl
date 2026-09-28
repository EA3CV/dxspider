#!/usr/bin/env perl
#
# Take a 2 line keps email file on STDIN, prepare it for import into standard import directory
# and then shove it there, marked for SB ALL.
#
# Copyright (c) 2004 Dirk Koopman G1TLH
#
#
#

use strict;

our $root;

# search local then perl directories
BEGIN {
	# root of directory tree for this system
	$root = "/spider"; 
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};
	
	unshift @INC, "$root/perl";	# this IS the right way round!
	unshift @INC, "$root/local";
}

my $fromcall = shift || 'G1TLH';
my $inp;
{
	local $/ = undef;
	$inp = <STDIN>;
}

# is it a 2 line kep file?
if ($inp =~ /ubject:\s+\[keps\]\s+orb\d{5}\.2l\.amsat/) {
	process();
}

exit(0);


#
# process the file
#

sub process
{
	# chop off most of the beginning
	return unless $inp =~ s/^.*SB\s+KEPS\s+\@\s+AMSAT\s+\$ORB\d{5}\.\w/SB ALL < $fromcall/s;
	return unless $inp =~ s/2Line\s+Orbital\s+Elements/2Line Keps/;
	
	# open the output file in the data area
	my $fn = "$root/tmp/keps.txt.$$";
	open OUT, ">$fn" or die "$fn $!";
	chmod 0666, $fn;
	print OUT $inp;
	close OUT;

	link $fn, "$root/msg/import/keps.txt.$$";
	unlink $fn;
}
