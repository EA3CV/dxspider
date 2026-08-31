#
# unlock a locked out user 
#
# Copyright (c) 1998 Iain Phillips G0RDI
#
# Modifications  (c) 2026 Dirk Koopman G1TLH
#

sub mod_existing
{
	my $self = shift;
	my $ref  = shift;
	$ref->lockout(0);
	$ref->put();
	return $self->msg("lockoutun", $ref->call);
}

sub handle
{

	my ($self, $line) = @_;
	my @args = split /\s+/, $line;
	my $call;
	# my $priv = shift @args;
	my @out;
	my $user;
	my $ref;

	if ($self->priv < 9) {
		Log('DXCommand', $self->call . " attempted to un-lockout @args");
		return (1, $self->msg('e5'));
	}
	
	foreach $call (@args) {
		$call = uc $call;
		unless ($self->remotecmd || $self->inscript) {
			if ($call =~ /-\d{1,2}$/) {	# This is a call + ssid, just do this exact call
				if ($ref = DXUser::get_current($call)) {
					push @out, mod_existing($self, $ref);
				}
			} else {
				# if this call exists, then lock it and go and find ssids 1 -> 99
				# look for any ssids associated with it and lock them as well
				# if this is a new call, just create it.
				$ref = DXUser::get_current($call);
				if ($ref) {
					push @out, mod_existing($self, $ref); # lock the base call
					foreach my $ssid (1..99) {
						$ref = DXUser::get_current("$call-$ssid");
						#						push @out, "try $call-$ssid" . ($ref ? " found" : "");
						push @out, mod_existing($self, $ref)  if $ref;
					}
				}
			}
			Log('DXCommand', $self->call . " un-locked out $call");
		} else {
			Log('DXCommand', $self->call . " attempted to un-lockout $call remotely");
			push @out, $self->msg('sorry');
		}
	}

	return (1, @out);
}

