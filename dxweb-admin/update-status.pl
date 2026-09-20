#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use File::Temp qw(tempfile);

my $root  = '/spider';
my $out   = '/root/test-sql-merge/dxweb-admin/admin/update-status.json';
my $branch = 'mojo';
my @remote = (
    ['dirk',  'git://scm.dxcluster.org/spider'],
    ['ea3cv', 'https://github.com/EA3CV/dxspider.git'],
);
sub cmd {
    my (@a)=@_; my $pid=open my $fh,'-|'; die "fork: $!" unless defined $pid;
    if(!$pid){open STDERR,'>','/dev/null'; exec @a; exit 127}
    local $/; my $v=<$fh>//''; close $fh; $v =~ s/^\s+|\s+$//g; return ($?==0?$v:'');
}
my $local = cmd('git','-C',$root,'rev-parse','HEAD');
my $local_branch = cmd('git','-C',$root,'rev-parse','--abbrev-ref','HEAD');
my ($remote_commit,$source,$error)=('','','');
for my $r (@remote) {
    my ($name,$url)=@$r;
    my $v=cmd('timeout','8','git','ls-remote',$url,"refs/heads/$branch");
    if($v =~ /^([0-9a-f]{40})\s+/i){$remote_commit=lc $1;$source=$name;last}
}
$error='both remote checks failed' unless $remote_commit;
my $status = !$local || !$remote_commit ? 'CHECK_FAILED' : lc($local) eq lc($remote_commit) ? 'UPDATED' : 'NOT_UPDATED';
my %j=(status=>$status,branch=>$branch,local_branch=>$local_branch,local_commit=>$local,remote_commit=>$remote_commit,source=>$source,checked_at=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime));
$j{error}=$error if $error;
my ($fh,$tmp)=tempfile('update-status.XXXXXX',DIR=>'/root/test-sql-merge/dxweb-admin/admin',UNLINK=>0);
print $fh encode_json(\%j),"\n"; close $fh; chmod 0644,$tmp; rename $tmp,$out or die "rename $tmp -> $out: $!\n";
print "$status source=",($source||'-')," local=",($local||'-')," remote=",($remote_commit||'-'),"\n";
