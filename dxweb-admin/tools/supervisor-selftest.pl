#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "$file: $!\n";
    local $/;
    return <$fh>;
}

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..', '..'));

my %f = (
    sup   => 'perl/DXSupervisor.pm',
    web   => 'perl/Web.pm',
    admin => 'dxweb-admin/admin.pl',
    js    => 'dxweb-admin/admin/admin.js',
    html  => 'dxweb-admin/admin/index.html',
    css   => 'dxweb-admin/admin/admin.css',
);

$_ = slurp(File::Spec->catfile($root, $_)) for values %f;

my @c = (
    ['passive module',                    $f{sup}   =~ /Deliberately passive/],
    ['no DBI in supervisor',              $f{sup}   !~ /\bDBI\b/],
    ['no IOLoop in supervisor',           $f{sup}   !~ /Mojo::IOLoop/],
    ['bounded connections',               $f{sup}   =~ /MAX_CONNECTIONS/],
    ['fail-open snapshot',                $f{sup}   =~ /snapshot_failed/],
    ['admin gate',                        $f{web}   =~ /_registration_admin\(\$req\)/],
    ['supervisor dispatch',               $f{web}   =~ /type eq 'supervisor'/],
    ['admin bridge',                      $f{admin} =~ /supervisor_\(status\|connections\|traffic\|web\|rbn\|self_health\)/],
    ['no background polling',             $f{js}    =~ /No background polling/],
    ['supervision UI',                    $f{html}  =~ /id="supervisorConnections"/],
    ['supervision internal tabs',         $f{html}  =~ /data-superpanel="overview"/
                                             && $f{html} =~ /data-superpanel="system"/
                                             && $f{html} =~ /data-superpanel="diagnostics"/],
    ['view-scoped refresh',               $f{js}    =~ /supervisorKindsFor/
                                             && $f{js} =~ /activeSupervisionPanel/],
    ['system metrics stay in admin',      $f{admin} =~ /sub local_system_snapshot/
                                             && $f{admin} =~ m{/proc/loadavg}
                                             && $f{web} !~ m{/proc/loadavg}],
    ['diagnostics uses self health',      $f{js}    =~ /self_health/
                                             && $f{html} =~ /supervisorDiagnostics/],

    ['v0.3 KPI dashboard',                $f{html}  =~ /class="kpiGrid"/
                                             && $f{html} =~ /id="ovChannels"/],
    ['v0.3 connection filters',           $f{html}  =~ /class="connFilter"/
                                             && $f{js} =~ /connectionKind/],
    ['v0.3 readable diagnostics',         $f{html}  =~ /id="supervisorPerformance"/
                                             && $f{js} =~ /Maximum generation/],
    ['v0.3 RBN tables',                   $f{html}  =~ /id="supervisorRbn"/
                                             && $f{js} =~ /class="miniTable"/],
    ['v0.3 no background supervisor timer',$f{js}   !~ /setInterval\s*\(\s*supervisor/i],

    ['v0.4 Channel terminology',          $f{html}  =~ /<th>Channel<\/th>/
                                             && $f{html} !~ /<th>Kind<\/th>/],
    ['v0.4 Nodes view',                   $f{html}  =~ /data-superpanel="nodes"/
                                             && $f{html} =~ /id="supervisorNodes"/],
    ['v0.4 PC92 activity order',          $f{html}  =~ /Generated locally.*Accepted logical.*Forwarded logical.*Physical IN.*Physical OUT/s],
    ['v0.4 PC92 neighbour header',        $f{html}  =~ /<th colspan="2">A<\/th>.*<th colspan="2">D<\/th>.*<th colspan="2">C<\/th>.*<th colspan="2">K<\/th>/s],
    ['v0.4 Web logical session placeholders',
                                             $f{html} =~ /Anonymous/
                                             && $f{html} =~ /Password configured/
                                             && $f{html} =~ /Unique real IPs/],
    ['v0.4 unavailable is dash not zero', $f{html}  =~ /—/ && $f{html} =~ /not currently exposed \/ not instrumented/],

    ['v0.5 local identity passive',          $f{sup} =~ /\$main::version/ && $f{sup} =~ /\$main::build/ && $f{sup} =~ /\$main::gitbranch/ && $f{sup} =~ /\$main::gitversion/],
    ['v0.5 connection metadata passive',     $f{sup} =~ /password_configured/ && $f{sup} =~ /usedpasswd/ && $f{sup} =~ /cnum/ && $f{sup} =~ /Route::Node::get/],
    ['v0.5 web logical users passive',       $f{sup} =~ /web_users/ && $f{js} =~ /webLogicalUsers/],
    ['v0.5 self excluded from neighbours',   $f{js} =~ /x\.kind==='node'&&!x\.is_self/],

    ['v0.6 physical password semantics',    $f{sup} =~ /password_used/ && $f{js} =~ /x\.password_used/ && $f{html} =~ /Pw used/],
    ['v0.6 DXSpider version decode guarded',$f{sup} =~ /sub _dxspider_version/ && $f{sup} =~ /is_spider/ && $f{sup} =~ /\$v - 53/],
    ['v0.6 no raw version as DXSpider',     $f{js} =~ /dash\(x\.dxspider_version\)/ && $f{js} !~ /x\.dxspider_version\?\?x\.version/],

    ['v0.7 uses existing PC11/61 getter',   $f{sup} =~ /DXProt::get_pc11_61_stats/ && $f{sup} =~ /pc11_received/ && $f{sup} =~ /pc61_received/],
    ['v0.7 PC11 promotion breakdown',       $f{sup} =~ /pc11_promoted_by_pc61/ && $f{sup} =~ /pc11_promoted_by_route/ && $f{sup} =~ /pc11_promotions/],
    ['v0.7 PC11/61 rendered passively',     $f{html} =~ /id="pc11Stats"/ && $f{html} =~ /id="pc61Stats"/ && $f{js} =~ /pc_spots/],
    ['v0.7 PC OUT remains unavailable',     $f{js} =~ /\['OUT',.*naValue.*—/],
    ['v0.7 PC92 placeholders preserved',   $f{html} =~ /Generated locally.*Accepted logical.*Forwarded logical.*Physical IN.*Physical OUT/s],
    ['DXHealth central RAM telemetry module',      slurp(File::Spec->catfile($root,'perl/DXHealth.pm')) =~ /sub pc92_physical_in/],
    ['DXHealth PC92 physical hooks',                slurp(File::Spec->catfile($root,'perl/DXChannel.pm')) =~ /DXHealth::pc92_physical_out_line/ && slurp(File::Spec->catfile($root,'perl/DXProtHandle.pm')) =~ /DXHealth::pc92_physical_in/],
    ['DXHealth PC92 logical hooks',                 slurp(File::Spec->catfile($root,'perl/DXProtHandle.pm')) =~ /DXHealth::pc92_received/ && slurp(File::Spec->catfile($root,'perl/DXProtHandle.pm')) =~ /DXHealth::pc92_forwarded/],
    ['DXHealth PC92 generation hooks',              slurp(File::Spec->catfile($root,'perl/DXProtout.pm')) =~ /DXHealth::pc92_generated_line/],
    ['DXHealth PC92 supervisor snapshot',           $f{sup} =~ /DXHealth::pc92_snapshot/],
    ['v0.8 PC92 UI live cells',              $f{html} =~ /pc92genA/ && $f{js} =~ /pc92NeighbourRows/],
    ['v0.9 PC92 accepted terminology',         $f{html} =~ /Accepted logical/ && $f{html} !~ /Received logical/],
    ['v0.9 PC92 packet and byte cells',          $f{js} =~ /s\?\.packets.*bytesVU\(Number\(s\?\.bytes/s && $f{html} =~ /Each A\/D\/C\/K cell shows packets and bytes/],
    ['v0.9 PC92 snapshot rates',                 $f{html} =~ /pc92TotalGenPps/ && $f{js} =~ /rateOK/ && $f{js} =~ /pc92Previous/],
    ['v0.9 PC92 reset protection',               $f{js} =~ /monotonic/ && $f{js} =~ /sameBoot/],
    ['v0.9 no background PC92 timer',            $f{js} !~ /setInterval\s*\([^\n;]*pc92/i],
    ['v0.10 compact traffic 3-2-2 layout',       $f{html} =~ /trafficTopGrid/ && $f{html} =~ /trafficPairGrid/ && $f{html} =~ /neighbourGrid/],
    ['v0.10 split neighbour tables',              $f{html} =~ /pc92NeighbourRowsA/ && $f{html} =~ /pc92NeighbourRowsB/ && $f{js} =~ /Math\.ceil\(names\.length\/2\)/],
    ['v0.10 aligned value and unit rendering',     $f{js} =~ /function valueUnit/ && $f{css} =~ /\.vuValue\{text-align:right\}/ && $f{css} =~ /\.vuUnit\{text-align:left/],
    ['v0.10 browser anonymous accounting',         slurp(File::Spec->catfile($root,'dxweb-admin/admin.pl')) =~ /sub browser_client_snapshot/ && $f{js} =~ /browser_clients/ && $f{js} !~ /\['Anonymous',0\]/],
    ['v0.10 web TX queue terminology',             $f{html} =~ /<th>TX queue<\/th>/ && $f{html} !~ /<th>Pending<\/th>/],
    ['v0.10 node identity order',                   $f{html} =~ /<th>Branch<\/th><th>Version<\/th>\s*<th>Build<\/th><th>Git commit<\/th>/ && $f{js} =~ /git_branch.*dxspider_version.*build.*git_version/s],
    ['v0.11 Route Node git metadata',                 slurp(File::Spec->catfile($root,'perl/Route/Node.pm')) =~ /gitbranch => '0,Git Branch'/ && slurp(File::Spec->catfile($root,'perl/Route/Node.pm')) =~ /gitversion => '0,Git Version'/],
    ['v0.11 PC92 K captures git field 8',              slurp(File::Spec->catfile($root,'perl/DXProtHandle.pm')) =~ /defined \$pc->\[8\]/ && slurp(File::Spec->catfile($root,'perl/DXProtHandle.pm')) =~ /\$parent->gitbranch\(\$gitbranch\)/ && slurp(File::Spec->catfile($root,'perl/DXProtHandle.pm')) =~ /\$parent->gitversion\(\$gitversion\)/],
    ['v0.11 Supervisor exposes peer git metadata',     $f{sup} =~ /git_branch => \$rnode \? \$rnode->gitbranch/ && $f{sup} =~ /git_version => \$rnode \? \$rnode->gitversion/],
    ['v0.11 Web logical password-used column',         $f{html} =~ /<th>R<\/th><th>P<\/th><th>Pw used<\/th><th>Auth<\/th>/ && $f{html} !~ /<th>Login<\/th>/ && $f{js} =~ /u\.password_used/ && $f{js} !~ /<td>Yes<\/td>/],
);

for my $check (@c) {
    die "FAIL $check->[0]\n" unless $check->[1];
    print "PASS  $check->[0]\n";
}

print "DXSpider supervisor static self-test: PASS (", scalar(@c), " checks)\n";
