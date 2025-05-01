#
# various utilities which are exported globally
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
#
#

package DXUtil;


use Date::Parse;
use IO::File;
use File::Copy;
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use Text::Wrap;
use strict;

use vars qw(@month %patmap $pi $d2r $r2d @ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(atime ztime cldate cldatetime slat slong yesno noyes promptf 
			 parray parraypairs phex phash shellregex readfilestr writefilestr
			 filecopy ptimelist
             print_all_fields cltounix unpad is_callsign is_latlong
			 is_qra is_freq is_digits is_pctext is_pcflag insertitem deleteitem
			 is_prefix dd is_ipaddr $pi $d2r $r2d localdata localdata_mv
			 diffms _diffms _diffus difft parraydifft is_ztime basecall
			 normalise_call is_numeric htime barecall is_rfc1918 alias_localhost
			 find_external_ipaddr find_local_ipaddr
            );


@month = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
%patmap = (
		   '*' => '.*',
		   '?' => '.',
		   '[' => '[',
		   ']' => ']',
		   '^' => '^',
		   '$' => '$',
);

$pi = 3.141592653589;
$d2r = ($pi/180);
$r2d = (180/$pi);


# BEGIN {
# 	our $enable_ptonok = 0;
# 	our $ptonok;


# 	if ($enable_ptonok && !$main::is_win) {
# 		eval {require Socket; Socket->import(qw(AF_INET6 AF_INET inet_pton)); };
# 		unless ($@) {
# 			$ptonok = !defined inet_pton(AF_INET,  '016.17.184.1')
# 				&& !defined inet_pton(AF_INET6, '2067::1:')
# 				# Some old versions of Socket are hopelessly broken
# 				&& length(inet_pton(AF_INET, '1.1.1.1')) == 4;
# 		}
# 	}
# }



# a full time for logging and other purposes
sub atime
{
	my $t = shift;
	my ($sec,$min,$hour,$mday,$mon,$year) = gmtime((defined $t) ? $t : time);
	$year += 1900;
	my $buf = sprintf "%02d%s%04d\@%02d:%02d:%02d", $mday, $month[$mon], $year, $hour, $min, $sec;
	return $buf;
}

sub htime
{
	my $t = shift;
	$t = defined $t ? $t : time;
	my $dst = shift;
	my ($sec,$min,$hour) = $dst ? localtime($t): gmtime($t);
	my $buf = sprintf "%02d:%02d:%02d%s", $hour, $min, $sec, ($dst) ? '' : 'Z';
	return $buf;
}

# get a zulu time in cluster format (2300Z)
sub ztime
{
	my $t = shift;
	$t = defined $t ? $t : time;
	my $dst = shift;
	my ($sec,$min,$hour) = $dst ? localtime($t): gmtime($t);
	my $buf = sprintf "%02d%02d%s", $hour, $min, ($dst) ? '' : 'Z';
	return $buf;
}

# get a cluster format date (23-Jun-1998)
sub cldate
{
	my $t = shift;
	$t = defined $t ? $t : time;
	my $dst = shift;
	my ($sec,$min,$hour,$mday,$mon,$year) = $dst ? localtime($t) : gmtime($t);
	$year += 1900;
	my $buf = sprintf "%2d-%s-%04d", $mday, $month[$mon], $year;
	return $buf;
}

# return a cluster style date time
sub cldatetime
{
	my $t = shift;
	my $dst = shift;
	my $date = cldate($t, $dst);
	my $time = ztime($t, $dst);
	return "$date $time";
}

# return a unix date from a cluster date and time
sub cltounix
{
	my $date = shift;
	my $time = shift;
	my ($thisyear) = (gmtime)[5] + 1900;

	return 0 unless $date =~ /^\s*(\d+)-(\w\w\w)-([12][90]\d\d)$/;
	return 0 if $3 > 2036;
	return 0 unless abs($thisyear-$3) <= 1;
	$date = "$1 $2 $3";
	return 0 unless $time =~ /^([012]\d)([012345]\d)Z$/;
	$time = "$1:$2 +0000";
	my $r = str2time("$date $time");
	return $r unless $r;
	return $r == -1 ? undef : $r;
}

# turn a latitude in degrees into a string
sub slat
{
	my $n = shift;
	my ($deg, $min, $let);
	$let = $n >= 0 ? 'N' : 'S';
	$n = abs $n;
	$deg = int $n;
	$min = int ((($n - $deg) * 60) + 0.5);
	return "$deg $min $let";
}

# turn a longitude in degrees into a string
sub slong
{
	my $n = shift;
	my ($deg, $min, $let);
	$let = $n >= 0 ? 'E' : 'W';
	$n = abs $n;
	$deg = int $n;
	$min = int ((($n - $deg) * 60) + 0.5);
	return "$deg $min $let";
}

# turn a true into 'yes' and false into 'no'
sub yesno
{
	my $n = shift;
	return $n ? $main::yes : $main::no;
}

# turn a true into 'no' and false into 'yes'
sub noyes
{
	my $n = shift;
	return $n ? $main::no : $main::yes;
}

# provide a data dumpered version of the object passed
sub dd
{
	my $value = shift;
	my $dd = new Data::Dumper([$value]);
	$dd->Indent(0);
	$dd->Terse(1);
    $dd->Quotekeys($] < 5.005 ? 1 : 0);
	$value = $dd->Dumpxs;
	$value =~ s/([\r\n\t])/sprintf("%%%02X", ord($1))/eg;
	$value =~ s/^\s*\[//;
    $value =~ s/\]\s*$//;
	
	return $value;
}

# format a prompt with its current value and return it with its privilege
sub promptf
{
	my ($line, $value, $promptl) = @_;
	my ($priv, $prompt, $action) = split ',', $line;

	# if there is an action treat it as a subroutine and replace $value
	if ($action) {
		my $q = qq{\$value = $action(\$value)};
		eval $q;
	} elsif (ref $value) {
		$value = dd($value);
	}
	$promptl ||= 15;
	$prompt = sprintf "%${promptl}s: %s", $prompt, $value;
	return ($priv, $prompt);
}

# turn a hex field into printed hex
sub phex
{
	my $val = shift;
	return sprintf '%X', $val;
}

# take an arg as a hash of call=>time pairs and print it
sub ptimelist
{
	my $ref = shift;
	my $out;
	for (sort keys %$ref) {
		$out .= "$_=" . atime($ref->{$_}) . ", ";
	}
	chop $out;
	chop $out;
	return $out;	
}

# take an arg as an array list and print it
sub parray
{
	my $ref = shift;
	return ref $ref ? join(', ', sort @{$ref}) : $ref;
}

# take the arg as an array reference and print as a list of pairs
sub parraypairs
{
	my $ref = shift;
	my $i;
	my $out;

	for ($i = 0; $i < @$ref; $i += 2) {
		my $r1 = @$ref[$i];
		my $r2 = @$ref[$i+1];
		$out .= "$r1-$r2, ";
	}
	chop $out;					# remove last space
	chop $out;					# remove last comma
	return $out;
}

# take the arg as a hash reference and print it out as such
sub phash
{
	my $ref = shift;
	my $out;

	foreach my $k (sort keys %$ref) {
		$out .= "${k}=>$ref->{$k}, ";
	}
	$out =~ s/, $// if $out;
	return $out;
}

sub _sort_fields
{
	my $ref = shift;
	my @a = split /,/, $ref->field_prompt(shift); 
	my @b = split /,/, $ref->field_prompt(shift); 
	return lc $a[1] cmp lc $b[1];
}

# print all the fields for a record according to privilege
#
# The prompt record is of the format '<priv>,<prompt>[,<action>'
# and is expanded by promptf above
#
sub print_all_fields
{
	my $self = shift;			# is a dxchan
	my $ref = shift;			# is a thingy with field_prompt and fields methods defined
	my @out;
	my @fields = $ref->fields;
	my $field;
	my $width = $self->width - 1;
	my $promptl = 0;
	$width ||= 80;

	# find the maximum length of the prompt
	foreach $field (@fields) {
		if (defined $ref->{$field}) {
			my (undef, $prompt, undef) = split ',', $ref->field_prompt($field);
			$promptl = length $prompt if length $prompt > $promptl;
		}
	}

	# now do print
	foreach $field (sort {_sort_fields($ref, $a, $b)} @fields) {
		if (defined $ref->{$field}) {
			my ($priv, $ans) = promptf($ref->field_prompt($field), $ref->{$field}, $promptl);
			my @tmp;
			if (length $ans > $width) {
				$Text::Wrap::columns = $width-2;
				my ($p, $a) = split /: /, $ans, 2;
				@tmp = split/\n/, Text::Wrap::wrap("$p: ", (' ' x $promptl) . ': ', $a);
			} else {
				push @tmp, $ans;
			}
			push @out, @tmp if ($self->priv >= $priv);
		}
	}
	return @out;
}

# generate a regex from a shell type expression 
# see 'perl cookbook' 6.9
sub shellregex
{
	my $in = shift;
	$in =~ s{(.)} { $patmap{$1} || "\Q$1" }ge;
	$in =~ s|\\/|/|g;
	if ($in =~ m|\.\*$|) {
		$in =~ s|\.\*$||;
#		$in = "^$in" unless $in =~ m|^\^|;
	}
	return $in;
}

# read in a file into a string and return it. 
# the filename can be split into a dir and file and the 
# file can be in upper or lower case.
# there can also be a suffix
sub readfilestr
{
	my ($dir, $file, $suffix) = @_;
	my $fn;
	my $f;
	if ($suffix) {
		$f = uc $file;
		$fn = "$dir/$f.$suffix";
		unless (-e $fn) {
			$f = lc $file;
			$fn = "$dir/$file.$suffix";
		}
	} elsif ($file) {
		$f = uc $file;
		$fn = "$dir/$file";
		unless (-e $fn) {
			$f = lc $file;
			$fn = "$dir/$file";
		}
	} else {
		$fn = $dir;
	}

	my $fh = new IO::File $fn;
	my $s = undef;
	if ($fh) {
		local $/ = undef;
		$s = <$fh>;
		$fh->close;
	}
	return $s;
}

# write out a file in the format required for reading
# in via readfilestr, it expects the same arguments 
# and a reference to an object
sub writefilestr
{
	my $dir = shift;
	my $file = shift;
	my $suffix = shift;
	my $obj = shift;
	my $fn;
	my $f;
	
	confess('no object to write in writefilestr') unless $obj;
	confess('object not a reference in writefilestr') unless ref $obj;
	
	if ($suffix) {
		$f = uc $file;
		$fn = "$dir/$f.$suffix";
		unless (-e $fn) {
			$f = lc $file;
			$fn = "$dir/$file.$suffix";
		}
	} elsif ($file) {
		$f = uc $file;
		$fn = "$dir/$file";
		unless (-e $fn) {
			$f = lc $file;
			$fn = "$dir/$file";
		}
	} else {
		$fn = $dir;
	}

	my $fh = new IO::File ">$fn";
	if ($fh) {
		my $dd = new Data::Dumper([ $obj ]);
		$dd->Indent(1);
		$dd->Terse(1);
		$dd->Quotekeys(0);
		#	$fh->print(@_) if @_ > 0;     # any header comments, lines etc
		$fh->print($dd->Dumpxs);
		$fh->close;
	}
}

sub filecopy
{
	copy(@_) or return $!;
}

# remove leading and trailing spaces from an input string
sub unpad
{
	my $s = shift;
	$s =~ s/^\s*//;
	$s =~ s/\s*$//;
	return $s;
}

# check that a field only has callsign characters in it
sub is_callsign
{
	return $_[0] =~ m!^
					  (?:\d?[A-Z]{1,2}\d{0,2}/)?    # out of area prefix /  
					  (?:\d?[A-Z]{1,2}\d{1,5})      # main prefix one (required) - lengthened for special calls 
					  [A-Z]{1,8}                # callsign letters (required)
					  (?:-(?:\d{1,2}))?         # - nn possibly (eg G8BPQ-8)
					  (?:/[0-9A-Z]{1,7})?       # / another prefix, callsign or special label (including /MM, /P as well as /EURO or /LGT) possibly
					  (?:/(?:AM?|MM?|P))?       # finally /A /AM /M /MM /P 
					  $!xo;

	# longest callign allowed is 1X11/1Y11XXXXX-11/XXXXXXX/MM
}

sub is_prefix
{
	return $_[0] =~ m!^(?:[A-Z]{1,2}\d+ | \d[A-Z]{1,2}}\d+)!x        # basic prefix
}
	

# check that a PC protocol field is valid text
sub is_pctext
{
	return undef unless length $_[0];
	return undef if $_[0] =~ /[\x00-\x08\x0a-\x1f\x80-\x9f]/;
	return 1;
}

# check that a PC prot flag is fairly valid (doesn't check the difference between 1/0 and */-)
sub is_pcflag
{
	return $_[0] =~ /^[01\*\-]+$/;
}

# check that a thing is a frequency
sub is_freq
{
	return $_[0] =~ /^\d+(?:\.\d+)?$/;
}

# check that a thing is just digits
sub is_digits
{
	return $_[0] =~ /^[\d]+$/;
}

# does it look like a qra locator?
sub is_qra
{
	return unless length $_[0] == 4 || length $_[0] == 6;
	return $_[0] =~ /^[A-Ra-r][A-Ra-r]\d\d(?:[A-Xa-x][A-Xa-x])?$/;
}

# does it look like a valid lat/long
sub is_latlong
{
	return $_[0] =~ /^\s*\d{1,2}\s+\d{1,2}\s*[NnSs]\s+1?\d{1,2}\s+\d{1,2}\s*[EeWw]\s*$/;
}

# is it an ip address?
sub is_ipaddr
{
	$_[0] =~ s|/\d+$||;
	# if ($ptonok) {
	# 	if ($_[0] =~ /:/) {
	# 		if (inet_pton(AF_INET6, $_[0])) {
	# 			return ($_[0] =~ /([:0-9a-f]+)/);
	# 		}
	# 	} else {
	# 		if (inet_pton(AF_INET, $_[0])) {
	# 			return ($_[0] =~ /([\.\d]+)/);
	# 		}
	# 	}
	# } else {
		if ($_[0] =~ /:/) {
			return ($_[0] =~ /^((?:\:?\:?[0-9a-f]{0,4}){1,8}\:?\:?)$/i);	
		} else {
			return ($_[0] =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
		}
#	}
	return undef;
}

sub is_rfc1918
{
	my $in = shift;
	return 0 if $in =~ /\:/;
	
	my @ip = split /\./, $in;
	return 1 if ($ip[0] == 127 || $ip[0] == 10 || ($ip[0] == 192 && $ip[1] == 168) || ($ip[0] == 172 && $ip[1] >= 16 && $ip[1] <= 31));
	return 0;
}

# is it a zulu time hhmmZ
sub is_ztime
{
	return $_[0] =~ /^(?:(?:2[0-3])|(?:[01][0-9]))[0-5][0-9]Z$/;
}

# insert an item into a list if it isn't already there returns 1 if there 0 if not
sub insertitem
{
	my $list = shift;
	my $item = shift;
	
	return 1 if grep {$_ eq $item } @$list;
	push @$list, $item;
	return 0;
}

# delete an item from a list if it is there returns no deleted 
sub deleteitem
{
	my $list = shift;
	my $item = shift;
	my $n = @$list;
	
	@$list = grep {$_ ne $item } @$list;
	return $n - @$list;
}

# find the correct local_data directory
# basically, if there is a local_data directory with this filename and it is younger than the
# equivalent one in the (system) data directory then return that name rather than the system one
sub localdata
{
	my $ifn = shift;
	my $lfn = "$main::local_data/$ifn";
	my $dfn =  "$main::data/$ifn";
	
	if (-e "$main::local_data") {
		if ((-e $dfn) && (-e $lfn)) {
			$lfn = $dfn if -M $dfn < -M $lfn;
		} else {
			$lfn = $dfn if -e $dfn;
		}
	} else {
		$lfn = $dfn;
	}

	return $lfn;
}

# move a file or a directory from data -> local_data if isn't there already
sub localdata_mv
{
	my $ifn = shift;
	if (-e "$main::data/$ifn" ) {
		unless (-e "$main::local_data/$ifn") {
			move("$main::data/$ifn", "$main::local_data/$ifn") or die "localdata_mv: cannot move $ifn from '$main::data' -> '$main::local_data' $!\n";
		}
	}
}

# measure the time taken for something to happen; use Time::HiRes qw(gettimeofday tv_interval);
sub _diffms
{
	my $ta = shift;
	my $tb = shift || [gettimeofday];
	my $a = int($ta->[0] * 1000) + int($ta->[1] / 1000); 
	my $b = int($tb->[0] * 1000) + int($tb->[1] / 1000);
	return $b - $a;
}

# and in microseconds
sub _diffus
{
	my $ta = shift;
	my $tb = shift || [gettimeofday];
	my $a = int($ta->[0] * 1000000) + int($ta->[1]); 
	my $b = int($tb->[0] * 1000000) + int($tb->[1]);
	return $b - $a;
}

sub diffms
{
	my $call = shift;
	my $line = shift;
	my $ta = shift;
	my $no = shift;
	my $tb = shift;
	my $msecs = _diffms($ta, $tb);

	$line =~ s|\s+$||;
	my $s = "subprocess stats cmd: '$line' $call ${msecs}mS";
	$s .= " $no lines" if $no;
	DXDebug::dbg($s);
}

# expects either an array reference or two times (in the correct order [start, end])
sub difft
{
	my $b = shift;
	my $adds = shift || 0;
	
	my $t;
	if (ref $b eq 'ARRAY') {
		$t = $b->[1] - $b->[0];
	} else {
		if ($adds && $adds =~ /^\d+$/ && $adds >= $b) {
			$t = $adds - $b;
			$adds = shift;
		} else {
			$t = $main::systime - $b;
		}
	}
	return '-(ve)' if $t < 0;
	$t ||= 0;
	my ($y,$d,$h,$m,$s);
	my $out = '';
	$y = int $t / (86400*365);
	$out .= sprintf ("%s${y}y", $adds?' ':'') if $y;
	$t -= $y * 86400 * 365;
	$d = int $t / 86400;
	$out .= sprintf ("%s${d}d", $adds?' ':'') if $d;
	$t -= $d * 86400;
	$h = int $t / 3600;
	$out .= sprintf ("%s${h}h", $adds?' ':'') if $h;
	$t -= $h * 3600;
	$m = int $t / 60;
	$out .= sprintf ("%s${m}m", $adds?' ':'') if $m || $h;
	if (($d == 0 && $adds) || ($adds && $adds =~ /^\d+$/ && $adds == 2)) {
		$s = int $t % 60;
		$out .= sprintf ("%s${s}s", $adds?' ':'');
	}
	$out = '0s' unless length $out;
	return $out;
}

# print an array ref of difft refs
sub parraydifft
{
	my $r = shift;
	my $out = '';
	for (@$r) {
		my $s = $_->[2] ? "($_->[2])" : '';
		$out .= sprintf "%s=%s$s, ", atime($_->[0]), difft($_->[0], $_->[1]);
	}
	$out =~ s/,\s*$//;
	return $out;
}

# just the callsign, not any bits in front or behind
sub barecall
{
	my ($r) = $_[0] =~ m{^(?:[\w\d]+\/)*?([\w\d]+)};
	return $r;
}

sub basecall
{
	my ($r) = $_[0] =~ m{^((?:[\w\d]+\/)?[\w\d]+)};
	return $r;
}

sub normalise_call
{
#	my ($c) $_[0] =~ m|^(?:\w+\/)?(\w+*)(?:-(\d+))?$|;
	my ($c, $ssid) = $_[0] =~ m|^(?:\w{0,4}\/)?(\w+)(?:\/\w{0,4})?(?:\-(\d+))?$| ;
	my $ncall = $c;
	$ssid += 0;
	$ncall .= "-$ssid" if $ssid;
	return $ncall;
}

sub is_numeric
{
	return $_[0] =~ /^[\.\d]+$/;
}

# alias localhost if required. This is designed to repress all localhost and other
# internal interfaces to a fixed (outside) IPv4 or IPV6 address
sub alias_localhost
{
	my $hostname = shift;

	# a band aid
	$hostname = '127.0.0.1' if $hostname eq 'localhost';
	
	if ($hostname =~ /\./) {
		return $hostname unless $main::localhost_alias_ipv4;
		return (grep $hostname eq $_, @main::localhost_names) ? $main::localhost_alias_ipv4 : $hostname;
	} elsif ($hostname =~ /:/) {
		return $hostname unless $main::localhost_alias_ipv6;
		return (grep $hostname eq $_, @main::localhost_names) ? $main::localhost_alias_ipv6 : $hostname;
	}
	return $hostname;
}

sub find_external_ipaddr
{
	my $addr;

	return $main::me->hostname if $main::is_win;
	
	$addr = $main::localhost_alias_ipv4;
	$addr ||= `wget -qO- ifconfig.me/ip`;
	$addr ||= `curl ipinfo.io/ip`;
	return $addr;
}

sub find_local_ipaddr
{
	my $sock = IO::Socket::IP->new(
                       PeerAddr=> "example.com",
                       PeerPort=> 80,
                       Proto   => "tcp");
	return $sock->sockhost;
}
1;
