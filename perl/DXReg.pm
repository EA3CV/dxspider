#
# DXReg.pm - DXSpider Registration subsystem
#
# Description:
#   Native DXSpider registration management for user requests,
#   acceptance/rejection, password handling, registration removal,
#   historical persistence and optional email/Telegram notifications.
#
# Data:
#   /spider/local_data/registration.json
#
# Templates:
#   /spider/local_data/reg_templates/
#
# Configuration:
#   /spider/local/DXVars.pm
#
# Version : 1.0
# Date    : 21-Aug-2026
#

package DXReg;

use strict;
use warnings;

use DXDebug;
use DXLog ();
use DXJSON;
use DXUtil;
use DXUser;
use DXChannel;

use Fcntl qw(:flock);
use Encode qw(encode);
use MIME::Base64 qw(encode_base64);

our $VERSION = '1.0';

my $json = DXJSON->new->canonical(1)->pretty(1);

my @requests;
my %by_id;
my %by_call;

my $next_id = 1;
my $ready   = 0;
my $telegram_ua;


# ------------------------------------------------------------
# init
#
# Called from cluster.pl after DXProt->init() and before
# scripts/startup.
#
# When registration is enabled:
#
#   $reqreg    = 1
#   $passwdreq = 0
#
# ------------------------------------------------------------

sub init
{
    return 1 unless $main::reg_enable;

    $main::reqreg    = 1;
    $main::passwdreq = 0;

    my ($ok, $err) = _load();

    unless ($ok) {
        DXLog::LogDbg('err', "DXReg: $err");
        $ready = 0;
        return;
    }

    $ready = 1;

    DXLog::LogDbg(
        'registration',
        sprintf(
            'DXReg v%s initialised: reqreg=1 passwdreq=0, %d request(s)',
            $VERSION,
            scalar @requests
        )
    );

    return 1;
}


sub ready
{
    return $ready;
}


# ------------------------------------------------------------
# create_request
# ------------------------------------------------------------

sub create_request
{
    my (%arg) = @_;

    return (0, 'registration subsystem is not available')
        unless $ready;

    my $call = uc($arg{call} // '');
    $call =~ s/^\s+//;
    $call =~ s/\s+$//;

    return (0, 'callsign is required')
        unless length $call;

    my ($valid_call, $call_err) = _validate_call($call);
    return (0, $call_err) unless $valid_call;

    my $email = $arg{email} // '';
    $email =~ s/^\s+//;
    $email =~ s/\s+$//;

    return (0, 'email address is required')
        unless length $email;

    return (0, 'invalid email address')
        unless _validate_email($email);

    my $language = uc($arg{language} // '');
    $language =~ s/^\s+//;
    $language =~ s/\s+$//;

    return (0, 'language must be EN or ES')
        unless $language eq 'EN' || $language eq 'ES';

    my @ssids = @{ $arg{ssids} || [] };

    my ($valid_ssids, $ssid_err, $clean_ssids)
        = _validate_ssids(@ssids);

    return (0, $ssid_err)
        unless $valid_ssids;

    my $source = uc($arg{source} // 'USER');
    $source = 'USER' unless $source eq 'SYSOP';

    my $ip;
    $ip = "$arg{ip}"
        if defined $arg{ip} && length $arg{ip};

    # One simultaneous PENDING request per CALL.
    if (my $ids = $by_call{$call}) {
        for my $id (@$ids) {
            my $r = $by_id{$id};
            next unless $r;

            if (($r->{status} // '') eq 'PENDING') {
                return (
                    0,
                    sprintf(
                        'a registration request for %s is already pending (#%d)',
                        $call,
                        $id
                    )
                );
            }
        }
    }

    my $id = int($next_id++);

    my $request = {
        id              => $id,
        call            => $call,
        email           => $email,
        language        => $language,
        requested_ssids => [ map { int($_) } @$clean_ssids ],
        accepted_ssids  => undef,
        status          => 'PENDING',
        source          => $source,
        ip              => $ip,
        created_at      => int(time),
        processed_at    => undef,
        processed_by    => undef,
        note            => undef,
    };

    push @requests, $request;
    _index_request($request);

    my ($saved, $save_err) = _save();

    unless ($saved) {
        pop @requests;
        _rebuild_indexes();
        --$next_id if $next_id > 1;

        DXLog::LogDbg(
            'err',
            "DXReg: cannot save request for $call: $save_err"
        );

        return (
            0,
            "unable to save registration request: $save_err"
        );
    }

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration request #%d %s created (%s)',
            $request->{id},
            $call,
            $source
        )
    );

    _queue_admin_request_notifications($request);

    return (1, $request);
}




# ------------------------------------------------------------
# resolve_pending_request
#
# Resolve either a numeric request ID or a callsign to the one
# currently PENDING request.
#
# This provides the common ID|CALL behaviour used by
# register/accept and register/reject.
# ------------------------------------------------------------

sub resolve_pending_request
{
    my ($target) = @_;

    return (0, 'request ID or callsign is required')
        unless defined $target && length $target;

    $target =~ s/^\s+//;
    $target =~ s/\s+$//;

    if ($target =~ /^\d+$/) {
        my $r = get_request(int($target));

        return (0, "registration request #$target not found")
            unless $r;

        return (
            0,
            sprintf(
                'registration request #%d %s is not pending (%s)',
                $r->{id},
                $r->{call},
                $r->{status} // 'UNKNOWN'
            )
        ) unless ($r->{status} // '') eq 'PENDING';

        return (1, $r);
    }

    my $call = uc($target);

    my ($valid, $err) = _validate_call($call);
    return (0, $err) unless $valid;

    my @history = get_history($call);

    return (0, "no registration history for $call")
        unless @history;

    my @pending = grep {
        ($_->{status} // '') eq 'PENDING'
    } @history;

    return (0, "no pending registration request for $call")
        unless @pending;

    return (
        0,
        "more than one pending registration request for $call"
    ) if @pending > 1;

    return (1, $pending[0]);
}

# ------------------------------------------------------------
# accept_request
#
# Accepts a PENDING request and applies registration to DXUser.
#
# Rules:
#   - CALL and CALL-SSID are independent DXUser records.
#   - Current registered SSIDs are preserved.
#   - Newly requested SSIDs are added.
#   - Missing SSIDs in a new request never mean "unregister".
#   - If the basecall already has a password, reuse it.
#   - Otherwise generate a new password.
#   - The same password is then synchronized across the basecall
#     and every accepted/current SSID.
#
# Arguments:
#   request ID
#   SYSOP callsign
#   optional note
#
# Returns:
#   (1, {
#       request         => $request,
#       password        => $password,
#       password_source => 'existing' | 'generated',
#       calls           => \@calls,
#   })
#
# or:
#   (0, $error)
#
# The password is returned to the SYSOP command but is never
# stored in registration.json or written to DXDebug.
# ------------------------------------------------------------

sub accept_request
{
    my ($id, $sysop, $note) = @_;

    return (0, 'registration subsystem is not available')
        unless $ready;

    return (0, 'request id is required')
        unless defined $id && "$id" =~ /^\d+$/;

    $id = int($id);

    my $request = $by_id{$id};

    return (0, "registration request #$id not found")
        unless $request;

    return (
        0,
        sprintf(
            'registration request #%d %s is not pending (%s)',
            $id,
            $request->{call},
            $request->{status} // 'UNKNOWN'
        )
    ) unless ($request->{status} // '') eq 'PENDING';

    $sysop = uc($sysop // '');
    $sysop =~ s/^\s+//;
    $sysop =~ s/\s+$//;

    return (0, 'SYSOP callsign is required')
        unless length $sysop;

    if (defined $note) {
        $note =~ s/^\s+//;
        $note =~ s/\s+$//;
        $note = undef unless length $note;
    }

    my $base = _base_call($request->{call});

    my ($call_ok, $call_err) = _validate_call($base);
    return (0, $call_err) unless $call_ok;

    my @requested = @{ $request->{requested_ssids} || [] };

    my ($ssid_ok, $ssid_err, $clean_requested)
        = _validate_ssids(@requested);

    return (0, $ssid_err) unless $ssid_ok;

    # The effective set is additive:
    # existing registered SSIDs UNION newly requested SSIDs.
    my @current = _current_registered_ssids($base);

    my %effective = map { int($_) => 1 } (@current, @$clean_requested);
    my @accepted  = sort { $a <=> $b } keys %effective;

    # Reuse the basecall password if one exists.
    # A new password is generated only if the basecall has no password.
    my $base_user = DXUser::get_current($base);

    my ($password, $password_source);

    if (
        $base_user
        && defined $base_user->passwd
        && length $base_user->passwd
    ) {
        $password        = $base_user->passwd;
        $password_source = 'existing';
    } else {
        my ($pw_ok, $pw_or_err) = _generate_password();

        return (0, $pw_or_err) unless $pw_ok;

        $password        = $pw_or_err;
        $password_source = 'generated';
    }

    my @calls = (
        $base,
        map { "$base-$_" } @accepted
    );

    # Snapshot all affected DXUser records so we can restore them
    # if any put() or registration.json persistence fails.
    my @snapshots;

    for my $call (@calls) {
        my $ref = DXUser::get_current($call);

        push @snapshots, {
            call               => $call,
            existed            => $ref ? 1 : 0,
            registered_exists  => $ref && exists $ref->{registered} ? 1 : 0,
            registered         => $ref ? $ref->{registered} : undef,
            passwd_exists      => $ref && exists $ref->{passwd} ? 1 : 0,
            passwd             => $ref ? $ref->{passwd} : undef,
        };
    }

    # Preserve request state for rollback.
    my %old_request = (
        status         => $request->{status},
        accepted_ssids => $request->{accepted_ssids},
        processed_at   => $request->{processed_at},
        processed_by   => $request->{processed_by},
        note           => $request->{note},
    );

    my $dx_ok  = 0;
    my $dx_err = '';

    eval {
        for my $call (@calls) {
            my $ref = DXUser::get_current($call);

            # alloc() avoids the intermediate put() done by DXUser->new().
            $ref = DXUser->alloc($call) unless $ref;

            $ref->registered(1);
            $ref->passwd($password);
            $ref->put();
        }

        $dx_ok = 1;
    };

    unless ($dx_ok) {
        $dx_err = $@ || 'unknown DXUser update error';
        $dx_err =~ s/\s+$//;

        _rollback_dxusers(\@snapshots);

        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: cannot accept request #%d %s: %s',
                $id,
                $request->{call},
                $dx_err
            )
        );

        return (0, "unable to update DXUser records: $dx_err");
    }

    $request->{status}         = 'ACCEPTED';
    $request->{accepted_ssids} = [ map { int($_) } @accepted ];
    $request->{processed_at}   = int(time);
    $request->{processed_by}   = $sysop;
    $request->{note}           = $note;

    my ($saved, $save_err) = _save();

    unless ($saved) {
        $request->{status}         = $old_request{status};
        $request->{accepted_ssids} = $old_request{accepted_ssids};
        $request->{processed_at}   = $old_request{processed_at};
        $request->{processed_by}   = $old_request{processed_by};
        $request->{note}           = $old_request{note};

        _rollback_dxusers(\@snapshots);

        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: DXUser changes rolled back for request #%d %s because registration history could not be saved: %s',
                $id,
                $request->{call},
                $save_err
            )
        );

        return (
            0,
            "unable to save accepted registration request: $save_err"
        );
    }

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration request #%d %s accepted by %s; password synchronized across %d DXUser record(s)',
            $id,
            $request->{call},
            $sysop,
            scalar @calls
        )
    );

    _queue_user_accept_email($request, $password);

    return (
        1,
        {
            request         => $request,
            password        => $password,
            password_source => $password_source,
            calls           => \@calls,
        }
    );
}


# ------------------------------------------------------------
# remove_registration
#
# Remove registration from a base callsign and every existing
# CALL-SSID (1..99):
#
#   registered = 0
#   passwd      = removed
#
# DXUser records themselves are preserved.
#
# Any affected connected sessions are disconnected only after
# the new DXUser state and administrative history have been
# persisted, forcing a fresh login with the new state.
#
# A REMOVED historical entry is appended to registration.json.
# ------------------------------------------------------------

sub remove_registration
{
    my ($target, $sysop, $note, $source_ip) = @_;

    return (0, 'registration subsystem is not available')
        unless $ready;

    return (0, 'callsign is required')
        unless defined $target && length $target;

    my $base = _base_call($target);

    my ($call_ok, $call_err) = _validate_call($base);
    return (0, $call_err) unless $call_ok;

    $sysop = uc($sysop // '');
    $sysop =~ s/^\s+//;
    $sysop =~ s/\s+$//;

    return (0, 'SYSOP callsign is required')
        unless length $sysop;

    if (defined $note) {
        $note =~ s/^\s+//;
        $note =~ s/\s+$//;
        $note = undef unless length $note;
    }

    my @affected;
    my @affected_ssids;

    my $base_user = DXUser::get_current($base);
    push @affected, $base if $base_user;

    for my $ssid (1 .. 99) {
        my $call = "$base-$ssid";
        my $ref  = DXUser::get_current($call);

        next unless $ref;

        push @affected, $call;
        push @affected_ssids, $ssid;
    }

    return (0, "no DXUser records found for $base")
        unless @affected;

    # Snapshot only the fields that this operation changes.
    my @snapshots;

    for my $call (@affected) {
        my $ref = DXUser::get_current($call);

        push @snapshots, {
            call              => $call,
            registered_exists => exists $ref->{registered} ? 1 : 0,
            registered        => $ref->{registered},
            passwd_exists     => exists $ref->{passwd} ? 1 : 0,
            passwd            => $ref->{passwd},
        };
    }

    my $dx_ok = eval {
        for my $call (@affected) {
            my $ref = DXUser::get_current($call)
                or die "DXUser $call disappeared during remove";

            $ref->registered(0);
            $ref->unset_passwd();
            $ref->put();
        }

        1;
    };

    unless ($dx_ok) {
        my $err = $@ || 'unknown DXUser update error';
        $err =~ s/\s+$//;

        _rollback_remove_dxusers(\@snapshots);

        DXLog::LogDbg(
            'err',
            "DXReg: remove failed for $base: $err"
        );

        return (0, "unable to remove registration for $base: $err");
    }

    # Preserve the most recent useful metadata when available.
    my @history = sort {
        ($b->{id} || 0) <=> ($a->{id} || 0)
    } get_history($base);

    my $previous = $history[0];

    my $now = int(time);

    my $record = {
        id              => int($next_id++),
        call            => $base,
        email           => $previous ? ($previous->{email} // '') : '',
        language        => $previous ? ($previous->{language} // 'EN') : 'EN',
        requested_ssids => [],
        accepted_ssids  => undef,
        affected_ssids  => [ map { int($_) } @affected_ssids ],
        status          => 'REMOVED',
        source          => 'SYSOP',
        ip              => defined $source_ip && length $source_ip ? "$source_ip" : undef,
        created_at      => $now,
        processed_at    => $now,
        processed_by    => $sysop,
        note            => $note,
    };

    push @requests, $record;
    _index_request($record);

    my ($saved, $save_err) = _save();

    unless ($saved) {
        pop @requests;
        --$next_id if $next_id > 1;
        _rebuild_indexes();

        _rollback_remove_dxusers(\@snapshots);

        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: remove for %s rolled back because registration history could not be saved: %s',
                $base,
                $save_err
            )
        );

        return (
            0,
            "unable to save registration removal history: $save_err"
        );
    }

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration: %s removed by %s; %d DXUser record(s) updated',
            $base,
            $sysop,
            scalar @affected
        )
    );

    # Disconnect after persistence. A failure here must not roll back
    # the registration removal; it is logged prominently instead.
    my @disconnected;
    my @disconnect_failed;

    for my $call (@affected) {
        my $chan = DXChannel::get($call);
        next unless $chan;

        my $ok = eval {
            $chan->disconnect();
            1;
        };

        if ($ok) {
            push @disconnected, $call;

            DXLog::LogDbg(
                'registration',
                "registration: disconnected $call after registration removal"
            );
        } else {
            my $err = $@ || 'unknown disconnect error';
            $err =~ s/\s+$//;

            push @disconnect_failed, $call;

            DXLog::LogDbg(
                'err',
                "DXReg: failed to disconnect $call after registration removal: $err"
            );
        }
    }

    return (
        1,
        {
            record            => $record,
            affected_calls    => \@affected,
            disconnected      => \@disconnected,
            disconnect_failed => \@disconnect_failed,
        }
    );
}

# ------------------------------------------------------------
# reject_request
#
# Rejects a PENDING request.
#
# Arguments:
#   request ID
#   SYSOP callsign
#   optional note
# ------------------------------------------------------------

sub reject_request
{
    my ($id, $sysop, $note) = @_;

    return (0, 'registration subsystem is not available')
        unless $ready;

    return (0, 'request id is required')
        unless defined $id && "$id" =~ /^\d+$/;

    $id = int($id);

    my $request = $by_id{$id};

    return (0, "registration request #$id not found")
        unless $request;

    return (
        0,
        sprintf(
            'registration request #%d %s is not pending (%s)',
            $id,
            $request->{call},
            $request->{status} // 'UNKNOWN'
        )
    ) unless ($request->{status} // '') eq 'PENDING';

    $sysop = uc($sysop // '');
    $sysop =~ s/^\s+//;
    $sysop =~ s/\s+$//;

    return (0, 'SYSOP callsign is required')
        unless length $sysop;

    if (defined $note) {
        $note =~ s/^\s+//;
        $note =~ s/\s+$//;
        $note = undef unless length $note;
    }

    # Keep previous state so a failed save can be rolled back.
    my %old = (
        status       => $request->{status},
        processed_at => $request->{processed_at},
        processed_by => $request->{processed_by},
        note          => $request->{note},
    );

    $request->{status}       = 'REJECTED';
    $request->{processed_at} = int(time);
    $request->{processed_by} = $sysop;
    $request->{note}         = $note;

    my ($saved, $save_err) = _save();

    unless ($saved) {
        $request->{status}       = $old{status};
        $request->{processed_at} = $old{processed_at};
        $request->{processed_by} = $old{processed_by};
        $request->{note}         = $old{note};

        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: cannot reject request #%d %s: %s',
                $id,
                $request->{call},
                $save_err
            )
        );

        return (
            0,
            "unable to save rejected registration request: $save_err"
        );
    }

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration request #%d %s rejected by %s',
            $id,
            $request->{call},
            $sysop
        )
    );

    _queue_user_reject_email($request);

    return (1, $request);
}


# ------------------------------------------------------------
# get_request
# ------------------------------------------------------------

sub get_request
{
    my ($id) = @_;

    return undef
        unless defined $id && "$id" =~ /^\d+$/;

    return $by_id{int($id)};
}


# ------------------------------------------------------------
# get_history
# ------------------------------------------------------------

sub get_history
{
    my ($call) = @_;

    $call = uc($call // '');

    return () unless length $call;

    my $ids = $by_call{$call} || [];

    return map { $by_id{$_} } @$ids;
}


# ------------------------------------------------------------
# list_pending
# ------------------------------------------------------------

sub list_pending
{
    return grep {
        ($_->{status} // '') eq 'PENDING'
    } @requests;
}


# ============================================================
# PRIVATE FUNCTIONS
# ============================================================

sub _load
{
    my $file = _data_file();

    @requests = ();
    %by_id    = ();
    %by_call  = ();
    $next_id  = 1;

    return (1, undef) unless -e $file;

    open my $fh, '<', $file
        or return (0, "cannot open $file: $!");

    local $/;
    my $raw = <$fh>;

    close $fh
        or return (0, "cannot close $file: $!");

    return (1, undef)
        unless defined $raw && $raw =~ /\S/;

    my $data;

    eval {
        $data = $json->decode($raw);
    };

    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        return (0, "invalid JSON in $file: $err");
    }

    return (0, "invalid JSON structure in $file")
        unless ref($data) eq 'HASH';

    return (0, "unsupported registration file version")
        unless defined $data->{version}
        && $data->{version} == 1;

    return (0, "invalid requests array in $file")
        unless ref($data->{requests}) eq 'ARRAY';

    @requests = @{ $data->{requests} };

    my %seen_id;

    for my $r (@requests) {
        return (0, "invalid request entry in $file")
            unless ref($r) eq 'HASH';

        return (0, "request without numeric id in $file")
            unless defined $r->{id}
            && "$r->{id}" =~ /^\d+$/
            && $r->{id} > 0;

        $r->{id} = int($r->{id});

        return (0, "duplicate request id $r->{id} in $file")
            if $seen_id{$r->{id}}++;

        return (0, "request #$r->{id} without callsign in $file")
            unless defined $r->{call}
            && length $r->{call};

        $r->{call} = uc($r->{call});

        if (ref($r->{requested_ssids}) eq 'ARRAY') {
            $r->{requested_ssids}
                = [ map { int($_) } @{ $r->{requested_ssids} } ];
        } else {
            $r->{requested_ssids} = [];
        }

        if (ref($r->{accepted_ssids}) eq 'ARRAY') {
            $r->{accepted_ssids}
                = [ map { int($_) } @{ $r->{accepted_ssids} } ];
        }

        if (ref($r->{affected_ssids}) eq 'ARRAY') {
            $r->{affected_ssids}
                = [ map { int($_) } @{ $r->{affected_ssids} } ];
        }

        $r->{created_at} = int($r->{created_at})
            if defined $r->{created_at}
            && "$r->{created_at}" =~ /^\d+$/;

        $r->{processed_at} = int($r->{processed_at})
            if defined $r->{processed_at}
            && "$r->{processed_at}" =~ /^\d+$/;
    }

    if (
        defined $data->{next_id}
        && "$data->{next_id}" =~ /^\d+$/
        && $data->{next_id} > 0
    ) {
        $next_id = int($data->{next_id});
    } else {
        for my $r (@requests) {
            $next_id = $r->{id} + 1
                if $r->{id} >= $next_id;
        }
    }

    for my $r (@requests) {
        $next_id = $r->{id} + 1
            if $r->{id} >= $next_id;
    }

    _rebuild_indexes();

    return (1, undef);
}


sub _save
{
    my $file = _data_file();
    my $tmp  = "$file.tmp";
    my $lock = "$file.lock";

    # Build a clean structure so numeric values are encoded as JSON numbers.
    my @out_requests;

    for my $r (@requests) {
        my %copy = %$r;

        $copy{id} = int($r->{id});

        $copy{requested_ssids} = [
            map { int($_) } @{ $r->{requested_ssids} || [] }
        ];

        if (ref($r->{accepted_ssids}) eq 'ARRAY') {
            $copy{accepted_ssids} = [
                map { int($_) } @{ $r->{accepted_ssids} }
            ];
        } else {
            $copy{accepted_ssids} = undef;
        }

        if (ref($r->{affected_ssids}) eq 'ARRAY') {
            $copy{affected_ssids} = [
                map { int($_) } @{ $r->{affected_ssids} }
            ];
        }

        $copy{created_at} = int($r->{created_at})
            if defined $r->{created_at};

        $copy{processed_at} = int($r->{processed_at})
            if defined $r->{processed_at};

        push @out_requests, \%copy;
    }

    my $data = {
        version  => 1,
        next_id  => int($next_id),
        requests => \@out_requests,
    };

    my $raw;

    eval {
        $raw = $json->encode($data);
    };

    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        return (0, "cannot encode registration data: $err");
    }

    return (0, 'cannot encode registration data')
        unless defined $raw && length $raw;

    open my $lfh, '>>', $lock
        or return (0, "cannot open lock file $lock: $!");

    unless (flock($lfh, LOCK_EX)) {
        my $err = $!;
        close $lfh;
        return (0, "cannot lock $lock: $err");
    }

    my $ok  = 0;
    my $err = '';

    eval {
        open my $fh, '>', $tmp
            or die "cannot open $tmp: $!";

        print {$fh} $raw
            or die "cannot write $tmp: $!";

        close $fh
            or die "cannot close $tmp: $!";

        rename $tmp, $file
            or die "cannot rename $tmp to $file: $!";

        $ok = 1;
    };

    if ($@) {
        $err = $@;
        $err =~ s/\s+$//;
        unlink $tmp if -e $tmp;
    }

    flock($lfh, LOCK_UN);
    close $lfh;

    return $ok
        ? (1, undef)
        : (0, $err || 'unknown write error');
}


sub _rebuild_indexes
{
    %by_id   = ();
    %by_call = ();

    for my $r (@requests) {
        _index_request($r);
    }

    return;
}


sub _index_request
{
    my ($r) = @_;

    $by_id{$r->{id}} = $r;
    push @{ $by_call{$r->{call}} }, $r->{id};

    return;
}




# ------------------------------------------------------------
# _next_tick
#
# Defer notification startup until the current DXSpider command
# stack has completely returned to the Mojo event loop.
# ------------------------------------------------------------

sub _next_tick
{
    my ($cb) = @_;

    require Mojo::IOLoop;

    Mojo::IOLoop->next_tick(sub {
        eval { $cb->() };

        if ($@) {
            my $err = $@;
            $err =~ s/\s+$//;

            DXLog::LogDbg(
                'err',
                "DXReg: deferred notification setup failed: $err"
            );
        }
    });

    return;
}


# ------------------------------------------------------------
# Notification helpers


sub _queue_admin_request_notifications
{
    my ($request) = @_;

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration: admin notifications deferred for request #%d %s',
            $request->{id},
            $request->{call}
        )
    );

    _next_tick(sub {
        _queue_admin_request_notifications_now($request);
    });

    return;
}


sub _queue_user_accept_email
{
    my ($request, $password) = @_;

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration: user acceptance notification deferred for request #%d %s',
            $request->{id},
            $request->{call}
        )
    );

    _next_tick(sub {
        _queue_user_accept_email_now($request, $password);
    });

    return;
}


sub _queue_user_reject_email
{
    my ($request) = @_;

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration: user rejection notification deferred for request #%d %s',
            $request->{id},
            $request->{call}
        )
    );

    _next_tick(sub {
        _queue_user_reject_email_now($request);
    });

    return;
}



#
# CRITICAL RULE:
#   Notification transport must NEVER block the DXSpider main loop.
#
# Telegram uses the asynchronous Mojo::UserAgent callback API.
# SMTP is blocking, so it is executed in Mojo::IOLoop::Subprocess.
#
# Request/accept/reject is already persisted before these functions
# are called. Notification failure never changes the operation result.
# ------------------------------------------------------------

sub _queue_admin_request_notifications_now
{
    my ($request) = @_;

    if ($main::reg_email_enable) {
        my ($ok, $subject, $body_or_err) = _load_mail_template(
            'mail_admin_request',
            $request,
            undef,
        );

        if (!$ok) {
            DXLog::LogDbg(
                'err',
                sprintf(
                    'DXReg: admin email template failed for request #%d %s: %s',
                    $request->{id},
                    $request->{call},
                    $body_or_err
                )
            );
        } elsif (!defined $main::reg_email_admin || !length $main::reg_email_admin) {
            DXLog::LogDbg(
                'err',
                sprintf(
                    'DXReg: admin email not queued for request #%d %s: destination is not configured',
                    $request->{id},
                    $request->{call}
                )
            );
        } else {
            _queue_email(
                kind       => 'admin',
                request_id => $request->{id},
                call       => $request->{call},
                to         => $main::reg_email_admin,
                subject    => $subject,
                body       => $body_or_err,
            );
        }
    }

    if ($main::reg_telegram_enable) {
        my ($ok, $text_or_err) = _load_text_template(
            'telegram_admin_request',
            $request,
            undef,
            1,      # HTML-escape dynamic variables
        );

        if (!$ok) {
            DXLog::LogDbg(
                'err',
                sprintf(
                    'DXReg: Telegram template failed for request #%d %s: %s',
                    $request->{id},
                    $request->{call},
                    $text_or_err
                )
            );
        } else {
            _queue_telegram(
                request_id => $request->{id},
                call       => $request->{call},
                text       => $text_or_err,
            );
        }
    }

    return;
}


sub _queue_user_accept_email_now
{
    my ($request, $password) = @_;

    return unless $main::reg_email_enable;

    my ($ok, $subject, $body_or_err) = _load_mail_template(
        'mail_user_accept',
        $request,
        $password,
    );

    if (!$ok) {
        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: acceptance email template failed for request #%d %s: %s',
                $request->{id},
                $request->{call},
                $body_or_err
            )
        );
        return;
    }

    _queue_email(
        kind       => 'user acceptance',
        request_id => $request->{id},
        call       => $request->{call},
        to         => $request->{email},
        subject    => $subject,
        body       => $body_or_err,
    );

    return;
}


sub _queue_user_reject_email_now
{
    my ($request) = @_;

    return unless $main::reg_email_enable;

    my ($ok, $subject, $body_or_err) = _load_mail_template(
        'mail_user_reject',
        $request,
        undef,
    );

    if (!$ok) {
        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: rejection email template failed for request #%d %s: %s',
                $request->{id},
                $request->{call},
                $body_or_err
            )
        );
        return;
    }

    _queue_email(
        kind       => 'user rejection',
        request_id => $request->{id},
        call       => $request->{call},
        to         => $request->{email},
        subject    => $subject,
        body       => $body_or_err,
    );

    return;
}


# ------------------------------------------------------------
# _queue_email
#
# Net::SMTP and Net::SMTP::SSL are blocking APIs. They run only
# inside a Mojo subprocess. The parent callback records success
# or failure and never contains/logs the password or message body.
# ------------------------------------------------------------

sub _queue_email
{
    my (%arg) = @_;

    my $kind = $arg{kind} || 'email';
    my $id   = $arg{request_id};
    my $call = $arg{call} || '-';
    my $to   = $arg{to};

    unless (defined $to && length $to) {
        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: %s email not queued for request #%d %s: destination is empty',
                $kind,
                $id,
                $call
            )
        );
        return;
    }

    my %smtp = (
        host => $main::reg_email_smtp,
        port => $main::reg_email_port || 465,
        user => $main::reg_email_user,
        pass => $main::reg_email_pass,
        from => $main::reg_email_from,
    );

    unless (defined $smtp{host} && length $smtp{host}) {
        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: %s email not queued for request #%d %s: SMTP host is not configured',
                $kind,
                $id,
                $call
            )
        );
        return;
    }

    unless (defined $smtp{from} && length $smtp{from}) {
        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: %s email not queued for request #%d %s: SMTP from address is not configured',
                $kind,
                $id,
                $call
            )
        );
        return;
    }

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration: %s email queued for request #%d %s to %s',
            $kind,
            $id,
            $call,
            $to
        )
    );

    require Mojo::IOLoop;

    Mojo::IOLoop->subprocess(
        sub {
            my ($subprocess) = @_;

            return _smtp_send_blocking(
                smtp    => \%smtp,
                to      => $to,
                subject => $arg{subject},
                body    => $arg{body},
            );
        },
        sub {
            my ($subprocess, $err, @result) = @_;

            if ($err) {
                $err =~ s/\s+$//;

                DXLog::LogDbg(
                    'err',
                    sprintf(
                        'DXReg: %s email failed for request #%d %s to %s: %s',
                        $kind,
                        $id,
                        $call,
                        $to,
                        $err
                    )
                );
                return;
            }

            my ($ok, $send_err) = @result;

            if ($ok) {
                DXLog::LogDbg(
                    'registration',
                    sprintf(
                        'registration: %s email sent for request #%d %s to %s',
                        $kind,
                        $id,
                        $call,
                        $to
                    )
                );
            } else {
                DXLog::LogDbg(
                    'err',
                    sprintf(
                        'DXReg: %s email failed for request #%d %s to %s: %s',
                        $kind,
                        $id,
                        $call,
                        $to,
                        $send_err || 'unknown SMTP error'
                    )
                );
            }
        }
    );

    return;
}


# ------------------------------------------------------------
# _smtp_send_blocking
#
# CHILD PROCESS ONLY.
# Never call this directly from request/accept/reject.
# ------------------------------------------------------------

sub _smtp_send_blocking
{
    my (%arg) = @_;

    my $cfg     = $arg{smtp};
    my $to      = $arg{to};
    my $subject = $arg{subject} // '';
    my $body    = $arg{body}    // '';

    my $smtp;
    my $stage = 'initialisation';

    # Net::SMTP timeouts do not necessarily protect every operation.
    # This alarm is inside the subprocess only, never in the DXSpider
    # main process. It guarantees the worker cannot remain stuck forever.
    local $SIG{ALRM} = sub {
        die "SMTP hard timeout during $stage\n";
    };

    alarm 30;

    my ($ok, $err);

    eval {
        $stage = 'connection';

        if ($cfg->{port} == 465) {
            require Net::SMTP::SSL;

            $smtp = Net::SMTP::SSL->new(
                $cfg->{host},
                Port    => $cfg->{port},
                Hello   => 'localhost',
                Timeout => 15,
                Debug   => 0,
            );

            die 'SMTP SSL connection failed' unless $smtp;
        } else {
            require Net::SMTP;

            $smtp = Net::SMTP->new(
                $cfg->{host},
                Port    => $cfg->{port},
                Hello   => 'localhost',
                Timeout => 15,
                Debug   => 0,
            );

            die 'SMTP connection failed' unless $smtp;

            $stage = 'STARTTLS';
            die 'SMTP STARTTLS failed' unless $smtp->starttls;
        }

        if (defined $cfg->{user} && length $cfg->{user}) {
            require Authen::SASL;

            $stage = 'AUTH';

            my $sasl = Authen::SASL->new(
                mechanism => 'PLAIN LOGIN',
                callback  => {
                    user => $cfg->{user},
                    pass => defined $cfg->{pass} ? $cfg->{pass} : '',
                },
            );

            my $auth_ok = $smtp->auth($sasl);
            die 'SMTP authentication failed' unless $auth_ok;
        }

        $stage = 'MAIL FROM';
        die 'SMTP MAIL FROM failed'
            unless $smtp->mail($cfg->{from});

        $stage = 'RCPT TO';
        die "SMTP RCPT TO failed for $to"
            unless $smtp->to($to);

        $stage = 'MIME encoding';

        # Templates are decoded as Perl Unicode strings. Never pass those
        # character strings directly to Net::SMTP sockets. Encode the body
        # to UTF-8 bytes and then MIME Base64 so SMTP receives ASCII only.
        my $subject_header = _mime_header_utf8($subject);
        my $body_b64 = encode_base64(
            encode('UTF-8', $body),
            "\r\n"
        );

        $stage = 'DATA';
        die 'SMTP DATA command failed'
            unless $smtp->data();

        $stage = 'message headers';
        $smtp->datasend("From: $cfg->{from}\r\n");
        $smtp->datasend("To: $to\r\n");
        $smtp->datasend("Subject: $subject_header\r\n");
        $smtp->datasend("MIME-Version: 1.0\r\n");
        $smtp->datasend("Content-Type: text/plain; charset=UTF-8\r\n");
        $smtp->datasend("Content-Transfer-Encoding: base64\r\n");
        $smtp->datasend("\r\n");

        $stage = 'message body';
        $smtp->datasend($body_b64);

        $stage = 'DATA end';
        die 'SMTP DATA end failed'
            unless $smtp->dataend();

        # The message is already accepted after dataend().
        # Do not let QUIT delay completion of the notification worker.
        $stage = 'QUIT';
        eval {
            local $SIG{ALRM} = sub { die "SMTP QUIT timeout\n" };
            alarm 2;
            $smtp->quit();
            alarm 0;
        };

        $ok = 1;
    };

    $err = $@;

    alarm 0;

    unless ($ok) {
        $err ||= "unknown SMTP error during $stage";
        $err =~ s/\s+$//;

        # Best effort cleanup only; never wait here.
        eval {
            local $SIG{ALRM} = sub { die "cleanup timeout\n" };
            alarm 1;
            $smtp->close() if $smtp;
            alarm 0;
        };

        return (0, $err);
    }

    return (1, undef);
}


# ------------------------------------------------------------
# _mime_header_utf8
#
# Encode non-ASCII mail subjects using RFC 2047 encoded-word syntax.
# ASCII-only subjects are returned unchanged.
# ------------------------------------------------------------

sub _mime_header_utf8
{
    my ($value) = @_;

    $value = '' unless defined $value;

    return $value
        unless $value =~ /[^\x00-\x7f]/;

    return '=?UTF-8?B?'
        . encode_base64(encode('UTF-8', $value), '')
        . '?=';
}


# ------------------------------------------------------------
# _queue_telegram
#
# Native non-blocking Mojo::UserAgent request.
# HTML mode is enabled so templates can use <b>...</b>.
# Dynamic template variables are HTML-escaped before substitution.
# ------------------------------------------------------------

sub _queue_telegram
{
    my (%arg) = @_;

    my $id   = $arg{request_id};
    my $call = $arg{call} || '-';

    unless (
        defined $main::reg_telegram_token
        && length $main::reg_telegram_token
    ) {
        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: Telegram not queued for request #%d %s: token is not configured',
                $id,
                $call
            )
        );
        return;
    }

    unless (
        defined $main::reg_telegram_chatid
        && length $main::reg_telegram_chatid
    ) {
        DXLog::LogDbg(
            'err',
            sprintf(
                'DXReg: Telegram not queued for request #%d %s: chat ID is not configured',
                $id,
                $call
            )
        );
        return;
    }

    require Mojo::UserAgent;

    # Keep one UA alive for the lifetime of DXReg. A lexical UA created
    # only inside this sub would be destroyed as soon as the function
    # returns, cancelling its still-running asynchronous transaction.
    unless ($telegram_ua) {
        $telegram_ua = Mojo::UserAgent->new;
        $telegram_ua->connect_timeout(10);
        $telegram_ua->request_timeout(20);
    }

    my $url =
        'https://api.telegram.org/bot'
        . $main::reg_telegram_token
        . '/sendMessage';

    DXLog::LogDbg(
        'registration',
        sprintf(
            'registration: Telegram queued for request #%d %s',
            $id,
            $call
        )
    );

    $telegram_ua->post(
        $url => form => {
            chat_id    => $main::reg_telegram_chatid,
            text       => $arg{text},
            parse_mode => 'HTML',
        } => sub {
            my ($ua, $tx) = @_;

            # Do not call ->result until transport errors have been checked,
            # because ->result may throw for failed/incomplete transactions.
            if (my $txerr = $tx->error) {
                my $message = ref($txerr) eq 'HASH'
                    ? ($txerr->{message} // 'unknown transport error')
                    : "$txerr";

                DXLog::LogDbg(
                    'err',
                    sprintf(
                        'DXReg: Telegram failed for request #%d %s: %s',
                        $id,
                        $call,
                        $message
                    )
                );
                return;
            }

            my $res = eval { $tx->result };

            if ($@ || !$res) {
                my $err = $@ || 'no HTTP response';
                $err =~ s/\s+$//;

                DXLog::LogDbg(
                    'err',
                    sprintf(
                        'DXReg: Telegram failed for request #%d %s: %s',
                        $id,
                        $call,
                        $err
                    )
                );
                return;
            }

            unless ($res->is_success) {
                DXLog::LogDbg(
                    'err',
                    sprintf(
                        'DXReg: Telegram failed for request #%d %s: HTTP %s %s',
                        $id,
                        $call,
                        $res->code // '-',
                        $res->message // '-'
                    )
                );
                return;
            }

            my $payload = eval { $res->json };

            if (
                ref($payload) eq 'HASH'
                && exists $payload->{ok}
                && !$payload->{ok}
            ) {
                my $description =
                    $payload->{description}
                    || 'API returned ok=false';

                DXLog::LogDbg(
                    'err',
                    sprintf(
                        'DXReg: Telegram failed for request #%d %s: %s',
                        $id,
                        $call,
                        $description
                    )
                );
                return;
            }

            DXLog::LogDbg(
                'registration',
                sprintf(
                    'registration: Telegram sent for request #%d %s',
                    $id,
                    $call
                )
            );
        }
    );

    return;
}


# ------------------------------------------------------------
# Templates
#
# Mail template format:
#
#   Subject: Some subject using $CALL
#
#   Body text...
#
# Telegram templates contain only the message body and may use
# basic Telegram HTML markup such as <b>...</b>.
# ------------------------------------------------------------

sub _load_mail_template
{
    my ($name, $request, $password) = @_;

    my ($ok, $raw_or_err) = _read_template(
        $name,
        $request->{language}
    );

    return (0, undef, $raw_or_err) unless $ok;

    my $raw = $raw_or_err;

    my ($subject, $body);

    if ($raw =~ /\ASubject:\s*(.*?)\r?\n(?:\r?\n)?(.*)\z/s) {
        $subject = $1;
        $body    = $2;
    } else {
        return (
            0,
            undef,
            "mail template $name does not start with 'Subject:'"
        );
    }

    $subject = _render_template($subject, $request, $password, 0);
    $body    = _render_template($body,    $request, $password, 0);

    return (1, $subject, $body);
}


sub _load_text_template
{
    my ($name, $request, $password, $html_escape) = @_;

    my ($ok, $raw_or_err) = _read_template(
        $name,
        $request->{language}
    );

    return (0, $raw_or_err) unless $ok;

    return (
        1,
        _render_template(
            $raw_or_err,
            $request,
            $password,
            $html_escape
        )
    );
}


sub _read_template
{
    my ($name, $language) = @_;

    $language = uc($language // 'EN');

    return (0, 'invalid template name')
        unless defined $name && $name =~ /^[A-Za-z0-9_]+$/;

    return (0, 'invalid template language')
        unless $language =~ /^[A-Z]{2}$/;

    my $dir = $main::reg_template_dir
        || "$main::local_data/reg_templates";

    my $file = "$dir/$name.$language";

    if (!-e $file && $language ne 'EN') {
        $file = "$dir/$name.EN";
    }

    return (0, "template not found: $file")
        unless -e $file;

    open my $fh, '<:encoding(UTF-8)', $file
        or return (0, "cannot open template $file: $!");

    local $/;
    my $raw = <$fh>;

    close $fh
        or return (0, "cannot close template $file: $!");

    return (0, "template is empty: $file")
        unless defined $raw && length $raw;

    return (1, $raw);
}


sub _render_template
{
    my ($text, $request, $password, $html_escape) = @_;

    my $requested = @{ $request->{requested_ssids} || [] }
        ? join(',', @{ $request->{requested_ssids} })
        : '-';

    my $accepted = ref($request->{accepted_ssids}) eq 'ARRAY'
        && @{ $request->{accepted_ssids} }
        ? join(',', @{ $request->{accepted_ssids} })
        : '-';

    my %vars = (
        CALL            => $request->{call}         // '',
        EMAIL           => $request->{email}        // '',
        LANGUAGE        => $request->{language}     // '',
        REQUEST_ID      => $request->{id}           // '',
        REQUESTED_SSIDS => $requested,
        ACCEPTED_SSIDS  => $accepted,
        SSID_LIST       => $accepted ne '-' ? $accepted : $requested,
        SOURCE          => $request->{source}       // '',
        IP              => $request->{ip}           // '',
        NOTE            => $request->{note}         // '',
        NODE            => $main::mycall            // '',
        PASSWORD        => defined $password ? $password : '',
    );

    if ($html_escape) {
        for my $key (keys %vars) {
            $vars{$key} = _html_escape($vars{$key});
        }
    }

    $text =~ s/\$([A-Z_]+)/exists $vars{$1} ? $vars{$1} : "\$$1"/ge;

    return $text;
}


sub _html_escape
{
    my ($value) = @_;

    $value = '' unless defined $value;

    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;

    return $value;
}


# ------------------------------------------------------------
# _base_call
# ------------------------------------------------------------

sub _base_call
{
    my ($call) = @_;

    $call = uc($call // '');
    $call =~ s/-\d+$//;

    return $call;
}


# ------------------------------------------------------------
# _current_registered_ssids
#
# SQL DXUser::get_all_calls() does not currently return a call list,
# so for the bounded SSID namespace the reliable approach is simply
# to inspect BASE-1 .. BASE-99.
# ------------------------------------------------------------

sub _current_registered_ssids
{
    my ($base) = @_;

    my @ssids;

    for my $ssid (1 .. 99) {
        my $ref = DXUser::get_current("$base-$ssid");

        next unless $ref;
        next unless $ref->registered;

        push @ssids, $ssid;
    }

    return @ssids;
}


# ------------------------------------------------------------
# _generate_password
#
# Cryptographically strong bytes are read from /dev/urandom.
# Ambiguous characters are deliberately excluded.
#
# Automatic generation only; this does not impose a password
# length rule on passwords manually selected by a user.
# ------------------------------------------------------------

sub _generate_password
{
    my $length = $main::reg_password_length || 10;

    return (0, 'invalid reg_password_length')
        unless $length =~ /^\d+$/ && $length >= 1 && $length <= 128;

    my $alphabet
        = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
        . 'abcdefghijkmnopqrstuvwxyz'
        . '23456789'
        . '.-=';

    my $alen  = length($alphabet);
    my $limit = 256 - (256 % $alen);
    my $pass  = '';

    open my $fh, '<:raw', '/dev/urandom'
        or return (0, "cannot open /dev/urandom: $!");

    while (length($pass) < $length) {
        my $buf = '';
        my $need = ($length - length($pass)) * 2;
        $need = 16 if $need < 16;

        my $n = sysread($fh, $buf, $need);

        unless (defined $n && $n > 0) {
            my $err = $!;
            close $fh;
            return (0, "cannot read /dev/urandom: $err");
        }

        for my $byte (unpack('C*', $buf)) {
            next if $byte >= $limit;

            $pass .= substr($alphabet, $byte % $alen, 1);

            last if length($pass) >= $length;
        }
    }

    close $fh
        or return (0, "cannot close /dev/urandom: $!");

    return (1, $pass);
}


# ------------------------------------------------------------
# _rollback_dxusers
#
# Best-effort rollback for accept_request().
# Password values are never logged.
# ------------------------------------------------------------

sub _rollback_dxusers
{
    my ($snapshots) = @_;

    for my $s (reverse @$snapshots) {
        eval {
            if ($s->{existed}) {
                my $ref = DXUser::get_current($s->{call});
                $ref ||= DXUser->alloc($s->{call});

                if ($s->{registered_exists}) {
                    $ref->{registered} = $s->{registered};
                } else {
                    delete $ref->{registered};
                }

                if ($s->{passwd_exists}) {
                    $ref->{passwd} = $s->{passwd};
                } else {
                    delete $ref->{passwd};
                }

                $ref->put();
            } else {
                my $ref = DXUser::get_current($s->{call});
                DXUser::del($ref) if $ref;
            }
        };

        if ($@) {
            my $err = $@;
            $err =~ s/\s+$//;

            DXLog::LogDbg(
                'err',
                "DXReg: rollback failed for $s->{call}: $err"
            );
        }
    }

    return;
}



# ------------------------------------------------------------
# _rollback_remove_dxusers
# ------------------------------------------------------------

sub _rollback_remove_dxusers
{
    my ($snapshots) = @_;

    for my $s (reverse @$snapshots) {
        eval {
            my $ref = DXUser::get_current($s->{call})
                or die "DXUser $s->{call} missing during rollback";

            if ($s->{registered_exists}) {
                $ref->{registered} = $s->{registered};
            } else {
                delete $ref->{registered};
            }

            if ($s->{passwd_exists}) {
                $ref->{passwd} = $s->{passwd};
            } else {
                delete $ref->{passwd};
            }

            $ref->put();
        };

        if ($@) {
            my $err = $@;
            $err =~ s/\s+$//;

            DXLog::LogDbg(
                'err',
                "DXReg: remove rollback failed for $s->{call}: $err"
            );
        }
    }

    return;
}


sub _validate_call
{
    my ($call) = @_;

    return (0, 'invalid callsign')
        unless is_callsign($call);

    if ($call =~ /-(\d+)$/) {
        my $ssid = $1;

        return (0, 'SSID 0 is not valid for registration')
            if $ssid eq '0';

        return (
            0,
            'SSIDs with leading zeroes are not valid for registration'
        ) if length($ssid) > 1
            && $ssid =~ /^0/;

        return (0, 'SSID must be between 1 and 99')
            if $ssid < 1 || $ssid > 99;
    }

    return (1, undef);
}


sub _validate_email
{
    my ($email) = @_;

    return (
        $email =~ /^[^\s\@]+\@[^\s\@]+\.[^\s\@]+$/
    ) ? 1 : 0;
}


sub _validate_ssids
{
    my @ssids = @_;

    my %seen;
    my @clean;

    for my $ssid (@ssids) {
        return (0, 'SSID is undefined', undef)
            unless defined $ssid;

        my $raw = "$ssid";

        return (0, "invalid SSID '$raw'", undef)
            unless $raw =~ /^\d+$/;

        return (
            0,
            "SSID '$raw' must not contain leading zeroes",
            undef
        ) if length($raw) > 1
            && $raw =~ /^0/;

        my $n = int($raw);

        return (
            0,
            'SSID 0 is not valid for registration',
            undef
        ) if $n == 0;

        return (
            0,
            "SSID '$raw' must be between 1 and 99",
            undef
        ) if $n < 1 || $n > 99;

        next if $seen{$n}++;

        push @clean, int($n);
    }

    @clean = sort { $a <=> $b } @clean;

    return (1, undef, \@clean);
}


sub _data_file
{
    return "$main::local_data/registration.json";
}


1;

__END__
