#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use File::Temp qw(tempfile);
my $root='/spider';
use FindBin qw($Bin);
my $out="$Bin/admin/update-status.json";
my $branch='mojo';
my @remote=(['dirk','git://scm.dxcluster.org/spider'],['ea3cv','https://github.com/EA3CV/dxspider.git']);
sub cmd{my(@a)=@_;my$pid=open my$fh,'-|';die"fork: $!"unless defined$pid;if(!$pid){open STDERR,'>','/dev/null';exec @a;exit 127}local$/;my$v=<$fh>//'';close$fh;$v=~s/^\s+|\s+$//g;return $?==0?$v:''}
sub desc{my($r)=@_;my$d=cmd('git','-C',$root,'describe','--long',$r);return unless$d;my($v,$s,$b,$g)=$d=~/^([\d.]+)(?:\.(\d+))?-(\d+)-g([0-9a-f]+)/i;return unless defined$v;($v,0+$b,lc$g)}
sub field_cmp{my($l,$r)=@_;my$ok=defined$l&&"$l"ne''&&defined$r&&"$r"ne'';{local=>defined$l?"$l":'',remote=>defined$r?"$r":'',comparable=>$ok?JSON::PP::true:JSON::PP::false,match=>$ok?("$l"eq"$r"?JSON::PP::true:JSON::PP::false):undef}}
my$lc=cmd('git','-C',$root,'rev-parse','HEAD');my$lb=cmd('git','-C',$root,'rev-parse','--abbrev-ref','HEAD');my($lv,$lbuild)=desc('HEAD');
my($rc,$source,$error)=('','','');for my$r(@remote){my($n,$url)=@$r;my$v=cmd('timeout','8','git','ls-remote',$url,"refs/heads/$branch");if($v=~/^([0-9a-f]{40})\s+/i){$rc=lc$1;$source=$n;last}}$error='both remote checks failed'unless$rc;
my($rv,$rbuild);if($rc&&cmd('git','-C',$root,'cat-file','-t',$rc)eq'commit'){($rv,$rbuild)=desc($rc)}
my%cp=(branch=>field_cmp($lb,$branch),version=>field_cmp($lv,$rv),build=>field_cmp($lbuild,$rbuild),commit=>field_cmp(lc($lc||''),lc($rc||'')));
my$status=!$lc||!$rc?'CHECK_FAILED':lc($lc)eq lc($rc)?'UPDATED':'NOT_UPDATED';
my%j=(status=>$status,branch=>$branch,local_branch=>$lb,local_commit=>$lc,remote_commit=>$rc,source=>$source,checked_at=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime),local_version=>$lv//'',local_build=>$lbuild//'',remote_version=>$rv//'',remote_build=>$rbuild//'',comparisons=>\%cp);$j{error}=$error if$error;
my($fh,$t)=tempfile('update-status.XXXXXX',DIR=>"$Bin/admin",UNLINK=>0);print$fh encode_json(\%j),"\n";close$fh;chmod 0644,$t;rename$t,$out or die"rename: $!\n";
for my$n(qw(branch version build commit)){my$c=$cp{$n};print"$n=",(!$c->{comparable}?'UNKNOWN':$c->{match}?'MATCH':'MISMATCH')," "}print"overall=$status\n";
