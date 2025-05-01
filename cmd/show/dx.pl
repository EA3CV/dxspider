#
# show dx (normal)
#
#
#

require 5.10.1;
use warnings;

sub iskeyword
{
	my $word = lc shift;
	
	my @keywords = qw|on freq call info spotter by ip ( ) or and not dxcc call_dxcc by_dxcc bydxcc origin call_itu itu call_zone zone cq bycq  byitu by_itu by_zone byzone call_state state bystate by_state day exact rt real filt qsl <es> <tr> <ms> iota qra |;
	return grep { $word eq $_ } @keywords;
}
	
sub expandregex
{
	my $input = shift;
	my $exact = shift || 0;
	
	$input .= '*' unless $input =~ /[\*\?\[]$/o;
	dbg("sh/dx: expandregex before shellregex input='$input' exact: $exact") if isdbg 'sh/dx'; 
	$input = shellregex($input);
	dbg("sh/dx: expandregex  after shellregex input='$input' exact: $exact") if isdbg 'sh/dx'; 
	if ($exact) {
		$input =~ s|\.\*\$$||;
		$input = '{^$input$}';
	} else {
		$input =~ s|\$+|\$|;
		$input =~ s|\\^||g;
		$input =~ s|^\.\*(.+)\$?$|$1\$|;
		$input =~ s|\$+$|\$|;	# tidy up multiple $ signs at the end
	}
	dbg("sh/dx: expandregex processed input='$input'") if isdbg 'sh/dx';
	return $input;
	
}

sub handle
{
	my ($self, $line) = @_;

	# disguise regexes
	dbg("sh/dx disguise any regex input: '$line'") if isdbg('sh/dx');
	$line = Filter::Cmd::encode_regex($line);
	dbg("sh/dx disguise any regex   now: '$line'") if isdbg('sh/dx');

	# now space out brackets and !
	$line =~ s/([\(\!\)])/ $1 /g;

	$line = Filter::Cmd::decode_regex($line);
	
	my @list = split /\s+/, $line; # split the line up

	# put back the regexes 
#	@list = map { my $l = $_; $l =~ s/\{([0-9a-fA-F]+)\}/'{' . pack('H*', $1) . '}'/eg; $l } @list;

	dbg("sh/dx after regex return: '" . join(' ', @list) . "'") if isdbg('sh/dx') || isdbg('filterparse');
	
	my @out;
	my $f;
	my $call = $self->call;
	my $usesql = $main::dbh && $Spot::use_db_for_search;
	my ($from, $to) = (0, 0);
	my ($fromday, $today) = (0, 0);
	my $exact;
	my $real;
	my $dofilter;
	my $pre;
	my $dxcc;

	my @flist;

	
	dbg("sh/dx list: " . join(" ", @list)) if isdbg('sh/dx');

#	$DB::single=1;
	
	while (@list) {	# next field
		$f = shift @list;

		dbg("sh/dx buildup: \$pre: '$pre' \$f: '$f' left: ". join(',', @list) . " created: " . join(',', @flist)) if isdbg('sh/dx');

		if ($f && !$from && !$to) {
			($from, $to) = $f =~ m|^(\d+)[-/](\d+)$| || (0,0); # is it a from -> to count?
			dbg("sh/dx from: $from to: $to") if isdbg('sh/dx');
			next if $from && $to > $from;
		}
		if ($f && !$to) {
			($to) = $f =~ /^(\d+)$/o if !$to; # is it a to count?
			$to ||= 0;
			dbg("sh/dx to: $to") if isdbg('sh/dx');
			next if $to;
		}
		if (lc $f eq 'day' && $list[0]) {
			($fromday, $today) = split m|[-/]|, shift(@list);
			dbg("sh/dx got day $fromday/$today") if isdbg('sh/dx');
			next;
		}
		if (lc $f eq 'exact') {
			dbg("sh/dx exact") if isdbg('sh/dx');
			$exact = 1;
			next;
		}
		if (lc $f eq 'rt' || $f =~ /^real/i) {
			dbg("sh/dx real") if isdbg('sh/dx');
			$real = 1;
			next;
		}
		if (lc $f =~ /^filt/) {
			dbg("sh/dx run spotfilter") if isdbg('sh/dx');
			$dofilter = 1 if $self && $self->spotsfilter;
			next;
		}
		if (lc $f eq 'qsl') {
			dbg("sh/dx qsl") if isdbg('sh/dx');
			push @flist, "info {QSL|VIA}";
			next;
		}
		if (lc $f eq '<es>') {
			dbg("sh/dx <es>") if isdbg('sh/dx');
			push @flist, "info {<ES>}";
			next;
		}
		if (lc $f eq '<tr>') {
			dbg("sh/dx <es>") if isdbg('sh/dx');
			push @flist, "info {<TR>}";
			next;
		}
		if (lc $f eq '<ms>') {
			dbg("sh/dx <ms>") if isdbg('sh/dx');
			push @flist, "info {<ms>}";
			next;
		}

		if (lc $f eq 'iota') {
			my $doiota;
			if (@list && $list[0] && (($a, $b) = $list[0] =~ /(AF|AN|NA|SA|EU|AS|OC)[-\s]?(\d\d?\d?)/i)) {
				$a = uc $a;
				$doiota = "\\b$a\[\-\ \]\?$b\\b";
				shift @list;
			}
			$doiota = '\b(IOTA|(AF|AN|NA|SA|EU|AS|OC)[-\s]?\d?\d\d)\b' unless $doiota;
			push @flist, 'info', "{$doiota}";
			dbg("sh/dx iota info {$doiota}") if isdbg('sh/dx');
			next;
		}
		if (lc $f eq 'qra') {
			my $doqra = uc shift @list if @list && $list[0] =~ /[A-Z][A-Z]\d\d/i;
			$doqra = '\b([A-Z][A-Z]\d\d|[A-Z][A-Z]\d\d[A-Z][A-Z])\b' unless $doqra;
			push @flist, 'info',  "{$doqra}";
			dbg("sh/dx qra info {$doqra}") if isdbg('sh/dx');
			next;
		}
		if (grep {lc $f eq $_} qw(freq on)) {
			my $in = shift @list;
			dbg("sh/dx $f arg: $in") if isdbg('sh/dx');
			push @flist, $f, $in;
			
			# my @arg = split ',', $in;
			# my $out;
			# foreach my $part (@arg) {
			# 	if ($part =~ m|^[\d/]+$|) {
			# 	    $out .= "$part,";
			# 	} else {
			# 		my ($s, $sb) = split m|/|, $part;
			# 		my @bands = Band::get_freq($s, $sb);
			# 		if (@bands) {
			# 			$out .= join(',', @bands) . ',';
			# 		}
			# 	}
			# 	$out =~ s/,$//;
			# }
			# dbg("sh/dx on or freq out: $out") if isdbg('sh/dx');
		}
		if (grep {lc $f eq $_} qw(dxcc call_dxcc by_dxcc bydxcc origin call_itu itu call_zone zone cq bycq  byitu by_itu by_zone byzone call_state state bystate by_state)) {
			my $arg = shift @list;
			dbg("sh/dx operator '$f' = '$arg'") if isdbg('sh/dx');
			push @flist, $f, $arg;
		}
		if (grep {lc $f eq $_} qw { ( or and not ) }) {
			push @flist, $f;
			dbg("sh/dx operator $f") if isdbg('sh/dx');
			next;
		}
		if (grep {lc $f eq $_} qw(call info spotter by ip) ) {
			push @flist, $f;
			if (@list) {
				my $string = shift @list;
				if ($string =~ /^\{/ || $string =~ m|[,/]|) {
					push @flist, $string;
				} else {
					my $regex = expandregex($string, $exact);
					push @flist,  qq|\{$regex\}|;
				}
				
			}
			dbg("sh/dx function -2 = '$flist[-2]' -1 = '$flist[-1]'") if isdbg('sh/dx');
			next;
		}

		unless ($pre) {
			$pre = $f;
			next;
		}

		push @flist, $f unless iskeyword($f);
	}

	dbg("sh/dx buildup: \$pre: $pre left: ". join(',', @list) . " created: " . join(',', @flist)) if isdbg('sh/dx');

	if ($pre) {
		# someone (probably me) has forgotten the 'call' keyword
		dbg("sh/dx: add \$pre: $pre before: flist='" . join(',', @flist)) if isdbg 'sh/dx'; 
		if ($pre =~ m'^{.*}$') {
			unshift @flist, 'call', $pre;
		} elsif (!iskeyword($pre)) {
			$pre = expandregex($pre, $exact);
			unshift @flist, 'call', qq|\{$pre\}|;
		}
	}

	dbg("sh/dx buildup: \$pre: '$pre' left: ". join(',', @list) . " created: " . join(',', @flist)) if isdbg('sh/dx');
	
    my $newline = join(' ', @flist);
	dbg("sh/dx newline: '$newline'") if isdbg('sh/dx') || isdbg('filterparse');
	my ($r, $filter, $fno, $user, $expr) = $Spot::filterdef->parse($self, 'spots', $newline, 1);

	return (0, "sh/dx parse error '$r' " . $filter) if $r;

	$user ||= $self->call;
	$expr ||= '';
  
	# now do the search

	if (($self->{_nospawn} || $main::is_win == 1) || ($Spot::spotcachedays && !$expr && $from == 0 && $fromday == 0 && $today == 0)) {
		my @res = Spot::search($expr, $fromday, $today, $from, $to, $user, $dofilter, $self);
		my $ref;
		my @dx;
		foreach $ref (@res) {
			if ($self && $self->ve7cc) {
				push @out, VE7CC::dx_spot($self, @$ref);
			}
			else {
				if ($self && $real) {
					push @out, DXCommandmode::format_dx_spot($self, @$ref);
				}
				else {
					push @out, Spot::formatl($self->{width}, @$ref);
				}
			}
		}
	}
	else {
		push @out, $self->spawn_cmd("sh/dx $line", \&Spot::search, 
									args => [$expr, $fromday, $today, $from, $to, $filter, $dofilter, $self],
									cb => sub {
										my ($dxchan, @res) = @_; 
										my $ref;
										my @out;

										foreach $ref (@res) {
											if ($self->ve7cc) {
												push @out, VE7CC::dx_spot($self, @$ref);
											}
											else {
												if ($real) {
													push @out, DXCommandmode::format_dx_spot($self, @$ref);
												}
												else {
													push @out, Spot::formatl($self->{width}, @$ref);
												}
											}
										}
										push @out, $self->msg('e3', "sh/dx", "'$line'") unless @out;
										return @out;
									});
	}


	return (1, @out);
}


