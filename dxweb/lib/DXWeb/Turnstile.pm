#
# DXSpider Web - Perl module
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

package DXWeb::Turnstile;

use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json);

our $VERSION = '0.07';

# No implicit fail-open. The caller must decide how to handle 'unavailable'.
sub classify {
    my ( $class, $http_ok, $payload, $transport_error, $http_code ) = @_;
    return { status => 'unavailable', reason => 'transport' }
      if $transport_error;

    # A 4xx HTTP error is not evidence of a Cloudflare outage. Fail closed.
    unless ($http_ok) {
        return { status => 'unavailable', reason => 'http_5xx' }
          if defined($http_code) && $http_code =~ /\A5[0-9]{2}\z/;
        return { status => 'ambiguous', reason => 'http_non_5xx' };
    }

    # Missing or malformed Siteverify JSON must never trigger outage fallback.
    return { status => 'ambiguous', reason => 'malformed_response' }
      unless ref($payload) eq 'HASH' && exists( $payload->{success} );
    my $success = $payload->{success};
    return { status => 'ambiguous', reason => 'malformed_success' }
      if ref($success) && !eval {
        $success->isa('JSON::PP::Boolean') || $success->isa('Mojo::JSON::_Bool');
      };
    return { status => 'ambiguous', reason => 'malformed_success' }
      unless defined($success) && ( "$success" eq '0' || "$success" eq '1' );
    return { status => 'valid' } if $success;
    my $codes = $payload->{'error-codes'};
    return { status => 'ambiguous', reason => 'malformed_error_codes' }
      if defined($codes) && ref($codes) ne 'ARRAY';
    my %errors =
      map { defined($_) && !ref($_) ? ( $_ => 1 ) : () } @{ $codes || [] };
    return { status => 'configuration_error', reason => 'secret' }
      if $errors{'invalid-input-secret'} || $errors{'missing-input-secret'};
    return { status => 'invalid', reason => 'token' };
}

sub new {
    my ( $class, %arg ) = @_;
    die "secret required\n" unless defined $arg{secret} && length $arg{secret};
    my $ua = $arg{ua} || Mojo::UserAgent->new;
    $ua->connect_timeout(2);
    $ua->request_timeout(5);
    return bless {
        secret   => $arg{secret},
        ua       => $ua,
        endpoint => $arg{endpoint}
          || 'https://challenges.cloudflare.com/turnstile/v0/siteverify'
    }, $class;
}

sub verify_async {
    my ( $self, %arg ) = @_;
    my $cb    = $arg{callback} or die "callback required\n";
    my $token = $arg{token} // '';
    return $cb->( { status => 'invalid', reason => 'missing_token' } )
      unless length($token) && length($token) <= 2048;
    my %form = ( secret => $self->{secret}, response => $token );
    $form{remoteip} = $arg{remoteip}
      if defined $arg{remoteip} && length $arg{remoteip};

    # Retain the verifier and its UserAgent until the asynchronous request ends.
    # The caller normally holds the verifier only in a lexical variable.
    my $keepalive = $self;
    my $completed = 0;
    my $finish    = sub {
        return if $completed++;
        my ($result) = @_;
        $cb->($result);
    };
    my $started = eval {
        $self->{ua}->post(
            $self->{endpoint} => form => \%form => sub {
                my ( $ua, $tx ) = @_;
                my $hold   = $keepalive;    # keep UA alive throughout callback
                my $result = eval {
                    my $error           = $tx->error;
                    my $res             = $tx->res;
                    my $code            = $res ? $res->code : undef;
                    my $transport_error = $error && !$code;
                    my $payload         = $code ? eval { $res->json } : undef;
                    __PACKAGE__->classify(
                        $res && $res->is_success, $payload,
                        $transport_error,         $code
                    );
                };
                $result = { status => 'unavailable', reason => 'transport' }
                  if $@ || ref($result) ne 'HASH';
                $finish->($result);
            }
        );
        1;
    };
    $finish->( { status => 'unavailable', reason => 'transport' } )
      unless $started;

}
1;
