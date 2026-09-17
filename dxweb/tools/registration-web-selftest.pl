#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;

sub slurp {
    my ($f) = @_;
    open my $h, '<', $f or die "$f: $!\n";
    local $/;
    return <$h>;
}

my $dxweb = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $root  = File::Spec->rel2abs(File::Spec->catdir($dxweb, '..'));
my $admin_root = File::Spec->catdir($root, 'dxweb-admin');

my $web   = slurp(File::Spec->catfile($root,       'perl',  'Web.pm'));
my $reg   = slurp(File::Spec->catfile($root,       'perl',  'DXReg.pm'));
my $app   = slurp(File::Spec->catfile($dxweb,      'app.pl'));
my $admin = slurp(File::Spec->catfile($admin_root, 'admin.pl'));
my $pubhtml = slurp(File::Spec->catfile($dxweb,      'public', 'index.html'));
my $pubjs   = slurp(File::Spec->catfile($dxweb,      'public', 'app.js'));
my $admjs = slurp(File::Spec->catfile($admin_root, 'admin',  'admin.js'));
my $admcss = slurp(File::Spec->catfile($admin_root, 'admin', 'admin.css'));
my $html  = slurp(File::Spec->catfile($admin_root, 'admin',  'index.html'));

my @checks = (
    ['DXReg 1.1',
        $reg =~ /our \$VERSION = '1\.1'/],

    ['request name',
        $reg =~ /name\s*=>\s*\$name/],

    ['request comment',
        $reg =~ /comment\s*=>\s*\$comment/],

    ['history API',
        $reg =~ /sub list_history/],

    ['family search API',
        $reg =~ /sub search_history/],

    ['Web reg request',
        $web =~ /sub _registration_request/],

    ['Web admin priv >= 9',
        $web =~ /\(\$owned->\{priv\}\s*\|\|\s*0\)\s*>=\s*9/],

    ['Web admin password used',
        $web =~ /unless \$owned->\{password_used\}/],

    ['public request bridge',
        $app =~ /type=>'reg_request'/],

    ['admin registration bridge',
        $admin =~ /reg_\(\?:pending\|history\)/
        || $admin =~ /reg_pending/],

    ['public request UI enabled',
        $pubjs =~ /type:'reg_request'/],

    ['admin accept UI',
        $admjs =~ /reg_\$\{action\}/],

    ['admin search UI',
        $html =~ /id="regSearchForm"/],

    ['DXReg delete family API',
        $reg =~ /sub delete_user_family/],

    ['Web delete family bridge',
        $web =~ /sub _registration_delete_user/],

    ['admin delete UI',
        $html =~ /id="deleteUserForm"/],

    ['admin delete websocket',
        $admjs =~ /reg_delete_user/],

    ['command final separator user',
        $pubjs =~ /finishCommandTarget/],

    ['command final separator admin helper',
        $admjs =~ /function finishCommandTarget/],

    ['command final separator admin is called on final',
        $admjs =~ /if\(m\.final!==false\)\{finishCommandTarget\(target\);pendingCommandTargets\.shift\(\)\}/],

    ['reject dialog exposes only selected action',
        index($admjs, q{decisionAction=action==='reject'?'reject':'accept'}) >= 0 &&
        index($admjs, q{$('regAccept').hidden=decisionAction!=='accept'}) >= 0 &&
        index($admjs, q{$('regReject').hidden=decisionAction!=='reject'}) >= 0],

    ['reject response cannot display generated password',
        $admjs =~ /const accepted=m\.type==='reg_accept_result'/],

    ['delete dialog has no redundant browser confirm',
        $admjs !~ /window\.confirm\(/],

    ['delete basecall field has compact layout',
        $admcss =~ /#deleteUserCall\{[^}]*width:180px/s],

    ['delete note is block full width',
        $admcss =~ /#deleteUserNote\{[^}]*display:block[^}]*width:100%/s],

    ['registration language selector',
        $pubhtml =~ /id="registerLanguage"/],

    ['registration language sent',
        $pubjs =~ /language:\$\('registerLanguage'\)/],

    ['generic two-letter registration language',
        $reg =~ /language must be a two-letter code/],

    ['template language fallback EN',
        $reg =~ /\$file = "\$dir\/\$name\.EN"/],
);

my $failed = 0;

for my $c (@checks) {
    my ($name, $ok) = @$c;

    if ($ok) {
        print "PASS  $name\n";
    }
    else {
        print "FAIL  $name\n";
        ++$failed;
    }
}

if ($failed) {
    print "DXSpider Web registration static self-test: FAIL ($failed/",
          scalar(@checks), " failed)\n";
    exit 1;
}

print "DXSpider Web registration static self-test: PASS (",
      scalar(@checks), " checks)\n";

exit 0;
