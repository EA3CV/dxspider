#!/usr/bin/env perl
#
# DXSpider Web - Perl script
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Spec;
my $manager = $ENV{DXWEB_MENU_MANAGER}
  // File::Spec->catfile( $FindBin::Bin, 'dxweb-manager.pl' );
die "Manager missing: $manager\n" unless -f $manager;
my $root = $ENV{DXWEB_MENU_ROOT}
  // abs_path( File::Spec->catdir( $FindBin::Bin, '..' ) );
die "Root missing\n" unless defined($root) && -d $root;
sub ask {
    my ( $prompt, $default ) = @_;
    print "$prompt", defined($default) ? " [$default]" : "", ": ";
    my $line = <STDIN>;
    die "Input closed\n" unless defined $line;
    $line =~ s/^\s+|\s+$//g;
    return length($line) ? $line : ( $default // '' );
}

sub choose {
    my ( $prompt, $allowed, $default ) = @_;
    while (1) {
        my $v = ask( $prompt, $default );
        return $v if grep { $_ eq $v } @$allowed;
        print "Invalid selection.\n";
    }
}
sub run_manager {
    my (@args) = @_;
    print "\nManager: ",
      join( ' ', map { /\A--(?:key|secret)\z/ ? '[REDACTED]' : $_ } @args ),
      "\n";
    system( $^X, $manager, @args );
    my $rc = $? == -1 ? 127 : ( $? & 127 ) ? 128 + ( $? & 127 ) : $? >> 8;
    print "Manager exit status: $rc\n";
    return $rc;
}

sub safe_path {
    my ($p) = @_;
    return
         defined($p)
      && $p =~ m{\A/[A-Za-z0-9_./-]+\z}
      && $p !~ m{(?:^|/)\.\.(?:/|$)};
}

sub deployment {
    my ($component) = @_;
    my $mode =
      choose( 'Access: 1 Direct, 2 Nginx', [qw(1 2)], '1' ) eq '1'
      ? 'direct'
      : 'nginx';
    my $scheme =
      choose( 'Scheme: 1 HTTP, 2 HTTPS', [qw(1 2)], '1' ) eq '1'
      ? 'http'
      : 'https';
    my @extra;
    if ( $scheme eq 'https' ) {
        my $hostname = ask('Public hostname');
        my $cert     = ask('Absolute certificate path');
        my $key      = ask('Absolute private key path');
        unless ( $hostname =~ /\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/
            && safe_path($cert)
            && safe_path($key)
            && -f $cert
            && -f $key )
        {
            print "Invalid hostname/certificate/key; cancelled.\n";
            return;
        }
        @extra = ( '--hostname', $hostname, '--cert', $cert, '--key', $key );
    }
    my $identity_choice = choose(
        'Service user/group: 1 Preserve/detect, 2 Specify explicitly',
        [qw(1 2)], '1'
    );
    if ( $identity_choice eq '2' ) {
        my $user  = ask('Service user');
        my $group = ask('Service group');
        for my $name ( $user, $group ) {
            unless ( $name =~ /\A[a-z_][a-z0-9_-]*\z/ ) {
                print "Invalid service user/group; cancelled.\n";
                return;
            }
        }
        unless ( defined(getpwnam($user)) && defined(getgrnam($group)) ) {
            print "Service user/group does not exist; cancelled.\n";
            return;
        }
        push @extra, '--user', $user, '--group', $group;
    }
    my @base = (
        '--root', $root, '--components', $component,
        '--mode', $mode, '--scheme',     $scheme,
        @extra
    );
    return if run_manager( '--action', 'plan', @base );
    return
      unless choose( 'Apply installation/update? 1 Yes, 2 No', [qw(1 2)], '2' )
      eq '1';
    run_manager( '--action', 'install', @base, '--apply' );
}
sub rollback {
    my $backup = ask('Absolute backup transaction directory');
    unless ( safe_path($backup) && -d $backup && -f "$backup/manifest.json" ) {
        print "Invalid transaction directory.\n";
        return;
    }
    return if run_manager( '--action', 'rollback', '--backup', $backup );
    return
      unless choose( 'Apply rollback? 1 Yes, 2 No', [qw(1 2)], '2' ) eq '1';
    run_manager( '--action', 'rollback', '--backup', $backup, '--apply' );
}
sub turnstile {
    my $tool =
      File::Spec->catfile( $FindBin::Bin, 'tools', 'turnstile-config.pl' );
    while (1) {
        print "\nCloudflare Turnstile — DXWeb registration / DXWeb Admin login\n";
        print
"1. Setup instructions\n2. Show configuration status\n3. Store / replace keys\n4. Enable Turnstile\n5. Disable Turnstile\n6. Back\n";
        my $n = choose( 'Selection', [qw(1 2 3 4 5 6)], '6' );
        last if $n eq '6';
        if ( $n eq '1' ) {
            print "1. Sign up: https://dash.cloudflare.com/sign-up\n";
            print
"2. Create a Managed widget for the hostname(s) used by DXWeb and/or DXWeb Admin.\n";
            print
"3. Add all protected hostnames to the widget; store Site Key and Secret Key (option 3).\n";
            print
"4. Enable after verifying Turnstile support in the installed web application(s).\n";
            next;
        }
        if ( $n eq '2' ) { system( $^X, $tool, '--status' ); next; }
        if ( $n eq '4' || $n eq '5' ) {
            my $action = $n eq '4' ? 'enable' : 'disable';
            next
              unless choose( "Confirm $action? 1 Yes, 2 No", [qw(1 2)], '2' )
              eq '1';
            system( $^X, $tool, '--' . $action );
            next;
        }
        print "Keys will be stored with protection disabled.\n";
        next
          unless choose( 'Proceed with key storage? 1 Yes, 2 No', [qw(1 2)],
            '2' ) eq '1';
        system( $^X, $tool, '--configure' );
    }
}
sub component_menu {
    my ( $component, $label ) = @_;
    while (1) {
        print
          "\n$label\n1. Service status\n2. Plan / install / update\n3. Back\n";
        my $n = choose( 'Selection', [qw(1 2 3)], '3' );
        last if $n eq '3';
        run_manager( '--action', 'status', '--components', $component )
          if $n eq '1';
        deployment($component) if $n eq '2';
    }
}
print
  "DXWeb interactive manager v0.09 (existing transactional engine preserved)\n";
while (1) {
    print
"\n1. DXWeb\n2. DXWeb Admin\n3. Both applications\n4. Cloudflare Turnstile\n5. Rollback (dry-run first)\n6. Exit\n";
    my $n = choose( 'Selection', [qw(1 2 3 4 5 6)], '6' );
    last if $n eq '6';
    if ( $n eq '4' ) { turnstile(); next; }
    if ( $n eq '5' ) { rollback();  next; }
    my $component = $n eq '1' ? 'dxweb' : $n eq '2' ? 'admin' : 'both';
    my $label =
      $n eq '1' ? 'DXWeb' : $n eq '2' ? 'DXWeb Admin' : 'Both applications';
    component_menu( $component, $label );
}
print "Bye.\n";
