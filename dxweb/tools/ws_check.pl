#!/usr/bin/env perl
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::IOLoop;

my $url   = shift // 'ws://127.0.0.1:8080/ws';
my $limit = shift // 20;
my $n = 0;
my %seen;
my $done = 0;

sub finish_test {
    my ($tx) = @_;
    return if $done++;

    print "RESULT human=" . ($seen{human} ? 1 : 0)
        . " rbn=" . ($seen{rbn} ? 1 : 0) . "\n";

    $tx->finish if $tx && $tx->is_websocket;
    Mojo::IOLoop->stop if Mojo::IOLoop->is_running;
}

my $ua = Mojo::UserAgent->new;
$ua->websocket($url => sub {
    my ($ua, $tx) = @_;
    die "WebSocket failed: $url\n" unless $tx->is_websocket;

    print "WebSocket connected: $url\n";

    $tx->on(message => sub {
        my ($tx, $msg) = @_;
        return if $done;

        print "$msg\n";
        $seen{human} = 1 if $msg =~ /\"feed\"\s*:\s*\"human\"/;
        $seen{rbn}   = 1 if $msg =~ /\"feed\"\s*:\s*\"rbn\"/;
        ++$n;

        finish_test($tx) if ($seen{human} && $seen{rbn}) || $n >= $limit;
    });

    $tx->on(finish => sub {
        finish_test(undef) unless $done;
    });
});

Mojo::IOLoop->start;
exit(($seen{human} && $seen{rbn}) ? 0 : 2);
