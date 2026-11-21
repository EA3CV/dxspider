#
# Search for bad words in strings
#
# Copyright (c) 2000 Dirk Koopman
#
#
#

package BadWords;

use strict;

use DXUtil;
use DXVars;
use DXDebug;

use IO::File;

our $regex;					# the big bad regex generated from @relist
our @relist; # the list of regexes to try, record = [canonical word, regex] 
my %in;	# the collection of words we are building up and their regexes


# Load all badword sources without rewriting or converting their formats.
# The extensionless historical file is a Data::Dumper DXHash object; .new
# and other badword.* files are line-oriented word lists.
sub _sources
{
    my $dir = $main::local_data;
    opendir my $dh, $dir or return ();
    my @files = sort map { "$dir/$_" }
                grep { $_ eq 'badword' || /^badword\./ }
                grep { -f "$dir/$_" } readdir $dh;
    closedir $dh;
    return @files;
}

sub _source_words
{
    my ($file) = @_;
    my $fh = IO::File->new($file, 'r') or return (undef, "BadWords: can't open $file: $!");
    my @words;
    my $line = 0;
    while (my $text = <$fh>) {
        ++$line;
        chomp $text;
        $text =~ s/\r$//;
        next if $text =~ /^\s*(?:#|$)/;
        if ($file =~ m{/badword$}) {
            # Parse only key/timestamp records. Never eval an untrusted file.
            if ($text =~ /^\s*(?:'([^']+)'|([A-Za-z0-9_]+))\s*=>\s*\d+\s*,?\s*$/) {
                my $key = defined $1 ? $1 : $2;
                push @words, uc $key unless lc($key) eq 'name';
            } elsif ($text =~ /^\s*name\s*=>/ || $text =~ /^\s*(?:bless\s*\(\s*\{|\}\s*,\s*'DXHash'\s*\))\s*$/) {
                next;
            } else {
                $fh->close;
                return (undef, "BadWords: invalid historical record $file:$line");
            }
        } else {
            # Plain files: one or more words per line, comments permitted.
            $text =~ s/\s+#.*$//;
            push @words, split /\s+/, uc $text;
        }
    }
    $fh->close;
    return (\@words, undef);
}

sub load
{
    my @files = _sources();
    my $newfn = localdata('badword.new');
    if (!@files) {
        filecopy("$main::data/badword.new.issue", $newfn) unless -e $newfn;
        @files = _sources();
    }
    my @words;
    for my $file (@files) {
        my ($found, $error) = _source_words($file);
        if ($error) {
            dbg($error);
            return ($error); # retain the previous active list on failure
        }
        push @words, @$found;
    }
    %in = ();
    @relist = ();
    $regex = '';
    add_regex($_) for sort @words;
    generate_regex();
    dbg('BadWords: loaded ' . scalar(@relist) . ' unique entries from ' . scalar(@files) . ' files');
    return ();
}

sub _rewrite_source
{
    my ($file, $word) = @_;
    my ($valid, $parse_error) = _source_words($file);
    return $parse_error if $parse_error;
    my $fh = IO::File->new($file, 'r') or return "BadWords: can't read $file: $!";
    my @lines = <$fh>;
    $fh->close;
    my @kept;
    my $removed = 0;
    for my $line (@lines) {
        my $entry;
        if ($file =~ m{/badword$}) {
            my ($quoted, $plain) = $line =~ /^\s*(?:'([^']+)'|([A-Za-z0-9_]+))\s*=>\s*\d+\s*,?\s*$/;
            $entry = defined $quoted ? $quoted : $plain;
        } else {
            ($entry) = $line =~ /^\s*([^\s#]+)/;
        }
        if (defined $entry && _cleanword($entry) eq $word) {
            ++$removed;
            next;
        }
        push @kept, $line;
    }
    return (undef, 0) unless $removed;
    require File::Temp;
    require File::Basename;
    my ($tmpfh, $tmp) = File::Temp::tempfile('.badword-XXXXXX', DIR => File::Basename::dirname($file), UNLINK => 0);
    my $mode = (stat($file))[2] & 07777;
    chmod $mode, $tmp;
    my $written = print {$tmpfh} @kept;
    my $closed = close($tmpfh);
    unless ($written && $closed) {
        unlink $tmp;
        return ("BadWords: can't write $file: $!", 0);
    }
    unless (rename $tmp, $file) {
        unlink $tmp;
        return ("BadWords: can't replace $file: $!", 0);
    }
    return (undef, $removed);
}

sub add_word
{
    my ($word) = @_;
    my $canonical = _cleanword($word);
    return ('BadWords: invalid word') unless $canonical =~ /^\w+$/;
    return ('BadWords: already defined') if $in{$canonical};
    my $file = localdata('badword.new');
    my $fh = IO::File->new($file, 'a') or return ("BadWords: can't append $file: $!");
    print {$fh} "$canonical\n" or return ("BadWords: can't write $file: $!");
    $fh->close or return ("BadWords: can't close $file: $!");
    return load();
}

sub remove_word
{
    my ($word) = @_;
    my $canonical = _cleanword($word);
    return ('BadWords: invalid word') unless $canonical =~ /^\w+$/;
    my @files = _sources();
    for my $file (@files) {
        my (undef, $err) = _source_words($file);
        return ($err) if $err;
    }
    my $removed = 0;
    for my $file (@files) {
        my ($err, $n) = _rewrite_source($file, $canonical);
        return ($err) if $err;
        $removed += $n;
    }
    return ('BadWords: word not defined') unless $removed;
    return load();
}

sub generate_regex
{
	my $res;
	@relist = sort {$a->[0] cmp $b->[0]} @relist;
	for (@relist) {
		$res .= qq{\\b(?:$_->[1]) |\n};
	}
	$res =~ s/\s*\|\s*$//;
	$regex = qr/\b($res)/x;
}


sub _cleanword
{
	my $w = uc shift;
	$w =~ tr/01/OI/;			# de-leet any incoming words
	my $last = '';	# remove duplicate letters (eg BOLLOCKS > BOLOCKS)
	my @w;
	for (split //, $w) {
		next if $last eq $_;
		$last = $_;
		push @w, $_;
	}
	return @w ? join('', @w) : '';
}

sub add_regex
{
	my @list = split /\s+/, shift;
	my @out;
	
	for (@list) {
		my $w = uc $_;
		$w = _cleanword($w);

		next unless $w && $w =~ /^\w+$/; # has to be a word
		next if $in{$w};	   # ignore any we have already dealt with
		next if _slowcheck($w); # check whether this will already be detected

		# re-leet word (in regex speak)if required
		my @l = map { s/O/[O0]/g; s/I/[I1]/g; $_ } split //, $w;
		my $e = join '+[\s\W]*',  @l;
		my $q = $e;
		push @relist, [$w, $q];
		$in{$w} = $q;
		dbg("$w = $q") if isdbg('badword');
		push @out, $w;
	}
	return @out;
}

sub del_regex
{
	my @list = split /\s+/, shift;
	my @out;

	for (@list) {
		my $w = uc $_;
		$w = _cleanword($w);
		next unless $in{$w};
		delete $in{$w};
		@relist = grep {$_->[0] ne $w} @relist;
		push @out, $w
	}
	return @out;
}

sub list_regex
{
	my $full = shift;
	return map { $full ? "$_->[0] = $_->[1]" : $_->[0] } @relist;
}

# check the text against the badwords list
sub check
{
	my $s = uc shift;
	my @out;
	
	if ($regex) {
		my %uniq;
		@out = grep {++$uniq{$_}; $uniq{$_} == 1 ? $_ : undef }($s =~ /($regex)/g);
		dbg("BadWords: check '$s' = '" . join(', ', @out) . "'") if isdbg('badword');
		return @out;
	}
	return _slowcheck($s) if @relist;
	return;
}


sub _slowcheck
{
	my $w = shift;
	my @out;
	
	for (@relist) {
		push @out, $w =~ /\b($_->[1])/;
	}
	return @out;
}

# write out the new bad words list
sub put
{
	my @out;
	my $newfn = localdata("badword.new");
	my $fh = new IO::File ">$newfn";
	if ($fh) {
		dbg("BadWords: put new badword.new file");
		@relist = sort {$a->[0] cmp $b->[0]} @relist;
		for (@relist) {
			print $fh "$_->[0]\n";
		}
		$fh->close;
	}
	else {
		my $l = "BadWords: can't open $newfn $!";
		dbg($l);
		push @out, $l;
		return @out;
	}
}
1;
