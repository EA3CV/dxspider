#
# show dx (normal)
#
#
#

require 5.10.1;
use warnings;

sub handle
{
	my ($self, $line) = @_;

	# disguise regexes
	$line =~ s/\{(.*)\}/'{'. unpack('H*', $1) . '}'/eg;
	dbg("sh/dx disguise any regex: '$line'") if isdbg('sh/dx');

	# now space out brackets and !
	$line =~ s/([\(\!\)])/ $1 /g;
	
	my @list = split /\s+/, $line; # split the line up

	# put back the regexes 
	@list = map { my $l = $_; $l =~ s/\{([0-9a-fA-F]+)\}/'{' . pack('H*', $1) . '}'/eg; $l } @list;

	dbg("sh/dx after regex return: '" . join(' ', @list) . "'") if isdbg('sh/dx');
	
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
		dbg("sh/dx arg: $f list: '" . join(',', @list) . "'") if isdbg('sh/dx');
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
		if (grep {lc $f eq $_} qw { ( or and not ) }) {
			push @flist, $f;
			dbg("sh/dx operator $f") if isdbg('sh/dx');
			next;
		}
		if (grep {lc $f eq $_} qw(on freq call info spotter by dxcc call_dxcc by_dxcc bydxcc origin call_itu itu call_zone zone cq bycq  byitu by_itu by_zone byzone call_state state bystate by_state ip) ) {
			push @flist, $f;
			push @flist, shift @list if @list;
			dbg("sh/dx function $flist[-2] $flist[-1]") if isdbg('sh/dx');
			next;
		}
		unless ($pre) {
			$pre = $f;
			next;
		}
		push @flist, $f;
	}

	dbg("sh/dx: flist = '" . join(',', @flist). "'") if isdbg('sh/dx');
	
	if ($pre) {
		# someone (probably me) has forgotten the 'call' keyword
		if ($pre =~ m'^{.*}$') {
			push @flist, 'call', $pre;
		} else {
			$pre .= '*' unless $pre =~ /[\*\?\[]$/o;
			$pre = shellregex($pre);
			if ($exact) {
				$pre =~ s/\.\*\$$//;
				$pre .= '^$pre';
			}
			$pre =~ s/\^//;
			push @flist, 'call', $pre;
		}
	}
	
    my $newline = join(' ', @flist);
	dbg("sh/dx newline: '$newline'") if isdbg('sh/dx');
	my ($r, $filter, $fno, $user, $expr) = $Spot::filterdef->parse($self, 'spots', $newline, 1);

	return (0, "sh/dx parse error '$r' " . $filter) if $r;

	$user ||= $self->call;
	$expr ||= '';
	dbg("sh/dx user: $user expr: $expr from: $from to: $to fromday: $fromday today: $today") if isdbg('sh/dx');
  
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


