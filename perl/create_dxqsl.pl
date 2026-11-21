#!/usr/bin/env perl
#
# Implement a 'GO' database list
#
# Copyright (c) 2003 Dirk Koopman G1TLH
#
#
#

# search local then perl directories
BEGIN {
	use vars qw($root);
	
	# root of directory tree for this system
	$root = "/spider"; 
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};
	
	unshift @INC, "$root/perl";	# this IS the right way round!
	unshift @INC, "$root/local";
}

use strict;

use IO::File;
use SysVar;
use DXUtil;
use Spot;
use QSL;
use DBI;


use vars qw($end $lastyear $lastday $lasttime);

$end = 0;
$SIG{TERM} = $SIG{INT} = sub { $end++ };

my $qslfn = "dxqsl";

$main::systime = time;

QSL::remove_files();
QSL::init(1) or die "cannot open QSL file";

my $base = localdata("spots");

opendir YEAR, $base or die "$base $!";
foreach my $year (sort readdir YEAR) {
	next if $year =~ /^\./;
	
	my $baseyear = "$base/$year";
	opendir DAY,  $baseyear or die "$baseyear $!";
	foreach my $day (sort readdir DAY) {
		next unless $day =~ /(\d+)\.dat$/;
		my $dayno = $1 + 0;
		
		my $fn = "$baseyear/$day";
		my $f = new IO::File $fn  or die "$fn ($!)"; 
		print "doing: $fn\n";
		QSL::begin_work;
		while (<$f>) {
			last if $end;
			if (/(QSL|VIA)/i) {
				my ($freq, $call, $t, $comment, $by, @rest) = split /\^/;
				my $q = QSL::get($call) || new QSL $call;
				$q->update($comment, $t, $by);
				$lasttime = $t;
			}
		}
		$f->close;
		QSL::commit;
		last if $end;
	}
	last if $end;
}

QSL::finish();

exit(0);


