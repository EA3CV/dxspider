# Show how many nodes have updated to the latest version
#
# To use: grepdbg countmojo.pm
#

package main;

my %count;
my %countold;
my %ccc;

my $gitbranch = 'none';
my $gitversion = 'none';
my $build = 'none';
my $version = 'none';

sub begin
{
	# determine the real Git build number and branch
	my $desc;
	eval {$desc = `git --git-dir=$root/.git describe --long`};
	if (!$@ && $desc) {
		my ($v, $s, $b, $g) = $desc =~ /^([\d\.]+)(?:\.(\d+))?-(\d+)-g([0-9a-f]+)/;
		$version = $v;
		my $subversion = $s || 0; # not used elsewhere
		$build = $b || 0;
		$gitversion = "$g\[r]";
	}
	if (!$@) {
		my @branch;

		eval {@branch = `git --git-dir=$root/.git branch`};
		unless ($@) {
			for (@branch) {
				my ($star, $b) = split /\s+/;
				if ($star eq '*') {
					$gitbranch = $b;
					last;
				}
			}
		}
	}

	($version) = $version =~ /^\d+\.(\d+)/;
	$version = $version + 5400;
}

sub handle
{
	my $line = $_;
	
	return unless $line =~ / I /;

	my ($call, $buildup) = $line =~ /PC92\^([^\^]+)\^[-\d+\.]+\^K\^([^\^]+)/;
	return unless $call;
	
	my ($vcall, $ver, $b) = split ':', $buildup;

	if ($ver eq $version) {
		$count{$call} = $b;
	} else {
		$ccc{$call} = $b if $ver >= 3000 && $ver < 4000;
		$countold{$call} = $b; 
	}
}

sub total
{
	my $good = 0;
	my $bad = 0;
	
	foreach my $k (keys %count) {
		my $b = $count{$k};
		if ($b == $build) {
			++$good;
		} else {
			++$bad;
		}
	}
	my $old = keys %countold;
	my $ccc = keys %ccc;
	my $mojo = $good + $bad;
	my $percentall = $good * 100 / ($mojo + $others);
	my $percentmojo = $good * 100 / $mojo;
	my $total = $good + $bad + $old;
	
	printf "Current mojo version/build $version/$build updated $good/$mojo (%.2f%%) not updated: $bad others: $old (CCC: $ccc) total: $total\n", $percentmojo, $percentall; 
	
}

1;
