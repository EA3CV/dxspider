#!/usr/bin/env perl
# DXSpider Web installer 2.6.0
# Date: 2026-09-16
use strict;use warnings;use File::Copy qw(move);
my$src=shift||'.';my$dst=shift||'/spider/dxweb';my$bak="$dst.pre-2.6.0-".time;
die"source missing\n" unless-f"$src/app.pl";
move($dst,$bak) or die"backup failed: $!\n" if-e$dst;
system('cp','-a',$src,$dst)==0 or die"copy failed\n"; chmod 0755,"$dst/start.sh" or die"chmod start.sh: $!\n";
print"Installed $dst\nBackup: $bak\n";
