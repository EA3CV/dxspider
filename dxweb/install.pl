#!/usr/bin/env perl
#
# DXSpider Web installer
#
# Installs DXWeb using a staged copy and preserves the previous tree.
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#
# DXSpider Web installer 2.7.3
# Date: 2026-10-14

use strict;
use warnings;
use File::Copy qw(move);
use File::Basename qw(dirname);
use File::Spec;
use File::Path qw(remove_tree);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $src = shift // '.';
my $root = $ENV{DXSPIDER_ROOT} // abs_path(
    File::Spec->catdir(dirname(abs_path(__FILE__)), '..')
);
my $dst = shift // File::Spec->catdir($root, 'dxweb');

die "source missing\n" unless -f "$src/app.pl";
die "invalid DXSpider root: $root\n" unless -d "$root/perl";

my $src_real = abs_path($src)
    or die "Cannot resolve source: $src\n";

die "destination must not be a symlink\n" if -l $dst;

my $parent = dirname($dst);
my $parent_real = abs_path($parent)
    or die "Cannot resolve destination parent: $parent\n";

my ($name) = File::Spec->splitpath($dst);
my @parts = File::Spec->splitpath($dst);
$name = $parts[2];

die "invalid destination name\n"
    unless length($name) && $name ne '.' && $name ne '..';

$dst = File::Spec->catdir($parent_real, $name);

my $dst_real = abs_path($dst);
die "source and destination are identical\n"
    if defined($dst_real) && $src_real eq $dst_real;

die "destination cannot contain source\n"
    if index("$src_real/", "$dst/") == 0;

die "source cannot contain destination\n"
    if index("$dst/", "$src_real/") == 0;

my $stage = tempdir(
    '.dxweb-stage-XXXXXXXX',
    DIR     => $parent_real,
    CLEANUP => 0
);

my $staged = "$stage/dxweb";
my $backup;
my $previous = -e $dst;

sub cleanup_stage {
    remove_tree($stage) if -d $stage;
}

if (system('cp', '-a', '--', $src_real, $staged) != 0) {
    cleanup_stage();
    die "staging copy failed\n";
}

unless (-f "$staged/app.pl" && -f "$staged/start.pl") {
    cleanup_stage();
    die "staged application incomplete\n";
}

unless (chmod 0755, "$staged/start.pl") {
    cleanup_stage();
    die "chmod staged start.pl failed: $!\n";
}

if ($previous) {
    $backup = "$dst.pre-2.7.3-" . time;
    die "backup already exists: $backup\n"
        if -e $backup || -l $backup;

    unless (move($dst, $backup)) {
        cleanup_stage();
        die "backup failed: $!\n";
    }
}

unless (move($staged, $dst)) {
    my $error = "$!";
    if ($previous) {
        move($backup, $dst)
            or die "activation failed ($error); restore failed: $!\n";
    }
    cleanup_stage();
    die "activation failed: $error\n";
}

cleanup_stage();

print "Installed $dst\n";
print "Backup: " . ($backup // 'none') . "\n";
