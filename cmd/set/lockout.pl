#
# lock a user out
#
# Copyright (c) 1998 Iain Phillips G0RDI
# Modifications (c) 2026 Dirk Koopman G1TLH
#

sub mod_existing
{
	my ($self, $ref) = @_;
	$ref->lockout(1);
	$ref->put();
	return $self->msg('lockout', $ref->call);
}

sub add_new
{
	my ($self, $call) = @_;
	my $ref = DXUser->new($call);
	$ref->lockout(1);
	$ref->put();
	return $self->msg('lockoutc', $call);
}

sub handle
{
	my ($self, $line) = @_;
	my @args = split /\s+/, uc($line // '');
	return (1, $self->msg('e5')) if $self->priv < 9;
	return (1, $self->msg('lockoutuse')) unless @args;

	my @invalid = grep {
		!DXUtil::is_callsign($_) || /-(?:0|00|0[1-9])$/
	} @args;
	return (1, 'Invalid callsign(s): ' . join(', ', @invalid) . '. No changes made.') if @invalid;

	my @out;
	for my $call (@args) {
		if ($self->remotecmd || $self->inscript) {
			Log('DXCommand', $self->call . " attempted to lockout $call remotely");
			push @out, $self->msg('sorry');
			next;
		}

		my $ref = DXUser::get_current($call);
		push @out, $ref ? mod_existing($self, $ref) : add_new($self, $call);

		# An explicit SSID affects that record only. A base callsign also
		# updates all existing SSIDs; never create missing SSID records.
		next if $call =~ /-\d+$/;
		for my $ssid (1 .. 99) {
			my $child = DXUser::get_current("$call-$ssid");
			push @out, mod_existing($self, $child) if $child;
		}
	}
	return (1, @out);
}

1;
