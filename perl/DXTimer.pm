#
# Polled Timer handling
#
# This uses callbacks. BE CAREFUL!!!!
#
#
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#

package DXTimer;

use Mojo::IOLoop;

use vars qw(@timerchain $notimers $lasttime);
use DXDebug;

@timerchain = ();
$notimers = 0;

$lasttime = 0;

sub new
{
    my ($pkg, $time, $proc, $recur) = @_;
	my $obj = ref($pkg);
	my $class = $obj || $pkg;
	my $self = bless { t=>$time + $main::systime, proc=>$proc }, $class;
	$self->{interval} = $time if $recur;
	push @timerchain, $self;
	$notimers = @timerchain;
	dbg("Timer created (notimers: $notimers)") if isdbg('connll');
	return $self;
}

sub del
{
	my $self = shift;
	delete $self->{proc};
	@timerchain = grep {$_ != $self} @timerchain;
	$notimers = @timerchain;
	dbg("Timer deleted (notimers: $notimers)") if isdbg('connll');
}

sub handler
{
	my $now = $main::systime;

	return unless $now != $lasttime;

	# handle things on the timer chain
	my $t;
	foreach $t (@timerchain) {
		if ($now >= $t->{t}) {
			&{$t->{proc}}() if $t->{proc};
			$t->{t} = $now + $t->{interval} if exists $t->{interval};
		}
	}

	$lasttime = $now;
}

sub DESTROY
{
	dbg("timer destroyed ($DXTimer::notimers)") if isdbg('connll');
}
1;
