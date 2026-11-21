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

sub new
{
	my ($pkg, $name) = @_;

	# move existing file to localhost, if necessary.
	localdata_mv($name);
	my $s = readfilestr($main::local_data, $name);
	my $self = undef;
	$self = eval $s if $s;
	dbg("error in reading $name in DXHash $@") if $@;
	$self = bless({name => $name}, $pkg) unless defined $self;
	
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
    # Existing DXHash files are Data::Dumper Perl hashes. Do not execute
    # arbitrary code from files beyond the existing DXHash read convention.
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
    my $local = "$main::local_data/$name.local";
    my @out;
    my %changed;

    for my $call (@calls) {
        my @found = grep { exists $data{$_}{$call} } @paths;
        if ($op eq 'set') {
            if (@found) {
                push @out, $dxchan->msg('hasha', $call, $name);
                next;
            }
            if (!exists $data{$local}) {
                $data{$local} = { name => $name };
                push @paths, $local;
            }
            $data{$local}{$call} = $main::systime;
            $changed{$local} = 1;
            push @out, $dxchan->msg('hashb', $call, $name);
        } else {
            if (!@found) {
                push @out, $dxchan->msg('hashd', $call, $name);
                next;
            }
            for my $path (@found) {
                delete $data{$path}{$call};
                $changed{$path} = 1;
            }
            push @out, $dxchan->msg('hashc', $call, $name);
        }
    }
    # Persist every changed source before rebuilding the live lookup.
    for my $path (sort keys %changed) {
        _list_write($path, $data{$path});
    }
    # Rebuild from all files.  add() supplies the historical basecall
    # fallback for SSIDs, but never writes that derived key into a file.
    my %merged;
    for my $path (@paths) {
        my $obj = $data{$path};
        for my $call (keys %$obj) {
            next if $call eq 'name';
            $merged{$call} = $obj->{$call};
        }
    }
    %$self = (name => $name);
    for my $call (sort keys %merged) {
        $self->add($call, $merged{$call});
    }
    return (1, @out);
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

1;
