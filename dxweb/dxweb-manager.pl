#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use Getopt::Long qw(GetOptions);
use File::Find;
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use Fcntl qw(:flock);
use HTTP::Tiny;
use POSIX qw(strftime);
# Bounded stop: do not let a systemd stop timeout hold a transaction for 90s.
# Never edit unit files while a stop is still pending.
sub stop_service_bounded {
 my ($svc,$seconds)=@_;
 $seconds //= 15;
 print STDERR "STOP REQUEST: $svc (limit ${seconds}s)\n";
 system('systemctl','--no-block','stop',$svc)==0 or return 0;
 for (1..$seconds*5) {
  my $state=`systemctl show --property=ActiveState --value $svc 2>/dev/null`;
  chomp $state;
  if ($state eq 'inactive') {
   # A stop job may still be queued; do not mutate unit files until it clears.
   my $jobs=`systemctl list-jobs --no-legend --no-pager 2>/dev/null`;
   return 1 unless $jobs =~ /\Q$svc\E/;
  }
  if ($state eq 'failed') { warn "STOP FAILED: $svc entered failed state\n"; return 0; }
  select(undef,undef,undef,0.2);
 }
 warn "STOP TIMEOUT: $svc did not reach inactive within ${seconds}s\n";
 return 0;
}
# Verify a stopped unit without issuing a second stop after its unit file
# has intentionally been removed by rollback. A queued job is never success.
sub service_stopped_or_absent {
 my ($svc)=@_;
 my $load=`systemctl show --property=LoadState --value $svc 2>/dev/null`;
 my $load_rc=$?;
 my $state=`systemctl show --property=ActiveState --value $svc 2>/dev/null`;
 my $state_rc=$?;
 chomp($load,$state);
 return 0 if $load_rc || $state_rc;
 return 0 unless ($load eq 'not-found' && $state eq 'inactive') || ($state eq 'inactive' && $load eq 'loaded');
 my $jobs=`systemctl list-jobs --no-legend --no-pager 2>/dev/null`;
 return 0 if $?;
 return $jobs !~ /\Q$svc\E/;
}
my %o=(root=>'/spider',components=>'both',mode=>'direct',scheme=>'http',action=>'plan',backup_dir=>'/var/backups/dxweb-installer');
GetOptions('root=s'=>\$o{root},'components=s'=>\$o{components},'mode=s'=>\$o{mode},'scheme=s'=>\$o{scheme},'action=s'=>\$o{action},'hostname=s'=>\$o{hostname},'cert=s'=>\$o{cert},'key=s'=>\$o{key},'backup-dir=s'=>\$o{backup_dir},'apply'=>\$o{apply},'user=s'=>\$o{user},'group=s'=>\$o{group},'backup=s'=>\$o{backup},'help'=>\$o{help}) or die "Invalid options\n";
if ($o{help}) {
 print <<'HELP';
DXWeb Installer v0.49
  --action plan|install|rollback|status    Default: plan
  --root /spider                    Installation root
  --components dxweb|admin|both     Default: both
  --mode direct|nginx               Default: direct
  --scheme http|https               Default: http
  --hostname NAME --cert FILE --key FILE   TLS parameters
  --user USER --group GROUP         Optional service identity
  --backup-dir DIR                  Backup base directory
  --backup DIR                      Required for --action rollback
  --apply                           Required for installation or rollback
  --help                            This help
  --action status                   Read-only systemd status (no root needed)
Examples:
  perl dxweb/dxweb-manager.pl --action plan --root /spider --components both --mode direct --scheme http
  perl dxweb/dxweb-manager.pl --action install --root /spider --components both --mode direct --scheme http --apply
  perl dxweb/dxweb-manager.pl --action rollback --backup /var/backups/dxweb-installer/TRANSACTION --apply
HELP
 exit 0;
}
# Read-only operational status. Never creates a transaction, changes a unit,
# probes through Nginx, or requires elevated privileges.
if ($o{action} eq 'status') {
 die "--components must be dxweb, admin or both\n" unless $o{components}=~/\A(?:dxweb|admin|both)\z/;
 my @check=$o{components} eq 'both' ? ('dxweb','admin') : ($o{components});
 my $failed=0;
 for my $c (@check) {
  my $svc=$c eq 'dxweb' ? 'dxweb.service' : 'dxweb-admin.service';
  my $active=system('systemctl','is-active','--quiet',$svc)==0 ? 'active' : 'inactive';
  my $enabled=system('systemctl','is-enabled','--quiet',$svc)==0 ? 'enabled' : 'not-enabled';
  print "SERVICE $svc active=$active enabled=$enabled\n";
  $failed++ if $active ne 'active';
 }
 print "STATUS ",($failed ? 'DEGRADED' : 'OK'),"\n";
 exit($failed ? 1 : 0);
}
if ($o{action} eq 'rollback') {
 die "--backup requires an absolute directory\n" unless defined($o{backup}) && $o{backup}=~m{^/[A-Za-z0-9_./-]+$} && $o{backup}!~m{(?:^|/)\.\.(?:/|$)};
 die "Root required\n" unless $>==0;
 my $manifest_path="$o{backup}/manifest.json";
 die "Invalid backup directory\n" if -l $o{backup} || !-d $o{backup} || -l $manifest_path || !-f $manifest_path;
 my $m=decode_json(read_file($manifest_path));
 die "Unsupported manifest\n" unless ref($m) eq 'HASH' && ($m->{format}//'') eq 'dxweb-transaction-v1' && ref($m->{journal}) eq 'ARRAY' && ref($m->{initial_active}) eq 'HASH' && ref($m->{initial_enabled}) eq 'HASH';
 die "Empty rollback journal\n" unless @{$m->{journal}};
 # Older transactions did not record root; they were valid only for /spider.
 # New transactions bind every application destination to their actual root.
 my $transaction_root=defined($m->{root}) ? $m->{root} : '/spider';
 # Resolve legacy /spider aliases to their real installation tree.
 # Never follow a symlink for a journal file or its intermediate children.
 my $resolved_transaction_root=abs_path($transaction_root);
 die "Missing transaction root\n" unless defined($resolved_transaction_root) && -d $resolved_transaction_root;
 die "Unsafe transaction root\n" unless !ref($transaction_root) &&
  $transaction_root =~ m{\A/[A-Za-z0-9_./-]+\z} &&
  $transaction_root !~ m{(?:^|/)\.{1,2}(?:/|$)} &&
  $transaction_root ne '/' && $transaction_root !~ m{/$};

 my (%affected,%seen);
 my $nginx_config=0;
 for my $e (@{$m->{journal}}) {
  die "Invalid journal entry\n" unless ref($e) eq 'HASH';
  my $dest=$e->{dest}//'';
  die "Unsafe rollback destination: $dest\n" unless $dest =~ m{^\Q$transaction_root\E/(?:dxweb|dxweb-admin)/[A-Za-z0-9_./-]+$} || $dest =~ m{^/etc/systemd/system/(?:dxweb|dxweb-admin)\.service$} || $dest eq '/etc/nginx/sites-available/dxweb-installer.conf';
  die "Traversal in destination\n" if $dest =~ m{(?:^|/)\.{1,2}(?:/|$)};
  die "Duplicate rollback destination\n" if $seen{$dest}++;
  if ($dest =~ m{^\Q$transaction_root\E/(dxweb|dxweb-admin)/(.+)$}) {
   my ($component,$relative)=($1,$2);
   die "Unsafe symlink component\n" if -l "$resolved_transaction_root/$component";
   $dest="$resolved_transaction_root/$component/$relative";
   $e->{dest}=$dest;
  }
  my $dir=dirname($dest);
  while ($dir ne '/') { die "Symlink parent: $dir\n" if -l $dir; $dir=dirname($dir); }
  die "Symlink destination\n" if -l $dest;
  die "Nonregular destination\n" if -e $dest && !-f $dest;
  die "Invalid existed flag\n" unless JSON::PP::is_bool($e->{existed});
  for my $k (qw(uid gid mode)) { die "Invalid $k\n" unless defined($e->{$k}) && !ref($e->{$k}) && $e->{$k}=~/\A\d+\z/; }
  die "Invalid mode\n" if $e->{mode}>07777;
  if ($e->{existed}) {
   my $b=$e->{backup}//'';
   die "Unsafe backup reference\n" unless $b =~ m{^\Q$o{backup}\E/[0-9]+\.bak$} && -f $b && !-l $b;
   die "Unreadable backup\n" unless -r $b;
  } else { die "Unexpected backup reference\n" if defined $e->{backup}; }
  $affected{dxweb}=1 if $dest =~ m{^\Q$transaction_root\E/dxweb/|/dxweb\.service$};
  $affected{admin}=1 if $dest =~ m{^\Q$transaction_root\E/dxweb-admin/|/dxweb-admin\.service$};
  $nginx_config=1 if $dest eq '/etc/nginx/sites-available/dxweb-installer.conf';
 }
 for my $c (keys %affected) {
  for my $key (qw(initial_active initial_enabled)) {
   die "Missing or invalid $key for $c\n" unless defined($m->{$key}{$c}) && ($m->{$key}{$c} eq '0' || $m->{$key}{$c} eq '1');
  }
 }
 my $link='/etc/nginx/sites-enabled/dxweb-installer.conf';
 my $remove_nginx_link=$nginx_config && $m->{nginx_link_created};
 if ($remove_nginx_link) {
  die "Unexpected Nginx link; refusing removal\n" unless -l $link && readlink($link) eq '/etc/nginx/sites-available/dxweb-installer.conf';
 }
 print "ROLLBACK PLAN: $o{backup}\n";
 print "RESTORE $_->{dest}\n" for reverse @{$m->{journal}};
 print "REMOVE NGINX LINK $link\n" if $remove_nginx_link;
 print "SERVICE STATE: $_ ".($m->{initial_active}{$_}?'active':'stopped').", ".($m->{initial_enabled}{$_}?'enabled':'disabled')."\n" for sort keys %affected;
 if (!$o{apply}) { print "DRY RUN: add --apply to restore.\n"; exit 0; }
 open my $lock,'>>','/run/lock/dxweb-installer.lock' or die "Cannot lock: $!";
 flock($lock,LOCK_EX|LOCK_NB) or die "Installer already running\n";
 # A durable checkpoint protects the state found NOW, not the state saved by
 # the original installation. Never overwrite the original transaction.
 my $stamp=strftime('%Y%m%d-%H%M%S',localtime)."-$$";
 my $safety="$o{backup_dir}/rollback-safety-$stamp";
 make_path($safety,{mode=>0700}); chmod 0700,$safety or die "Cannot protect safety checkpoint: $!\n";
 my (@checkpoint,%now_active,%now_enabled);
 for my $c (keys %affected) {
  my $svc=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
  $now_active{$c}=system('systemctl','is-active','--quiet',$svc)==0?1:0;
  $now_enabled{$c}=system('systemctl','is-enabled','--quiet',$svc)==0?1:0;
 }
 for my $e (@{$m->{journal}}) {
  my $d=$e->{dest}; my $exists=-e $d;
  my @st=$exists?stat($d):();
  my $cp={dest=>$d,existed=>$exists?JSON::PP::true:JSON::PP::false,mode=>$exists?($st[2]&07777):0644,uid=>$exists?$st[4]:0,gid=>$exists?$st[5]:0};
  if ($exists) { my $f="$safety/".scalar(@checkpoint).'.bak'; write_atomic($f,read_file($d),0600,0,0); $cp->{backup}=$f; }
  push @checkpoint,$cp;
 }
 my $link_was_present=-l $link ? readlink($link) : undef;
 write_atomic("$safety/manifest.json",JSON::PP->new->canonical->pretty->encode({format=>'dxweb-rollback-safety-v1',journal=>\@checkpoint,initial_active=>\%now_active,initial_enabled=>\%now_enabled,nginx_link_target=>$link_was_present}),0600,0,0);
 # Preflight: no journal mutation has happened yet. On stop timeout leave the
 # original unit and checkpoint untouched; do not enter recovery and stop again.
 for my $c (keys %affected) {
  my $svc=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
  stop_service_bounded($svc,15) or die "ROLLBACK ABORTED: $svc did not stop cleanly; no files restored. Checkpoint: $safety\n";
 }
 my $ok=eval {
  for my $e (reverse @{$m->{journal}}) {
   if ($e->{existed}) { write_atomic($e->{dest},read_file($e->{backup}),$e->{mode},$e->{uid},$e->{gid}); }
   elsif (-e $e->{dest}) { unlink $e->{dest} or die "Cannot unlink $e->{dest}: $!\n"; }
  }
  if ($remove_nginx_link) { unlink $link or die "Cannot remove Nginx link: $!\n"; }
  system('systemctl','daemon-reload')==0 or die "daemon-reload failed\n";
  if ($nginx_config) { system('nginx','-t')==0 or die "Nginx configuration invalid after restore\n"; system('systemctl','reload','nginx')==0 or die "Nginx reload failed\n"; }
  for my $c (keys %affected) {
   my $svc=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
   system('systemctl',$m->{initial_enabled}{$c}?'enable':'disable',$svc)==0 or die "Cannot restore enable state for $svc\n";
   ($m->{initial_active}{$c} ? system('systemctl','start',$svc)==0 : service_stopped_or_absent($svc)) or die "Cannot restore active state for $svc\n";
   if ($m->{initial_active}{$c}) { system('systemctl','is-active','--quiet',$svc)==0 or die "Service not active after rollback: $svc\n"; }
  }
  1;
 };
 if (!$ok) {
  my $err=$@||'Unknown rollback failure'; warn "ROLLBACK FAILED: $err";
  for my $c (keys %affected) { my $svc=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service'; stop_service_bounded($svc,15); }
  for my $e (reverse @checkpoint) {
   eval { if ($e->{existed}) { write_atomic($e->{dest},read_file($e->{backup}),$e->{mode},$e->{uid},$e->{gid}); } elsif (-e $e->{dest}) { unlink $e->{dest} or die "unlink: $!"; } }; warn "SAFETY RESTORE FILE ERROR: $@" if $@;
  }
  if ($remove_nginx_link && defined($link_was_present) && !-e $link && !-l $link) { symlink($link_was_present,$link) or warn "SAFETY NGINX LINK ERROR: $!\n"; }
  system('systemctl','daemon-reload');
  if ($nginx_config && system('nginx','-t')==0) { system('systemctl','reload','nginx'); }
  for my $c (keys %affected) {
   my $svc=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
   system('systemctl',$now_enabled{$c}?'enable':'disable',$svc);
   if ($now_active{$c}) { system('systemctl','start',$svc); } else { service_stopped_or_absent($svc) or warn "SAFETY RESTORE STATE ERROR: $svc not inactive\n"; }
  }
  die "Rollback failed; safety restoration attempted. Inspect services. Checkpoint: $safety\n";
 }
 print "ROLLBACK OK: $o{backup}\nSAFETY CHECKPOINT: $safety\n";
 exit 0;
}
$o{root}=~m{^/[A-Za-z0-9_./-]+$} && $o{root}!~m{(?:^|/)\.\.(?:/|$)} or die "Unsafe root\n";
$o{mode}=~/^(direct|nginx)$/ && $o{scheme}=~/^(http|https)$/ && $o{components}=~/^(both|dxweb|admin)$/ or die "Invalid mode/scheme/components\n";
$o{action}=~/^(plan|install)$/ or die "Invalid action\n";
my @components=$o{components} eq 'both' ? qw(dxweb admin):($o{components});
my $nginx=$o{mode} eq 'nginx';
my $backend=$nginx?'http':$o{scheme};
my ($wp,$ap)=$nginx?(7480,7481):(7380,7381);
# /spider is commonly a symlink to /home/sysop/spider. Resolve it once
# and use the real path consistently in units, manifests and backups.
my $requested_root=$o{root};
my $resolved_root=abs_path($requested_root);
die "Installation root does not exist\n" unless defined($resolved_root) && -d $resolved_root;
die "Unsafe resolved root\n" unless $resolved_root =~ m{\A/[A-Za-z0-9_./-]+\z} && $resolved_root !~ m{(?:^|/)\.{1,2}(?:/|$)} && $resolved_root ne '/';
$o{root}=$resolved_root;
my $src=$o{root};
# Applications are tracked by Git; never copy or rewrite them in place.
for my $c (@components) {
 my $folder=$c eq 'dxweb' ? 'dxweb' : 'dxweb-admin';
 -d "$src/$folder" or die "Missing component directory: $src/$folder\n";
}
my $ssl=$o{scheme} eq 'https';
if ($ssl) {
 for my $k (qw(cert key)) { die "--$k must be an existing regular file\n" unless defined($o{$k}) && $o{$k}=~m{^/} && -f $o{$k} && !-l $o{$k}; }
 system('openssl','x509','-in',$o{cert},'-noout','-checkend','0')==0 or die "Certificate expired or invalid\n";
 my $cert_pub=openssl_output('x509','-in',$o{cert},'-pubkey','-noout');
 my $key_pub=openssl_output('pkey','-in',$o{key},'-pubout');
 die "TLS key does not match certificate\n" unless $cert_pub && $cert_pub eq $key_pub;
 die "--hostname required for HTTPS\n" unless ($o{hostname}//'') =~ /\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/;
 system('openssl','x509','-in',$o{cert},'-noout','-checkhost',$o{hostname})==0 or die "Certificate does not cover hostname\n";
}
# Preserve the identity of an installed service unless explicitly overridden.
my ($existing_user,$existing_group);
for my $c (@components) {
 my $unit_path='/etc/systemd/system/'.($c eq 'dxweb'?'dxweb.service':'dxweb-admin.service');
 next unless -f $unit_path;
 my $unit_text=read_file($unit_path);
 my ($u)=$unit_text =~ /^User=([^\s#]+)\s*$/m;
 my ($g)=$unit_text =~ /^Group=([^\s#]+)\s*$/m;
 if (defined $u) { die "Conflicting installed service users\n" if defined($existing_user) && $existing_user ne $u; $existing_user=$u; }
 if (defined $g) { die "Conflicting installed service groups\n" if defined($existing_group) && $existing_group ne $g; $existing_group=$g; }
}
# Resolve defaults from the actual DXSpider service, not invented account names.
# Existing DXWeb service identities take precedence during an update.
my ($spider_user,$spider_group);
for my $spider_unit ('/etc/systemd/system/dxspider.service',
                     '/lib/systemd/system/dxspider.service',
                     '/usr/lib/systemd/system/dxspider.service') {
 next unless -f $spider_unit;
 my $content=read_file($spider_unit);
 ($spider_user)=$content =~ /^User=([^\s#]+)\s*$/m;
 ($spider_group)=$content =~ /^Group=([^\s#]+)\s*$/m;
 last if defined($spider_user) && defined($spider_group);
}
my $username=$o{user}//$existing_user//$spider_user;
my $groupname=$o{group}//$existing_group//$spider_group;
die "Cannot determine DXSpider user/group; supply --user and --group explicitly\n"
 unless defined($username) && defined($groupname);

for my $name ($username,$groupname) { die "Unsafe account name\n" unless $name =~ /\A[a-z_][a-z0-9_-]*\z/; }
my @uid=getpwnam($username); my @gid=getgrnam($groupname);
die "Service user/group missing: $username/$groupname\n" unless @uid && @gid;
my $uid=$uid[2]; my $gid=$gid[2];
my %unit;
for my $c (@components) {
 my $isweb=$c eq 'dxweb'; my $folder=$isweb?'dxweb':'dxweb-admin';
 my $port=$isweb?$wp:$ap; my $host=$nginx?'127.0.0.1':'0.0.0.0';
 my $service=$isweb?'dxweb.service':'dxweb-admin.service';
 my $script=$isweb?'start.pl':'admin.pl';
 # The Git checkout already contains the deployable application scripts.
 # Only systemd and Nginx are managed here; application code is never rewritten.
 my $body=read_file("$src/$folder/$script");
 die "DXWeb application script missing\n" unless length($body);
 my $env=$isweb ? "Environment=HTTP_HOST=$host\nEnvironment=HTTP_PORT=$port\n" : "Environment=DXWEB_HOST=$host\nEnvironment=DXWEB_PORT=$port\nEnvironment=DXWEB_CLIENT_PORT=$wp\nEnvironment=DXWEB_CLIENT_SCHEME=$backend\nEnvironment=DXWEB_CLIENT_HOST=".($backend eq 'https'?$o{hostname}:'127.0.0.1')."\n";
 $env.="Environment=DXWEB_SCHEME=$backend\nEnvironment=MOJO_REVERSE_PROXY=".($nginx?1:0)."\n";
 if ($backend eq 'https') {
  $env.="Environment=DXWEB_TLS_CERT=$o{cert}\nEnvironment=DXWEB_TLS_KEY=$o{key}\n";
 }
 $env.="Environment=DXSPIDER_ROOT=$o{root}\n";
 # Keep locally configured environment values unrelated to listener management.
 my $installed_unit='/etc/systemd/system/'.$service;
 if (-f $installed_unit) {
  my $prior=read_file($installed_unit);
  my %managed=map { $_=>1 } qw(HTTP_HOST HTTP_PORT DXWEB_HOST DXWEB_PORT DXWEB_CLIENT_PORT DXWEB_CLIENT_SCHEME DXWEB_CLIENT_HOST DXWEB_SCHEME DXWEB_TLS_CERT DXWEB_TLS_KEY MOJO_REVERSE_PROXY DXS_HOST DXS_PORT DXSPIDER_ROOT);
  for my $line (split /\n/, $prior) {
   next unless $line =~ /^Environment=([A-Za-z_][A-Za-z_0-9]*)=/;
   next if $managed{$1};
   die "Unsafe Environment line in existing $service\n" if $line =~ /[\r\x00]/;
   $env.="$line\n";
  }
 }

 my ($dxs_host,$dxs_port)=('127.0.0.1',27754);
 if (-f $installed_unit) {
  my $prior=read_file($installed_unit);
  $dxs_host=$1 if $prior =~ /^Environment=DXS_HOST=([^\s#]+)\s*$/m;
  $dxs_port=$1 if $prior =~ /^Environment=DXS_PORT=(\d+)\s*$/m;
 }
 die "Unsafe existing DXS_HOST\n" unless $dxs_host =~ /\A[a-zA-Z0-9_.:-]+\z/;
 die "Unsafe existing DXS_PORT\n" unless $dxs_port =~ /\A\d{1,5}\z/ && $dxs_port > 0 && $dxs_port < 65536;
 my $extra_service='';
 if (-f $installed_unit) {
  my $prior=read_file($installed_unit);
  my $in_service=0;
  my %managed=map { $_=>1 } qw(Type User Group WorkingDirectory Environment ExecStart Restart RestartSec);
  for my $line (split /\n/, $prior) {
   if ($line =~ /^\[([^]]+)\]$/) { $in_service=($1 eq 'Service'); next; }
   next unless $in_service && $line =~ /^([A-Za-z][A-Za-z0-9]*)=(.*)$/;
   next if $managed{$1};
   die "Unsafe service directive\n" if $line =~ /[\r\x00]/;
   $extra_service.="$line\n";
  }
 }
 # For a new DXWeb unit, retain the proven file descriptor limit.
 # Existing unit directives, including a custom LimitNOFILE, take precedence.
 if ($isweb && $extra_service !~ /^LimitNOFILE=/m) {
  $extra_service .= "LimitNOFILE=8192:8192\n";
 }
 # Bound systemd's own stop job; mixed mode signals the main server first,
 # allowing it to release its browser-owned children before escalation.
 if (!$isweb) {
  $extra_service .= "TimeoutStopSec=20s\n" unless $extra_service =~ /^TimeoutStopSec=/m;
  $extra_service .= "KillMode=mixed\n" unless $extra_service =~ /^KillMode=/m;
 }
 my $command=$isweb?'start.pl':'admin.pl';
 $unit{$c}="[Unit]\nDescription=DXSpider $folder\nAfter=network.target\n\n[Service]\nType=simple\nUser=$username\nGroup=$groupname\nWorkingDirectory=$o{root}/$folder\nEnvironment=DXS_HOST=$dxs_host\nEnvironment=DXS_PORT=$dxs_port\n$env"."ExecStart=/usr/bin/perl $o{root}/$folder/$command\nRestart=on-failure\nRestartSec=3\n$extra_service\n[Install]\nWantedBy=multi-user.target\n";
}
my $nginx_conf='';
if ($nginx) {
 die "--hostname required for Nginx\n" unless ($o{hostname}//'') =~ /\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/;
 for my $c (@components) {
  my ($public,$internal)=$c eq 'dxweb'?(7380,7480):(7381,7481);
  my $listen=$ssl?"listen $public ssl;":"listen $public;";
  my $tls=$ssl?"ssl_certificate $o{cert};\nssl_certificate_key $o{key};\n":'';
  $nginx_conf.="server {\n$listen\nserver_name $o{hostname};\n$tls".'location / {' . "\nproxy_http_version 1.1;\nproxy_set_header Host \$http_host;\nproxy_set_header X-Real-IP \$remote_addr;\nproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\nproxy_set_header X-Forwarded-Proto \$scheme;\nproxy_set_header Upgrade \$http_upgrade;\nproxy_set_header Connection \"upgrade\";\nproxy_read_timeout 3600s;\nproxy_pass http://127.0.0.1:$internal;\n}\n}\n";
 }
}
my @targets;
for my $c (@components) {
 my $service=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
 push @targets,[undef,"/etc/systemd/system/$service",$unit{$c},1];
}
if (!$nginx && (-e '/etc/nginx/sites-enabled/dxweb.conf' || -e '/etc/nginx/sites-enabled/dxweb-installer.conf')) { die "Conflicting Nginx DXWeb site enabled; refusing direct installation\n"; }
if ($nginx && (-e '/etc/nginx/sites-enabled/dxweb.conf' || -l '/etc/nginx/sites-enabled/dxweb.conf')) { die "Existing DXWeb Nginx site: manual migration required before installing managed site\n"; }
if ($nginx && (-e '/etc/nginx/sites-enabled/dxweb-installer.conf' || -l '/etc/nginx/sites-enabled/dxweb-installer.conf') && (!-l '/etc/nginx/sites-enabled/dxweb-installer.conf' || readlink('/etc/nginx/sites-enabled/dxweb-installer.conf') ne '/etc/nginx/sites-available/dxweb-installer.conf')) { die "Managed Nginx site link points elsewhere\n"; }
# Preserve the other component's proxy during a partial deployment.
# Only accept the exact two-block layout produced by this installer.
if ($nginx && $o{components} ne 'both' &&
    -e '/etc/nginx/sites-available/dxweb-installer.conf') {
 my $existing=read_file('/etc/nginx/sites-available/dxweb-installer.conf');
 my %old=validate_managed_nginx($existing);
 my $other=$o{components} eq 'dxweb' ? 7381 : 7380;
 $nginx_conf .= $old{$other} if exists $old{$other};
}
if ($nginx) { push @targets,[undef,'/etc/nginx/sites-available/dxweb-installer.conf',$nginx_conf,1]; }
print "SOURCE: Git working tree at $o{root}; application files are not copied.\n";
print "MODE=$o{mode} PUBLIC=$o{scheme} BACKEND=$backend COMPONENTS=$o{components}\n";
my @changed;
for my $t (@targets) {
 my ($from,$dest,$override)=@$t;
 my $new=defined($override)?$override:read_file($from);
 my $status= !-e $dest ? 'CREATE' : sha256_hex(read_file($dest)) eq sha256_hex($new) ? 'UNCHANGED' : 'UPDATE';
 print "TARGET $dest $status\n";
 push @changed,$t unless $status eq 'UNCHANGED';
}
if (!@changed) {
 print "NO CONFIG CHANGES: service units and proxy already match.\n";
 if ($o{action} eq 'plan' || !$o{apply}) {
  print "Run --action install --apply after Git updates to restart services.\n";
  exit 0;
 }
}
if ($o{action} eq 'plan' || !$o{apply}) { print "DRY RUN: no files or services changed. Use --action install --apply to deploy.\n"; exit 0; }
die "Root required\n" unless $>==0;
# Preflight all prerequisites before touching the destination tree.
for my $c (@components) {
 my $script=$c eq 'dxweb'?'start.pl':'admin.pl';
 my $folder=$c eq 'dxweb'?'dxweb':'dxweb-admin';
 my $source="$src/$folder/$script";
 system($^X,'-c',$source)==0 or die "Perl source syntax/dependencies failed: $source\n";
}
if ($nginx) { system('nginx','-t')==0 or die "Existing Nginx configuration invalid; abort\n"; }
# A TLS private key must be accessible to the account running the Perl daemon.
# Checking this before the transaction avoids replacing working HTTP services
# with HTTPS services that cannot read their key.
if ($ssl && !$nginx) {
 my @st=stat($o{key});
 die "TLS private key inaccessible\n" unless @st;
 my $perm=$st[2]&0777;
 my $readable=($st[4]==$uid && ($perm&0400)) || ($st[5]==$gid && ($perm&0040)) || ($perm&0004);
 die "TLS private key not readable by service identity $username/$groupname\n" unless $readable;
}
for my $t (@targets) {
 my $d=$t->[1]; my $dir=dirname($d);
 while ($dir ne '/' && $dir ne '.') { die "Symlink parent forbidden: $dir\n" if -l $dir; $dir=dirname($dir); }
 die "Symlink target forbidden: $d\n" if -l $d;
}

open my $lock,'>>','/run/lock/dxweb-installer.lock' or die "Cannot lock: $!";
flock($lock,LOCK_EX|LOCK_NB) or die "Installer already running\n";
my (%active,%enabled,%existed_unit);
my %was_installed;
my %original_endpoint;
my %original_probeable;
for my $c (@components) {
 my $p=$c eq 'dxweb'?7380:7381;
 my $unit_path='/etc/systemd/system/'.($c eq 'dxweb'?'dxweb.service':'dxweb-admin.service');
 if (-f $unit_path) {
  my $u=read_file($unit_path);
  my $var=$c eq 'dxweb'?'HTTP_PORT':'DXWEB_PORT';
  $p=$1 if $u =~ /^Environment=$var=(\d+)\s*$/m;
 }
 # Reconstruct the OLD listener from the installed unit, never from the
 # requested new deployment. A failed HTTPS or Nginx migration must probe
 # the original protocol/port after rollback.
 my $old_scheme='http';
 my $old_host='127.0.0.1';
 if (-f $unit_path) {
  my $old_unit=read_file($unit_path);
  $old_scheme=$1 if $old_unit =~ /^Environment=DXWEB_SCHEME=(https?)\s*$/m;
  if ($old_scheme eq 'https') {
   # The old certificate's DNS identity is not necessarily available to the
   # installer. Do not claim that an IP-based HTTPS check can verify it.
   $old_host=undef;
  }
 }
 $original_probeable{$c}=defined($old_host)?1:0;
 $original_endpoint{$c}=defined($old_host) ? "$old_scheme://$old_host:$p".($c eq 'dxweb'?'/software-version.json':'/software-versions.json') : undef;
}
 for my $c (@components) {
 my $s=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
 $active{$c}=system('systemctl','is-active','--quiet',$s)==0?1:0;
 $enabled{$c}=system('systemctl','is-enabled','--quiet',$s)==0?1:0;
 $existed_unit{$c}=-f "/etc/systemd/system/$s"?1:0;
 $was_installed{$c}=$existed_unit{$c};
 die "Masked unit: $s\n" if (system('systemctl','is-enabled','--quiet',$s)==1 && do { my $v=`systemctl is-enabled $s 2>/dev/null`; $v =~ /^masked/ });
}
my $stamp=strftime('%Y%m%d-%H%M%S',localtime)."-$$";
my $backup="$o{backup_dir}/$stamp";
make_path($backup,{mode=>0700});
chmod 0700,$backup or die "Cannot protect backup directory: $!\n";
my @journal; my $nginx_link_created=0; my $success=eval {
 for my $t (@changed) {
  my ($from,$dest,$override,$config)=@$t;
  die "Symlink destination forbidden: $dest\n" if -l $dest || -l dirname($dest);
  my $existed=-e $dest;
  die "Nonregular target: $dest\n" if $existed && !-f $dest;
  my $old=$existed?read_file($dest):undef;
  my $new=defined($override)?$override:read_file($from);
  next if $existed && sha256_hex($old) eq sha256_hex($new);
  my @stat=$existed?stat($dest):();
  my $entry={dest=>$dest,existed=>$existed?JSON::PP::true:JSON::PP::false,mode=>$existed?($stat[2]&07777):($config?0644:0644),uid=>$existed?$stat[4]:($config?0:$uid),gid=>$existed?$stat[5]:($config?0:$gid)};
  if ($existed) { my $p="$backup/".scalar(@journal).'.bak'; write_atomic($p,$old,0600,0,0); $entry->{backup}=$p; }
  push @journal,$entry;
  # Persist recovery instructions BEFORE modifying the destination.  A failed
  # write must never leave a changed file absent from the on-disk journal.
  write_atomic("$backup/manifest.json",JSON::PP->new->canonical->pretty->encode({format=>'dxweb-transaction-v1',root=>$o{root},journal=>\@journal,initial_active=>\%active,initial_enabled=>\%enabled}),0600,0,0);
  make_path(dirname($dest));
  write_atomic($dest,$new,$entry->{mode},$entry->{uid},$entry->{gid});
 }
 write_atomic("$backup/manifest.json",JSON::PP->new->canonical->pretty->encode({format=>'dxweb-transaction-v1',root=>$o{root},journal=>\@journal,initial_active=>\%active,initial_enabled=>\%enabled}),0600,0,0);
 for my $c (@components) {
  my $script=$c eq 'dxweb'?'start.pl':'admin.pl'; my $folder=$c eq 'dxweb'?'dxweb':'dxweb-admin';
  system($^X,'-c',"$o{root}/$folder/$script")==0 or die "Perl syntax failed: $script\n";
 }
 system('systemctl','daemon-reload')==0 or die "systemd reload failed\n";
 if ($nginx) {
  die "Existing conflicting DXWeb Nginx site; manual migration required\n" if -e '/etc/nginx/sites-enabled/dxweb.conf';
  my $link='/etc/nginx/sites-enabled/dxweb-installer.conf';
  if (!-e $link && !-l $link) { symlink('/etc/nginx/sites-available/dxweb-installer.conf',$link) or die "Nginx enable failed: $!"; $nginx_link_created=1; }
  if ($nginx_link_created) { write_atomic("$backup/manifest.json",JSON::PP->new->canonical->pretty->encode({format=>'dxweb-transaction-v1',root=>$o{root},journal=>\@journal,initial_active=>\%active,initial_enabled=>\%enabled,nginx_link_created=>JSON::PP::true}),0600,0,0); }
  system('nginx','-t')==0 or die "Nginx configuration invalid\n";
  system('systemctl','reload','nginx')==0 or die "Nginx reload failed\n";
 }
 for my $c (@components) {
  # Git may have changed application code without changing systemd units.
  my $s=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
  if ($active{$c}) { system('systemctl','restart',$s)==0 or die "Restart failed: $s\n"; }
  elsif (!$was_installed{$c}) { system('systemctl','start',$s)==0 or die "Start failed: $s\n"; }
  else { print "PRESERVED STOPPED: $s\n"; }
 }
 for my $c (@components) {
  next if !$active{$c} && $was_installed{$c}; # Do not probe deliberately stopped services.
  my $p=$c eq 'dxweb'?$wp:$ap;
  my $path=$c eq 'dxweb'?'/software-version.json':'/software-versions.json';
  my $checkhost=$backend eq 'https' ? $o{hostname} : '127.0.0.1';
  my $url="$backend://$checkhost:$p$path";
  my $ok=0;
  for (1..8) { sleep 1; my $r=HTTP::Tiny->new(timeout=>3,verify_SSL=>1)->get($url); if ($r->{success} && eval { my $j=decode_json($r->{content}); ref($j) eq 'HASH' && ($c eq 'dxweb' ? exists($j->{running}) : exists($j->{admin}) && exists($j->{dxweb})) }) {$ok=1;last} }
  die "Health check failed: $url\n" unless $ok;
 }
 # New services must survive reboot. Never change the enabled state of an
 # existing service, including a deliberately disabled one.
 for my $c (@components) {
  next if $was_installed{$c};
  my $s=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
  system('systemctl','enable',$s)==0 or die "Enable failed: $s\n";
 }
 1;
};
if (!$success) {
 my $err=$@||'Unknown error'; warn "INSTALL FAILED: $err";
 my @recovery_errors;
 my $recovery_error=sub { my ($message)=@_; push @recovery_errors,$message; warn "RECOVERY ERROR: $message\n"; };
 for my $c (@components) {
  my $s=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
  stop_service_bounded($s,15) or $recovery_error->("Cannot stop $s");
 }
 for my $entry (reverse @journal) {
  my $restored=eval {
   if ($entry->{existed}) {
    write_atomic($entry->{dest},read_file($entry->{backup}),$entry->{mode},$entry->{uid},$entry->{gid});
   } elsif (-e $entry->{dest}) {
    unlink $entry->{dest} or die "Cannot unlink $entry->{dest}: $!\n";
   }
   1;
  };
  $recovery_error->("Cannot restore $entry->{dest}: ".($@||'unknown error')) unless $restored;
 }
 if ($nginx) {
  if ($nginx_link_created) {
   my $link='/etc/nginx/sites-enabled/dxweb-installer.conf';
   if (-l $link && readlink($link) eq '/etc/nginx/sites-available/dxweb-installer.conf') {
    unlink $link or $recovery_error->("Cannot remove created Nginx link: $!");
   } else {
    $recovery_error->('Created Nginx link changed unexpectedly; not removing it');
   }
  }
  if (system('nginx','-t')==0) {
   system('systemctl','reload','nginx')==0 or $recovery_error->('Cannot reload Nginx');
  } else {
   $recovery_error->('Nginx configuration invalid after restoration');
  }
 }
 system('systemctl','daemon-reload')==0 or $recovery_error->('systemd daemon-reload failed');
 for my $c (@components) {
  my $s=$c eq 'dxweb'?'dxweb.service':'dxweb-admin.service';
  ($active{$c} ? system('systemctl','start',$s)==0 : stop_service_bounded($s,15)) or $recovery_error->("Cannot restore active state for $s");
  if ($was_installed{$c}) {
   system('systemctl',$enabled{$c}?'enable':'disable',$s)==0 or $recovery_error->("Cannot restore enabled state for $s");
  } else {
   system('systemctl','disable',$s)==0 or $recovery_error->("Cannot disable newly installed $s");
  }
  if ($active{$c}) {
   if (system('systemctl','is-active','--quiet',$s)!=0) {
    $recovery_error->("Service not active after recovery: $s");
   } elsif (!$original_probeable{$c}) {
    warn "RECOVERY HEALTH UNVERIFIED: $s used HTTPS; original TLS hostname unknown\n";
   } else {
    my $url=$original_endpoint{$c}; my $healthy=0;
    for (1..8) {
     sleep 1;
     my $res=HTTP::Tiny->new(timeout=>3,verify_SSL=>1)->get($url);
     $healthy=$res->{success} && eval {
      my $json=decode_json($res->{content});
      ref($json) eq 'HASH' && ($c eq 'dxweb' ? exists($json->{running}) : exists($json->{admin}) && exists($json->{dxweb}));
     };
     last if $healthy;
    }
    $recovery_error->("Health check failed after recovery: $url") unless $healthy;
   }
  }
 }
 if (@recovery_errors) {
  die "INSTALL FAILED; RECOVERY INCOMPLETE (".scalar(@recovery_errors)." errors). Original failure: $err Backup: $backup\n";
 }
 die "INSTALL FAILED; RECOVERY VERIFIED for probeable endpoints. Original failure: $err Backup: $backup\n";
}
print "INSTALL OK. Configuration backup: $backup\n";
# Strictly recognize only blocks generated by this installer.  Never
# silently preserve unexpected directives during partial updates.
sub validate_managed_nginx {
 my ($existing)=@_;
 die "Unrecognized managed Nginx layout; refusing partial update\n"
  unless defined($existing) && length($existing);
 my @blocks=split /(?<=\n\}\n)(?=server \{\n)/, $existing;
 my %old;
 for my $block (@blocks) {
  my ($port,$ssl,$hostname,$tls,$backend)=$block =~ m{\Aserver \{\nlisten (738[01])( ssl)?;\nserver_name ([a-zA-Z0-9][a-zA-Z0-9.-]*);\n((?:ssl_certificate [^\n;]+;\nssl_certificate_key [^\n;]+;\n)?)location / \{\nproxy_http_version 1\.1;\nproxy_set_header Host \$http_host;\nproxy_set_header X-Real-IP \$remote_addr;\nproxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\nproxy_set_header X-Forwarded-Proto \$scheme;\nproxy_set_header Upgrade \$http_upgrade;\nproxy_set_header Connection "upgrade";\nproxy_read_timeout 3600s;\nproxy_pass http://127\.0\.0\.1:(748[01]);\n\}\n\}\n\z};
  die "Unrecognized managed Nginx layout; refusing partial update\n"
   unless defined($port) && !exists($old{$port}) &&
          $backend == $port+100 &&
          (($ssl && length($tls)) || (!$ssl && !length($tls)));
  $old{$port}=$block;
 }
 die "Unrecognized managed Nginx layout; refusing partial update\n"
  unless join('',@blocks) eq $existing && @blocks<=2;
 return %old;
}

sub openssl_output { my @args=@_; open my $fh,'-|','openssl',@args or die "OpenSSL launch failed: $!\n"; local $/; my $out=<$fh>; close $fh or die "OpenSSL command failed\n"; return $out; }
sub read_file { my ($p)=@_; open my $f,'<',$p or die "Read $p: $!"; binmode $f; local $/; return <$f>; }
sub write_atomic { my ($p,$data,$mode,$uid,$gid)=@_; make_path(dirname($p)); my ($fh,$tmp)=tempfile('.dxweb-XXXXXX',DIR=>dirname($p),UNLINK=>0); binmode $fh; print {$fh} $data or die "Write $tmp: $!"; close $fh or die "Close $tmp: $!"; chmod $mode,$tmp or die "chmod $tmp: $!"; chown $uid,$gid,$tmp or die "chown $tmp: $!"; rename $tmp,$p or die "rename $tmp: $!"; }
