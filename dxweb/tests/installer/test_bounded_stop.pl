#!/usr/bin/env perl
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use Test::More;
my $source = shift @ARGV or die "Usage: perl tests/test_bounded_stop.pl dxweb/dxweb-manager.pl\n";
open my $in, '<', $source or die "$source: $!";
my $code = do { local $/; <$in> };
my ($sub) = $code =~ /(sub stop_service_bounded \{.*?\n\})\nmy %o=/s;
die 'stop_service_bounded not found' unless $sub;
my $dir = tempdir(CLEANUP => 1);
my $mock = File::Spec->catfile($dir,'systemctl');
open my $out, '>', $mock or die $!;
print $out <<'MOCK';
#!/usr/bin/env perl
use strict;
use warnings;
my @args=@ARGV;
if (@args >= 2 && $args[0] eq '--no-block' && $args[1] eq 'stop') { exit(($ENV{MOCK_STOP_RC}//0)); }
if (@args && $args[0] eq 'show') { print(($ENV{MOCK_STATE}//'inactive')."\n"); exit 0; }
if (@args && $args[0] eq 'list-jobs') { print(($ENV{MOCK_JOBS}//'')); exit 0; }
exit 1;
MOCK
close $out;
chmod 0755, $mock or die $!;
local $ENV{PATH} = "$dir:$ENV{PATH}";
my $ok = eval "$sub; 1";
die $@ unless $ok;
{
 local $ENV{MOCK_STATE}='inactive';
 local $ENV{MOCK_JOBS}='';
 ok(stop_service_bounded('dxweb-admin.service',1),'inactive with no job accepted');
}
{
 local $ENV{MOCK_STATE}='failed';
 ok(!stop_service_bounded('dxweb-admin.service',1),'failed rejected');
}
{
 local $ENV{MOCK_STATE}='active';
 ok(!stop_service_bounded('dxweb-admin.service',1),'active timeout rejected');
}
{
 local $ENV{MOCK_STATE}='inactive';
 local $ENV{MOCK_JOBS}='1 dxweb-admin.service stop running';
 ok(!stop_service_bounded('dxweb-admin.service',1),'pending stop job rejected');
}
{
 local $ENV{MOCK_STOP_RC}=1;
 ok(!stop_service_bounded('dxweb-admin.service',1),'failed stop request rejected');
}
done_testing();
