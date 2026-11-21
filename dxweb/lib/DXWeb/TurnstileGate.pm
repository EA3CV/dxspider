#
# DXSpider Web - Perl module
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

package DXWeb::TurnstileGate;

use strict;
use warnings;
our $VERSION = '0.05';

# Pure state machine. It does not make network requests and never enables CAPTCHA.
# Caller owns the asynchronous Siteverify request and must release reservations.
sub new {
    my ( $class, %a ) = @_;
    my $limit = $a{max_inflight} // 16;
    die "invalid concurrency limit\n"
      unless $limit =~ /\A[1-9][0-9]*\z/ && $limit <= 1024;
    return bless { max_inflight => $limit, inflight => {}, total => 0 }, $class;
}

sub reserve {
    my ( $self, $client ) = @_;
    return 'invalid_client' unless defined $client && $client =~ /\A[0-9]+\z/;
    return 'already_pending' if $self->{inflight}{$client};
    return 'capacity'        if $self->{total} >= $self->{max_inflight};
    $self->{inflight}{$client} = 1;
    ++$self->{total};
    return 'reserved';
}

sub release {
    my ( $self, $client ) = @_;
    return 0 unless defined $client && delete $self->{inflight}{$client};
    --$self->{total};
    return 1;
}
sub count { $_[0]->{total} }

# No fallback for rejected tokens, bad credentials, or ambiguous replies.
# A separately controlled, bounded server-side outage policy may handle
# unavailable; this module deliberately does NOT authorize that path.
sub decide {
    my ( $class, $result ) = @_;
    return 'deny_ambiguous' unless ref($result) eq 'HASH';
    my $status = $result->{status} // '';
    return 'allow'               if $status eq 'valid';
    return 'deny_invalid'        if $status eq 'invalid';
    return 'deny_configuration'  if $status eq 'configuration_error';
    return 'needs_outage_policy' if $status eq 'unavailable';
    return 'deny_ambiguous';
}
1;
