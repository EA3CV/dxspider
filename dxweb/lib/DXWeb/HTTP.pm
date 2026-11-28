package DXWeb::HTTP;

# Shared HTTP response policy for DXWeb and DXWeb Admin.
#
# Security headers, cache policy and the version endpoint live here so the
# two applications cannot drift apart. This module only touches responses;
# it has no knowledge of DXSpider internals.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(install_headers);

sub csp {
    return join '; ',
      "default-src 'self'",
      "base-uri 'none'",
      "object-src 'none'",
      "frame-ancestors 'none'",
      "form-action 'self'",
      "img-src 'self' data: blob:",
      "font-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "script-src 'self' https://challenges.cloudflare.com",
      "frame-src https://challenges.cloudflare.com",
      "connect-src 'self' https://challenges.cloudflare.com";
}

sub install_headers {
    my ($app) = @_;
    die "install_headers requires a Mojolicious app\n" unless $app && ref $app;

    my $csp = csp();

    $app->hook(
        after_dispatch => sub {
            my $c = shift;
            my $res = $c->res;

            # A 101 response has already completed the WebSocket handshake.
            return if ( $res->code || 0 ) == 101;

            my $h = $res->headers;
            $h->header( 'Content-Security-Policy'   => $csp );
            $h->header( 'X-Content-Type-Options'    => 'nosniff' );
            $h->header( 'X-Frame-Options'           => 'DENY' );
            $h->header( 'Referrer-Policy'           => 'no-referrer' );
            $h->header( 'Permissions-Policy'        =>
                  'geolocation=(), camera=(), microphone=(), payment=(), usb=()'
            );
            $h->header( 'Cross-Origin-Opener-Policy' => 'same-origin' );

            my $path = $c->req->url->path->to_string;
            my $v    = $c->req->url->query->param('v');

            if ( $path =~ /\.(?:css|js|mjs|png|jpe?g|gif|svg|ico|woff2?|ttf)$/i )
            {
                $h->cache_control(
                    $v
                    ? 'public, max-age=31536000, immutable'
                    : 'public, max-age=3600'
                );
            }
            elsif ( $path =~ /\.json$/i ) {
                $h->cache_control('no-store');
            }
            elsif ( $path eq '/' || $path =~ /\.html?$/i ) {
                $h->cache_control('no-cache, must-revalidate');
            }
            return;
        }
    );
    return 1;
}

1;
