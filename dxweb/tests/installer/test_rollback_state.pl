#!/usr/bin/env perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use Test::More;
my $source = shift @ARGV or die "Usage: perl tests/test_rollback_state.pl dxweb/dxweb-manager.pl\n";
open my $in, '<', $source or die "$source: $!";
my $code = do { local $/; <$in> };
my ($sub) = $code =~ /(sub service_stopped_or_absent \{.*?\n\})\nmy %o=/s;
die 'service_stopped_or_absent not found' unless $sub;
my $dir=tempdir(CLEANUP=>1);
my $mock=File::Spec->catfile($dir,'systemctl');
open my $out,'>',$mock or die $!;
print $out <<'MOCK';
#!/usr/bin/env perl
use strict;
use warnings;
my @args=@ARGV;
if ($args[0] eq 'show') {
 my $v=$args[1] =~ /LoadState/ ? ($ENV{MOCK_LOAD}//'loaded') : ($ENV{MOCK_STATE}//'inactive');
 print "$v\n";
 exit($ENV{MOCK_SHOW_RC}//0);
}
if ($args[0] eq 'list-jobs') {print($ENV{MOCK_JOBS}//'');exit($ENV{MOCK_JOBS_RC}//0)}
exit 1;
MOCK
close $out;
chmod 0755,$mock or die $!;
local $ENV{PATH}="$dir:$ENV{PATH}";
eval "$sub; 1" or die $@;
{local $ENV{MOCK_LOAD}='not-found';local $ENV{MOCK_STATE}='inactive';ok(service_stopped_or_absent('dxweb-admin.service'),'removed unit with inactive state accepted')}
{local $ENV{MOCK_LOAD}='loaded';local $ENV{MOCK_STATE}='inactive';ok(service_stopped_or_absent('dxweb-admin.service'),'loaded inactive accepted')}
{local $ENV{MOCK_LOAD}='not-found';local $ENV{MOCK_STATE}='active';ok(!service_stopped_or_absent('dxweb-admin.service'),'active not accepted')}
{local $ENV{MOCK_LOAD}='loaded';local $ENV{MOCK_STATE}='failed';ok(!service_stopped_or_absent('dxweb-admin.service'),'failed not accepted')}
{local $ENV{MOCK_LOAD}='not-found';local $ENV{MOCK_STATE}='inactive';local $ENV{MOCK_JOBS}='1 dxweb-admin.service stop running';ok(!service_stopped_or_absent('dxweb-admin.service'),'pending job not accepted')}
{local $ENV{MOCK_LOAD}='not-found';local $ENV{MOCK_STATE}='inactive';local $ENV{MOCK_SHOW_RC}=1;ok(!service_stopped_or_absent('dxweb-admin.service'),'failed query not accepted')}
{local $ENV{MOCK_LOAD}='not-found';local $ENV{MOCK_STATE}='inactive';local $ENV{MOCK_JOBS_RC}=1;ok(!service_stopped_or_absent('dxweb-admin.service'),'failed job query not accepted')}
like($code,qr/service_stopped_or_absent\(\$svc\)\) or die/, 'rollback verifies inactive without issuing second stop');
done_testing();
