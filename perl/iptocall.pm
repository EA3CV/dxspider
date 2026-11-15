#
#
# Map callsign to IP addresses (or maybe the other around :-)
#
# We are looking for IP addresses that have many callsigns and callsigns that
# have many IP addresses
#
# Some of these may be suspicious...
#
# We are interested in PC92 A and C records - some of these may clash...
#

use strict;

package main;

my %ipcall;
my %callip;
my %callserial;
my %callnode;

my $count;

my %susip;
my %suscall;

sub handle
{
	my $line = shift;
	return unless  $line =~ / I [-\w\d]+ PC92\^[-\w\d]+\^[\d\.]+\^[AC]\^/;
	my @parts = split /\^/, $line;
	shift @parts;
	shift @parts;
	my $node = shift @parts;
	my $serial = shift @parts;
	return if exists $callserial{$node} && $serial <= $callserial{$node} ;
	$callserial{$node} = $serial;
	
	my $letter = shift @parts;
	return unless $letter =~ /^[AC]$/;
	shift @parts unless $parts[0];
	#	print "slot: $node $serial $letter ";
	foreach my $slot (@parts) {
		last if $slot =~ /^H\d{1,2}$/;
		my ($state, $call, $ip) = $slot =~ /^([0-7])([-\w\d]+):(.*)$/;
		next unless $ip && is_ipaddr($ip);
		$ip =~ s/(?:,[\da-f]+){4}$/\/64/i; # reduce IPV6 to /64 addresses
		$ip =~ s/,/:/g if $ip;

		++$callip{$call}{$ip};
		++$ipcall{$ip}{$call};
		++$callnode{$call}{$node};

#		++$susip{$ip} if $callip{$call} != $ipcall{$ip}{$call};
		#	print "callip $call|$ip = $callip{$call}{$ip} ipcall $ip|$call = $ipcall{$ip}{$call}\n";
	}
	++$count;
}

# special for IPV6 still using , rather than : as separators
sub is_ipaddr
{
    my $addr = shift;
	if ($addr =~ /,/) {
		return ($addr =~ /^((?:,?,?[0-9a-f]{0,4}){1,8}\,?\,?)$/i);
	} else {
		return ($addr =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
	}
    return undef;
}
	

sub end
{
#	print "callsigns: ", keys %callip, "IP addresses: ", keys %ipcall, "\n";
	
	foreach my $call (keys %callip) {
		my $hash = $callip{$call};
		++$suscall{$call}  if keys %$hash > 1;
	}
	foreach my $ip (keys %ipcall) {
		my $hash = $ipcall{$ip};
		++$susip{$ip}  if keys %$hash > 1;
	}

#	print "SUSPECT callsigns: ", keys %suscall, "IP addresses: ", keys %susip, "\n";

	foreach my $call (sort keys %suscall) {
		my $hash = $callip{$call};
		print "Suspect call: $call ", join(', ',  sort keys %$hash), "\n";
	}

	foreach my $ip (sort keys %susip) {
		my $hash = $ipcall{$ip};
		print "Suspect ip: $ip ", join(', ',  sort keys %$hash), "\n";
	}

	
	print sprintf("Totals: PC92 A/C records read: $count  calls: %d  ips: %d  suspect calls: %d  ips: %d\n", scalar keys  %callip, scalar keys %ipcall, scalar keys %suscall, scalar keys %susip); 
}

1;
