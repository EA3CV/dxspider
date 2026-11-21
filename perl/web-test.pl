#!/usr/bin/env perl

#
#  web-test.pl — DXSpider WebCluster protocol test client
#
#  Description:
#    Interactive test and diagnostic client for the DXSpider WebCluster
#    interface.
#
#    The client connects to the DXSpider internal Web endpoint using IntMsg,
#    identifies itself as a WebCluster connection, negotiates the WebCluster
#    JSON protocol and allows protocol messages to be generated interactively.
#
#    It can be used to:
#      - Test the #WEB-n connection and WebCluster protocol negotiation
#      - Add and remove WebCluster users
#      - Submit test DX spots
#      - Submit local, full or sysop announcements
#      - Send raw JSON protocol messages
#      - Observe HUMAN, RBN and announcement feeds received from DXSpider
#      - Check legacy CC11 feed compatibility during regression testing
#
#    This is a development and diagnostic utility. It is not required for
#    normal DXSpider operation.
#
#  Usage:
#    Run from the command line:
#
#      perl /spider/perl/web-test.pl
#
#    By default it connects to:
#
#      127.0.0.1:27754
#
#    The destination can be changed with:
#
#      DXSPIDER_CLUSTER_ADDR
#      DXSPIDER_CLUSTER_PORT
#
#    The DXSpider root directory defaults to /spider and can be changed with:
#
#      DXSPIDER_ROOT
#
#  Interactive commands:
#
#      add CALL IP [true|false]
#          Add a WebCluster user.  The optional boolean indicates whether
#          the user is authenticated.  The default is false.
#
#      del CALL
#          Remove a WebCluster user.
#
#      spot CALL FREQ DXCALL [COMMENT]
#          Submit a DX spot on behalf of CALL.
#
#      ann CALL local|full|sysop TEXT
#          Submit an announcement on behalf of CALL.
#
#      raw JSON
#          Send a raw JSON protocol message using the assigned #WEB-n
#          connection.
#
#      quit
#          Disconnect and terminate the test client.
#
#  Installation:
#    Included in the DXSpider source tree as:
#
#      /spider/perl/web-test.pl
#
#  Requirements:
#    - Perl
#    - Mojo::IOLoop
#    - DXSpider IntMsg
#    - DXSpider DXJSON
#    - Access to the DXSpider internal cluster/Web port
#
#  Kin EA3CV
#  v1.1 20262802
#
#  Note:
#    Developed as part of the DXSpider Web/WebCluster integration work.
#    The program deliberately exercises both Protocol v1 JSON feeds and
#    selected legacy CC11 paths for regression testing.
#

use strict;
use warnings;

our ($root, $clusteraddr, $clusterport);
BEGIN {
    $root = $ENV{DXSPIDER_ROOT} || '/spider';
    unshift @INC, "$root/perl";
    unshift @INC, "$root/local";
}

use Mojo::IOLoop;
use IntMsg;
use DXJSON ();

$clusteraddr = $ENV{DXSPIDER_CLUSTER_ADDR} || '127.0.0.1';
$clusterport = $ENV{DXSPIDER_CLUSTER_PORT} || 27754;

my $json = DXJSON->new;
my $conn;
my $assigned_call;
my $hello_sent = 0;
my $webcluster_ready = 0;
my $next_id = 1;

sub jenc {
    my ($data) = @_;
    my $s = $json->encode($data);
    die "Cannot encode JSON\n" unless defined $s;
    return $s;
}

sub tx {
    my ($msg) = @_;
    print "TX: $msg\n";
    $conn->send_later($msg);
}

sub send_hello {
    return unless $assigned_call;
    return if $hello_sent++;
    tx("I$assigned_call|" . jenc({
        type => 'hello', role => 'webcluster', version => 1,
    }));
}

sub send_request {
    my ($data) = @_;
    unless ($webcluster_ready && $assigned_call) {
        print "WebCluster protocol not ready yet\n";
        return;
    }
    tx("I$assigned_call|" . jenc($data));
}

sub print_json_summary {
    my ($data) = @_;
    print "JSON:";
    for my $key (sort keys %$data) {
        my $v = $data->{$key};
        if (ref $v eq 'ARRAY') { $v = '[' . scalar(@$v) . ' items]'; }
        elsif (ref $v) { $v = ref($v); }
        elsif (!defined $v) { $v = 'null'; }
        print " $key=$v";
    }
    print "\n";
}

sub decode_feed_json {
    my ($kind, $payload) = @_;
    return unless defined $payload && $payload =~ /^\s*\{/;
    my $data = $json->decode($payload);
    return unless $data && ref $data eq 'HASH';
    my $type = $data->{type} || '';
    my $body = defined $data->{payload} ? $data->{payload} : '';
    print uc($kind) . " JSON: type=$type payload=$body\n";
    return 1;
}

sub rec_socket {
    my ($con, $msg, $err) = @_;

    if (defined $err && length $err) {
        print STDERR "Socket error: $err\n";
        Mojo::IOLoop->stop;
        return;
    }
    unless (defined $msg) {
        print "Connection closed by DXSpider\n";
        Mojo::IOLoop->stop;
        return;
    }

    print "RX: $msg\n";

    if ($msg =~ /^C(\#WEB-\d+)$/) {
        $assigned_call = $1;
        print "Assigned Web call: $assigned_call\n";
        return;
    }

    # WebCluster feeds: X=HUMAN spot, R=RBN, N=announcement.
    # After "|" Protocol v1 requires JSON.  Keep legacy decoding only to
    # make regression testing explicit; a v1 JSON feed must never fall to OTHER.
    if ($msg =~ /^([XRN])([^|]+)\|(.*)$/s) {
        my ($frame, $channel, $payload) = ($1, $2, $3);
        my %kind = (X => 'spot', R => 'rbn', N => 'ann');
        my $kind = $kind{$frame};

        if (decode_feed_json($kind, $payload)) {
            return;
        }

        if ($frame eq 'X' && $payload =~ /^CC11\^/) {
            print "HUMAN CC11 (legacy): $payload\n";
            return;
        }
        if ($frame eq 'R' && $payload =~ /^CC11\^/) {
            print "RBN CC11 (legacy): $payload\n";
            return;
        }
        if ($frame eq 'N') {
            print "ANN (legacy): $payload\n";
            return;
        }

        print "FEED PARSE ERROR: frame=$frame channel=$channel payload=$payload\n";
        return;
    }

    if ($msg =~ /^D([^|]+)\|(.*)$/s) {
        my ($call, $payload) = ($1, $2);

        # Backward compatibility with the previous native HUMAN path.
        if ($payload =~ /^CC11\^/) {
            print "HUMAN CC11 (legacy D): $payload\n";
            return;
        }

        unless ($payload =~ /^\s*\{/) {
            print "TEXT: $payload\n";
            if (!$hello_sent && $assigned_call && $payload =~ /dxspider\s*>\s*$/i) {
                print "DXSpider Web startup complete; negotiating WebCluster JSON\n";
                send_hello();
            }
            return;
        }

        my $data = $json->decode($payload);
        if ($data && ref $data eq 'HASH') {
            if (($data->{type} || '') eq 'hello' &&
                ($data->{role} || '') eq 'webcluster' &&
                ($data->{status} || '') eq 'ok') {
                $webcluster_ready = 1;
                print "WebCluster JSON protocol ready\n";
            }
            print_json_summary($data);
        }
        return;
    }

    print "OTHER: $msg\n";
}

sub on_connect {
    print "Connected to $clusteraddr:$clusterport\n";
    tx('A#WEB|webcluster enhanced');
}

sub on_disconnect {
    print "Disconnected\n";
    Mojo::IOLoop->stop if Mojo::IOLoop->is_running;
}

$conn = IntMsg->connect($clusteraddr, $clusterport, rproc => \&rec_socket);
die "Cannot create IntMsg connection to $clusteraddr:$clusterport\n" unless $conn;
$conn->{on_connect} = \&on_connect;
$conn->{on_disconnect} = \&on_disconnect;

Mojo::IOLoop->singleton->reactor->io(\*STDIN => sub {
    my $line = <STDIN>;
    unless (defined $line) {
        $conn->disconnect if $conn;
        Mojo::IOLoop->stop;
        return;
    }
    chomp $line;
    $line =~ s/\r$//;

    if ($line =~ /^\s*quit\s*$/i) {
        $conn->disconnect if $conn;
        Mojo::IOLoop->stop;
        return;
    }

    # add CALL IP [true|false]; default is guest/false.
    if ($line =~ /^\s*add\s+(\S+)\s+(\S+)(?:\s+(true|false|1|0))?\s*$/i) {
        my $auth = defined $3 && $3 =~ /^(?:true|1)$/i ? 1 : 0;
        send_request({
            type => 'user_add', id => $next_id++, call => uc($1), ip => $2,
            authenticated => $auth,
        });
        return;
    }

    if ($line =~ /^\s*del\s+(\S+)\s*$/i) {
        send_request({type => 'user_del', id => $next_id++, call => uc($1)});
        return;
    }

    if ($line =~ /^\s*spot\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+(.*))?\s*$/i) {
        send_request({
            type => 'spot', id => $next_id++, call => uc($1), freq => $2,
            dxcall => uc($3), comment => defined $4 ? $4 : '',
        });
        return;
    }

    if ($line =~ /^\s*ann\s+(\S+)\s+(local|full|sysop)\s+(.+)\s*$/i) {
        send_request({
            type => 'ann', id => $next_id++, call => uc($1),
            scope => lc($2), text => $3,
        });
        return;
    }

    if ($line =~ /^\s*raw\s+(.+)$/i) {
        unless ($assigned_call) {
            print "No assigned #WEB-n yet\n";
            return;
        }
        tx("I$assigned_call|$1");
        return;
    }

    print "Commands: add CALL IP [true|false] | del CALL | spot CALL FREQ DXCALL [COMMENT] | ann CALL local|full|sysop TEXT | raw JSON | quit\n";
})->watch(\*STDIN, 1, 0);

Mojo::IOLoop->start;
exit 0;
