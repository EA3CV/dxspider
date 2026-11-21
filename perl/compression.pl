#!/usr/bin/env perl

#
# DXSpider debug and monthly log archive maintenance.
#
# Copyright (c) 2026 Dirk Koopman
#
# Add the following line to crontab:
#
#   10 0 * * * spawn("$main::root/perl/compression.pl")
#
# Requires gzip; optional DX_COMPRESSION_MAX_FILES (default 100).
#

use strict;
use warnings;
use Cwd qw(realpath);
use File::Basename qw(dirname);
use File::Spec;
use Fcntl qw(:flock);
use Time::Local qw(timegm);

my $script = realpath($0) or die "Cannot resolve script path: $!\n";
my $root = dirname(dirname($script));
my $data = File::Spec->catdir($root, 'local_data');
my $tmpdir = File::Spec->catdir($data, 'tmp');
my $limit = $ENV{DX_COMPRESSION_MAX_FILES} // 100;
die "DX_COMPRESSION_MAX_FILES must be 1..10000\n"
    unless $limit =~ /\A[0-9]+\z/ && $limit >= 1 && $limit <= 10000;

my $debug = File::Spec->catdir($data, 'debug');
my $log = File::Spec->catdir($data, 'log');
exit 0 unless -d $debug || -d $log;
die "Missing DXSpider temporary directory: $tmpdir\n" unless -d $tmpdir;

my $lockpath = File::Spec->catfile($tmpdir, 'compression.lock');
open my $lock, '>>', $lockpath or die "Cannot open $lockpath: $!\n";
exit 0 unless flock($lock, LOCK_EX | LOCK_NB);

my @now = gmtime(time);
my $today_midnight = timegm(0, 0, 0, $now[3], $now[4], $now[5]);
my @yesterday = gmtime($today_midnight - 86400);
my $daily_cutoff = sprintf('%04d%03d', $yesterday[5] + 1900, $yesterday[7] + 1);
my ($prev_year, $prev_month) = ($now[5] + 1900, $now[4]);
if ($prev_month == 0) {
    --$prev_year;
    $prev_month = 12;
}
my $monthly_cutoff = sprintf('%04d%02d', $prev_year, $prev_month);

my @candidates;
for my $spec (
    [$debug, 'daily'],
    [$log, 'monthly'],
) {
    my ($base, $kind) = @$spec;
    next unless -d $base && !-l $base;
    opendir my $years, $base or die "Cannot read $base: $!\n";
    while (my $year = readdir $years) {
        next unless $year =~ /\A(?:19|20|21)[0-9]{2}\z/;
        my $dir = File::Spec->catdir($base, $year);
        next unless -d $dir && !-l $dir;
        opendir my $files, $dir or die "Cannot read $dir: $!\n";
        while (my $name = readdir $files) {
            my $key;
            if ($kind eq 'daily') {
                next unless $name =~ /\A([0-9]{3})\.dat\z/;
                my $day = 0 + $1;
                next if $day < 1 || $day > 366;
                my $jan1 = timegm(0, 0, 0, 1, 0, $year - 1900);
                my @check = gmtime($jan1 + ($day - 1) * 86400);
                next unless $check[5] + 1900 == $year;
                $key = sprintf('%04d%03d', $year, $day);
                next unless $key lt $daily_cutoff;
            } else {
                next unless $name =~ /\A(0[1-9]|1[0-2])\.dat\z/;
                $key = sprintf('%04d%02d', $year, $1);
                next unless $key lt $monthly_cutoff;
            }
            my $path = File::Spec->catfile($dir, $name);
            next unless -f $path && !-l $path;
            next if -e "$path.gz" || -l "$path.gz";
            push @candidates, [$key, $path];
        }
        closedir $files;
    }
    closedir $years;
}

@candidates = sort { $a->[0] cmp $b->[0] || $a->[1] cmp $b->[1] } @candidates;
my ($done, $failed, $attempted) = (0, 0, 0);
for my $item (@candidates) {
    last if $attempted >= $limit;
    my $file = $item->[1];
    next unless -f $file && !-l $file && !-e "$file.gz" && !-l "$file.gz";
    ++$attempted;
    my $rc = system('gzip', '-9', '--', $file);
    if ($rc != 0) {
        warn "gzip failed for $file (status $rc)\n";
        ++$failed;
    } else {
        ++$done;
    }
}
print "compression: compressed=$done pending=" . (@candidates - $done) . " failed=$failed\n";
exit($failed ? 1 : 0);
