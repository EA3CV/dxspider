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
use DXHash ();

our $regex;					# the big bad regex generated from @relist
our @relist; # the list of regexes to try, record = [canonical word, regex] 
my @legacy_regex; # independent, read-only badw_regex sources
my %in;	# the collection of words we are building up and their regexes


# Load all badword sources, repairing individual invalid records.
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
    my ($file, $readonly) = @_;
    my $obj;
    my $ok = eval { ($obj) = DXHash::_badlist_source($file,'word',$readonly); 1 };
    return (undef, "BadWords: $file: $@") unless $ok;
    return ([map { uc $_ } sort keys %$obj], undef);
}

# Historical mojo: whitespace-separated words, full-line comments, and
# repeated characters / punctuation between letters. Keep these sources
# independent from the editable badword lists and never evaluate file code.
sub _load_legacy_regex
{
    my $dir = $main::local_data;
    opendir my $dh, $dir or return ("BadWords: can't open $dir: $!");
    my @files = sort grep { /\Abadw_regex(?:\..*)?\z/ && -f "$dir/$_" } readdir $dh;
    closedir $dh;
    my (@next,@errors);
    for my $name (@files) {
        my $words;
        my $ok = eval { ($words) = DXHash::_badlist_source("$dir/$name",'legacy'); 1 };
        unless ($ok) { push @errors,"BadWords: $name: $@"; next; }
        for my $word (@$words) {
            my $re;
            my $compiled = eval {
                my $pattern = join '+[\s\W]*', map { quotemeta $_ } split //, uc $word;
                $re = qr/\b($pattern)/; 1;
            };
            if ($compiled) { push @next,$re; }
            else { push @errors,"BadWords: cannot compile legacy entry in $name: $@"; }
        }
    }
    @legacy_regex = @next;
    return @errors;
}

sub load
{
    my @errors;
    my @files = _sources();
    # Preserve the historical default selection without overwriting a local list.
    my $dir=$main::local_data;
    my $data=$main::data;
    if (defined($data) && !-e "$dir/badword.new") {
        my $default = -f "$data/badword.new" ? "$data/badword.new" : !@files && -f "$data/badword.new.issue" ? "$data/badword.new.issue" : undef;
        if (defined $default) {
            my $ok=eval { my $err=filecopy($default,"$dir/badword.new"); die $err if defined($err) && length($err) && !-f "$dir/badword.new"; 1 };
            push @errors,"BadWords: default copy failed: $@" unless $ok;
            @files=_sources();
        }
    }
    my @words;
    for my $file (@files) {
        my ($found, $error) = _source_words($file, index($file,"$dir/") != 0);
        if ($error) { push @errors,$error; next; }
        push @words, @$found;
    }
    %in = ();
    @relist = ();
    $regex = '';
    for my $word (sort @words) {
        my $ok=eval { add_regex($word); 1 };
        push @errors,"BadWords: entry skipped: $@" unless $ok;
    }
    my $ok=eval { generate_regex(); 1 };
    unless ($ok) { $regex=''; push @errors,"BadWords: combined regex failed, using individual patterns: $@"; }
    dbg('BadWords: loaded ' . scalar(@relist) . ' unique entries from ' . scalar(@files) . ' files');
    push @errors,_load_legacy_regex();
    DXHash::_badlist_log($_) for @errors;
    return @errors;
}

sub _rewrite_source
{
    my ($file, $word) = @_;
    return ("BadWords: cannot modify symlink $file",0) if -l $file;
    my ($obj,$clean);
    my $ok=eval { ($obj,$clean)=DXHash::_badlist_source($file,'word',1); 1 };
    return ("BadWords: $file: $@",0) unless $ok;
    my @kept;
    my $removed=0;
    if ($file =~ m{/badword$}) {
        for my $key (keys %$obj) { if (_cleanword($key) eq $word) { delete $obj->{$key}; ++$removed; } }
        @kept=(Data::Dumper->new([bless({name=>'badword',%$obj},'DXHash')])->Indent(1)->Terse(1)->Quotekeys(0)->Sortkeys(1)->Dump);
    } else {
        for my $line (split /(?<=\n)/,$clean) {
            if ($line =~ /^\s*(?:#|$)/) { push @kept,$line; next; }
            my $body=$line; $body =~ s/\r?\n$//;
            my $comment=''; $comment=$1 if $body =~ s/(\s+#.*)$//;
            my @tokens=split ' ',$body;
            my @good=grep { _cleanword($_) ne $word } @tokens;
            if (@good==@tokens) { push @kept,$line; next; }
            $removed+=@tokens-@good;
            push @kept,join(' ',@good).$comment."\n" if @good || length $comment;
        }
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
    my $file = "$main::local_data/badword.new";
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
	unless (@relist) { $regex = ''; return; }
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
        my $test = qr/\b($q)/; # validate before publishing
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
		return @out if @out;
	} elsif (@relist) {
		@out = _slowcheck($s);
		return @out if @out;
	}
	for my $pattern (@legacy_regex) {
		push @out, $s =~ /$pattern/;
	}
	return @out;
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
	my $newfn = "$main::local_data/badword.new";
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
