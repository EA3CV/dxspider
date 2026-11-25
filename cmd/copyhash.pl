#
# copyhash - merge native hash and plain-text files
#
# Copyright (c) 2026 Dirk Koopman G1TLH
#

use strict;
use warnings;
use File::Basename qw(basename dirname);
use File::Spec;
use Cwd qw(abs_path);
use File::Glob qw(bsd_glob GLOB_ERR GLOB_NOSORT);
use File::Temp qw(tempfile);
use Data::Dumper;
use Fcntl qw(:mode);

# DXHash files contain a flat map of keys to non-negative integer timestamps.
# The reserved name field is metadata, not a record.
sub is_text { basename($_[0]) =~ /\./ }
sub read_file {
    my ($path) = @_;
    die "not a regular file: $path\n" if -l $path || !-f $path;
    open my $fh, '<:raw', $path or die "open $path: $!\n";
    my $data = '';
    while (1) { my $n = read($fh, my $buf, 65536); defined $n or die "read $path: $!\n"; last unless $n; $data .= $buf; }
    close $fh or die "close $path: $!\n";
    return $data;
}
sub space { ${$_[0]} =~ /\G(?:\s+|\#[^\n]*)*/gc; }
sub literal {
    my ($s,$path) = @_;
    space($s);
    if ($$s =~ /\G'((?:[^'\\]|\\.)*)'/gcs) {
        my $v=$1; $v =~ s/\\(['\\])/$1/g; return $v;
    }
    if ($$s =~ /\G([A-Za-z_][A-Za-z0-9_]*|[0-9]+)(?![A-Za-z0-9_])/gc) { return $1; }
    die "invalid literal in $path at byte ".(pos($$s)//0)."\n";
}
sub expect {
    my ($s,$token,$path)=@_; space($s);
    $$s =~ /\G\Q$token\E/gc or die "expected '$token' in $path at byte ".(pos($$s)//0)."\n";
}
sub valid_key { length($_[0]) && $_[0] !~ /[\x00-\x1f\x7f]/ }
sub newer {
    my ($a,$b)=@_; return length($a)>length($b) || (length($a)==length($b) && $a gt $b);
}
sub normalize_stamp { my $v=shift; $v =~ s/^0+(?=\d)//; return $v; }
sub parse_hash {
    my ($s,$path)=@_; $s =~ s/\A\xEF\xBB\xBF//; pos($s)=0; space(\$s);
    my $blessed = $s =~ /\Gbless\b/gc;
    expect(\$s,'(',$path) if $blessed;
    expect(\$s,'{',$path); my %map; my $name_seen=0;
    while (1) {
        space(\$s); last if $s =~ /\G\}/gc;
        my $k=literal(\$s,$path); expect(\$s,'=>',$path); my $v=literal(\$s,$path);
        if ($k eq 'name') { die "duplicate name metadata in $path\n" if $name_seen++; }
        else {
            die "invalid key or timestamp in $path\n" unless valid_key($k) && $v =~ /\A[0-9]+\z/;
            $v=normalize_stamp($v); $map{$k}=$v if !exists($map{$k}) || newer($v,$map{$k});
        }
        space(\$s); last if $s =~ /\G\}/gc;
        expect(\$s,',',$path);
    }
    if ($blessed) { expect(\$s,',',$path); die "unsupported hash class in $path\n" unless literal(\$s,$path) eq 'DXHash'; expect(\$s,')',$path); }
    space(\$s); $s =~ /\G;/gc; space(\$s);
    die "unexpected content in $path\n" unless (pos($s)//0)==length($s);
    return \%map;
}
sub parse_text {
    my ($s,$path)=@_; $s =~ s/\A\xEF\xBB\xBF//; my %map;
    for my $line (split /\n/,$s) {
        $line =~ s/\r\z//; $line =~ s/^\s*#.*//; $line =~ s/[ \t]+#.*//;
        die "invalid control character in $path\n" if $line =~ /[\x00-\x08\x0a-\x1f\x7f]/;
        die "hash syntax in text source $path\n" if $line =~ /(?:^\s*bless\s*\(|^\s*[{}]|=>)/;
        $map{$_}=undef for grep { length } split /[ \t]+/,$line;
    }
    return \%map;
}
sub merge_files {
    my $output = shift;
    die "Usage: copyhash.pl source [source ...] destination\n" if @_ < 2;
    my $dest=pop; my $dir=abs_path(dirname($dest));
    die "destination directory does not exist\n" unless defined $dir && -d $dir;
    $dest=File::Spec->catfile($dir,basename($dest));
    die "invalid destination: $dest\n" if -l $dest || (-e $dest && !-f $dest) || basename($dest)=~/^\./ || $dest =~ /[\x00-\x1f\x7f]/;
    my %seen; my @sources;
    for my $arg (@_) {
        my @paths= -e $arg || -l $arg ? ($arg) : bsd_glob($arg,GLOB_ERR|GLOB_NOSORT);
        die "no source matches $arg\n" unless @paths;
        for my $p (sort @paths) {
            die "not a regular file: $p\n" if -l $p || !-f $p;
            my $real=abs_path($p); next if $seen{$real}++;
            push @sources,$real;
        }
    }
    my %merged; my ($read,$dup)=(0,0); my $now=''.time;
    my $original= -e $dest ? read_file($dest) : undef;
    for my $p (@sources) {
        my $s=read_file($p); my $map=is_text($p)?parse_text($s,$p):parse_hash($s,$p);
        push @$output, "$p: ".scalar(keys %$map)." records";
        for my $k (keys %$map) {
            ++$read; ++$dup if exists $merged{$k};
            my $v=$map->{$k};
            $merged{$k}=$v if !exists($merged{$k}) || (defined($v) && (!defined($merged{$k}) || newer($v,$merged{$k})));
        }
    }
    my $out;
    if (is_text($dest)) {
        for (keys %merged) { die "key cannot be represented in text format: $_\n" if /\s|^#/; }
        $out=join('',map { "$_\n" } sort keys %merged);
    } else {
        die "text record 'name' conflicts with reserved hash metadata\n" if exists $merged{name};
        my %h=(name=>basename($dest), map { $_ => (defined($merged{$_}) ? $merged{$_} : $now) } keys %merged);
        $out=Data::Dumper->new([bless(\%h,'DXHash')])->Terse(1)->Indent(1)->Sortkeys(1)->Quotekeys(0)->Dump;
        # Validate our own output before committing it.
        my $check=parse_hash($out,$dest); die "output verification failed\n" unless keys(%$check)==keys(%merged);
    }
    if (defined($original) && $out eq $original) { push @$output, "Result: OK (unchanged)"; return; }
    my @st=defined($original)?stat($dest):();
    my ($fh,$tmp)=tempfile('.copyhash-XXXXXXXX',DIR=>$dir,UNLINK=>0);
    my $ok=eval {
        binmode($fh,':raw') or die "binmode: $!\n";
        print {$fh} $out or die "write $tmp: $!\n";
        close($fh) or die "close $tmp: $!\n";
        if (@st) {
            my @ts=stat($tmp);
            if ($ts[4]!=$st[4] || $ts[5]!=$st[5]) { chown($st[4],$st[5],$tmp) or die "chown: $!\n"; }
            chmod($st[2]&0777,$tmp) or die "chmod: $!\n";
        } else { chmod(0666 & ~umask(),$tmp) or die "chmod: $!\n"; }
        die "destination changed during merge\n" if -l $dest || (defined($original) ? (!-f $dest || read_file($dest) ne $original) : -e $dest);
        rename($tmp,$dest) or die "rename $tmp: $!\n";
        1;
    };
    if (!$ok) { my $e=$@; close($fh) if defined fileno($fh); unlink $tmp; die $e; }
    push @$output, "Files processed: ".scalar(@sources), "Records read: $read", "Duplicate keys: $dup", "Records written: ".scalar(keys %merged), "Destination: $dest", "Result: OK";
}

sub handle
{
my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd || $self->priv < 9;
my @args = grep { length } split /\s+/, ($line // '');
return (1, 'Usage: copyhash source [source ...] destination') if @args < 2;
my $dest = $args[-1];
return (1, 'copyhash: ERROR: invalid destination filename')
    unless $dest =~ /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/;
for my $src (@args[0 .. $#args-1]) {
    return (1, 'copyhash: ERROR: invalid source filename or pattern')
        unless $src =~ /\A[A-Za-z0-9_][A-Za-z0-9_.?*-]*\z/;
}
# spawn_cmd has synchronous fallbacks. Refuse those rather than blocking DXSpider.
return (1, 'copyhash: ERROR: asynchronous execution unavailable')
    if $self->{_nospawn} || $main::is_win || !$self->can('spawn_cmd');
my $dir = File::Spec->rel2abs($main::local_data);
my @out = $self->spawn_cmd("copyhash $line", sub {
    return ('copyhash: ERROR: cannot enter local_data') unless chdir $dir;
    my @result;
    my $ok = eval { merge_files(\@result, @args); 1 };
    unless ($ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/[\x00-\x1f\x7f]/ /g;
        push @result, "copyhash: ERROR: $err";
    }
    return @result;
});
return (1, 'copyhash: started (result follows)', @out);
}
