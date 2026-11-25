#
# a class for setting 'bad' (or good) things
#
# This is really a general purpose list handling 
# thingy for determining good or bad objects like
# callsigns. It is for storing things "For Ever".
#
# Things entered into the list are always upper
# cased.
# 
# The files that are created live in /spider/local_data (was data)
# 
# Dunno why I didn't do this earlier but heyho..
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
#
#

package DXHash;

use DXVars;
use DXUtil;
use DXDebug;

use strict;
use File::Basename qw(basename);
use File::Temp qw(tempfile);
use Data::Dumper;
use File::Copy qw(copy);
use File::Basename qw(dirname);
use File::Path qw(make_path);

sub new
{
	my ($pkg, $name) = @_;

    # Keep unrelated DXHash consumers on the historical path.
    unless (_is_multifile_list($name)) {
        localdata_mv($name);
        my $s = readfilestr($main::local_data, $name);
        my $self = undef;
        $self = eval $s if $s;
        dbg("error in reading $name in DXHash $@") if $@;
        $self = bless({name=>$name}, $pkg) unless defined $self;
        bless($self,$pkg) if ref($self) eq 'HASH';
        return $self;
    }
    my $self = bless {name => $name}, $pkg;
    return $self unless defined($main::local_data) && length($main::local_data);
    my $migrated = eval { localdata_mv($name); 1 };
    _badlist_log("migration failed for $name: $@") unless $migrated;
    my @paths;
    my $ok = eval { @paths = _list_files($name); 1 };
    _badlist_log("enumeration failed for $name: $@") unless $ok;
    # If migration failed, read the original without trying to rewrite it.
    push @paths, "$main::data/$name" if !$migrated && defined($main::data)
        && -f "$main::data/$name" && !-e "$main::local_data/$name";
    my %merged;
    for my $path (@paths) {
        my $obj;
        my $loaded = eval { $obj = _list_read($path, !$migrated && defined($main::data) && $path eq "$main::data/$name", 1); 1 };
        unless ($loaded) { _badlist_log("source skipped $path: $@"); next; }
        $merged{$_}=$obj->{$_} for grep { $_ ne 'name' } keys %$obj;
    }
    $self->add($_,$merged{$_}) for sort keys %merged;
    return $self;
}

sub put
{
	my $self = shift;
	writefilestr($main::local_data, $self->{name}, undef, $self);
}

sub add
{
	my $self = shift;
	my $n = uc shift;
	my $t = shift || $main::systime;
	$self->{$n} = $t;

	# also add the base version if it has some ssid on it
	my $nn = basecall($n);
	$self->{$nn} = $t if defined($nn) && length($nn) && !exists($self->{$nn}) && $n ne $nn;
}

sub del
{
	my $self = shift;
	my $n = uc shift;
	my $exact = shift;
	delete $self->{$n};
	return if $exact;

	my $nn = basecall($n);
	my @ssid = (0..99);
	delete $self->{"$nn-$_"} for @ssid;
}


sub in
{
	my $self = shift;
	my $n = uc shift;
	my $exact = shift;
	
	return 1 if exists $self->{$n};
	return 0 if $exact;
	my $m = basecall($n);
	return defined($m) && length($m) && exists $self->{$m};
}

# File-backed lists with layered sources. Keep other DXHash lists unchanged.
sub _is_multifile_list { return $_[0] =~ /\A(?:badnode|baddx|badspotter)\z/; }
sub _list_files
{
    my $name = shift;
    my $dir = $main::local_data;
    # DXProt constructs these objects while modules are being loaded.
    # A standalone perl -c may load DXProt before cluster.pl sets local_data.
    # Match the original DXHash behavior in that uninitialized context:
    # do not enumerate files or abort the module load.
    return () unless defined($dir) && length($dir);
    opendir(my $dh, $dir) or die "$name: cannot open $dir: $!";
    my @names = sort grep { /^\Q$name\E(?:\.[^\/]+)?$/ && -f "$dir/$_" } readdir($dh);
    closedir($dh);
    return map { "$dir/$_" } @names;
}

sub _list_read
{
    my ($path, $readonly, $startup) = @_;
    my ($name) = basename($path) =~ /^([^.]+)/;
    my ($obj) = _badlist_source($path, 'call', $readonly, !$startup);
    return {name => $name, %$obj};
}

sub _list_write
{
    my ($path, $obj) = @_;
    my ($fh, $tmp) = tempfile('.dxhash-XXXXXX', DIR => $main::local_data, UNLINK => 0);
    my $ok = eval {
        my $d = Data::Dumper->new([$obj]);
        $d->Indent(1); $d->Terse(1); $d->Quotekeys(0);
        print {$fh} $d->Dumpxs or die "write $tmp: $!";
        my $mode = -e $path ? ((stat($path))[2] & 07777) : 0664;
        chmod($mode, $tmp) or die "chmod $tmp: $!";
        close($fh) or die "close $tmp: $!";
        rename($tmp, $path) or die "rename $tmp to $path: $!";
        1;
    };
    if (!$ok) {
        my $err = $@ || 'unknown error';
        close $fh if fileno($fh);
        unlink $tmp;
        die $err;
    }
}

sub _list_command
{
    my ($self, $op, $priv, $noline, $dxchan, $line) = @_;
    my $name = $self->{name};
    die "$name: local_data not initialized" unless defined($main::local_data) && length($main::local_data);
    return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
    my @calls = map { uc $_ } grep { length } split /\s+/, $line;
    return (1, $noline) unless @calls;
    my @paths = _list_files($name);
    my %data = map { $_ => _list_read($_) } @paths;
    my %before = map { $_ => { %{$data{$_}} } } @paths;
    my $local = "$main::local_data/$name.local";
    my @out;
    my %changed;
    for my $call (@calls) {
        my @found = grep { exists $data{$_}{$call} } @paths;
        if ($op eq 'set') {
            if (@found) { push @out, $dxchan->msg('hasha', $call, $name); next; }
            if (!exists $data{$local}) { $data{$local} = { name => $name }; push @paths, $local; }
            $data{$local}{$call} = $main::systime || time;
            $changed{$local} = 1;
            push @out, $dxchan->msg('hashb', $call, $name);
        } else {
            if (!@found) { push @out, $dxchan->msg('hashd', $call, $name); next; }
            for my $path (@found) { delete $data{$path}{$call}; $changed{$path} = 1; }
            push @out, $dxchan->msg('hashc', $call, $name);
        }
    }
    for my $path (sort keys %changed) {
        die "cannot modify symlink $path" if -l $path;
        if ($path =~ /\.[^\/]+$/) {
            my $old = readfilestr($path);
            my $out;
            if (defined $old) {
                my %deleted = map { $_ => 1 } grep { $_ ne 'name' && !exists $data{$path}{$_} } keys %{$before{$path} || {}};
                my @lines;
                for my $line (split /(?<=\n)/, $old) {
                    if ($line =~ /^\s*(?:#|$)/) { push @lines,$line; next; }
                    my $body=$line; $body =~ s/\s+#.*$//; $body =~ s/\s+$//;
                    my @tokens=grep { !$deleted{uc $_} } split /\s+/, $body;
                    push @lines, join(' ',@tokens)."\n" if @tokens;
                }
                $out=join('',@lines);
            } else { $out=''; }
            my %added=map { $_ => 1 } grep { $_ ne 'name' && !exists $before{$path}{$_} } keys %{$data{$path}};
            $out .= "\n" if length($out) && $out !~ /\n\z/ && %added;
            $out .= join('',map { "$_\n" } sort keys %added);
            _list_write_text($path,$out);
        } else { _list_write($path,$data{$path}); }
    }
    my %merged;
    for my $path (@paths) {
        for my $call (keys %{$data{$path}}) {
            next if $call eq 'name';
            $merged{$call} = $data{$path}{$call};
        }
    }
    %$self = (name => $name);
    $self->add($_,$merged{$_}) for sort keys %merged;
    return (1,@out);
}

sub _list_write_text
{
    my ($path,$out) = @_;
    my ($fh,$tmp) = tempfile('.badlist-new-XXXXXX', DIR=>$main::local_data, UNLINK=>0);
    my $ok=eval { print {$fh} $out or die $!; close($fh) or die $!; rename($tmp,$path) or die $!; 1 };
    if (!$ok) { my $err=$@; close($fh) if fileno($fh); unlink $tmp; die $err; }
}

# this is really just a general shortcut for all commands to
# set and unset values 
sub set
{
	my ($self, $priv, $noline, $dxchan, $line) = @_;
	return $self->_list_command('set', $priv, $noline, $dxchan, $line) if _is_multifile_list($self->{name});
	return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
	my @f = split /\s+/, $line;
	return (1, $noline) unless @f;
	my $f;
	my @out;
	
	foreach $f (@f) {

		if ($self->in($f, 1)) {
			push @out, $dxchan->msg('hasha',uc $f, $self->{name});
			next;
		}
		$self->add($f, $main::systime);
		push @out, $dxchan->msg('hashb', uc $f, $self->{name});
	}
	$self->put;
	return (1, @out);
}

# this is really just a general shortcut for all commands to
# set and unset values 
sub unset
{
	my ($self, $priv, $noline, $dxchan, $line) = @_;
	return $self->_list_command('unset', $priv, $noline, $dxchan, $line) if _is_multifile_list($self->{name});
	return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
	my @f = split /\s+/, $line;
	return (1, $noline) unless @f;
	my $f;
	my @out;
	
	foreach $f (@f) {

		unless ($self->in($f, 1)) {
			push @out, $dxchan->msg('hashd', uc $f, $self->{name});
			next;
		}
		$self->del($f, 1);
		push @out, $dxchan->msg('hashc', uc $f, $self->{name});
	}
	$self->put;
	return (1, @out);
}

sub show
{
	my ($self, $priv, $dxchan) = @_;
	return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
	
	my @out;
	for (sort keys %{$self}) {
		next if $_ eq 'name';
		push @out, $dxchan->msg('hashe', $_, cldatetime($self->{$_}));
	}
	return (1, @out);
}



# Shared data-only bad-list recovery. Each consumer validates the exact
# sources it will load, after any migration. Never evaluate list contents.
sub _badlist_log {
    my ($msg) = @_;
    my $ok = defined(&DXLog::LogDbg) && eval { DXLog::LogDbg('audit', "DXHash badlist: $msg"); 1 };
    unless ($ok) {
        eval { DXDebug::dbg("DXHash badlist: $msg"); 1 } or eval { warn "DXHash badlist: $msg\n"; 1 };
    }
}
sub _badlist_write {
    my ($path,$src,$out,$removed,$kind) = @_;
    return if $src eq $out;
    my $backup_dir = "$main::local_data/badlist-backups";
    make_path($backup_dir, { mode => 0700 }) unless -d $backup_dir;
    my $bak = "$backup_dir/" . basename($path) . "." . time . "-$$";
    my $seq = 0;
    $bak .= "." . ++$seq while -e $bak;
    # Copy the exact bytes inspected, and refuse to overwrite a concurrently changed source.
    my $current = readfilestr($path);
    $current = '' if !defined($current) && -z $path;
    die "source changed during repair $path" unless defined($current) && $current eq $src;
    copy($path,$bak) or die "backup $path -> $bak: $!";
    my ($fh,$tmp) = tempfile('.badlist-check-XXXXXX',DIR=>dirname($path),UNLINK=>0);
    my @st = stat($path);
    my $mode = $st[2] & 07777;
    my $ok = eval {
        my @ts = stat($tmp);
        if ($ts[4] != $st[4] || $ts[5] != $st[5]) { chown($st[4],$st[5],$tmp) or die "chown $tmp: $!"; }
        chmod($mode,$tmp) or die "chmod $tmp: $!";
        print {$fh} $out or die "write $tmp: $!";
        close($fh) or die "close $tmp: $!";
        my $current=readfilestr($path);
        $current='' if !defined($current) && -z $path;
        die "source changed during repair $path" unless defined($current) && $current eq $src;
        rename($tmp,$path) or die "rename $tmp: $!";
        1;
    };
    if (!$ok) { my $err=$@; close($fh) if fileno($fh); unlink($tmp); die $err; }
    _badlist_log("repaired $path format=$kind removed=$removed backup=$bak");
}
# Parse the native Data::Dumper format without executing it. Recovery is
# deliberately limited to complete literal key/value records, never guessing
# timestamps or interpreting arbitrary Perl expressions.
sub _badlist_hash {
    my ($src,$name,$type) = @_;
    my %clean;
    my ($removed,$changed,$named) = (0,0,0);
    my $body = $src;
    $changed++ if $body =~ s/\A\xEF\xBB\xBF//;
    my $blessed = $body =~ /\A\s*bless\s*\(/;
    $changed++ unless $body =~ s/\A\s*(?:bless\s*\(\s*)?\{//;
    if ($blessed) { $changed++ unless $body =~ s/\}\s*,\s*['"]DXHash['"]\s*\)\s*;?\s*\z//; }
    else { $changed++ unless $body =~ s/\}\s*;?\s*\z//; }
    # Missing commas between physical rows are repairable.
    $changed++ if $body =~ /[^,\s]\s*\n\s*[^\s#]/;
    # Data::Dumper emits one record per line. Also accept compact literal
    # records; a comma inside an invalid quoted key is not a separator.
    for my $line (split /\n/, $body) {
        next if $line =~ /^\s*(?:#.*)?$/;
        my @records;
        my $start=0; my $quote='';
        for (my $i=0; $i<length($line); ++$i) {
            my $c=substr($line,$i,1);
            if ($quote) { $quote='' if $c eq $quote; }
            elsif ($c eq "'" || $c eq '"') { $quote=$c; }
            elsif ($c eq ',') { push @records,substr($line,$start,$i-$start); $start=$i+1; }
            elsif ($c eq '#') { $line=substr($line,0,$i); last; }
        }
        push @records,substr($line,$start);
        $changed++ if grep { /^\s*$/ } @records[0..$#records-1];
        for my $row (@records) {
            next if $row =~ /^\s*$/;
            if ($row =~ /^\s*(?:'([^']*)'|"([^"\\]*)"|([A-Za-z0-9_\/-]+))\s*=>\s*(?:'([^']*)'|"([^"\\]*)"|([0-9]+))\s*$/) {
                my $key = defined($1) ? $1 : defined($2) ? $2 : $3;
                my $val = defined($4) ? $4 : defined($5) ? $5 : $6;
                if ($key eq 'name') { $named++; $changed++ if $val ne $name || $named > 1; next; }
                if (_badlist_token($key,$type) && $val =~ /\A[0-9]+\z/ && length($val) <= 18) {
                    $changed++ if exists $clean{$key};
                    $changed++ if $row =~ /=>\s*0[0-9]+\s*$/ || $row =~ /^\s*0[0-9]+\s*=>/;
                    # Unquoted digit-leading mixed keys, slash and hyphen
                    # are not native Perl barewords; reserialize them.
                    $changed++ if $row =~ /^\s*[0-9A-Za-z_\/-]+\s*=>/ && $key !~ /\A(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+)\z/;
                    $clean{$key} = $val;
                    next;
                }
            }
            $removed++;
        }
    }
    $changed++ unless $named == 1;
    my $out = $src;
    if ($changed || $removed) {
        $out = Data::Dumper->new([bless({name=>$name,%clean}, 'DXHash')])->Indent(1)->Terse(1)->Quotekeys(0)->Sortkeys(1)->Dump;
    }
    return (\%clean,$out,$removed);
}
sub _badlist_token {
    my ($token,$type) = @_;
    return $token =~ /\A[A-Za-z0-9_\/-]+\z/ if $type eq 'call';
    return $token =~ /\A[A-Za-z0-9_]+\z/ if $type eq 'word';
    # Legacy badw_regex words are literal tokens, including punctuation.
    return $token =~ /\A[^\x00-\x20\x7f]+\z/ if $type eq 'legacy';
    return 0;
}
sub _badlist_text {
    my ($src,$type) = @_;
    my (@tokens,@keep); my $removed=0;
    my $first=1;
    for my $line (split /(?<=\n)/,$src) {
        my $v=$line;
        my $bom=$first && ($v =~ s/\A\xEF\xBB\xBF//);
        $first=0;
        $v =~ s/\r?\n\z//;
        if ($v =~ /^\s*(?:#|$)/) { push @keep,($bom ? "$v\n" : $line); next; }
        my $comment='';
        if ($type ne 'legacy' && $v =~ s/(\s+#.*)\z//) { $comment=$1; }
        $v =~ s/\A[ \t]+|[ \t]+\z//g;
        my @parts=split /[ \t]+/, $v;
        my @good;
        for my $token (@parts) {
            my $valid = $type eq 'ip' ? eval { DXCIDR::valid_spec($token) } : _badlist_token($token,$type);
            if ($valid) { push @good,$token; push @tokens,$token; }
            else { ++$removed; }
        }
        if ($type eq 'ip') {
            if (!$bom && @good == 1 && @parts == 1 && $line eq $good[0]."\n") { push @keep,$line; next; }
            if (@good) { push @keep, map { "$_\n" } @good; $comment =~ s/^\s+//; push @keep, "$comment\n" if length $comment; }
            elsif (length $comment) { $comment =~ s/^\s+//; push @keep,"$comment\n"; }
            next;
        }
        if (!$bom && @good == @parts) { push @keep,$line; }
        elsif (@good) { push @keep, join(' ',@good).$comment."\n"; }
        elsif (length $comment) { $comment =~ s/^\s+//; push @keep,"$comment\n"; }
    }
    return (\@tokens,join('',@keep),$removed);
}
sub _badlist_source {
    my ($path,$type,$readonly,$strict_write) = @_;
    die "not a regular source $path" unless -f $path;
    open(my $fh,'<',$path) or die "open $path: $!";
    binmode($fh);
    my $src='';
    while (1) { my $n=read($fh,my $buf,65536); die "read $path: $!" unless defined $n; last unless $n; $src.=$buf; }
    close($fh) or die "close $path: $!";
    my ($name) = basename($path) =~ /^([^.]+)/;
    my ($obj,$out,$removed,$kind);
    if (($type eq 'call' || $type eq 'word') && (basename($path) eq $name || $src =~ /\A(?:\xEF\xBB\xBF)?\s*(?:bless\s*\(|\{)/ || $src =~ /^\s*(?:[A-Za-z0-9_\/-]+|'[^'\n]*'|"[^"\n]*")\s*=>\s*(?:[0-9]+|['"][0-9]+['"])\s*,?\s*$/m)) {
        ($obj,$out,$removed)=_badlist_hash($src,$name,$type);
        $kind='hash';
        if (basename($path) ne $name) { $out=join('',map { "$_\n" } sort keys %$obj); $kind='hash-to-text'; }
    } else {
        my $tokens;
        ($tokens,$out,$removed)=_badlist_text($src,$type);
        $obj=($type eq 'call' || $type eq 'word') ? {map { uc($_)=>($main::systime || time) } @$tokens} : $tokens;
        $kind=$type;
    }
    if ($src ne $out && !$readonly && !-l $path) {
        my $ok=eval { _badlist_write($path,$src,$out,$removed,$kind); 1 };
        unless ($ok) { my $err=$@; die $err if $strict_write; _badlist_log("repair not persisted $path; using recovered records in memory: $err"); }
    }
    if ($src ne $out && -l $path) { die "cannot repair symlink $path" if $strict_write; _badlist_log("source is a symlink; using recovered records without rewriting $path"); }
    return ($obj,$out,$removed);
}
1;
