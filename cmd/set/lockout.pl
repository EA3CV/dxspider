#
# lock a user out
#
# Copyright (c) 1998 Iain Phillips G0RDI
#
# Modifications  (c) 2026 Dirk Koopman G1TLH
#

sub mod_existing
{
	my $self = shift;
	my $ref  = shift;
	$ref->lockout(1);
	$ref->put();
	return $self->msg("lockout", $ref->call);
}

sub add_new
{
	my $self = shift;
	my $call = shift;

	my $ref = DXUser->new($call);
	$ref->lockout(1);
	$ref->put();
	return $self->msg("lockoutc", $call);
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
		Log('DXCommand', $self->call . " attempted to lockout @args");
		return (1, $self->msg('e5'));
	}

	foreach $call (@args) {
		$call = uc $call;
		unless ($self->remotecmd || $self->inscript) {
			if ($call =~ /-\d{1,2}$/) {	# This is a call + ssid, just do this exact call
				$call =~ s/-0$//;		    # this means just the base callsignx
				if ($ref = DXUser::get_current($call)) {
					push @out, mod_existing($self, $ref);
				} else {
					push @out, add_new($self, $call);
				}
			} else {
				# if this call exists, then lock it and go and find ssids 1 -> 99
				# look for any ssids associated with it and lock them as well
				# if this is a new call, just create it.
				$ref = DXUser::get_current($call);
				if ($ref) {
					push @out, mod_existing($self, $ref);    # lock the base call
					foreach my $ssid (1..99) {
						$ref = DXUser::get_current("$call-$ssid");
#						push @out, "try $call-$ssid" . ($ref ? " found" : "");
						push @out, mod_existing($self, $ref)  if $ref;
					}
				} else {
					push @out, add_new($call);
				}
			}
			Log('DXCommand', $self->call . " locked out $call");
		}
		else {
			Log('DXCommand', $self->call . " attempted to lockout $call remotely");
			push @out, $self->msg('sorry');
		}
	}
	return (1, @out);
}
