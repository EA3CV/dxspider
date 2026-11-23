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

	# move existing file to localhost, if necessary.
	localdata_mv($name);
	_badlist_run() if defined($main::local_data) && -d $main::local_data;
	my $s = readfilestr($main::local_data, $name);
	my $self = undef;
	$self = eval $s if $s;
	dbg("error in reading $name in DXHash $@") if $@;
	$self = bless({name => $name}, $pkg) unless defined $self;
    bless($self,$pkg) if ref($self) eq 'HASH';
	
	if (_is_multifile_list($name)) {
        my %merged;
        for my $path (_list_files($name)) {
            my $obj = _list_read($path);
            for my $call (keys %$obj) {
                next if $call eq 'name';
                $merged{$call} = $obj->{$call};
            }
        }
        %$self = (name => $name);
        $self->add($_, $merged{$_}) for sort keys %merged;
    }
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
	$self->{$nn} = $t unless exists $self->{$nn} || $n eq $nn;
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
	return exists $self->{$m};
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
    my ($path) = @_;
    my $src = readfilestr($path);
    die "cannot read $path" unless defined $src;
    if ($path =~ /\.(?:[^\/]+)$/) {
        my %obj = (name => basename($path) =~ /^([^.]*)/ ? $1 : '');
        for my $line (split /\n/, $src) {
            $line =~ s/\r$//;
            $line =~ s/\s+#.*$//;
            next if $line =~ /^\s*(?:#|$)/;
            for my $word (split /\s+/, $line) {
                $obj{uc $word} = $main::systime || time;
            }
        }
        return \%obj;
    }
    my $obj = eval $src;
    die "invalid $path: $@" if $@;
    die "invalid hash in $path" unless ref($obj) && eval { keys %$obj; 1 };
    return $obj;
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



# Startup verification of bad* lists. No additional module.
our $badlist_checked = 0;

sub _badlist_log {
    my ($msg) = @_;
    if (defined &DXLog::LogDbg) { eval { DXLog::LogDbg('audit', "DXHash badlist: $msg") }; }
    elsif (defined &DXDebug::dbg) { DXDebug::dbg("DXHash badlist: $msg") }
    else { warn "DXHash badlist: $msg\n" }
}
sub _badlist_write {
    my ($path,$src,$out,$removed,$kind) = @_;
    return if $src eq $out;
    my $backup_dir = "$main::local_data/badlist-backups";
    make_path($backup_dir, { mode => 0700 }) unless -d $backup_dir;
    my $bak = "$backup_dir/" . basename($path) . "." . time . "-$$";
    my $seq = 0;
    $bak .= "." . ++$seq while -e $bak;
    copy($path,$bak) or die "backup $path -> $bak: $!";
    my ($fh,$tmp) = tempfile('.badlist-check-XXXXXX',DIR=>dirname($path),UNLINK=>0);
    my $mode = (stat($path))[2] & 07777;
    my $ok = eval {
        chmod($mode,$tmp) or die "chmod $tmp: $!";
        print {$fh} $out or die "write $tmp: $!";
        close($fh) or die "close $tmp: $!";
        rename($tmp,$path) or die "rename $tmp: $!";
        1;
    };
    if (!$ok) { my $err=$@; close($fh) if fileno($fh); unlink($tmp); die $err; }
    _badlist_log("repaired $path format=$kind removed=$removed backup=$bak");
}
sub _badlist_hash {
    my ($path,$src) = @_;
    my $base=basename($path);
    my $obj=eval $src;
    if (!$@ && ref($obj) && eval { keys %$obj; 1 }) {
        my %clean;
        my $removed=0;
        for my $key (keys %$obj) {
            if ($key eq 'name') { $clean{name}=$base; next; }
            if ($key =~ m{\A[A-Za-z0-9_/-]+\z} && defined($obj->{$key}) && !ref($obj->{$key}) && $obj->{$key} =~ /\A[0-9]+\z/) {
                $clean{$key}=$obj->{$key};
            } else { ++$removed; }
        }
        return unless $removed;
        my $out=Data::Dumper->new([\%clean])->Indent(1)->Terse(1)->Quotekeys(0)->Dump;
        _badlist_write($path,$src,$out,$removed,'hash');
        return;
    }
    # Salvage only isolated key => integer rows within an intact hash envelope.
    my @lines=split /(?<=\n)/,$src;
    my $first=shift @lines;
    my $last=pop @lines;
    die "invalid hash envelope $path" unless defined($first) && defined($last)
        && $first =~ /^\s*(?:bless\s*\(\s*)?\{\s*$/
        && $last =~ /^\s*\}\s*(?:,\s*['"]DXHash['"]\s*\))?\s*;?\s*$/;
    my (%clean,$removed,$name); $removed=0;
    for my $line (@lines) {
        if ($line =~ /^\s*(?:'([^']+)'|([A-Za-z0-9_\/-]+))\s*=>\s*(?:'([^']*)'|([0-9]+))\s*,?\s*$/) {
            my ($key,$val)=(defined($1)?$1:$2,defined($3)?$3:$4);
            if ($key eq 'name' && $val eq $base) { $name=$val; $clean{name}=$val; }
            elsif ($key =~ m{\A[A-Za-z0-9_/-]+\z} && $val =~ /^\d+$/) { $clean{$key}=$val; }
            else { ++$removed; }
        } elsif ($line =~ /^\s*$/) { next; }
        else { ++$removed; }
    }
    die "invalid hash name $path" unless defined $name;
    # Re-serialize parsed keys, never re-evaluate the original unquoted rows.
    # Data::Dumper correctly quotes digit-leading callsigns such as 6L0NJ.
    my $out=Data::Dumper->new([\%clean])->Indent(1)->Terse(1)->Quotekeys(0)->Dump;
    my $check=eval $out;
    die "invalid recovered hash $path: $@" if $@ || !ref($check) || !eval { keys %$check; 1 };
    _badlist_write($path,$src,$out,$removed,'hash');
}
sub _badlist_text {
    my ($path,$src,$type) = @_;
    # A legacy Hash stored in a dotted file is migrated to text once, with backup.
    if ($type eq 'call') {
        my $obj=eval $src;
        if (!$@ && ref($obj) && eval { keys %$obj; 1 }) {
            my @words=sort grep { $_ ne 'name' && m{\A[A-Za-z0-9_/-]+\z} && defined($obj->{$_}) && !ref($obj->{$_}) && $obj->{$_} =~ /^\d+$/ } keys %$obj;
            my $invalid=(scalar(keys %$obj)-1)-scalar(@words);
            my $out=join('',map { "$_\n" } @words);
            _badlist_write($path,$src,$out,$invalid,'hash-to-text');
            return;
        }
    }
    if ($type eq 'call' && $src =~ /^\s*(?:bless\s*\(|\{)/) {
        die "unrecoverable dotted hash $path (kept unchanged)";
    }
    my @lines=split /(?<=\n)/,$src;
    my (@keep,$removed); $removed=0;
    for my $line (@lines) {
        my $v=$line; $v =~ s/\r?\n$//;
        if ($v =~ /^\s*(?:#|$)/) { push @keep,$line; next; }
        if ($type eq 'ip') {
            if (DXCIDR::valid_spec($v)) { push @keep,$line; } else { ++$removed; }
        } else {
            $v =~ s/\s+#.*$//;
            my @words=split /\s+/, $v;
            my $valid= @words && !grep { $_ !~ ($type eq 'call' ? qr{\A[A-Za-z0-9_/-]+\z} : qr{\A[A-Za-z0-9_]+\z}) } @words;
            if ($valid) { push @keep,$line; } else { ++$removed; }
        }
    }
    _badlist_write($path,$src,join('',@keep),$removed,$type);
}
sub _badlist_run {
    return if $badlist_checked;
    my $dir=$main::local_data;
    return unless defined($dir) && -d $dir;
    opendir(my $dh,$dir) or die "DXHash badlist: opendir $dir: $!";
    my @names=sort grep { /^bad/ && !/^badlist-/ && -f "$dir/$_" && !/\.badlist-backup-/ && !/\.bak(?:\.|$)/ } readdir($dh);
    closedir $dh;
    for my $name (@names) {
        my $path="$dir/$name";
        my $ok=eval {
            open(my $fh,'<',$path) or die "open $path: $!";
            local $/; my $src=<$fh>; close $fh;
            if ($name =~ /^badip(?:\.\w+)?$/) { _badlist_text($path,$src,'ip'); }
            elsif ($name !~ /\./) { _badlist_hash($path,$src); }
            elsif ($name =~ /^(?:baddx|badnode|badspotter)\.[A-Za-z0-9_]+$/) { _badlist_text($path,$src,'call'); }
            elsif ($name =~ /^badword\.[A-Za-z0-9_]+$/) { _badlist_text($path,$src,'word'); }
            elsif ($name =~ /^bad[A-Za-z0-9_]+\.[A-Za-z0-9_]+$/) { _badlist_text($path,$src,'word'); }
            1;
        };
        if (!$ok) { my $err=$@ || 'unknown error'; _badlist_log("ERROR $path: $err"); die "DXHash badlist: $err"; }
    }
    $badlist_checked=1;
}
1;
