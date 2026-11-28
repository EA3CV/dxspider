use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

use lib 'dxweb/lib';
use DXWeb::Config;

# Isolate the test from the developer's environment.
local %ENV = (%ENV);
delete @ENV{ keys %{ DXWeb::Config::schema() } };

my $dir  = tempdir( CLEANUP => 1 );
my $root = "$dir/spider";
make_path("$root/perl");
open my $fh, '>', "$root/perl/cluster.pl" or die $!;
close $fh;

my $conf = "$dir/dxweb.conf";
open $fh, '>', $conf or die $!;
print {$fh} JSON::PP->new->encode(
    {
        DXS_PORT       => 27755,
        HTTP_PORT      => 7390,
        DXSPIDER_ROOT  => $root,
        DXWEB_WS_PER_IP_LIMIT => 4,
    }
);
close $fh;

my $cfg = DXWeb::Config::effective( path => $conf );
is( $cfg->{DXS_PORT},      27755, 'file value loaded' );
is( $cfg->{HTTP_PORT},     7390,  'second file value loaded' );
is( $cfg->{DXWEB_HOST},    '0.0.0.0', 'default preserved' );
ok( $cfg->{_file_exists}, 'configuration file reported as present' );

$ENV{HTTP_PORT} = 7391;
$cfg = DXWeb::Config::effective( path => $conf );
is( $cfg->{HTTP_PORT}, 7391, 'environment wins over file' );

my ( $errors, $warnings ) = DXWeb::Config::validate($cfg);
is_deeply( $errors, [], 'valid configuration has no errors' );

my $bad = DXWeb::Config::effective( path => $conf );
$bad->{DXS_PORT} = 99999;
( $errors, $warnings ) = DXWeb::Config::validate($bad);
like( $errors->[0], qr/DXS_PORT/, 'invalid port rejected' );

is( DXWeb::Config::check_value( 'DXWEB_SCHEME', 'ftp' ),
    'DXWEB_SCHEME must be http or https', 'invalid scheme rejected' );
is( DXWeb::Config::check_value( 'DXWEB_WS_PER_IP_LIMIT', '8' ),
    undef, 'valid integer accepted' );

my $saved = "$dir/saved.conf";
DXWeb::Config::save_file( $saved, { DXS_PORT => 27756, DXSPIDER_ROOT => $root } );
my $round = DXWeb::Config::load_file($saved);
is( $round->{DXS_PORT}, 27756, 'saved value round-trips' );
ok( -f $saved, 'saved file exists' );

done_testing();
