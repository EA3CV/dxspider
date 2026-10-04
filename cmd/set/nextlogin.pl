#
# prevent a user from logging in for xxx seconds
#
#  (c) 2026 Dirk Koopman G1TLH
#

sub mod_existing
{
	my $self = shift;
	my $ref  = shift;
	my $secs = shift;
	if ($secs) {
		$ref->nextlogin($secs+$main::systime);
	} else {
		delete $ref->{nextlogin};
	}
	$ref->put();
	return $self->msg("nextlogin", $ref->call, cldatetime($ref->nextlogin));
}

sub handle
{
	my ($self, $line) = @_;
	my @args = split /\s+/, $line;
	my $call;
	my @out;
	my $user;
	my $ref;

	return (1, "not allowed") if $self->remotecmd || $self->inscript;
	if ($self->priv < 9) {
		Log('DXCommand', $self->call . " attempted to set nextlogin  @args");
		return (1, $self->msg('e5'));
	}

	return (1, "usage: set/nextlogin <seconds> <callsign> ...") unless @args;

	my $secs = shift @args;
	return (1, $self->msg('e21', $secs)) unless $secs =~ /^\d+$/;
	
	foreach $call (@args) {
		$call = uc $call;
		if ($call =~ /-\d{1,2}$/) {	# This is a call + ssid, just do this exact call
			$call =~ s/-0$//;	# this means just the base callsignx
			if ($ref = DXUser::get_current($call)) {
				push @out, mod_existing($self, $ref, $secs);
			}
			else {
				push @out, $self->msg('e41', $call);
			}
		}
		else {
			# if this call exists, then lock it and go and find ssids 1 -> 99
			# look for any ssids associated with it and lock them as well
			# if this is a new call, just create it.
			$ref = DXUser::get_current($call);
			if ($ref) {
				push @out, mod_existing($self, $ref, $secs); # lock the base call
				foreach my $ssid (1..99) {
					$ref = DXUser::get_current("$call-$ssid");
					#						push @out, "try $call-$ssid" . ($ref ? " found" : "");
					push @out, mod_existing($self,  $ref, $secs)  if $ref;
				}
				Log('DXCommand', $self->call . "$call nextlogin set  to $secs (" . cldatetime($ref->nextlogin) .")" );
			}
		}
	}
	return (1, @out);
}
