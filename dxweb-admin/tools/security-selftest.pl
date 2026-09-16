#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..', '..'));
sub slurp { my($f)=@_; open my $h,'<',$f or die "$f: $!\n"; local $/; <$h> }
my $w = slurp(File::Spec->catfile($root,'perl','Web.pm'));
my $a = slurp(File::Spec->catfile($root,'dxweb-admin','admin.pl'));

my @tests = (
 ['technical #WEB channel forced priv 0', $w =~ /\$self->\{priv\}\s*=\s*0;/],
 ['public actor privilege remains zero', $w =~ /my \$effective_priv = \$is_admin \? \(\$user->priv \|\| 0\) : 0;/],
 ['admin HELLO loopback enforced in DXSpider', $w =~ /\$role eq 'dxweb-admin' && !\$self->_admin_peer_is_loopback/],
 ['non-local admin has explicit rejection', $w =~ /error => 'admin_local_only'/],
 ['admin requires DXUser priv >= 9 in DXSpider', $w =~ /\(\$user->priv \|\| 0\) >= 9/],
 ['admin requires non-empty DXUser password', $w =~ /unless \(length \$stored\)/],
 ['admin actor receives server-side DXUser privilege', $w =~ /my \$effective_priv = \$is_admin \? \(\$user->priv \|\| 0\) : 0;/],
 ['registration admin accepts >= 9', $w =~ /\(\$owned->\{priv\} \|\| 0\) >= 9/],
 ['Web Actor width remains 80', $w =~ /width\s*=>\s*80/],
 ['admin process DXS target hard-wired loopback', $a =~ /my \$DXS_HOST = '127\.0\.0\.1'/],
 ['admin client accepts priv >= 9', $a =~ /\$priv<9/],
 ['admin negotiates separate role', $a =~ /role=>'dxweb-admin'/],
 ['admin expects matching HELLO role', $a =~ /\(\$m->\{role\}\/\/''\) eq 'dxweb-admin'/],
);
my $bad=0;
for my $t (@tests) { my($n,$ok)=@$t; print(($ok?'PASS':'FAIL'),"  $n\n"); $bad++ unless $ok }
exit($bad ? 1 : 0);
