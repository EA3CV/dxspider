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
	
	# Validate the complete argument list before changing any DXUser record.
	# A malformed item must not cause partial updates.
	my @invalid = grep { !DXUtil::is_callsign($_) } map { uc $_ } @args;
	if (@invalid) {
		return (1, "Invalid callsign(s): " . join(', ', @invalid) . ". No changes made.");
	}

	foreach $call (@args) {
		$call = uc $call;
		unless ($self->remotecmd || $self->inscript) {
				if ($ref = DXUser::get_current($call)) {
					push @out, mod_existing($self, $ref);
				}
			Log('DXCommand', $self->call . " un-locked out $call");
		} else {
			Log('DXCommand', $self->call . " attempted to un-lockout $call remotely");
			push @out, $self->msg('sorry');
		}
	}

	return (1, @out);
}

