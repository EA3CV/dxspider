# Read PC92 and match ip addresses to a spotter
#
# We are looking for ip addresses that have many spotters
#
# To use: grepdbg anaylseip.pm
#

package main;

use strict;

my %ip;

my %countold;
my %ccc;

my %key;

sub begin
{

}

sub handle
{
	my $line = $_;
	
	return unless $line =~ /I ([\w\d-]+) PC92\^/;
	$line =~ s/^.*I ([\w\d\-]+) PC92/$1/;
	chomp $line;

#	print "$line\n";
	
	my @e;

	@e = split /\^/, $line;
	return unless @e;
	return unless $e[3] =~ /[AC]/;
	
	
	shift @e;					# remove source node

	my $k = join '|', @e[0,1];
	next if exists $key{$k};
	pop @e;						# remove Hnn
	

	foreach my $slot (@e[4..$#e]) {
		$slot =~ s/^\d//;
		next unless $slot;

		# split each slot into call and ip
		my @s = split /:/, $slot;
		next unless @s >= 2;
		
		$s[1] =~ s/,/:/g;
		my $entry = $ip{$s[1]} || {};
		$entry->{$s[0]}++;
		$ip{$s[1]} = $entry;
	}

	
	my $l = join('|', @e), "\n";
	$key{$k} ||= $l;

#	print "$l\n";
}

sub total
{
	foreach my $k (sort keys %ip) {
		my @calls = sort keys %{$ip{$k}};
		print "$k -> " . join(',', @calls) . "\n";
	}
}

1;
