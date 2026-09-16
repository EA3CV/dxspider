#
# DXSpider - The Web Interface Helper Routines
#
# Copyright (c) 2015-2026 Dirk Koopman G1TLH
#

use strict;

package Web;

use DXDebug;
use DXChannel;
use DXLog;
use DXJSON;
use DXUtil;
use DXUser;
use DXCIDR;
use DXReg;
use Route;
use Route::User;


# One-request execution context for a logical WebCluster user.
#
# It is deliberately NOT created with DXChannel::alloc(), so it is never
# inserted into %DXChannel::channels and never becomes a real connection.
package Web::ActorConn;

sub new
{
	my ($class, $ip) = @_;
	return bless {
		peerhost => $ip,
		sockhost => $ip,
	}, $class;
}

sub peerhost { return $_[0]->{peerhost}; }
sub sockhost { return $_[0]->{sockhost}; }

package Web::Actor;

our @ISA = qw(DXCommandmode);

sub new
{
	my ($class, $call, $ip, $user, $priv, $registered) = @_;

	# Reaching this constructor means Web.pm has already verified that this
	# logical user belongs to this #WEB-n connection and was authenticated by
	# WebCluster.  The flag is deliberately actor-local: never copy it into the
	# persistent DXUser record.
	return bless {
		call        => $call,
		dcall       => $call,
		user        => $user,
		sort        => 'U',
		hostname    => $ip,
		sockhost    => $ip,
		conn        => Web::ActorConn->new($ip),
		lang        => $user->lang || $main::lang || 'en',
		priv        => defined $priv ? $priv : 0,
		width       => 80,
		registered  => defined $registered ? $registered : ($user->registered ? 1 : 0),
		remotecmd   => 0,
		inscript    => 0,
		badip       => DXCIDR::find($ip) || 0,
		badcount    => 0,
		isslugged   => 0,
		sluggedpcs  => [],
		state       => 'prompt',
		here        => 1,
		errors      => 0,
		_output     => [],
	}, $class;
}

# Capture direct command output locally.  This is used, for example, by the
# standard announce handler when policy deliberately keeps an announcement
# local to the sender.
sub send
{
	my $self = shift;
	push @{$self->{_output}}, grep { defined $_ } @_;
	return;
}

sub send_now
{
	my $self = shift;
	shift;  # framing letter
	push @{$self->{_output}}, grep { defined $_ } @_;
	return;
}

sub send_later
{
	my $self = shift;
	shift;  # framing letter
	push @{$self->{_output}}, grep { defined $_ } @_;
	return;
}

sub local_send
{
	my ($self, $let, $buf) = @_;
	push @{$self->{_output}}, $buf if defined $buf;
	return;
}

# cmd/dx.pl echoes the submitted spot to the invoking user.  WC already has
# its request and will also receive the global HUMAN feed if the spot is
# distributed, so suppress only that one-request echo.
sub dx_spot
{
	return;
}

sub disconnect
{
	$_[0]->{_disconnected} = 1;
	return;
}

# Web::Actor is not allocated through DXChannel::alloc(), therefore it must
# not inherit DXChannel::DESTROY(), which decrements the global channel count.
sub DESTROY { }

sub output
{
	my $self = shift;
	return @{$self->{_output} || []};
}

package Web;

require Exporter;
our @ISA = qw(DXCommandmode Exporter);
our @EXPORT = qw(is_webcall find_next_webcall);

our $maxssid = 64;
our $web_hwm = 64 * 1024;
our $web_hwm_resume = 32 * 1024;

my $json = DXJSON->new;

sub is_webcall
{
	return $_[0] =~ /^\#WEB/;
}

sub find_next_webcall
{
	foreach my $i (1 .. $maxssid) {
		next if DXChannel::get("\#WEB-$i");
		return "\#WEB-$i";
	}
	return undef;
}

sub new
{
	# Technical #WEB-n channel.
	# Use DXChannel::alloc(), not DXCommandmode::new(), because the latter
	# would add #WEB-n itself to normal routing.
	my $self = DXChannel::alloc(@_);

	# #WEB-n is a shared technical transport, never a user/security context.
	# Keep its effective channel privilege at zero regardless of the persistent
	# DXUser record or any later logical-user authentication.
	$self->{priv} = 0;

	$self->{web_role} = '';
	$self->{web_version} = 0;
	$self->{web_users} = {};
	$self->{web_feed_ann} = 1;
	$self->{web_feed_wwv} = 1;
	$self->{web_feed_wcy} = 1;
	$self->{web_feed_wx} = 1;

	return $self;
}

# DXCommandmode::start() normally copies the persistent DXUser privilege into
# the channel.  #WEB-n is transport only, so suppress that copy even if an
# old/persistent #WEB-n DXUser record were ever to contain a non-zero priv.
sub start
{
	my $self = shift;
	local $self->{user}{priv} = 0 if $self->{user};
	my @ret = $self->SUPER::start(@_);
	$self->{priv} = 0;
	return wantarray ? @ret : $ret[-1];
}

sub is_webcluster
{
	my $self = shift;
	return ($self->{web_role} || '') eq 'webcluster' ||
	       ($self->{web_role} || '') eq 'dxweb' ||
	       ($self->{web_role} || '') eq 'dxweb-admin';
}

# #WEB output safety. HUMAN/RBN/ANN are disposable; overload must never
# grow the Mojo write buffer without bound or degrade the DXSpider node.
sub _enable_webcluster_backpressure
{
	my $self = shift;
	my $conn = $self->{conn};
	my $sock = $conn && $conn->{sock};
	return unless $sock;

	$sock->high_water_mark($web_hwm) if $sock->can('high_water_mark');
	$self->{web_feed_accepted} = 0;
	$self->{web_feed_dropped} = 0;
	$self->{web_feed_saturated} = 0;
}

sub _web_output_state
{
	my ($self, $bytes) = @_;
	my $conn = $self->{conn};
	my $sock = $conn && $conn->{sock};

	return (0, 0) unless $sock;
	return (0, 0) unless $sock->can('can_write') && $sock->can('bytes_waiting');

	my $waiting = $sock->bytes_waiting;
	my $can_write = $sock->can_write ? 1 : 0;
	return ($can_write, $waiting);
}

sub _web_feed_can_write
{
	my ($self, $bytes) = @_;
	$bytes ||= 0;

	my ($can_write, $waiting) = $self->_web_output_state($bytes);
	my $saturated = $self->{web_feed_saturated} ? 1 : 0;

	if ($saturated) {
		if (!$can_write || $waiting > $web_hwm_resume ||
		    $waiting + $bytes > $web_hwm) {
			++$self->{web_feed_dropped};
			return 0;
		}

		$self->{web_feed_saturated} = 0;
		LogDbg('DXCommand', sprintf(
			'Web %s feed output recovered waiting=%d',
			$self->{call}, $waiting
		));
	}
	elsif (!$can_write || $waiting + $bytes > $web_hwm) {
		$self->{web_feed_saturated} = 1;
		++$self->{web_feed_dropped};
		LogDbg('DXCommand', sprintf(
			'Web %s feed output saturated waiting=%d hwm=%d; dropping web feed',
			$self->{call}, $waiting, $web_hwm
		));
		return 0;
	}

	++$self->{web_feed_accepted};
	return 1;
}

sub _web_control_can_write
{
	my ($self, $bytes) = @_;
	return 1 unless $self->is_webcluster;

	my ($can_write, $waiting) = $self->_web_output_state($bytes);
	return 1 if $can_write && $waiting + ($bytes || 0) <= $web_hwm;

	LogDbg('DXCommand', sprintf(
		'Web %s control output saturated waiting=%d; disconnecting #WEB',
		$self->{call}, $waiting
	));
	$self->disconnect unless $self->{disconnecting};
	return 0;
}

# WebCluster needs an absolute ANN feed switch.  DXCommandmode::announce()
# deliberately lets local-node announcements through even when {ann} is off,
# so intercept them here only for negotiated WebCluster channels.
sub announce
{
	my $self = shift;
	if ($self->is_webcluster) {
		# DXCommandmode::announce args after $line/$isolate are $to,$target,...
		my $target = $_[3] || '';
		return if $target eq 'WX' ? !$self->{web_feed_wx} : !$self->{web_feed_ann};
	}
	return $self->SUPER::announce(@_);
}

sub wwv
{
	my $self = shift;
	return if $self->is_webcluster && !$self->{web_feed_wwv};
	return $self->SUPER::wwv(@_);
}

sub wcy
{
	my $self = shift;
	return if $self->is_webcluster && !$self->{web_feed_wcy};
	return $self->SUPER::wcy(@_);
}

# Keep DXSpider/IntMsg framing untouched, but normalise the WebCluster feed
# payload after "|" to JSON.  This override only affects a negotiated
# WebCluster technical channel; ordinary Web/CLI channels retain the native
# DXCommandmode behaviour.
#
# X -> HUMAN spot, R -> RBN spot, N -> announcement, V -> WWV, Y -> WCY, W -> WX.
# Encode a protocol object in a deterministic field order.  DXJSON is still
# used for each value so escaping and JSON scalar/array handling remain native.
# DXJSON::encode() deliberately returns undef for a top-level scalar 0
# because its success check tests the encoded string for truth.  Protocol
# fields such as feed.rbn legitimately contain 0, so encode values inside a
# one-key object and then extract the encoded value.  This preserves DXJSON's
# escaping/boolean/array handling while allowing a deterministic key order.
sub _encode_protocol_value
{
	my ($value) = @_;
	my $wrapped = $json->encode({v => $value});
	return unless defined $wrapped;

	# DXJSON is canonical, and a one-key object is always {"v":<value>}.
	return $1 if $wrapped =~ /^\{"v":(.*)\}$/s;
	return;
}

sub _encode_protocol_object
{
	my ($pairs) = @_;
	return unless $pairs && ref $pairs eq 'ARRAY';

	my @out;
	for my $pair (@$pairs) {
		next unless $pair && ref $pair eq 'ARRAY' && @$pair == 2;
		my ($key, $value) = @$pair;
		my $ek = _encode_protocol_value($key);
		my $ev = _encode_protocol_value($value);
		return unless defined $ek && defined $ev;
		push @out, "$ek:$ev";
	}

	return '{' . join(',', @out) . '}';
}

sub local_send
{
	my ($self, $let, $buf) = @_;

	if ($self->is_webcluster && defined $buf) {
		my %type_for = (
			X => 'spot',
			R => 'rbn',
			N => 'ann',
			V => 'wwv',
			Y => 'wcy',
			W => 'wx',
		);

		if (my $type = $type_for{$let}) {
			my $payload = _encode_protocol_object([
				['type',    $type],
				['payload', $buf],
			]);

			unless (defined $payload) {
				LogDbg('err', "Web $self->{call}: cannot encode $type feed JSON");
				return;
			}

			# Conservatively include framing, call and line ending.
			my $wire_bytes = length($payload) + length($self->{call} || '') + 4;
			return unless $self->_web_feed_can_write($wire_bytes);

			return $self->SUPER::local_send($let, $payload);
		}
	}

	return $self->SUPER::local_send($let, $buf);
}

sub _send_json
{
	my ($self, $data) = @_;
	my $s;

	if ($data && ref $data eq 'HASH' && ($data->{type} || '') eq 'hello') {
		my @pairs = (
			['type', 'hello'],
			['role', $data->{role}],
		);
		push @pairs, ['auth', $data->{auth}] if exists $data->{auth};
		push @pairs, ['version', $data->{version}] if exists $data->{version};
		push @pairs, ['status', $data->{status}] if exists $data->{status};
		push @pairs, ['error', $data->{error}] if exists $data->{error};
		push @pairs, ['supported', $data->{supported}] if exists $data->{supported};
		$s = _encode_protocol_object(\@pairs);
	}
	elsif ($data && ref $data eq 'HASH' && ($data->{type} || '') eq 'response') {
		my @pairs = (['type', 'response']);
		push @pairs, ['id', $data->{id}] if exists $data->{id};
		push @pairs, ['status', $data->{status}] if exists $data->{status};
		push @pairs, ['action', $data->{action}] if exists $data->{action};

		for my $key (qw(call ip authenticated auth_source password_required password_used priv registered scope human rbn ann wwv wcy wx result error messages field)) {
			push @pairs, [$key, $data->{$key}] if exists $data->{$key};
		}

		# Preserve any future extension fields without disturbing the v1 prefix order.
		my %known = map { $_ => 1 } qw(type id status action call ip authenticated auth_source password_required password_used priv registered scope human rbn ann wwv wcy wx result error messages field);
		for my $key (sort grep { !$known{$_} } keys %$data) {
			push @pairs, [$key, $data->{$key}];
		}
		$s = _encode_protocol_object(\@pairs);
	}
	else {
		$s = $json->encode($data);
	}

	unless (defined $s) {
		LogDbg('err', "Web $self->{call}: cannot encode JSON");
		return;
	}

	my $wire_bytes = length($s) + length($self->{call} || '') + 4;
	return unless $self->_web_control_can_write($wire_bytes);

	$self->send_now('D', $s);
}

sub _response
{
	my ($self, $id, $status, $action, $extra) = @_;

	my $out = {
		type   => 'response',
		id     => $id,
		status => $status,
		action => $action,
	};

	if ($extra && ref $extra eq 'HASH') {
		$out->{$_} = $extra->{$_} for keys %$extra;
	}

	$self->_send_json($out);
}

sub _error
{
	my ($self, $id, $action, $error, $extra) = @_;
	$extra ||= {};
	$extra->{error} = $error;
	$self->_response($id, 'error', $action, $extra);
}

sub _normalise_user_call
{
	my $call = shift;
	return unless defined $call && !ref $call;

	$call = normalise_call(uc $call);
	return unless defined $call && $call && is_callsign($call);
	return $call;
}

sub _locked_out
{
	my ($call, $user) = @_;
	my $lock;

	my $basecall = $call;
	$basecall =~ s/-\d+$//;

	if ($user) {
		$lock = $user->lockout;
	}
	elsif ($basecall ne $call) {
		my $baseuser = DXUser::get_current($basecall);
		$lock = $baseuser->lockout if $baseuser;
	}

	return $lock ? 1 : 0;
}

sub _admin_peer_is_loopback
{
	my $self = shift;

	# This is the peer of the technical #WEB-n TCP connection as recorded by
	# DXChannel::alloc(), not an address supplied in Web JSON.
	for my $peer ($self->{hostname}, $self->{sockhost}) {
		next unless defined $peer && !ref $peer;
		my $ip = lc $peer;
		$ip =~ s/^\[|\]$//g;
		$ip =~ s/^::ffff://;
		return 1 if $ip eq '::1' || $ip eq 'localhost';
		return 1 if $ip =~ /^127(?:\.\d{1,3}){3}$/;
	}
	return 0;
}

sub _auth_request
{
	my ($self, $req) = @_;
	my $id = $req->{id};

	unless ((($self->{web_role} || '') eq 'dxweb' || ($self->{web_role} || '') eq 'dxweb-admin') &&
	        ($self->{web_auth} || '') eq 'dxspider') {
		$self->_error($id, 'auth', 'wrong_auth_mode');
		return;
	}

	my $call = _normalise_user_call($req->{call});
	my $ip = $req->{ip};
	my $password = exists $req->{password} && !ref($req->{password}) ? $req->{password} : undef;

	unless ($call) { $self->_error($id, 'auth', 'invalid_call'); return; }
	unless (defined $ip && !ref $ip && is_ipaddr($ip)) {
		$self->_error($id, 'auth', 'invalid_ip', {call => $call}); return;
	}
	$ip =~ s/^::ffff://i;
	if (DXCIDR::find($ip)) { $self->_error($id, 'auth', 'bad_ip', {call => $call}); return; }

	my $user = DXUser::get_current($call);
	if (_locked_out($call, $user)) { $self->_error($id, 'auth', 'locked_out', {call => $call}); return; }
	if ($user && !$user->is_user) { $self->_error($id, 'auth', 'not_user', {call => $call}); return; }

	my $is_admin = ($self->{web_role} || '') eq 'dxweb-admin';
	my $password_required;

	if ($is_admin) {
		# Administrative authority is granted only by DXSpider itself.  The
		# technical dxweb-admin transport must already be local (checked during
		# HELLO), the account must be a real SYSOP, and a non-empty DXUser
		# password must match.  Browser/client supplied privilege is ignored.
		unless ($user && ($user->priv || 0) >= 9) {
			$self->_error($id, 'auth', 'admin_privilege_required', {call => $call});
			return;
		}
		my $stored = $user->passwd || '';
		unless (length $stored) {
			$self->_error($id, 'auth', 'password_required', {call => $call, password_required => 1});
			return;
		}
		unless (defined($password) && length($password) && $password eq $stored) {
			$self->_error($id, 'auth', 'bad_password', {call => $call, password_required => 1});
			return;
		}
		$password_required = 1;
	} else {
		# Public dxweb keeps the normal DXSpider login/password semantics, but
		# its effective actor privilege remains zero after authentication.
		$password_required = $main::passwdreq || ($user && $user->passwd) ? 1 : 0;
		if ($password_required) {
			unless ($user && defined($password) && $password eq ($user->passwd || '')) {
				$self->_error($id, 'auth', 'bad_password', {call => $call, password_required => 1});
				return;
			}
		}
	}

	# Reuse the existing logical-user presence path only after DXS authentication.
	my %u = %$req;
	$u{authenticated} = 1;
	$u{type} = 'user_add';
	# Authentication proves identity.  A normal Web User never inherits the
	# persistent DXUser privilege.  Only the separately negotiated Admin
	# transport may receive the server-side DXUser privilege for its isolated
	# administrative actor.
	my $effective_priv = $is_admin ? ($user->priv || 0) : 0;

	$self->_user_add(\%u, {
		priv => $effective_priv,
		registered => $user ? ($user->registered ? 1 : 0) : 0,
		password_used => $password_required ? 1 : 0,
		auth_source => 'dxspider',
	});
}

sub _user_add
{
	my ($self, $req, $authmeta) = @_;

	my $id = $req->{id};
	my $call = _normalise_user_call($req->{call});
	my $ip = $req->{ip};

	# In external mode authentication is asserted by the trusted WebCluster.
	# In integrated dxweb mode this routine is reached only through _auth_request().
	# Authentication state is never copied into DXUser->{registered}.
	my $authenticated = $authmeta ? 1 : ($req->{authenticated} ? 1 : 0);
	if (($self->{web_auth} || '') eq 'dxspider' && !$authmeta) {
		$self->_error($id, 'user_add', 'use_auth');
		return;
	}
	if (($self->{web_auth} || '') eq 'external' && !$authenticated) {
		$self->_error($id, 'user_add', 'authentication_required', {call => $call});
		return;
	}

	unless ($call) {
		$self->_error($id, 'user_add', 'invalid_call');
		return;
	}

	unless (defined $ip && !ref $ip && is_ipaddr($ip)) {
		$self->_error($id, 'user_add', 'invalid_ip', {call => $call});
		return;
	}
	$ip =~ s/^::ffff://i;

	if (DXCIDR::find($ip)) {
		$self->_error($id, 'user_add', 'bad_ip', {call => $call});
		return;
	}

	if (exists $self->{web_users}{$call}) {
		$self->_error($id, 'user_add', 'already_owned', {call => $call});
		return;
	}

	if ($main::routeroot->is_user($call)) {
		$self->_error($id, 'user_add', 'already_connected', {call => $call});
		return;
	}

	my $user = DXUser::get_current($call);

	if (_locked_out($call, $user)) {
		$self->_error($id, 'user_add', 'locked_out', {call => $call});
		return;
	}

	if ($user && !$user->is_user) {
		$self->_error($id, 'user_add', 'not_user', {call => $call});
		return;
	}

	if ($user) {
		my $r = Route::get($call);

		if ($r) {
			my @parents = $r->parents;
			my $max = $user->maxconnect;
			$max = $main::maxconnect_user unless defined $max;

			if ($max && @parents >= $max + ($main::allowmultiple || 0)) {
				$self->_error($id, 'user_add', 'too_many_connections', {
					call  => $call,
					max   => $max,
					nodes => \@parents,
				});
				return;
			}
		}
	}

	# Do not pre-create a missing DXUser here.  _add_thingy() calls the native
	# check_add_user(), which must see a genuinely new user so it can initialise
	# sort/homenode/node/priv/lockout/lastin using normal DXSpider semantics.
	DXProt::_add_thingy(
		$main::routeroot,
		[$call, 0, 0, 1, undef, undef, $ip]
	);

	my $ref = Route::User::get($call);

	unless ($ref && $main::routeroot->is_user($call)) {
		$self->_error($id, 'user_add', 'route_add_failed', {call => $call});
		return;
	}

	$main::me->route_pc16($main::mycall, undef, $main::routeroot, $ref);
	$main::me->route_pc92a($main::mycall, undef, $main::routeroot, $ref)
		unless $DXProt::pc92_slug_changes || !$DXProt::pc92_ad_enabled;

	my $effective_priv = (($self->{web_role} || '') eq 'dxweb-admin' && $authmeta)
		? ($authmeta->{priv} || 0) : 0;

	$self->{web_users}{$call} = {
		ip            => $ip,
		startt        => $main::systime,
		authenticated => $authenticated,
		priv          => $effective_priv,
		registered    => $authmeta ? ($authmeta->{registered} || 0) : 0,
		password_used => $authmeta ? ($authmeta->{password_used} || 0) : 0,
		auth_source   => $authmeta ? ($authmeta->{auth_source} || 'dxspider') : 'external',
	};

	$self->tell_login('loginu', $call);
	$self->tell_buddies('loginb', $call);

	LogDbg('DXCommand', "Web $self->{call} USER_ADD $call from $ip");

	$self->_response($id, 'ok', $authmeta ? 'auth' : 'user_add', {
		call          => $call,
		ip            => $ip,
		authenticated => $authenticated,
		auth_source   => $authmeta ? 'dxspider' : 'external',
		password_used => $authmeta ? ($authmeta->{password_used} || 0) : 0,
		priv          => $effective_priv,
		registered    => $authmeta ? ($authmeta->{registered} || 0) : 0,
	});
}

sub _remove_user
{
	my ($self, $call, $reason) = @_;

	my $owned = $self->{web_users}{$call};
	return unless $owned;

	my $ref = Route::User::get($call);

	if ($ref && $main::routeroot->is_user($call)) {
		DXProt::_del_thingy($main::routeroot, [$call, 0]);

		$main::me->route_pc17($main::mycall, undef, $main::routeroot, $ref);
		$main::me->route_pc92d($main::mycall, undef, $main::routeroot, $ref)
			unless $DXProt::pc92_slug_changes || !$DXProt::pc92_ad_enabled;
	}

	# _add_thingy() already performs DXSpider's normal DXUser accounting when
	# the presence is added.  Do not close() the DXUser again here: that would
	# add a second connlist entry and persist a duplicate session record.
	delete $self->{web_users}{$call};

	$self->tell_login('logoutu', $call);
	$self->tell_buddies('logoutb', $call);

	LogDbg('DXCommand', "Web $self->{call} " . ($reason || 'USER_DEL') . " $call");
	return 1;
}

sub _user_del
{
	my ($self, $req) = @_;

	my $id = $req->{id};
	my $call = _normalise_user_call($req->{call});

	unless ($call) {
		$self->_error($id, 'user_del', 'invalid_call');
		return;
	}

	unless (exists $self->{web_users}{$call}) {
		$self->_error($id, 'user_del', 'not_owned', {call => $call});
		return;
	}

	$self->_remove_user($call, 'USER_DEL');

	$self->_response($id, 'ok', 'user_del', {
		call => $call,
	});
}


# Configure the technical #WEB-n DXUser for the two global WebCluster feeds.
#
# RBN.pm already sends consensus spots to normal user channels according to
# the DXUser wantrbn/want* flags and uses VE7CC::dx_spot() when ve7cc is set.
# These settings are therefore runtime-only transport preferences for this
# WebCluster connection; they are restored on disconnect.
sub _enable_webcluster_feeds
{
	my $self = shift;
	my $user = $self->{user};
	return unless $user;

	my @fields = qw(wantrbn wantbeacon wantcw wantrtty wantpsk wantft);

	$self->{_web_saved_user_feed_flags} ||= {};
	for my $field (@fields) {
		$self->{_web_saved_user_feed_flags}{$field} = $user->$field()
			unless exists $self->{_web_saved_user_feed_flags}{$field};
		$user->$field(1);
	}

	# HUMAN uses DXCommandmode::dx_spot(), RBN uses the technical DXUser's
	# wantrbn flag, and ANN is intercepted by Web::announce() so it can be
	# disabled absolutely (including announcements originated by this node).
	$self->{dx} = 1;
	$self->{wantrbn} = 1;
	$self->{web_feed_ann} = 1;
	$self->{web_feed_wwv} = 1;
	$self->{web_feed_wcy} = 1;
	$self->{web_feed_wx} = 1;
	$self->{wwv} = 1;
	$self->{wcy} = 1;
	$self->{wx} = 1;
	delete $self->{spotsfilter};
	delete $self->{rbnfilter};
}

sub _restore_webcluster_feeds
{
	my $self = shift;
	my $user = $self->{user};
	my $saved = delete $self->{_web_saved_user_feed_flags};

	return unless $user && $saved;

	for my $field (keys %$saved) {
		$user->$field($saved->{$field});
	}
}

# Accept JSON boolean values represented either as ordinary 0/1 scalars or
# as boolean objects that stringify to 0/1.  Other values are rejected so a
# malformed control request cannot silently change a feed.
sub _feed_bool
{
	my $value = shift;
	return undef unless defined $value;

	my $s = "$value";
	return 0 if $s eq '0';
	return 1 if $s eq '1';
	return undef;
}

sub _feed_state
{
	my $self = shift;
	my $user = $self->{user};

	return {
		human    => $self->{dx} ? 1 : 0,
		rbn      => ($user && $user->wantrbn) ? 1 : 0,
		ann      => $self->{web_feed_ann} ? 1 : 0,
		wwv      => $self->{web_feed_wwv} ? 1 : 0,
		wcy      => $self->{web_feed_wcy} ? 1 : 0,
		wx       => $self->{web_feed_wx} ? 1 : 0,
	};
}

sub _feed_request
{
	my ($self, $req) = @_;
	my $id = $req->{id};
	my $user = $self->{user};

	unless ($user) {
		$self->_error($id, 'feed', 'user_not_found');
		return;
	}

	my %changes;
	for my $field (qw(human rbn ann wwv wcy wx)) {
		next unless exists $req->{$field};
		my $value = _feed_bool($req->{$field});
		unless (defined $value) {
			$self->_error($id, 'feed', 'bad_arguments', {field => $field});
			return;
		}
		$changes{$field} = $value;
	}


	if (exists $changes{human}) {
		$self->{dx} = $changes{human};
	}

	if (exists $changes{rbn}) {
		$user->wantrbn($changes{rbn});
		$self->{wantrbn} = $changes{rbn};
	}

	if (exists $changes{ann}) { $self->{web_feed_ann} = $changes{ann}; }
	if (exists $changes{wwv}) { $self->{web_feed_wwv} = $changes{wwv}; $self->{wwv} = $changes{wwv}; }
	if (exists $changes{wcy}) { $self->{web_feed_wcy} = $changes{wcy}; $self->{wcy} = $changes{wcy}; }
	if (exists $changes{wx})  { $self->{web_feed_wx}  = $changes{wx};  $self->{wx}  = $changes{wx}; }

	my $state = $self->_feed_state;

	LogDbg('DXCommand', sprintf(
		'Web %s FEED human=%d rbn=%d ann=%d wwv=%d wcy=%d wx=%d',
		$self->{call}, $state->{human}, $state->{rbn}, $state->{ann}, $state->{wwv}, $state->{wcy}, $state->{wx}
	));

	$self->_response($id, 'ok', 'feed', $state);
}


# Resolve a WC-owned logical user into a transient standard-command actor.
sub _actor_for_call
{
	my ($self, $rawcall) = @_;

	my $call = _normalise_user_call($rawcall);
	return (undef, undef, 'invalid_call') unless $call;

	my $owned = $self->{web_users}{$call};
	return (undef, $call, 'not_owned') unless $owned;
	return (undef, $call, 'not_authenticated') unless $owned->{authenticated};

	return (undef, $call, 'not_present')
		unless $main::routeroot->is_user($call);

	my $user = DXUser::get_current($call);
	return (undef, $call, 'user_not_found') unless $user;
	return (undef, $call, 'not_user') unless $user->is_user;

	my $ip = $owned->{ip};
	return (undef, $call, 'invalid_ip')
		unless defined $ip && is_ipaddr($ip);

	my $actor_priv = ($self->{web_role} || '') eq 'dxweb-admin' ? ($owned->{priv} || 0) : 0;
	return (Web::Actor->new($call, $ip, $user, $actor_priv, $owned->{registered}), $call, undef);
}

sub _wc_text
{
	my ($value, $allow_empty) = @_;
	return undef if ref $value;
	return undef unless defined $value;
	return undef if $value =~ /[\r\n\0]/;
	return undef if !$allow_empty && $value eq '';
	return $value;
}

# Execute a fixed standard user command through the normal DXSpider command
# resolver.  The command name is supplied by Web.pm itself; WC never supplies
# an arbitrary CLI command name.
#
# run_cmd() strips the handler's internal leading success flag and returns
# only user-facing output.  Therefore:
#   - no returned/captured text => processed normally by the standard handler
#   - returned/captured text    => preserve that exact DXS result for WC
#
# We intentionally do not invent finer result semantics than the handler
# exposes to a normal user.
sub _run_wc_command
{
	my ($self, $actor, $cmd, $args) = @_;

	my @returned;
	my $eval_ok = eval {
		@returned = $actor->run_cmd("$cmd $args");
		1;
	};

	unless ($eval_ok) {
		LogDbg('err', "Web $self->{call}: $cmd execution failed: $@");
		return ('internal_error', []);
	}

	my @captured = $actor->output;
	my @messages = grep { defined $_ && length $_ } (@returned, @captured);

	return @messages ? ('message', \@messages) : ('processed', []);
}

sub _registration_ready
{
	return $main::reg_enable && DXReg::ready();
}

sub _registration_admin
{
	my ($self, $req) = @_;
	return (undef, 'admin_context_required') unless ($self->{web_role} || '') eq 'dxweb-admin';
	my $call = _normalise_user_call($req->{call});
	return (undef, 'invalid_call') unless $call;
	my $owned = $self->{web_users}{$call};
	return (undef, 'not_owned') unless $owned;
	return (undef, 'not_authenticated') unless $owned->{authenticated};
	return (undef, 'password_required') unless $owned->{password_used};
	return (undef, 'admin_privilege_required') unless ($owned->{priv} || 0) >= 9;
	return ($call, undef);
}

sub _registration_request
{
	my ($self, $req) = @_;
	my $id = $req->{id};
	unless (_registration_ready()) { $self->_error($id, 'reg_request', 'registration_unavailable'); return; }
	my $ip = $req->{ip};
	unless (defined $ip && !ref($ip) && is_ipaddr($ip)) { $self->_error($id, 'reg_request', 'invalid_ip'); return; }
	$ip =~ s/^::ffff://i;
	if (DXCIDR::find($ip)) { $self->_error($id, 'reg_request', 'bad_ip'); return; }
	my $ssids = $req->{ssids};
	$ssids = [] unless defined $ssids;
	unless (ref($ssids) eq 'ARRAY') { $self->_error($id, 'reg_request', 'bad_arguments'); return; }
	my ($ok, $result) = DXReg::create_request(
		call => $req->{call}, email => $req->{email}, language => ($req->{language} || 'EN'),
		ssids => $ssids, name => $req->{name}, comment => $req->{comment}, source => 'USER', ip => $ip,
	);
	unless ($ok) { $self->_error($id, 'reg_request', 'registration_rejected', {messages => [$result]}); return; }
	$self->_response($id, 'ok', 'reg_request', {result => $result});
}

sub _registration_pending
{
	my ($self, $req) = @_;
	my $id=$req->{id}; unless (_registration_ready()) { $self->_error($id,'reg_pending','registration_unavailable'); return; }
	my ($call,$err)=$self->_registration_admin($req); unless($call){$self->_error($id,'reg_pending',$err);return}
	my @rows=sort {($b->{created_at}||0)<=>($a->{created_at}||0)||($b->{id}||0)<=>($a->{id}||0)} DXReg::list_pending();
	$self->_response($id,'ok','reg_pending',{result=>\@rows});
}

sub _registration_history
{
	my ($self, $req) = @_;
	my $id=$req->{id}; unless (_registration_ready()) { $self->_error($id,'reg_history','registration_unavailable'); return; }
	my ($call,$err)=$self->_registration_admin($req); unless($call){$self->_error($id,'reg_history',$err);return}
	my @rows=DXReg::list_history();
	$self->_response($id,'ok','reg_history',{result=>\@rows});
}

sub _registration_search
{
	my ($self, $req) = @_;
	my $id=$req->{id}; unless (_registration_ready()) { $self->_error($id,'reg_search','registration_unavailable'); return; }
	my ($call,$err)=$self->_registration_admin($req); unless($call){$self->_error($id,'reg_search',$err);return}
	my $query=_wc_text($req->{query},0); unless(defined$query){$self->_error($id,'reg_search','bad_arguments');return}
	my @rows=DXReg::search_history($query);
	$self->_response($id,'ok','reg_search',{result=>\@rows});
}

sub _registration_accept
{
	my ($self, $req) = @_;
	my $id=$req->{id}; unless (_registration_ready()) { $self->_error($id,'reg_accept','registration_unavailable'); return; }
	my ($call,$err)=$self->_registration_admin($req); unless($call){$self->_error($id,'reg_accept',$err);return}
	my $rid=$req->{request_id}; unless(defined$rid&&!ref($rid)&&"$rid"=~/^\d+$/){$self->_error($id,'reg_accept','bad_arguments');return}
	my $note=exists($req->{note})?_wc_text($req->{note},1):undef; if(exists($req->{note})&&!defined$note){$self->_error($id,'reg_accept','bad_arguments');return}
	my ($ok,$result)=DXReg::accept_request($rid,$call,$note);
	unless($ok){$self->_error($id,'reg_accept','registration_rejected',{messages=>[$result]});return}
	$self->_response($id,'ok','reg_accept',{result=>$result});
}

sub _registration_reject
{
	my ($self, $req) = @_;
	my $id=$req->{id}; unless (_registration_ready()) { $self->_error($id,'reg_reject','registration_unavailable'); return; }
	my ($call,$err)=$self->_registration_admin($req); unless($call){$self->_error($id,'reg_reject',$err);return}
	my $rid=$req->{request_id}; unless(defined$rid&&!ref($rid)&&"$rid"=~/^\d+$/){$self->_error($id,'reg_reject','bad_arguments');return}
	my $note=exists($req->{note})?_wc_text($req->{note},1):undef; if(exists($req->{note})&&!defined$note){$self->_error($id,'reg_reject','bad_arguments');return}
	my ($ok,$result)=DXReg::reject_request($rid,$call,$note);
	unless($ok){$self->_error($id,'reg_reject','registration_rejected',{messages=>[$result]});return}
	$self->_response($id,'ok','reg_reject',{result=>$result});
}

sub _command_request
{
	my ($self, $req) = @_;
	my $id = $req->{id};
	my ($actor, $call, $err) = $self->_actor_for_call($req->{call});
	unless ($actor) { $self->_error($id, 'command', $err, $call ? {call => $call} : undef); return; }
	my $command = _wc_text($req->{command}, 0);
	unless (defined $command) { $self->_error($id, 'command', 'bad_arguments', {call => $call}); return; }
	my (@returned, $ok);
	$ok = eval { @returned = $actor->run_cmd($command); 1 };
	unless ($ok) { LogDbg('err', "Web $self->{call}: command failed: $@"); $self->_error($id, 'command', 'internal_error', {call => $call}); return; }
	my @messages = grep { defined $_ && length $_ } (@returned, $actor->output);
	$self->_response($id, 'ok', 'command', {call => $call, messages => \@messages});
}

sub _spot_request
{
	my ($self, $req) = @_;
	my $id = $req->{id};

	my ($actor, $call, $err) = $self->_actor_for_call($req->{call});
	unless ($actor) {
		$self->_error($id, 'spot', $err, $call ? {call => $call} : undef);
		return;
	}

	my $freq = _wc_text($req->{freq}, 0);
	my $dxcall = _wc_text($req->{dxcall}, 0);
	my $comment = exists $req->{comment} ? _wc_text($req->{comment}, 1) : '';

	unless (defined $freq && defined $dxcall && defined $comment) {
		$self->_error($id, 'spot', 'bad_arguments', {call => $call});
		return;
	}

	my $args = "$freq $dxcall";
	$args .= " $comment" if length $comment;

	my ($result, $messages) = $self->_run_wc_command($actor, 'dx', $args);

	if ($result eq 'internal_error') {
		$self->_error($id, 'spot', 'internal_error', {call => $call});
		return;
	}

	if ($result eq 'message') {
		$self->_response($id, 'rejected', 'spot', {
			call     => $call,
			messages => $messages,
		});
		return;
	}

	$self->_response($id, 'ok', 'spot', {
		call   => $call,
		result => 'processed',
	});
}

sub _announce_request
{
	my ($self, $req) = @_;
	my $id = $req->{id};

	my ($actor, $call, $err) = $self->_actor_for_call($req->{call});
	unless ($actor) {
		$self->_error($id, 'ann', $err, $call ? {call => $call} : undef);
		return;
	}

	my $text = _wc_text($req->{text}, 0);
	my $scope = lc(exists $req->{scope} ? $req->{scope} : 'local');

	unless (defined $text && $scope =~ /^(?:local|full|sysop)$/) {
		$self->_error($id, 'ann', 'bad_arguments', {call => $call});
		return;
	}

	my $args = $scope eq 'local' ? $text : uc($scope) . " $text";
	my ($result, $messages) = $self->_run_wc_command($actor, 'announce', $args);

	if ($result eq 'internal_error') {
		$self->_error($id, 'ann', 'internal_error', {
			call  => $call,
			scope => $scope,
		});
		return;
	}

	if ($result eq 'message') {
		$self->_response($id, 'rejected', 'ann', {
			call     => $call,
			scope    => $scope,
			messages => $messages,
		});
		return;
	}

	$self->_response($id, 'ok', 'ann', {
		call   => $call,
		scope  => $scope,
		result => 'processed',
	});
}

sub normal
{
	my ($self, $line) = @_;

	# Before WebCluster negotiation, preserve Dirk's existing Web/CLI behaviour.
	unless ($self->is_webcluster) {
		my $req = $json->decode($line);

		if ($req && ref $req eq 'HASH' && ($req->{type} || '') eq 'hello' &&
			(($req->{role} || '') eq 'webcluster' || ($req->{role} || '') eq 'dxweb' || ($req->{role} || '') eq 'dxweb-admin')) {

			my $version = $req->{version};
			my $role = $req->{role};
			my $expected_auth = ($role eq 'dxweb' || $role eq 'dxweb-admin') ? 'dxspider' : 'external';

			# dxweb-admin is a local DXSpider control-plane transport.  Enforce
			# loopback here, inside DXSpider, before the role is activated.
			if ($role eq 'dxweb-admin' && !$self->_admin_peer_is_loopback) {
				LogDbg('err', "Web $self->{call}: rejected non-local dxweb-admin HELLO from " . ($self->{hostname} || $self->{sockhost} || 'unknown'));
				$self->_send_json({
					type => 'hello', role => $role, version => $version,
					status => 'error', error => 'admin_local_only',
				});
				return;
			}

			unless (defined $version && !ref $version && $version =~ /^\d+$/ &&
				(($role eq 'webcluster' && ($version == 1 || $version == 2)) || (($role eq 'dxweb' || $role eq 'dxweb-admin') && $version == 2))) {
				$self->_send_json({
					type      => 'hello',
					role      => $role,
					status    => 'error',
					error     => 'unsupported_version',
					supported => ($role eq 'dxweb' || $role eq 'dxweb-admin') ? [2] : [1,2],
				});
				return;
			}

			$self->{web_role} = $role;
			$self->{web_auth} = $expected_auth;
			$self->{web_version} = $version;
			$self->_enable_webcluster_backpressure;
			$self->_enable_webcluster_feeds;

			LogDbg('DXCommand', "Web $self->{call} switched to $role protocol v$version auth=$expected_auth");

			my $hello = {
				type    => 'hello',
				role    => $role,
				version => $version,
				status  => 'ok',
			};
			$hello->{auth} = $expected_auth if $role eq 'dxweb' || $role eq 'dxweb-admin' || $version >= 2;
			$self->_send_json($hello);
			return;
		}

		return $self->SUPER::normal($line);
	}

	my $req = $json->decode($line);

	unless ($req && ref $req eq 'HASH') {
		$self->_send_json({
			type   => 'response',
			status => 'error',
			error  => 'invalid_json',
		});
		return;
	}

	my $id = $req->{id};
	my $type = lc($req->{type} || '');

	unless (defined $id && !ref $id && length "$id") {
		$self->_send_json({
			type   => 'response',
			status => 'error',
			error  => 'missing_id',
		});
		return;
	}

	if ($type eq 'auth') {
		$self->_auth_request($req);
		return;
	}

	if ($type eq 'user_add') {
		$self->_user_add($req);
		return;
	}

	if ($type eq 'user_del') {
		$self->_user_del($req);
		return;
	}

	if ($type eq 'feed') {
		$self->_feed_request($req);
		return;
	}

	if ($type eq 'command') {
		$self->_command_request($req);
		return;
	}

	if ($type eq 'spot') {
		$self->_spot_request($req);
		return;
	}

	if ($type eq 'ann') {
		$self->_announce_request($req);
		return;
	}

	if ($type eq 'reg_request') { $self->_registration_request($req); return; }
	if ($type eq 'reg_pending') { $self->_registration_pending($req); return; }
	if ($type eq 'reg_history') { $self->_registration_history($req); return; }
	if ($type eq 'reg_search') { $self->_registration_search($req); return; }
	if ($type eq 'reg_accept') { $self->_registration_accept($req); return; }
	if ($type eq 'reg_reject') { $self->_registration_reject($req); return; }

	$self->_error($id, $type || 'unknown', 'unknown_type');
}

sub disconnect
{
	my $self = shift;
	my $call = $self->call;

	return if $self->{disconnecting}++;

	if ($self->is_webcluster && $self->{web_users}) {
		my @users = keys %{$self->{web_users}};
		$self->_remove_user($_, 'WEB_DISCONNECT') for @users;
	}

	$self->_restore_webcluster_feeds if $self->is_webcluster;

	delete $self->{senddbg};

	LogDbg('DXCommand', "Web $call disconnected");

	DXChannel::disconnect($self);
}

1;
