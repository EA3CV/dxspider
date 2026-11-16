#
#
# This module impliments the handlers for the protocal mode for a dx cluster
#
# Copyright (c) 1998-2007 Dirk Koopman G1TLH
#
#
#

package DXProt;

@ISA = qw(DXChannel);

use DXUtil;
use DXChannel;
use DXUser;
use DXM;
use DXProtVars;
use DXCommandmode;
use DXLog;
use Spot;
use DXProtout;
use DXDebug;
use Filter;
use Local;
use DXDb;
use AnnTalk;
use Geomag;
use WCY;
use BadWords;
use DXHash;
use Route;
use Route::Node;
use Script;
use DXCIDR;

use strict;
use DXHealth;
use warnings qw(all);
no warnings qw(uninitialized);



use vars qw($pc11_max_age $pc23_max_age $last_pc50 $eph_restime $eph_info_restime $eph_pc34_restime
			$last_hour $last10 %eph  %pings %rcmds $ann_to_talk
			$pingint $obscount %pc19list $chatdupeage $chatimportfn
			$investigation_int $pc19_version $myprot_version
			%nodehops $baddx $badspotter $badnode $censorpc
			$allowzero $decode_dk0wcy $send_opernam @checklist
			$eph_pc15_restime $pc9x_past_age $pc9x_dupe_age
			$pc10_dupe_age $pc92_slug_changes $last_pc92_slug
			$pc92Ain $pc92Cin $pc92Din $pc92Kin $pc9x_time_tolerance
			$pc92filterdef $senderverify $pc11_dwell_time $pc61_extract_route
			$pc92_ad_enabled $pc92c_ipaddr_enable
			$preserve_node_ssid
		   );

$pc9x_dupe_age = 60;			# catch loops of circular (usually) D records
$pc10_dupe_age = 45;			# just something to catch duplicate PC10->PC93 conversions
$pc92_slug_changes = 10*2;		# slug any changes going outward for this long
$last_pc92_slug = 0;			# the last time we sent out any delayed add or del PC92s
$pc9x_time_tolerance = 15*60;	# the time on a pc9x is allowed to be out by this amount
$pc9x_past_age = (122*60)+		# maximum age in the past of a px9x (a config record might be the only
$pc9x_time_tolerance;           # thing a node might send - once an hour and we allow an extra hour for luck)
                                # this is actually the partition between "yesterday" and "today" but old.
$senderverify = 1;				# 1 - check for forged PC11 or PC61.
                                # 2 - if forged, dump them.
$pc11_dwell_time = 2;			# number of seconds to wait for a PC61 to come to substitute the PC11
$pc61_extract_route = 0;		# generate missing  user route entry and IP address from passing PC61s

$preserve_node_ssid = 0;		# With the changes to badnode set this to 1 to preserve badnode ssids

our $remove_auto_ftx = 0;		# remove all auto generated FTx spots

$pc92filterdef = bless ([
			  # tag, sort, field, priv, special parser
			  ['call', 'c', 0],
			  ['by', 'c', 0],
			  ['dxcc', 'nc', 1],
			  ['itu', 'ni', 2],
			  ['zone', 'nz', 3],
			 ], 'Filter::Cmd');

sub check_available
{
	my $self = shift;
	my $origin = shift;
	my $pcno = shift;

	return 0 if $self == $main::me;

	unless ($self->is_node && $self->state eq 'normal') {
		dbg("PC$pcno sent to $self->{call} ignored as this channel is not yet initialised (state: $self-{state})");
		return 1;
	}
	return 0;
}

our %pc11q;
# this is a place to park an incoming PC11 in the sure and certain hope that
# a PC61 will be along soon. This has the side benefit that it will delay a
# a PC11 for one second - assuming that it is not removed by a PC61 version

# incoming talk commands
sub handle_10
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# this is to catch loops caused by bad software ...
	if (eph_dup($line, $pc10_dupe_age)) {
		return;
	}

	return if $self->check_available($origin, $pcno);

	# is it for me or one of mine?
	my ($from, $to, $via, $call, $dxchan);
	$from = $pc->[1];
	if ($pc->[5] gt ' ') {
		$via = $pc->[2];
		$to = $pc->[5];
	} else {
		$to = $pc->[2];
	}

	# if this is a 'nodx' node then ignore it
	if ($badnode->in($pc->[6], $preserve_node_ssid) || ($via && $badnode->in($via, $preserve_node_ssid))) {
		DXHealth::operator_event('badlist', 'badnode', $self->{call}, $pc->[6], 'PC10');
		dbg($line) if isdbg('nologchan');
		$via ||= '*';
		dbg("PCPROT: Bad Node $pc->[6]/$via, dropped");
		return;
	}


	if ($badspotter->in($from)) {
		DXHealth::operator_event('badlist', 'badspotter', $self->{call}, $pc->[6], 'PC10');
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Bad Spotter $from, dropped");
		return;
	}

	# if we are converting announces to talk is it a dup?
	if ($ann_to_talk) {
		if (AnnTalk::is_talk_candidate($from, $pc->[3]) && AnnTalk::dup($from, $to, $pc->[3])) {
			dbg("PCPROT: Dupe talk from announce, dropped") if isdbg('chanerr') || isdbg('routelow');
			return;
		}
	}

	# will we allow it at all?
	if ($censorpc) {
		my @bad;
		if (@bad = BadWords::check($pc->[3])) {
			DXHealth::operator_event('badlist', 'badword', $self->{call}, $pc->[6], 'PC10');
			my $bw = join ', ', @bad;
			dbg($line) if isdbg('nologchan');
			dbg("PCPROT: Badwords: '$bw', dropped");
			return;
		}
	}

	# convert this to a PC93, coming from mycall with origin set and process it as such
	my $ref = Route::get($pc->[6]);
	my $ip = $ref->ip;
	$main::me->normal(pc93($to, $from, $via, $pc->[3], $pc->[6]), $ip);
}

my %pc11_saved;					# delayed PC11s
my $pc11_rx;					# no of pc11 rxed
my $pc61_rx;					# no of pc61 rxed
my $pc11_to_61;					# no of 'better' pc61, that replaced stored waiting pc11
my $rpc11_to_61;				# no of pc11s 'promoted' to pc61 by IP captured in routing table

# DX Spot handling
sub handle_11
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;
	my $recurse = shift || 0;

	return if $self->check_available($origin, $pcno);

	# route 'foreign' pc26s
	if ($pcno == 26) {
		if ($pc->[7] ne $main::mycall) {
			$self->route($pc->[7], $line);
			return;
		}
	}

	dbg("---") if isdbg("spot") || isdbg("pc61");
	dbg("INPUT $self->{call}: $line via: $origin recurse: $recurse") if isdbg("spot") || isdbg("pc61");

#	my ($hops) = $pc->[8] =~ /^H(\d+)/;

	# is the spotted callsign blank? This should really be trapped earlier but it
	# could break other protocol sentences. Also check for lower case characters.
	if ($pc->[2] =~ /^\s*$/) {
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: blank callsign, dropped");
		return;
	}
	if ($pc->[2] =~ /[a-z]/) {
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: lowercase characters, dropped");
		return;
	}


	# if this is a 'nodx' node then ignore it
	if ($badnode->in($pc->[7], $preserve_node_ssid)) {
		DXHealth::operator_event('badlist', 'badnode', $self->{call}, $pc->[7], sprintf('PC%02d', $pcno));
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Bad Node $pc->[7], dropped");
		return;
	}

	# convert the date to a unix date
	my $d = cltounix($pc->[3], $pc->[4]);
	# bang out (and don't pass on) if date is invalid or the spot is too old (or too young)
	if (!$d || (($pcno == 11 || $pcno == 61) && ($d < $main::systime - $pc11_max_age || $d > $main::systime + 900))) {
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Spot ignored, invalid date or out of range ($pc->[3] $pc->[4])");
		return;
	}

	# is it 'baddx'
	if ($baddx->in($pc->[2])) {
		DXHealth::operator_event('badlist', 'baddx', $self->{call}, $pc->[7], sprintf('PC%02d', $pcno));
		dbg("PCPROT: Bad DX spot '$pc->[2]', ignored");
		dbg($line) if isdbg('nologchan');
		return;
	}

	# is it claiming to be BUST(ed)
	$pc->[5] =~ s/^\s+//;			# take any leading blanks off
	$pc->[2] = unpad($pc->[2]);		# take off leading and trailing blanks from spotted callsign
	if ($pc->[2] =~ /BUST\w*$/) {
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: useless 'BUSTED' spot") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	my $nossid = $pc->[6];
    $nossid =~ s/-\d+$//;

	# is this is a 'bad spotter' or an unknown user then ignore it.
	if ($badspotter->in($nossid)) {
		DXHealth::operator_event('badlist', 'badspotter', $self->{call}, $pc->[7], sprintf('PC%02d', $pcno));
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Bad Spotter $nossid, dropped");
		return;
	}

	# if required (default: no) remove all FTx spots that are (or appear to be) autogenerated
	if ($remove_auto_ftx && $pc->[5] =~ /^\s*FT[48]\s+(?:db|hz|sent|rcvd)?[\-\+]?\d+\s*(?:db|hz)?/i) {
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Autogenerated FTx Spot by $nossid '$pc->[5]', dropped");
		return;
	}

	my @spot = Spot::prepare($pc->[1], $pc->[2], $d, $pc->[5], $nossid, $pc->[7], $pc->[8]);

	#   $f0 = frequency
	#   $f1 = call
	#   $f2 = date in unix format
	#   $f3 = comment
	#   $f4 = spotter
	#   $f5 = spotted dxcc country
	#   $f6 = spotter dxcc country
	#   $f7 = origin
	#   $f8 = spotted itu
	#   $f9 = spotted cq zone
	#   $f10 = spotter itu
	#   $f11 = spotter cq zone
	#   $f12 = spotted us state
	#   $f13 = spotter us state
	#   $f14 = ip address


	# global spot filtering on INPUT
	if ($self->{inspotsfilter}) {
		my ($filter, $hops) = $self->{inspotsfilter}->it(@spot);
		unless ($filter) {
			dbg("PCPROT: Rejected by input spot filter") if isdbg('chanerr') || isdbg('routelow');
			return;
		}
	}

	my $rug = Route::User::get($pc->[6]);
	if ($pcno == 61) {
		unless ($pc->[8] && is_ipaddr($pc->[8])) {
			LogDbg('err', "PCPROT: ROUTE $self->{call} NO IP ADDRESS in '$line'!");
			return;
		}
		if ($pc61_extract_route) {
			$self->populate_routing_table($pc->[7], $pc->[6], $pc->[8]);
		}
	}

	# remove all auto generated FTx spots at this point

	# this is where we decide to delay PC11s in the hope that a PC61 will be along soon.
	my $key = join '|', @spot[0..2,4,7]; # not including text

	my $dupe_reason = '';			# returned by reference for dupes found

	unless ($recurse) {

		if ($pcno == 61) {

			if ($pc11_saved{$key}) {
				# before we promote  because it's a better pc61, check that it's not a dupe (but don't insert it).
#				if (Spot::dup_find(@spot[0..4,7,14], \$dupe_reason)) {
#					dbg("PCPROT: Duplicate Spot $self->{call}: $pc->[0] $key ignored $dupe_reason") if isdbg('chanerr') || isdbg('dupespot') || isdbg('spot');
#					delete $pc11_saved{$key};
#					return;
#				}

				++$pc11_to_61;

				my $percent = $pc11_rx ? $pc11_to_61 * 100 / $pc11_rx : 0;
				dbg(sprintf("PROMOTED $self->{call}: BETTER $pc->[0] $key, using pc61, WAITING pc11 DUMPED: $pc61_rx pc11: $pc11_rx better pc61: $pc11_to_61 (%0.1f%%)", $percent)) if isdbg("spot");

				delete $pc11_saved{$key}; # because we have promoted it, no longer needed.

				# so unlike the promotion by route, there is a stored, but uncounted PC11
				# which have discarded. But we have chosen to use better PC61 that's just come in
				# so we allow the PC61 to be counted later, but count the now discarded PC11
				# because it *did* come in.
				++$pc11_rx;
			}
		}

		if ($pcno == 11) {

			# if this fires then we have already had one or more PC11s but no PC61 for this spot
			if ($pc11_saved{$key}) {

				dbg("DUPE $self->{call} $pc->[0] key: $key recurse: $recurse is already being processed, ignored") if isdbg("spot");
				return;		# because it's a dup
			}

			if ((Spot::dup_find(@spot[0..4,7,14], \$dupe_reason))) {

				dbg("DUPE $self->{call} $pc->[0] key: $key recurse: $recurse is already a DUPE, ignored") if isdbg("spot");
				$recurse = 0;
				return;		# because it's a dup
			}

#			# before we promote by route, check that it's not been preceded by a previous PC61
#			if (Spot::dup_find(@spot[0..4,7,14], \$dupe_reason)) {
#				my $s = exists $pc11_saved{$key} ? " stored $key removed" : " key $key";
#				dbg("PCPROT: Duplicate Spot $self->{call}: PC11$s, recurse: $recurse, ignored $dupe_reason") if isdbg('chanerr') || isdbg('dupespot') || isdbg('spot');
#				delete $pc11_saved{$key};
#				return;
#			}

			# If we have an ip address we can promote by route
			if ($rug && $rug->ip) {
				$pcno = 61;
				$pc->[0] = 'PC61';
				my $hops = $pc->[8];
				$pc->[8] = $spot[14] = $rug->ip;
				++$rpc11_to_61;
				my $percent = $pc11_rx ? $rpc11_to_61 * 100 / $pc11_rx : 0;
				dbg(sprintf("PROMOTED $self->{call}: ROUTE pc11 $key PROMOTED to pc61 with IP $spot[14] pc61: $pc61_rx pc11: $pc11_rx route->pc61 $rpc11_to_61 (%0.1f%%)", $percent)) if isdbg("spot");
				$line = join '^', @$pc, $hops, '~';

				# update the stats (NOTE, this record was a PC11, it has now become a PC61
				# this is NOT the same choosing a better PC61, that is a separate record.
				++$pc11_rx;		# 'cos we received as a PC11 it and it won't be a pc11 anymore
				--$pc61_rx;		# 'cos we'll increment it later as it's now a pc61, no double counting

#				dbg("CHANGED saved key: $key PC11 line to $line") if isdbg('spot');
				delete $pc11_saved{$key};
			}

			# if it is STILL (despite all efforts to change it) a PC11
			# save it and wait - it will be called from pc11_process
			if ($pcno == 11 && !$self->do_pc9x) {
				$pc11_saved{$key} = [$main::systime, $self, $pcno, $line, $origin, $pc];
				dbg("WAITING $self->{call}: NEW $pc->[0] spot $key waiting for a better offer") if isdbg("spot");
				return;
			}
		}
	}

	$key .= "|$pc->[8]" if @$pc > 8 && is_ipaddr($pc->[8]);

	dbg("PROCESSING $self->{call}: $pc->[0] key: $key") if isdbg('spot');

	if ($pcno == 11) {
		++$pc11_rx;
	} else {
		++$pc61_rx;
	}

	# we check IP addresses for PC61 - this will also dedupe PC11 promotions
	if ($pcno >= 61 && @$pc > 8 && $pc->[8]) {
		my $ip = $pc->[8];
		$ip =~ s/,/:/g;
		$ip =~ s/^::ffff://;

		if (is_ipaddr($ip)) {

			# PC61 may only advertise a public Internet address.
			if (!is_public_ip($ip)) {
				DXHealth::operator_event('pc61_drop', 'non_public_ip', $self->{call}, $pc->[7], 'PC61');
				dbg($line) if isdbg('nologchan');
				dbg("PCPROT: PC61 $ip is not a public Internet address, dropped");
				return;
			}

			if (DXCIDR::find($ip)) {
				DXHealth::operator_event('pc61_drop', 'badip', $self->{call}, $pc->[7], 'PC61');
				dbg($line) if isdbg('nologchan');
				dbg("PCPROT: PC61 $ip in badip list, dropped");
				return;
			}
		} else {
			dbg($line) if isdbg('nologchan');
			dbg("PCPROT: PC61 $ip is not an IP address, dropped");
		}
	}

	# we until here to do any censorship to try and reduce the amount of noise that repeated copies
	# from other connected nodes cause
	if ($censorpc) {
		my @bad;
		if (@bad = BadWords::check($pc->[5])) {
			DXHealth::operator_event('badlist', 'badword', $self->{call}, $pc->[7], sprintf('PC%02d', $pcno));
			my $bw = join ', ', @bad;
			dbg($line) if isdbg('nologchan');
			dbg("PCPROT: Badwords: '$bw', dropped");
			return;
		}
	}

	# this goes after the input filtering, but before the actual add
	# of the spot so that if it is input filtered, it isn't added to the dup
	# list. This allows it to come in from a "legitimate" source
	#
	## NOTE: this is where we FINALLY insert the spot into the DXDupe cache
	##
	## Jan 2025 - I have moved this here so that ONLY potential spots for
	##            output to users are added to the duplicate cache
	#
	#

	if (Spot::dup_find(@spot[0..4,7,14], \$dupe_reason)) {
		dbg("DUPE $self->{call}: $pc->[0] $key ignored $dupe_reason") if isdbg('chanerr') || isdbg('dupespot') || isdbg('spot');
		return;
	}

	# here we verify the spotter is currently connected to the node it says it is one. AKA email sender verify
	# but without the explicit probe to the node. We are relying on "historical" information, but it very likely
	# to be current once we have seen the first PC92C from that node.
	#
	# As for spots generated from non-PC92 nodes, we'll see...
	#
	if ($senderverify || isdbg('suspicious')) {
		my $sv = $senderverify;
#		$sv += 2 if isdbg('suspicious');
		my $nroute = Route::Node::get($pc->[7]);
		my $local = DXChannel::get($pc->[7]);
		my $uref = DXUser::get_current($pc->[7]);
		my $s = '';
		my $ip = $pcno == 61 ?  $pc->[8] : '';
		my ($hops) = $pc->[$pcno == 61 ? 9 : 8] =~ /H(\d+)/;

		if ($nroute && (($nroute->last_PC92C && $nroute->users) || ($local && !$local->do_pc9x))) {
#			$s .= "User $pc->[6] not logged in, " unless $uroute;
			$s .= "User $pc->[6] not on node $pc->[7], " unless $nroute->is_user($pc->[6]);
#			$s .= "Node $pc->[7] at '$ip' not on Node's IP " . $nroute->ip if $ip && $nroute && $nroute->ip && $nroute->ip ne $ip;
		}
		# check for ip addresses on spots from non-pc9x nodes - if they have it's likely done by DXSpider nodes
		#if ($ip && ($nroute  && !$nroute->do_pc9x || $uref && $uref->is_spider)) {
		#	$s .= "PC$pcno has spurious ipaddr '$ip' from non-pc9x node $pc->[7]";
		#}
		if ($s) {
			my $action = $sv > 1 ? ", DUMPED" : ', WARNING';
			$s =~ s/, $//;
			$hops ||= '0';
			dbg("PCPROT: Bad Spot $pc->[2] on $pc->[1] by $pc->[6]($ip)\@$pc->[7] $s$action via $self->{call} $hops hops");
			return unless $sv < 2;
		}
	}

	#
	# Now finally: save the spot itself and then send it on its merry way to the users
	#

	Spot::add_local(@spot);

	my $ip = '';
	$ip ||= $spot[14] if defined $spot[14];

	if (isdbg('progress')) {
		my $sip = $ip ? sprintf "($ip)" : '' unless $ip =~ m|[\(\)\*]|;
		$sip ||= '';
		my $d = ztime($spot[2]);
		my $s = "SPOT: $spot[1] on $spot[0] \@ $d by $spot[4]$sip\@$spot[7]";
		$s .= $spot[3] ? " '$spot[3]'" : q{ ''};
		$s .=  " route: $origin";
		dbg($s);
	}

	#
	# @spot at this point contains:-
	# freq, spotted call, time, text, spotter, spotted cc, spotters cc, orig node
	# then  spotted itu, spotted cq, spotters itu, spotters cq
	# you should be able to route on any of these
	#

	# fix up qra locators of known users
	my $user = DXUser::get_current($spot[4]);
	if ($user) {
		my $qra = $user->qra;
		unless ($qra && is_qra($qra)) {
			my $lat = $user->lat;
			my $long = $user->long;
			if (defined $lat && defined $long) {
				$user->qra(DXBearing::lltoqra($lat, $long));
				$user->put;
			}
		}

		# send a remote command to a distant cluster if it is visible and there is no
		# qra locator and we havn't done it for a month.

		unless ($user->qra) {
			my $node;
			my $to = $user->homenode;
			my $last = $user->lastoper || 0;
			if ($send_opernam && $to && $to ne $main::mycall && $main::systime > $last + $DXUser::lastoperinterval && ($node = Route::Node::get($to)) ) {
				my $cmd = "forward/opernam $spot[4]";
				# send the rcmd but we aren't interested in the replies...
				my $dxchan = $node->dxchan;
				if ($dxchan && $dxchan->is_clx) {
					route(undef, $to, pc84($main::mycall, $to, $main::mycall, $cmd));
				} else {
					route(undef, $to, pc34($main::mycall, $to, $cmd));
				}
				if ($to ne $origin) {
					$to = $origin;
					$node = Route::Node::get($to);
					if ($node) {
						$dxchan = $node->dxchan;
						if ($dxchan && $dxchan->is_clx) {
							route(undef, $to, pc84($main::mycall, $to, $main::mycall, $cmd));
						} else {
							route(undef, $to, pc34($main::mycall, $to, $cmd));
						}
					}
				}
				$user->lastoper($main::systime);
				$user->put;
			}
		}
	}

	# local processing
	if (defined &Local::spot) {
		my $r;
		eval {
			$r = Local::spot($self, @spot);
		};
		return if $r;
	}

	# Metrics: failure-isolated accepted PC11/PC61 rank telemetry.
	if ($pcno == 11 || $pcno == 61) {
		eval { DXHealth::accepted_spot_rank($spot[1], $spot[4], $spot[7]); 1 };
	}

	# DON'T be silly and send on PC26s!
	return if $pcno == 26;

	# Accepted semantic event: survived spot validation/local hook.
	DXHealth::protocol_logical_origin_line('accepted', $pc->[7], $line) if @spot && $self != $main::me;

	# send out the filtered spots. Forwarded is one logical event if at least
	# one protocol neighbour really received an egress after filtering/hops.
	my $sent = @spot ? send_dx_spot($self, $line, @spot) : 0;
	DXHealth::protocol_logical_origin_line('forwarded', $pc->[7], $line) if $sent && $self != $main::me;

	# cancel any recursion as we have now processed it
	my $count =  $pc11_to_61+$rpc11_to_61;
	my $percent = ($pc11_rx + $pc61_rx) ? ($pc11_rx * 100) / ($pc11_rx + $pc61_rx) : 0;
	my $pc11_61 = $pc11_rx ? ($count * 100) / $pc11_rx : 0;
	my $data = "$pc->[0] key: $key";
	my $stats = sprintf "pc11: $pc11_rx pc61: $pc61_rx pc11%%: %0.1f%% pc11->pc61: $count(%0.1f%%)", $percent, $pc11_61;
	if ($recurse) {
		if ($pc11_saved{$key}) {
			dbg("END $self->{call}: RECURSED $data removed and finished $stats") if isdbg('spot');
			delete $pc11_saved{$key};
		} else {
			dbg("END $self->{call}: RECURSED NO KEY finished $stats") if isdbg('spot');
		}
		$recurse = 0;
	} else {
		dbg("END $self->{call}: NORMAL $data finished $stats") if isdbg('spot');
	}
}

# used to kick outstanding PC11 if required
sub pc11_process
{
	foreach my $key (keys %pc11_saved) {
		my $r = $pc11_saved{$key};
		if ($main::systime > $r->[0] + $pc11_dwell_time) {
			dbg("---") if isdbg("spot");
			dbg("RECURSE $r->[1]->{call}: PC11 spot $key timed out waiting, resend") if isdbg("spot");
			my $self = $r->[1];
			delete $pc11_saved{$key};
			$self->handle_11(@$r[2..5], 1);
		}
	}
}

# return the pc11 / pc61 / promotions data
sub get_pc11_61_stats
{
	my $promotions =  $pc11_to_61+$rpc11_to_61;
	my $percent = ($pc11_rx + $pc61_rx) ? ($pc11_rx * 100) / ($pc11_rx + $pc61_rx) : 0;
	my $pc11_61p = $pc11_rx ? ($promotions * 100) / $pc11_rx : 0;
	return {
			pc11_rx => $pc11_rx+0,
			pc61_rx => $pc61_rx+0,
			pc11_to_61 => $pc11_to_61+0,
			rpc11_to_61 => $rpc11_to_61+0,
			promotions => $promotions+0,
			pc11_percent => $percent+0,
			promotions_percent => $pc11_61p+0,
		   };
}

# announces
sub handle_12
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	return if $self->check_available($origin, $pcno);

	# announce duplicate checking
	$pc->[3] =~ s/^\s+//;			# remove leading blanks

	# if this is a 'nodx' node then ignore it
	if ($badnode->in($pc->[5], $preserve_node_ssid)) {
		DXHealth::operator_event('badlist', 'badnode', $self->{call}, $pc->[5], 'PC12');
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Bad Node $pc->[5], dropped");
		return;
	}

	# if this is a 'bad spotter' user then ignore it
	if ($badspotter->in($pc->[1])) {
		DXHealth::operator_event('badlist', 'badspotter', $self->{call}, $pc->[5], 'PC12');
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Bad Spotter $pc->[1], dropped");
		return;
	}

	# ignore PC12s from origins that use PCxx protocol
	my $oref = Route::get($origin);
	if ($oref->do_pc9x) {
		dbg("PCPROT: PC12 rxed from PC9x node, ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	if ($censorpc) {
		my @bad;
		if (@bad = BadWords::check($pc->[3])) {
			DXHealth::operator_event('badlist', 'badword', $self->{call}, $pc->[5], 'PC12');
			my $bw = join ', ', @bad;
			dbg($line) if isdbg('nologchan');
			dbg("PCPROT: Badwords: '$bw', dropped");
			return;
		}
	}


	my $dxchan;

	if ((($dxchan = DXChannel::get($pc->[2])) && $dxchan->is_user) || $pc->[4] =~ /^[\#\w.]+$/){
		$self->send_chat(0, $line, @$pc[1..6]);
	} elsif ($pc->[2] eq '*' || $pc->[2] eq $main::mycall) {

		# ignore something that looks like a chat line coming in with sysop
		# flag - this is a kludge...
		if ($pc->[3] =~ /^\#\d+ / && $pc->[4] eq '*') {
			dbg('PCPROT: Probable chat rewrite, dropped') if isdbg('chanerr') || isdbg('routelow');
			return;
		}

		# here's a bit of fun, convert incoming ann with a callsign in the first word
		# or one saying 'to <call>' to a talk if we can route to the recipient
		if ($ann_to_talk) {
			my $call = AnnTalk::is_talk_candidate($pc->[1], $pc->[3]);
			if ($call) {
				my $ref = Route::get($call);
				if ($ref) {
					$dxchan = $ref->dxchan;
					$dxchan->talk($pc->[1], $call, undef, $pc->[3], $pc->[5]) if $dxchan != $self;
					return;
				}
			}
		}

		# send it
		$self->send_announce(0, $line, @$pc[1..6]);
	} else {
		$self->route($pc->[2], $line);
	}

	# local processing
	if (defined &Local::ann) {
		my $r;
		eval {
			$r = Local::ann($self, $line, @$pc[1..6]);
		};
		return if $r;
	}
}

sub handle_15
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if (eph_dup($line, $eph_pc15_restime)) {
		return;
	} else {
		unless ($self->{isolate}) {
			DXChannel::broadcast_nodes($line, $self) if $line =~ /\^H\d+\^?~?$/; # send it to everyone but me
		}
	}
}

# incoming user
sub handle_16
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# Accept legacy routing only on the directly connected classic-protocol link.
	# Never ingest legacy routing forwarded by a PC9x neighbour.
	return if $self->{do_pc9x};
	
	# general checks
	my $dxchan;
	my $ncall = $pc->[1];
	my $newline = "PC16^";

	# dos I want users from this channel?
	unless ($self->user->wantpc16) {
		dbg("PCPROT: don't send users to $self->{call}") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	# is it me?
	if ($ncall eq $main::mycall) {
		dbg("PCPROT: trying to alter config on this node from outside!") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	my $h;
	$h = 1 if DXChannel::get($ncall);
	if ($h && $self->{call} ne $ncall) {
		dbg("PCPROT: trying to update a local node, ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	if (eph_dup($line)) {
		return;
	}

	# isolate now means only accept stuff from this call only
	if ($self->{isolate} && $ncall ne $self->{call}) {
		dbg("PCPROT: $self->{call} isolated, $ncall ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	my $parent = Route::Node::get($ncall);

	if ($parent) {
		$dxchan = $parent->dxchan;
		if ($dxchan && $dxchan ne $self) {
			dbg("PCPROT: PC16 from $self->{call} trying to alter locally connected $ncall, ignored!") if isdbg('chanerr') || isdbg('routelow');
			return;
		}

		# input filter if required
		return unless $self->in_filter_route($parent);
	} else {
		$parent = Route::Node->new($ncall);
	}

	unless ($h) {
		if ($parent->via_pc92) {
			dbg("PCPROT: non-local node controlled by PC92, ignored") if isdbg('chanerr') || isdbg('routelow');
			return;
		}
	}

	my $i;
	my @rout;
	for ($i = 2; $i < $#$pc; $i++) {
		my ($call, $conf, $here) = $pc->[$i] =~ /^(\S+) (\S) (\d)/o;
		next unless $call && $conf && defined $here && is_callsign($call);
		next if $call eq $main::mycall;

		eph_del_regex("^PC17\\^$call\\^$ncall");

		$conf = $conf eq '*';

		# reject this if we think it is a node already
		my $rng = Route::Node::get($call);
		my $u = DXUser::get_current($call) unless $rng;
		if ($rng || ($u && $u->is_node)) {
			dbg("PCPROT: $call is a node") if isdbg('chanerr') || isdbg('routelow');
			next;
		}

		my $rug = Route::User::get($call);
		my $flags = Route::here($here)|Route::conf($conf);

		if ($rug) {
			my $au = $rug->addparent($parent);
			if ($rug->flags != $flags) {
				$rug->flags($flags);
				$au = $rug;
			}
			push @rout, $rug if $h && $au;
		} else {
			my @ans = $parent->add_user($call, $flags);
			push @rout, @ans if $h && @ans;
		}

		# add this station to the user database, if required
		my $user = DXUser::get_current($ncall);
		$user = DXUser->new($call) unless $user;
		$user->homenode($parent->call) if !$user->homenode;
		$user->node($parent->call);
		$user->lastin($main::systime) unless DXChannel::get($call);
		$user->put;

		# send info to all logged in thingies
		$self->tell_login('loginu', "$ncall: $call") if $user->is_local_node;
		$self->tell_buddies('loginb', $call, $ncall);
	}
	if (@rout) {
		$self->route_pc16($origin, $line, $parent, @rout) if @rout;
#		$self->route_pc92a($main::mycall, undef, $parent, @rout) if $h && $self->{state} eq 'normal';
	}
}

# remove a user
sub handle_17
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# Accept legacy routing only on the directly connected classic-protocol link.
	# Never ingest legacy routing forwarded by a PC9x neighbour.
	return if $self->{do_pc9x};
	
	my $dxchan;
	my $ncall = $pc->[2];
	my $ucall = $pc->[1];

	eph_del_regex("^PC16\\^$ncall.*$ucall");

	# do I want users from this channel?
	unless ($self->user->wantpc16) {
		dbg("PCPROT: don't send users to $self->{call}") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	if ($ncall eq $main::mycall) {
		dbg("PCPROT: trying to alter config on this node from outside!") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	# isolate now means only accept stuff from this call only
	if ($self->{isolate} && $ncall ne $self->{call}) {
		dbg("PCPROT: $self->{call} isolated, $ncall ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	my $uref = Route::User::get($ucall);
	unless ($uref) {
		dbg("PCPROT: Route::User $ucall not in config") if isdbg('chanerr') || isdbg('routelow');
		return;
	}
	my $parent = Route::Node::get($ncall);
	unless ($parent) {
		dbg("PCPROT: Route::Node $ncall not in config") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	$dxchan = DXChannel::get($ncall);
	if ($dxchan && $dxchan ne $self) {
		dbg("PCPROT: PC17 from $self->{call} trying to alter locally connected $ncall, ignored!") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	unless ($dxchan) {
		if ($parent->via_pc92) {
			dbg("PCPROT: non-local node controlled by PC92, ignored") if isdbg('chanerr') || isdbg('routelow');
			return;
		}
	}

	if (DXChannel::get($ucall)) {
		dbg("PCPROT: trying do disconnect local user, ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	# input filter if required and then remove user if present
#		return unless $self->in_filter_route($parent);
	$parent->del_user($uref);

	# send info to all logged in thingies
	my $user = DXUser::get_current($ncall);
	$self->tell_login('logoutu', "$ncall: $ucall") if $user && $user->is_local_node;
	$self->tell_buddies('logoutb', $ucall, $ncall);

	if (eph_dup($line)) {
		return;
	}

	$self->route_pc17($origin, $line, $parent, $uref);
#	$self->route_pc92d($main::mycall, undef, $parent, $uref) if $dxchan;
}

# link request
sub handle_18
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $conn = $self->conn;

	$self->state('init');

	my $parent = Route::Node::get($self->{call});

	my ($software, $version, $build) = (undef, 0, 0);
	my $old_user_version = $self->user->version;
	my $old_user_build = $self->user->build;

	# record the type and version offered
	if (($software, $version) = $pc->[1] =~ /(DXSpider|CC\s*Cluster)\s+Version: (\d+(?:\.\d+)?)/i) {
		$version += 0;
		$version += 53 if $version < 6;
		$self->{version} = $version;
		$self->user->version($version);
		$parent->version($version);
		my ($build) = $pc->[1] =~ /Build: (\d+(?:\.\d+)?)/;
		$build += 0;
		$build = 0 unless $build > 1;
		$self->{build} = $build;
		$self->user->build($build);
		$parent->build($build);
		dbg("PC18 $self->{call} = $software version $version build $build");
		if ($software =~ /^DXSp/ && !$self->is_spider) {
			dbg("PC18 Change sort U " . $self->user->sort . " C $self->{sort} -> S");
			$self->sort('S');
			$self->user->sort('S');
			$self->user->put;
		}
		if ($software =~ /^CC/ && !$self->is_ccluster) {
			dbg("PC18 Change sort U " . $self->user->sort . " C $self->{sort} -> L");
			$self->sort('L');
			$self->user->sort('L');
			$self->user->put;
		}
	} elsif (($software, $version, $build) = $pc->[1] =~ /(AR-Cluster)\s+Version:\s+(\d+\.\d+).?(\d+\.\d+)?/) {
		dbg("PC18 $self->{call} = $software version $version build $build");
		$self->{version} = $version;
		$self->user->version($version);
		$parent->version($version);
		$self->{build} = $build;
		$self->user->build($build);
		$parent->build($build);
		unless ($self->is_arcluster) {
			dbg("Change U " . $self->user->sort . " C $self->{sort} -> R");
			$self->user->sort('R');
			$self->user->put;
			$self->sort('R');
		}
	} else {
		dbg("PC18 $self->{call} = Unknown software ($pc->[1] $pc->[2])");
		$self->version(50.0);
		$self->version($pc->[2] / 100) if $pc->[2] && $pc->[2] =~ /^\d+$/;
		$self->user->version($self->version);
	}

	# Persist changed PC18 metadata even when the node sort stays the same.
	# Keep existing sort-change puts untouched for compatibility.
	my $new_user_version = $self->user->version;
	my $new_user_build = $self->user->build;
	$self->user->put if (defined $new_user_version ? !defined $old_user_version || "$new_user_version" ne "$old_user_version" : defined $old_user_version)
	                || (defined $new_user_build ? !defined $old_user_build || "$new_user_build" ne "$old_user_build" : defined $old_user_build);

	# for incoming CC Clusters go straight to state 'normal', otherwise bang out.
	# In future this may well cause a disconnection
	unless ($self->outbound) {
		if ($self->is_ccluster) {
			my @rout = $parent->del_nodes;
			$self->route_pc21($origin, $line, @rout, $parent) if @rout;
#			$self->send_local_config();
			$self->state('normal');
			$self->{lastping} = 0;
#			$self->route_pc92a($main::mycall, undef, $main::routeroot, Route::Node::get($self->{call}));
		} else {
			dbg("PC18 on startup an incoming connection from $self->{call} ignored as iappropriate");
			return;
		}
	}

	if ($pc->[1] =~ /CC\s*Cluster/i || $pc->[1] =~ /\bpc9x/i) {
		if ($self->{isolate}) {
			dbg("PC18 $self->{call} pc9x recognised, but node is isolated, using old protocol");
		} elsif (!$self->user->wantpc9x) {
			dbg("PC18 $self->{call} pc9x explicitly switched off, using old protocol");
		} else {
			$self->{do_pc9x} = 1;
			$self->{do_pc91} = $pc->[1] =~ /\b91/;;
			dbg("PC18 $self->{call} Set do " . $self->{pc91} ? "PC9[123]" : "PC9[23]");
		}
	}

	# for incoming CC Clusters go straight to state 'normal', otherwise bang out.
	# In future this may well cause a disconnection
	unless ($self->outbound) {
		if ($self->is_ccluster) {
			$self->state('normal');
			$self->{lastping} = 0;
#			$self->route_pc92a($main::mycall, undef, $main::routeroot, Route::Node::get($self->{call}));
		} else {
			dbg("PC18 on startup an incoming connection from $self->{call} ignored as iappropriate");
			return;
		}
	}


	# first clear out any nodes on this dxchannel
	my @rout = $parent->del_nodes;
	$self->route_pc21($origin, $line, @rout, $parent) if @rout;
	$self->send_local_config();
	$self->send(pc20());
}

sub check_add_user
{
	my $call = shift;
	my $type = shift;
	my $homenode = shift;
	my $changed = 0;

	# add this station to the user database, if required (don't remove SSID from nodes)
	my $user = DXUser::get_current($call);
	unless ($user) {
		$user = DXUser->new($call);
		$user->sort($type || 'U');
		if ($user->is_node) {
			$user->priv(1);		# I have relented and defaulted nodes
			$user->lockout(1);
		} else {
			$user->homenode($homenode) if $homenode;
			$user->node($homenode);
			$user->priv(0);
			$user->lockout(0);
		}
		$user->lastin($main::systime); # this makes it last longer than just this invocation
		++$changed;
		dbg(sprintf "DXProt: PC92 new user record for $call created type: %s priv: %d lockout: %d", $user->sort, $user->priv, $user->lockout);
	}

	# this is to fix a problem I introduced some build ago by using this function for users
	# whereas it was only being used for nodes.
	if ($user->is_user && $user->lockout && ($user->priv || 0) == 1) {
		dbg(sprintf "DXProt: PC92 user record for $call type: %s priv: %d lockout: %d updated, depriv'd and unlocked", $user->sort, $user->priv, $user->lockout);
		$user->priv(0);
		$user->lockout(0);
		++$changed;
	}
	$user->put if $changed;				# just to make sure it gets written away!!!
	return $user;
}

# incoming cluster list
sub handle_19
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# Accept legacy routing only on the directly connected classic-protocol link.
	# Never ingest legacy routing forwarded by a PC9x neighbour.
	return if $self->{do_pc9x};

	my $i;
	my $newline = "PC19^";

	# new routing list
	my @rout;
	# PC19 remains local/legacy; never synthesize PC92 for another node.

	# first get the INTERFACE node
	my $parent = Route::Node::get($self->{call});
	unless ($parent) {
		dbg("PCPROT: my parent $self->{call} has disappeared");
		$self->disconnect;
		return;
	}

	my $h;

	# parse the PC19
	#
	# We are making a major change from now on. We are only going to accept
	# PC19s from directly connected nodes.  This means that we are probably
	# going to throw away most of the data that we are being sent.
	#
	# The justification for this is that most of it is wrong or out of date
	# anyway.
	#
	# From now on we are only going to believe PC92 data and locally connected
	# non-pc92 nodes.
	#
	for ($i = 1; $i < $#$pc-1; $i += 4) {
		my $here = $pc->[$i];
		my $call = uc $pc->[$i+1];
		my $conf = $pc->[$i+2];
		my $ver = $pc->[$i+3];
		next unless defined $here && defined $conf && is_callsign($call);

		eph_del_regex("^PC(?:21\\^$call|17\\^[^\\^]+\\^$call)");

		# check for sane parameters
		#				$ver = 5000 if $ver eq '0000';
		next unless $ver && $ver =~ /^\d+$/;
		next if $ver < 5000;	# only works with version 5 software
		next if length $call < 3; # min 3 letter callsigns
		next if $call eq $main::mycall || $call eq $main::myalias;

		# check that this PC19 isn't trying to alter the wrong dxchan
		$h = 0;
		my $dxchan = DXChannel::get($call);
		if ($dxchan) {
			if ($dxchan == $self) {
				$h = 1;
			} else {
				dbg("PCPROT: PC19 from $self->{call} trying to alter wrong locally connected $call, ignored!") if isdbg('chanerr') || isdbg('routelow');
				next;
			}
		}

		# isolate now means only accept stuff from this call only
		if ($self->{isolate} && $call ne $self->{call}) {
			dbg("PCPROT: $self->{call} isolated, $call ignored") if isdbg('chanerr') || isdbg('routelow');
			next;
		}

		if ($call eq $main::myalias) {
			LogDbg('err', "ROUTE: $call eq \$myalias from $self->{call}, ignored!!!");
			dbgprintring(3) if isdbg('nologchan');
			next;
		}

		unless ($h) {
			if ($parent->via_pc92) {
				dbg("PCPROT: non-local node controlled by PC92, ignored") if isdbg('chanerr') || isdbg('routelow');
				next;
			}
		}

		my $user = check_add_user($call, 'A');
		my $r = Route::Node::get($call);
		my $flags = Route::here($here)|Route::conf($conf);

		# modify the routing table if it is in it, otherwise store it in the pc19list for now
		if ($r) {
			my $ar;
			if ($call ne $parent->call) {
				if ($self->in_filter_route($r)) {
					$ar = $parent->add($call, $ver, $flags);
#					push @rout, $ar if $ar;
				} else {
					next;
				}
			}
			if ($r->version ne $ver || $r->flags != $flags) {
				$r->version($ver);
				$r->flags($flags);
			}
			push @rout, $r;
		} else {
			if ($call eq $self->{call} || $user->wantroutepc19) {
				my $new = Route->new($call); # throw away
				if ($self->in_filter_route($new)) {
					my $ar = $parent->add($call, $ver, $flags);
					$user->wantroutepc19(1) unless defined $user->wantroutepc19;
					push @rout, $ar if $ar;
				} else {
					next;
				}
			}
		}

		# unbusy and stop and outgoing mail (ie if somehow we receive another PC19 without a disconnect)
		my $mref = DXMsg::get_busy($call);
		$mref->stop_msg($call) if $mref;

		$user->lastin($main::systime) unless DXChannel::get($call);
		$user->put;
	}

	# we are not automatically sending out PC19s, we send out a composite PC21,PC19 instead
	# but remember there will only be one (pair) these because any extras will be
	# thrown away.
	if (@rout) {
#		$self->route_pc21($self->{call}, $line, @rout);
		$self->route_pc19($self->{call}, $line, @rout);
	}
}

# send local configuration
sub handle_20
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($self->{do_pc9x} && $self->{state} ne 'init92' && $self->{state} ne 'normal') {
		$self->send("Reseting to oldstyle routing because login call not sent in any pc92");
		$self->{do_pc9x} = 0;
	}
	$self->send_local_config;
	$self->send(pc22());
	$self->state('normal');
	$self->{lastping} = 0;
	$self->route_pc92a($main::mycall, undef, $main::routeroot, Route::Node::get($self->{call}));
}

# delete a cluster from the list
#
# This should never occur for directly connected nodes.
#
sub handle_21
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# Accept legacy routing only on the directly connected classic-protocol link.
	# Never ingest legacy routing forwarded by a PC9x neighbour.
	return if $self->{do_pc9x};

	my $call = uc $pc->[1];

	eph_del_regex("^PC1[679].*$call");

	# if I get a PC21 from the same callsign as self then ignore it
	if ($call eq $self->{call}) {
		dbg("PCPROT: self referencing PC21 from $self->{call}");
		return;
	}

	# for the above reason and also because of the check for PC21s coming
	# in for self->call from outside being ignored further down
	# we don't need any isolation code here, because we will never
	# act on a PC21 with self->call in it.

	my $parent = Route::Node::get($self->{call});
	unless ($parent) {
		dbg("PCPROT: my parent $self->{call} has disappeared");
		$self->disconnect;
		return;
	}

	my @rout;

	if ($call ne $main::mycall && $call ne $main::myalias) { # don't allow malicious buggers to disconnect me!
		my $node = Route::Node::get($call);
		if ($node) {

			if ($node->via_pc92) {
				dbg("PCPROT: controlled by PC92, ignored") if isdbg('chanerr') || isdbg('routelow');
				return;
			}

			my $dxchan = DXChannel::get($call);
			if ($dxchan && $dxchan != $self) {
				dbg("PCPROT: PC21 from $self->{call} trying to alter locally connected $call, ignored!") if isdbg('chan');
				return;
			}

			# input filter it
			return unless $self->in_filter_route($node);

			# routing objects, force a PC21 if it is local
			push @rout, $node->del($parent);
			push @rout, $call if $dxchan && @rout == 0;
		}
	} else {
		dbg("PCPROT: I WILL _NOT_ be disconnected!") if isdbg('chan');
		return;
	}

	if (eph_dup($line)) {
		return;
	}

	if (@rout) {
		$self->route_pc21($origin, $line, @rout);
#		$self->route_pc92d($main::mycall, $line, $main::routeroot, @rout);
	}
}


sub handle_22
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($self->{do_pc9x}) {
		if ($self->{state} ne 'init92' && $self->{state} ne 'normal') {
			$self->send("Reseting to oldstyle routing because login call not sent in any pc92");
			$self->{do_pc9x} = 0;
		}
	}
	$self->{lastping} = 0;
	$self->state('normal');
	$self->route_pc92a($main::mycall, undef, $main::routeroot, Route::Node::get($self->{call}));
}

# WWV info
sub handle_23
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	# route foreign' pc27s
	if ($pcno == 27) {
		if ($pc->[8] ne $main::mycall) {
			$self->route($pc->[8], $line);
			return;
		}
	}


	# do some de-duping
	my $d = cltounix($pc->[1], sprintf("%02d18Z", $pc->[2]));
	my $sfi = unpad($pc->[3]);
	my $k = unpad($pc->[4]);
	my $i = unpad($pc->[5]);
	my ($r) = $pc->[6] =~ /R=(\d+)/;
	$r = 0 unless $r;
	if (($pcno == 23 && $d < $main::systime - $pc23_max_age) || $d > $main::systime + 1500 || $pc->[2] < 0 || $pc->[2] > 23) {
		dbg("PCPROT: WWV Date ($pc->[1] $pc->[2]) out of range") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	# global wwv filtering on INPUT
	my @dxcc = ((Prefix::cty_data($pc->[7]))[0..2], (Prefix::cty_data($pc->[8]))[0..2]);
	if ($self->{inwwvfilter}) {
		my ($filter, $hops) = $self->{inwwvfilter}->it(@$pc[7,8], $origin, @dxcc);
		unless ($filter) {
			dbg("PCPROT: Rejected by input wwv filter") if isdbg('chanerr') || isdbg('routelow');
			return;
		}
	}
	$pc->[7] =~ s/-\d+$//o;		# remove spotter's ssid
	if (Geomag::dup($d,$sfi,$k,$i,$pc->[6],$pc->[7])) {
		dbg("PCPROT: Dup WWV Spot ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	# note this only takes the first one it gets
	Geomag::update($d, $pc->[2], $sfi, $k, $i, @$pc[6..8], $r);
	dbg("WWV: <$pc->[2]>, sfi=$sfi k=$k info=$i '$pc->[6]' $pc->[7]\@$pc->[8] $r route: $origin") if isdbg('progress');

	if (defined &Local::wwv) {
		my $rep;
		eval {
			$rep = Local::wwv($self, $pc->[1], $pc->[2], $sfi, $k, $i, @$pc[6..8], $r);
		};
		return if $rep;
	}

	# DON'T be silly and send on PC27s!
	return if $pcno == 27;

	DXHealth::protocol_logical_line('accepted', $line) if $self != $main::me;

	# broadcast to the eager world
	my $sent = send_wwv_spot($self, $line, $d, $pc->[2], $sfi, $k, $i, @$pc[6..8]);
	DXHealth::protocol_logical_line('forwarded', $line) if $sent && $self != $main::me;
}

# set here status
sub handle_24
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $call = uc $pc->[1];
	my ($nref, $uref);
	$nref = Route::Node::get($call);
	$uref = Route::User::get($call);
	return unless $nref || $uref; # if we don't know where they are, it's pointless sending it on

	if (eph_dup($line)) {
		return;
	}

	$nref->here($pc->[2]) if $nref;
	$uref->here($pc->[2]) if $uref;
	my $ref = $nref || $uref;
	return unless $self->in_filter_route($ref);
	DXHealth::protocol_logical_line('accepted', $line) if $self != $main::me;

	my $sent = $self->route_pc24($origin, $line, $ref, $pc->[3]);
	DXHealth::protocol_logical_line('forwarded', $line) if $sent && $self != $main::me;
}

# merge request
sub handle_25
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($pc->[1] ne $main::mycall) {
		$self->route($pc->[1], $line);
		return;
	}
	if ($pc->[2] eq $main::mycall) {
		dbg("PCPROT: Trying to merge to myself, ignored") if isdbg('chan');
		return;
	}

	Log('DXProt', "Merge request for $pc->[3] spots and $pc->[4] WWV from $pc->[2]");

	# spots
	if ($pc->[3] > 0) {
		my @in = reverse Spot::search(1, undef, undef, 0, $pc->[3]);
		my $in;
		foreach $in (@in) {
			$self->send(pc26(@{$in}[0..4], $pc->[2]));
		}
	}

	# wwv
	if ($pc->[4] > 0) {
		my @in = reverse Geomag::search(0, $pc->[4], time, 1);
		my $in;
		foreach $in (@in) {
			$self->send(pc27(@{$in}[0..5], $pc->[2]));
		}
	}
}

sub handle_26 {goto &handle_11}
sub handle_27 {goto &handle_23}

# mail/file handling
sub handle_28
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($pc->[1] eq $main::mycall) {
		no strict 'refs';
		my $sub = "DXMsg::handle_$pcno";
		&$sub($self, @$pc);
	} else {
		$self->route($pc->[1], $line) unless $self->is_clx;
	}
}

sub handle_29 {goto &handle_28}
sub handle_30 {goto &handle_28}
sub handle_31 {goto &handle_28}
sub handle_32 {goto &handle_28}
sub handle_33 {goto &handle_28}

sub handle_34
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if (eph_dup($line, $eph_pc34_restime)) {
		return;
	} else {
		$self->process_rcmd($pc->[1], $pc->[2], $pc->[2], $pc->[3]);
	}
}

# remote command replies
sub handle_35
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	eph_del_regex("^PC35\\^$pc->[2]\\^$pc->[1]\\^");
	$self->process_rcmd_reply($pc->[1], $pc->[2], $pc->[1], $pc->[3]);
}

sub handle_36 {goto &handle_34}

# database stuff
sub handle_37
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($pc->[1] eq $main::mycall) {
		no strict 'refs';
		my $sub = "DXDb::handle_$pcno";
		&$sub($self, @$pc);
	} else {
		$self->route($pc->[1], $line) unless $self->is_clx;
	}
}

# node connected list from neighbour
sub handle_38
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;
}

# incoming disconnect
sub handle_39
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if ($pc->[1] eq $self->{call}) {
		$self->disconnect(1);
	} else {
		dbg("PCPROT: came in on wrong channel") if isdbg('chanerr') || isdbg('routelow');
	}
}

sub handle_40 {goto &handle_28}

# user info
sub handle_41
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	return if $self->check_available($origin, $pcno);

	my $call = $pc->[1];
	my $sort = $pc->[2];
	my $val = $pc->[3];

	my $l = "PC41^$call^$sort";
	if (eph_dup($l, $eph_info_restime)) {
		return;
	}

	# input filter if required
	#			my $ref = Route::get($call) || Route->new($call);
	#			return unless $self->in_filter_route($ref);

	if ($val eq $sort || $val =~ /^\s*$/) {
		dbg('PCPROT: invalid value') if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	if ($call eq $main::mycall || $call eq $main::myalias) {
		dbg "DXPROT: PC41 trying to update $call from outside via $origin, ignored";
		return;
	}
	my $chan = DXChannel::get($call);
	if ($chan) {
		dbg "DXPROT: PC41 trying to update online $call from outside via $origin, ignored";
		return;
	}

	# add this station to the user database, if required
	my $user = DXUser::get_current($call);
	$user = DXUser->new($call) unless $user;

	if ($sort == 1) {
		if (($val =~ /spotter/i || $val =~ /self/i) && $user->name && $user->name ne $val) {
			dbg("PCPROT: invalid name") if isdbg('chanerr') || isdbg('routelow');
			return;
		}
		$user->name($val);
	} elsif ($sort == 2) {
		$user->qth($val);
	} elsif ($sort == 3) {
		if (is_latlong($val)) {
			my ($lat, $long) = DXBearing::stoll($val);
			$user->lat($lat) if $lat;
			$user->long($long) if $long;
			$user->qra(DXBearing::lltoqra($lat, $long)) unless $user->qra;
		} else {
			dbg('PCPROT: not a valid lat/long') if isdbg('chanerr') || isdbg('routelow');
			return;
		}
	} elsif ($sort == 4) {
		$user->homenode($val);
	} elsif ($sort == 5) {
		if (is_qra(uc $val)) {
			my ($lat, $long) = DXBearing::qratoll(uc $val);
			$user->lat($lat) if $lat && !$user->lat;
			$user->long($long) if $long && !$user->long;
			$user->qra(uc $val);
		} else {
			dbg('PCPROT: not a valid QRA locator') if isdbg('chanerr') || isdbg('routelow');
			return;
		}
	}
	$user->lastoper($main::systime); # to cut down on excessive for/opers being generated
	$user->put;

	unless ($self->{isolate}) {
		DXChannel::broadcast_nodes($line, $self); # send it to everyone but me
	}

	#  perhaps this IS what we want after all
	#			$self->route_pc41($ref, $call, $sort, $val, $pc->[4]);
}

sub handle_42 {goto &handle_28}


# database
sub handle_44 {goto &handle_37}
sub handle_45 {goto &handle_37}
sub handle_46 {goto &handle_37}
sub handle_47 {goto &handle_37}
sub handle_48 {goto &handle_37}

# message and database
sub handle_49
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	if (eph_dup($line)) {
		return;
	}

	if ($pc->[1] eq $main::mycall) {
		DXMsg::handle_49($self, @$pc);
	} else {
		$self->route($pc->[1], $line) unless $self->is_clx;
	}
}

# keep alive/user list
sub handle_50
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	return if (eph_dup($line));

	my $call = $pc->[1];

	my $node = Route::Node::get($call);
	if ($node) {
		return unless $node->call eq $self->{call};
		$node->usercount($pc->[2]) unless $node->users;
		$node->reset_obs;
		$node->PC92C_dxchan($self->call, $pc->[-1]);

		# input filter if required
#		return unless $self->in_filter_route($node);

		unless ($self->{isolate}) {
			DXChannel::broadcast_nodes($line, $self); # send it to everyone but me
		}
#		$self->route_pc50($origin, $line, $node, $pc->[2], $pc->[3]) unless eph_dup($line);
	}
}

# incoming ping requests/answers
sub handle_51
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $to = $pc->[1];
	my $from = $pc->[2];
	my $flag = $pc->[3];

	if ($to eq $main::myalias) {
		dbg("DXPROT: Ping addressed to \$myalias ($main::myalias), ignored") if isdbg('chan');
		return;
	}

	# is it for us?
	if ($to eq $main::mycall) {
		DXHealth::protocol_logical_line('accepted', $line) if $self != $main::me;
		if ($flag == 1) {
			my $reply = pc51($from, $to, '0');
			DXHealth::protocol_logical_line('reply', $reply);
			$self->send($reply);
		} else {
			DXXml::Ping::handle_ping_reply($self, $from);
		}
	} else {
		if (eph_dup($line)) {
			return;
		}
		DXHealth::protocol_logical_line('accepted', $line) if $self != $main::me;
		# route down an appropriate thingy
		my $sent = $self->route($to, $line);
		DXHealth::protocol_logical_line('forwarded', $line) if $sent && $self != $main::me;
	}
}

sub handle_61 { goto &handle_11; }

# dunno but route it
sub handle_75
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $call = $pc->[1];
	if ($call ne $main::mycall) {
		$self->route($call, $line);
	}
}

# WCY broadcasts
sub handle_73
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my $call = $pc->[1];

	# do some de-duping
	my $d = cltounix($call, sprintf("%02d18Z", $pc->[2]));
	if (($pcno == 23 && $d < $main::systime - $pc23_max_age) || $d > $main::systime + 1500 || $pc->[2] < 0 || $pc->[2] > 23) {
		dbg("PCPROT: WCY Date ($call $pc->[2]) out of range") if isdbg('chanerr') || isdbg('routelow');
		return;
	}
	$pc = [ map { unpad($_) } @$pc ];
	# Do not let an unauthorized source reserve a duplicate slot.
	unless (WCY::allowed_source($pc->[11])) {
		dbg("PCPROT: WCY source $pc->[11] not allowed") if isdbg('chanerr') || isdbg('routelow');
		return;
	}
	if (WCY::dup($d, $pc->[11])) {
		dbg("PCPROT: Dup WCY Spot ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	my $wcy = WCY::update($d, @$pc[2..12]);
	dbg("WCY: <$pc->[2]> K=$pc->[5] expK=$pc->[6] A=$pc->[4] R=$pc->[7] SFI=$pc->[3] SA=$pc->[8] GMF=$pc->[9] Au=$pc->[10] $pc->[11]\@$pc->[12] route: $origin") if isdbg('progress');

	if (defined &Local::wcy) {
		my $rep;
		eval {
			$rep = Local::wcy($self, @$pc[1..12]);
		};
		return if $rep;
	}

	DXHealth::protocol_logical_line('accepted', $line) if $self != $main::me;

	# broadcast to the eager world
	my $sent = send_wcy_spot($self, $line, $d, @$pc[2..12]);
	DXHealth::protocol_logical_line('forwarded', $line) if $sent && $self != $main::me;
}

# remote commands (incoming)
sub handle_84
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	return if $self->check_available($origin, $pcno);

	$self->process_rcmd($pc->[1], $pc->[2], $pc->[3], $pc->[4]);
}

# remote command replies
sub handle_85
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	$self->process_rcmd_reply($pc->[1], $pc->[2], $pc->[3], $pc->[4]);
}

# decode a pc92 call: flag call : version : build
sub _decode_pc92_call
{
	my $icall = shift;
	my @part = split /:/, $icall;
	my ($flag, $call) = unpack "A A*", $part[0];
	unless (defined $flag && $flag ge '0' && $flag le '7') {
		dbg("PCPROT: $icall no flag byte (0-7) at front of call, ignored") if isdbg('chanerr') || isdbg('routelow');
		return ();
	}
	unless ($call && is_callsign($call)) {
		dbg("PCPROT: $icall no recognisable callsign, ignored") if isdbg('chanerr') || isdbg('routelow');
		return ();
	}
	my $is_node = $flag & 4;
	my $is_extnode = $flag & 2;
	my $here = $flag & 1;
	my $version = $part[1] || 0;
	my $build = $part[2] || 0;
	my $ip = $part[3] || '';

	# A/C/D wire format is CALL[:VERSION][:IP].  The legacy K format
	# CALL:VERSION:BUILD is still supported; distinguish by actual IP
	# syntax rather than by the presence of a dot or comma alone.
	if (defined $part[1] && length $part[1]) {
		my $candidate = $part[1];
		$candidate =~ tr/,/:/;
		if (is_ipaddr($candidate)) {
			$ip = $candidate;
			$version = 0;
			$build = 0;
		}
	}
	if (defined $part[2] && length $part[2]) {
		my $candidate = $part[2];
		$candidate =~ tr/,/:/;
		if (is_ipaddr($candidate)) {
			$ip = $candidate;
			$build = 0;
		}
	}
	$version =~ s/\D//g;
	$version = 0 unless $version && $version =~ /^[0-9]+$/;
	$build =~ s/^0\.//;
	$build =~ s/\D//g;
	$build = 0 unless $build && $build =~ /^[0-9]+$/;
	if ($ip) {
		$ip =~ s/,/:/g;
		$ip =~ s/^::ffff://i;
		$ip = '' unless is_ipaddr($ip);
	}
	dbg("'$icall' = '" . join("', '", $call, $is_node, $is_extnode, $here, $version, $build, $ip) . "'") if isdbg('pc92');
	return ($call, $is_node, $is_extnode, $here, $version+0, $build+0, $ip);
}

# decode a pc92 call: flag call : version : build
sub _encode_pc92_call
{
	my $ref = shift;

	# plain call or value
	return $ref unless ref $ref;

	my $ext = shift || 0;
	my $flag = 0;
	my $call = $ref->call;
	my $extra = '';
	$flag |= $ref->here ? 1 : 0;
	if ($ref->isa('Route::Node') || $ref->isa('DXProt')) {
		$flag |= 4;
		my $dxchan = DXChannel::get($call);
		$flag |= 2 if $call ne $main::mycall && $dxchan && !$dxchan->{do_pc9x};
		if (($ext & 1) && $ref->version) {
			my $version = $ref->version || 1.0;
			$version =  $version * 100 + 5300 if $version < 50;
			$extra .= ":" . $version;
		}
	}
	if (($ext & 2) && $ref->ip) {
		my $ip = $ref->ip;
		# Normalize only locally owned objects; preserve remote routing data.
		my $local = $call eq $main::mycall;
		unless ($local) {
			my $chan = DXChannel::get($call);
			$local = $chan && $chan->is_user && $chan->hostname;
		}
		if ($local) {
			require DXPublicIP;
			$ip = DXPublicIP::normalize_owned($ip);
		}
		# Do not publish private/loopback addresses for our own origin.
		if ($call ne $main::mycall || is_public_ip($ip)) {
			$ip =~ s/:/,/g;
			$extra .= ':' . $ip;
		}
	}

	return "$flag$call$extra";
}

my %things_add;
my %things_del;

# A PC92 user advertisement must not shadow a known node identity.
# Use the same two authoritative sources as the PC16 admission guard.
sub _pc92_user_is_known_node
{
	my ($call, $parent, $dxchan, $sort) = @_;
	return 0 unless $call;
	# Match the identity that _add_thingy will actually use. In particular,
	# prefix/suffix decoration and SSID 0 must not bypass the node guard.
	my $normcall = normalise_call($call);
	return 0 unless $normcall;
	my $node = Route::Node::get($normcall);
	my $user = DXUser::get_current($normcall) unless $node;
	return 0 unless $node || ($user && $user->is_node);
	my $from = $parent ? $parent->call : '-';
	my $peer = $dxchan ? $dxchan->call : '-';
	dbg("PCPROT: PC92$sort rejected user $call (node identity $normcall): known node; parent=$from; peer=$peer") if isdbg('chanerr') || isdbg('routelow');
	return 1;
}

# The external-node bit is an attribute of a node entry, not a user type.
# A flag with extnode set but node clear is inconsistent: never admit it
# as a human user or silently reinterpret it as a valid node.
sub _pc92_invalid_extnode_user
{
    my ($slot, $parent, $dxchan, $sort) = @_;
    return 0 unless $slot && !$slot->[1] && $slot->[2];
    my $call = $slot->[0] || '-';
    my $from = $parent ? $parent->call : '-';
    my $peer = $dxchan ? $dxchan->call : '-';
    dbg("PCPROT: PC92$sort rejected inconsistent external-node flag for $call; parent=$from; peer=$peer") if isdbg('chanerr') || isdbg('routelow');
    return 1;
}

# Side-effectful file logs and logical acceptance metrics must not be emitted
# until a guarded A/C/D transaction has committed. Physical RX metrics remain
# physical observations and are intentionally not part of the transaction.
our $pc92_acd_deferred_logs;
our $pc92_acd_deferred_metrics;
sub _pc92_acd_log
{
    my (@args) = @_;
    if ($pc92_acd_deferred_logs) { push @{$pc92_acd_deferred_logs}, \@args; }
    else { Log(@args); }
}
sub _pc92_acd_metric
{
    my ($method, @args) = @_;
    if ($pc92_acd_deferred_metrics) { push @{$pc92_acd_deferred_metrics}, [$method, @args]; }
    else { my $cb = DXHealth->can($method) or die "Unknown DXHealth metric $method"; $cb->(@args); }
}

# Defer buddy notifications until the SQL and Route changes are committed.
# Scoped dynamically to this A/C/D handler only; other protocol paths unchanged.
our $pc92_acd_deferred_buddies;
sub _pc92_acd_tell_buddies
{
    my ($dxchan, @args) = @_;
    return unless $dxchan;
    if ($pc92_acd_deferred_buddies) {
        push @$pc92_acd_deferred_buddies, [$dxchan, @args];
    } else {
        $dxchan->tell_buddies(@args);
    }
}

sub _add_thingy
{
	my $parent = shift;
	my $s = shift;
	my $dxchan = shift;
	my $hops = shift;
	my $pc92sort = shift || 'A';

	my ($call, $is_node, $is_extnode, $here, $version, $build, $ip) = @$s;
	my @rout;

	dbg("DXProt::_add_thingy $parent->{call}: $call $is_node $is_extnode $ip") if isdbg('routelow');

	# Reject invalid user advertisements before any DXUser normalization cleanup.
	# The cleanup below may delete an existing DXUser record.
	if (!$is_node && $dxchan) {
		return if _pc92_invalid_extnode_user($s, $parent, $dxchan, $pc92sort);
		return if _pc92_user_is_known_node($call, $parent, $dxchan, $pc92sort);
	}

	# remove spurious IPV6 prefix on IPV4 addresses
	$build ||= 0;
	$version ||= 0;

	if ($call && is_callsign($call)) {
		my $ncall = $parent->call;
		if ($ncall ne $call) {
			my $user;
			my $r;

			# normalise call, delete any unnormalised calls in the users file.
			# then ignore this thingy
			my $normcall = normalise_call($call);
			unless ($normcall) {
				LogDbg('err', "ROUTE: $call normalised as $normcall is not considered a valid callsign");
				dbgprintring(3) if isdbg('nologchan');
				return;
			}
			if ($normcall ne $call) {
				next if DXChannel::get($call);
				$user = DXUser::get($call);
				dbg("DXProt::_add_thingy call $call normalised to $normcall, deleting spurious user $call");
				$user->del if $user;
			    $call = $normcall; # this is safe because a route add will ignore duplicates
			}

			if ($call eq $main::myalias && $is_node) {
				LogDbg('err', "ROUTE: $call eq \$myalias from $ncall - downgraded to user!!!");
				dbgprintring(3) if isdbg('nologchan');
				$is_node = 0;
			}
			if ($is_node) {
				dbg("ROUTE: added node $call to $ncall") if isdbg('routelow');
				$user = check_add_user($call, 'S');
				@rout = $parent->add($call, $version, Route::here($here), $ip);
				$r = Route::Node::get($call);
				$r->PC92C_dxchan($dxchan->call, $hops) if $r;
				if ($version && is_numeric($version) && !$r->K && !$user->K) {
					my $old = $user->sort;
					if ($user->is_ak1a && (($version >= 5455 &&  $build > 0) || ($version >= 3000 && $version <= 3500)) ) {
						$user->sort('S');
						dbg("PCPROT::_add_thingy node $call v: $version b: $build sort ($old) updated to " . $user->sort);
					} elsif ($user->is_spider && ($version < 3000 || ($version > 4000 && $version < 5455))) {
						unless ($version > 0  && $build == 0) {
							$user->sort('A');
							$build ||= 0;
							dbg("PCPROT::_add_thingy node $call v: $version b: $build sort ($old) downgraded to " . $user->sort);
						}
					}
				}
				# PC92K metadata is authoritative; missing A/C fields are not updates.
				# Persist accepted non-K announcements only when DXUser differs.
				if ($user->K) {
					$r->version($user->version) if $user->version;
					$r->build($user->build) if $user->build;
					$r->K(1);
				} elsif (!$r->K) {
					my $changed = 0;
					if ($version && is_numeric($version)) {
						$r->version($version) if ($r->version || 0) != $version;
						if (!defined $user->version || $user->version != $version) {
							$user->version($version);
							++$changed;
						}
					}
					if ($build && is_numeric($build)) {
						$r->build($build) if ($r->build || 0) != $build;
						if (!defined $user->build || $user->build != $build) {
							$user->build($build);
							++$changed;
						}
					}
					$user->put if $changed;
				}
			} else {
				if ($dxchan) {
					return if _pc92_invalid_extnode_user($s, $parent, $dxchan, $pc92sort);
					return if _pc92_user_is_known_node($call, $parent, $dxchan, $pc92sort);
				}
				dbg("ROUTE: added user $call to $ncall") if isdbg('routelow');
				$user = check_add_user($call, 'U', $parent->call);
				@rout = $parent->add_user($call, Route::here($here), $ip);
				_pc92_acd_tell_buddies($dxchan, 'loginb', $call, $ncall);
				$r = Route::User::get($call);
			}
			if ($ip) {
				$r->ip($ip);
				_pc92_acd_log('DXProt', "PC92A $call -> $ip on $ncall");
			}
			if ($r && $pc92_slug_changes && $parent == $main::routeroot) {
				dbg("add_thingy: $call in add($things_del{$call})") if isdbg('routelow');
				$things_add{$call} = $r;
				delete $things_del{$call};
			}
			$user->close($main::systime, $ip) if $user;		# this just updates lastseen and the connlist list containing the IP address
		} else {
			dbgprintring(10) if isdbg('nologchan');
			dbg("DXProt::add_thingy: Trying to add parent $call to itself $ncall, ignored");
		}
	}

	return @rout;
}

sub _del_thingy
{
	my $parent = shift;
	my $s = shift;
	my $dxchan = shift;
	my ($call, $is_node, $is_extnode, $here, $version, $build) = @$s;
	my @rout;
	dbg("DXProt::_del_thingy $parent->{call}: $call $is_node $is_extnode") if isdbg('routelow');
	if ($call) {
		my $ref;
		if ($is_node) {
			if ($ref = Route::Node::get($call)) {
				dbg("ROUTE: deleting node $call from " . $parent->call) if isdbg('routelow');
				@rout = $ref->del($parent);
			}
		} else {
			$ref = Route::User::get($call);
			if ($ref) {
				dbg("ROUTE: deleting user $call from " . $parent->call) if isdbg('routelow');
				_pc92_acd_tell_buddies($dxchan, 'logoutb', $call, $parent->call);
				@rout = $parent->del_user($ref);
			}
		}
		if ($ref && $pc92_slug_changes && $parent == $main::routeroot) {
			dbg("del_thingy: $call in add($things_add{$call})") if isdbg('routelow');
			$things_del{$call} = $ref unless exists $things_add{$call};
			delete $things_add{$call};
		}
	}
	return @rout;
}

# this will only happen if we are slugging changes and
# there are some changes to be sent, it will create an add or a delete
# or both
sub gen_pc92_changes
{
	my @add = values %things_add;
	my @del = values %things_del;
	 dbg("pc92_changes del: " . join(' ', sort keys %things_del) ) if isdbg('routelow');
	 dbg("pc92_changes add: " . join(' ', sort keys %things_add) ) if isdbg('routelow');
	return (\@add, \@del);
}

sub clear_pc92_changes
{
	 dbg("clear pc92_changes del: " . join(' ', sort keys %things_del) ) if isdbg('routelow');
	 dbg("clear pc92_changes add: " . join(' ', sort keys %things_add) ) if isdbg('routelow');
	%things_add = %things_del = ();
	$last_pc92_slug = $main::systime;
}

my $_last_time;
my $_last_occurs;
my $_last_pc9x_id;

sub last_pc9x_id
{
	return $_last_pc9x_id;
}

sub gen_pc9x_t
{
	if (!$_last_time || $_last_time != $main::systime) {
		$_last_time = $main::systime;
		$_last_occurs = 0;
		return $_last_pc9x_id = $_last_time - $main::systime_daystart;
	} else {
		$_last_occurs++;
		return $_last_pc9x_id = sprintf "%d.%02d", $_last_time - $main::systime_daystart, $_last_occurs;
	}
}

sub check_pc9x_t
{
	my $call = shift;
	my $t = shift;
	my $pc = shift;
	my $create = shift;
	my $acd_midnight_cutoff = shift;

	# check that the time is between 0 >= $t < 86400
	unless ($t >= 0 && $t < 86400) {
		dbg("PCPROT: time invalid t: $t, ignored") if isdbg('chanerr') || isdbg('routelow');
		return undef;
	}

	# check that the time of this pc9x is within tolerance (default 15 mins either way)
	my $now = $main::systime - $main::systime_daystart ;
	my $diff = abs($now - $t);
	if ($acd_midnight_cutoff && $t > $now
	    && $t > 86400 - $pc9x_time_tolerance && $now > 3) {
		return undef;
	}
	unless ($diff < $pc9x_time_tolerance || 86400 - $diff < $pc9x_time_tolerance) {
		my $c = ref $call ? $call->call : $call;
		dbg("PC9XERR: $c time out of range t: $t now: $now diff: $diff > $pc9x_time_tolerance, ignored") if isdbg('chan');
		return undef;
	}

	my $parent = ref $call ? $call : Route::Node::get($call);
	if ($parent) {
		# we only do this for external calls whose routing table
		# record come and go. The reference for mycall is permanent
		# and not that frequently used, it also never times out, so
		# the id on it is completely unreliable. Besides, only commands
		# originating on this box will go through this code...
		if ($parent->call ne $main::mycall) {
			my $lastid = $parent->lastid;
			if (defined $lastid) {
				if ($t < $lastid) {
					# note that this is where we determine whether this pc9x has come in yesterday
					# but is still greater (modulo 86400) than the lastid or is simply an old
					# duplicate sentence. To determine this we need to do some module 86400
					# arithmetic. High numbers mean that this is an old duplicate sentence,
					# low numbers that it is a new sentence.
					#
					# Typically you will see yesterday being taken on $t = 84, $lastid = 86235
					# and old dupes with $t = 234, $lastid = 256 (which give answers 249 and
					# 86378 respectively in the calculation below).
					#
					if ($t+86400-$lastid > $pc9x_past_age) {
						dbg("PCPROT: dup id on $t <= lastid $lastid, ignored") if isdbg('chanerr') || isdbg('pc92dedupe');
						return undef;
					}
				} elsif ($t == $lastid) {
					dbg("PCPROT: dup id on $t == lastid $lastid, ignored") if isdbg('chanerr') || isdbg('pc92dedupe');
					return undef;
				} else {
					# check that if we have a low number in lastid that yesterday's numbers
					# (likely in the 85000+ area) don't override them, thus causing flip flopping
					if ($lastid+86400-$t < $pc9x_past_age) {
						dbg("PCPROT: dup id on $t in yesterday, lastid $lastid, ignored") if isdbg('chanerr') || isdbg('pc92dedupe');
						return undef;
					}
				}
			}
		}
	} elsif ($create) {
		$parent = Route::Node->new($call);
		# PC92 can recreate a transient Route::Node after its last parent
		# disappears. Recover previously accepted K metadata from DXUser;
		# this is not a newly received K announcement.
		if ($pc == 92 && !DXChannel::get($call)) {
			my $user = DXUser::get_current($call);
			if ($user && $user->K) {
				my $version = $user->version;
				my $build = $user->build;
				$parent->version($version)
					if defined $version && is_numeric($version) && $version > 0;
				$parent->build($build)
					if defined $build && is_numeric($build) && $build > 0;
				$parent->K(1);
			}
		}
	} else {
		dbg("PCPROT: $call does not exist, ignored") if isdbg('pc92dedupe');
		return undef;
	}
	# A Route::Node may already exist with constructor defaults while its
	# accepted PC92K metadata survives in DXUser. Restore only missing/default
	# values, only for remote PC92 nodes, without changing correct live values.
	if ($pc == 92 && $parent && !DXChannel::get($parent->call)
	    && ($parent->version || 0) == 5401) {
		my $user = DXUser::get_current($parent->call);
		if ($user && $user->K) {
			my $version = $user->version;
			my $build = $user->build;
			if (defined $version && is_numeric($version) && $version > 0) {
				$parent->version($version);
				$parent->build($build)
					if defined $build && is_numeric($build) && $build > 0
					&& !($parent->build || 0);
				$parent->K(1);
			}
		}
	}
	if (isdbg('pc92dedupe')) {
		my $exists = exists $parent->{lastid}; # naughty, naughty :-)
		my $val = $parent->{lastid};
		my $s = $exists ? (defined $val ? $val : 'exists/undef') : 'undef';
		dbg("PCPROT: $call pc92 id lastid $s -> $t");
	}
	$parent->lastid($t);

	return $parent;
}

sub pc92_handle_first_slot
{
	my $self = shift;
	my $slot = shift;
	my $parent = shift;
	my $t = shift;
	my $hops = shift;
	my $oparent = $parent;

	my @radd;

	my ($call, $is_node, $is_extnode, $here, $version, $build) = @$slot;

	if ($call && $is_node) {
		if ($call eq $main::mycall) {
			LogDbg('err', "PCPROT: $self->{call} : $call looped back onto \$main::mycall ($main::mycall), ignored");
			return;
		}
		if ($call eq $main::myalias) {
			LogDbg('err', "PCPROT: $self->{call} : $call looped back onto \$main::myalias ($main::myalias), ignored");
			return;
		}
		# this is only accepted from my "self".
		# this also kills configs from PC92 nodes with external PC19 nodes that are also
		# locally connected. Local nodes always take precedence. But we remember the lastid
		# to try to reduce the number of dupe PC92s for this external node.
		if (DXChannel::get($call) && $call ne $self->{call}) {
			$parent = check_pc9x_t($call, $t, 92); # this will update the lastid time
			dbg("PCPROT: locally connected node $call from other another node $self->{call}, ignored") if isdbg('chanerr') || isdbg('routelow');
			return;
		}
		if ($is_extnode) {
			# reparent to external node (note that we must have received a 'C' or 'A' record
			# from the true parent node for this external before we get one for the this node
			unless ($parent = Route::Node::get($call)) {
				if ($is_extnode && $oparent) {
					@radd = _add_thingy($oparent, $slot, $self, $hops);
					$parent = $radd[0];
				} else {
					dbg("PCPROT: no previous C or A for this external node received, ignored") if isdbg('chanerr') || isdbg('routelow');
					return;
				}
			}
			$parent = check_pc9x_t($call, $t, 92) || return;
			$parent->via_pc92(1);
			$parent->PC92C_dxchan($self->{call}, $hops);
		}
	} else {
		dbg("PCPROT: must be \$mycall or external node as first entry, ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}
	$parent->here(Route::here($here));
	# The only caller is PC92K. Apply its metadata atomically in the K handler
	# after validation; the first-slot path must not preempt that comparison.

	$parent->PC92C_dxchan($self->{call}, $hops) unless $self->{call} eq $parent->call;
	return ($parent, @radd);
}

# DXSpider routing entries
# Pure A/C/D wire-format preflight. No routing, lastid or SQLite writes.
# This is intentionally separate from the mutating legacy decoder.
# Read-only wire validation. Must run before check_pc9x_t and routing changes.
# K has a separate optional IP field; A/C/D have CALL[:VERSION][:IP].
sub _pc92_k_preflight
{
    my ($pc) = @_;
    return 'missing fields' unless $pc && ref($pc) eq 'ARRAY' && @$pc >= 8;
    return 'invalid hops' unless defined $pc->[-1] && $pc->[-1] =~ /\AH[0-9]{1,2}\z/;
    return 'invalid origin' unless defined $pc->[1] && is_callsign($pc->[1])
        && normalise_call($pc->[1]) eq $pc->[1];
    return 'invalid id' unless defined $pc->[2]
        && $pc->[2] =~ /\A(?:0|[1-9][0-9]{0,4})(?:\.0[1-9]|\.[1-9][0-9])?\z/
        && $pc->[2] < 86400;
    my $node = $pc->[4];
    # Use the same node-object syntax as PC92 A/C/D. Version, build and
    # IP are optional; do not require VERSION:BUILD for a K node.
    return 'invalid node' if _pc92_acd_wire_object($node, 1);
    return 'invalid node count' unless defined $pc->[5] && $pc->[5] =~ /\A[0-9]+\z/;
    return 'invalid user count' unless defined $pc->[6] && $pc->[6] =~ /\A[0-9]+\z/;
    # The K address field is optional. When present, allow any syntactically
    # valid IPv4/IPv6 or a conventional localhost name; do not impose public-IP
    # policy. A trailing branch/build descriptor is optional.
    return 'invalid field count' if @$pc > 10;
    if (@$pc >= 9) {
        my $ip = $pc->[7];
        # Empty IP is legitimate in historical K packets, even with branch metadata.
        return 'invalid K IP' if defined($ip) && length($ip)
            && !(is_ipaddr($ip) || $ip =~ /\A(?:localhost|localhost\.localdomain)\z/i);
    }
    if (@$pc == 10) {
        return 'invalid K metadata' unless defined $pc->[8]
            && length $pc->[8] && $pc->[8] !~ /\s/;
    }
    return '';
}

sub _pc92_malformed_reject
{
    my ($self, $pc, $reason, $badfield) = @_;
    return unless $DXProt::checkcpu >= 1;
    my ($origin, $id, $type) = map { defined $_ ? $_ : '?' } @$pc[1,2,3];
    my $peer = defined $self->{call} ? $self->{call} : '?';
    # Single-line escaped wire representation, preserving every field.
    my $wire = join('^', map { defined $_ ? $_ : '' } @$pc);
    $wire =~ s/([^\x20-\x7e])/sprintf('\\x%02X', ord($1))/ge;
    # Report the exact rejected wire field in reason, not in a separate key.
    # Keep the diagnostic category for errors without an identifiable field.
    if (defined $badfield) {
        my $value = $badfield;
        $value =~ s/([^\x20-\x7e])/sprintf('\\x%02X', ord($1))/ge;
        $reason = "invalid object: $value" if $reason =~ /\Ainvalid object:/;
        $reason = "invalid relay: $value" if $reason =~ /\Ainvalid relay:/;
        $reason .= ": $value" unless $reason =~ /\Ainvalid (?:object|relay):/;
    }
    dbg("PC92_MALFORMED drop peer=$peer origin=$origin id=$id type=$type reason=$reason packet=$wire");
    return;
}

sub _pc92_acd_preflight
{
    my ($pc, $badref) = @_;
    $$badref = undef if $badref;
    return 'missing fields' unless $pc && ref($pc) eq 'ARRAY' && @$pc >= 6;
    my ($origin, $id, $sort, $relay) = @$pc[1,2,3,4];
    unless (defined $origin && length $origin && is_callsign($origin) && normalise_call($origin) eq $origin) { $$badref = $origin if $badref; return 'invalid origin'; }
    unless (defined $id && $id =~ /\A(?:0|[1-9][0-9]{0,4})(?:\.0[1-9]|\.[1-9][0-9])?\z/ && $id < 86400) { $$badref = $id if $badref; return 'invalid id'; }
    unless (defined $sort && $sort =~ /\A[ACD]\z/) { $$badref = $sort if $badref; return 'invalid type'; }
    unless (defined $relay) { $$badref = 'field[4]=undef' if $badref; return 'missing relay'; }
    unless (defined $pc->[-1] && $pc->[-1] =~ /\AH[0-9]{1,2}\z/) { $$badref = $pc->[-1] if $badref; return 'invalid hops'; }
    for my $i (1 .. $#$pc) {
        unless (defined $pc->[$i]) { $$badref = 'field[' . $i . ']=undef' if $badref; return 'undefined field'; }
        if ($pc->[$i] =~ /\s/) { $$badref = $pc->[$i] if $badref; return 'space in field'; }
    }
    # RELAY is a node, or the empty string; historical ORIGIN repetition
    # is accepted, but a different RELAY must still be a valid node.
    if (length $relay) {
        # v0.15: all A/C/D types may announce a classical node via RELAY.
        # Historic origin repetition is also admitted on reception only.
        my $err = _pc92_acd_wire_object($relay, 1);
        if ($err) { $$badref = $relay if $badref; return "invalid relay: $err"; }
    }
    my %seen;
    for my $i (5 .. $#$pc - 1) {
        my $obj = $pc->[$i];
        my $err = _pc92_acd_wire_object($obj, 0);
        if ($err) { $$badref = $obj if $badref; return "invalid object: $err"; }
        my ($flag, $call) = $obj =~ /\A([0-7])([^:]+)/;
        # An explicit ORIGIN node IP must be globally reachable.  Reuse
        # DXUtil::is_public_ip (also used by PC61); other OBJECT IPs may
        # legitimately be private.  Missing IP is historical and accepted.
        if (($flag & 4) && $call eq $origin) {
            my (undef, @meta) = split /:/, $obj, -1;
            my $ip = @meta && ($meta[-1] =~ /[.,]/) ? $meta[-1] : undef;
            if (defined $ip && $ip =~ /[.,]/) {
                unless (is_public_ip(_pc92_acd_ip($ip))) { $$badref = $obj if $badref; return 'non-public origin IP'; }
            }
        }
        my $key = (($flag & 4) ? 'N' : 'U') . ':' . $call;
        if ($seen{$key}++) { $$badref = $obj if $badref; return 'duplicate identity'; }
    }
    return '';
}

sub _pc92_acd_wire_object
{
    my ($wire, $must_node) = @_;
    return 'empty' unless defined $wire && length $wire;
    my ($flag, @meta) = split /:/, $wire, -1;
    my $call;
    return 'flag' unless $flag =~ /\A[0-7]/;
    $call = substr($flag, 1);
    $flag = substr($flag, 0, 1);
    return 'relay must be node' if $must_node && !($flag & 4);
    # A badspotter entry is a policy decision, not malformed wire syntax.
    # Only exempt user objects (flag 1); retain metadata/IP and all other checks.
    my $badlisted_user = $flag eq '1' && defined($badspotter)
        && $badspotter->in($call);
    return 'callsign' unless length $call
        && ($badlisted_user || (is_callsign($call)
            && normalise_call($call) eq $call && $call !~ /-0\z/));
    # A final colon denotes an omitted optional field (e.g. CALL:5300:).
    # Ignore only that empty suffix; never suppress empty interior fields.
    pop @meta if @meta >= 2 && $meta[-1] eq '';
    return 'metadata count' if @meta > 3;
    for (@meta) { return 'empty metadata' unless length $_; }
    if (@meta) {
        my $first = $meta[0];
        if ($first =~ /\A[0-9]{4}\z/) {
            if (@meta == 2) {
                # VERSION:IP and historical VERSION:BUILD are both accepted.
                return 'metadata' unless (_pc92_acd_build($meta[1])
                    || ($meta[1] =~ /[.,]/ && is_ipaddr(_pc92_acd_ip($meta[1]))));
            } elsif (@meta == 3) {
                return 'build' unless _pc92_acd_build($meta[1]);
                return 'ip' unless $meta[2] =~ /[.,]/ && is_ipaddr(_pc92_acd_ip($meta[2]));
            }
        } else {
            return 'metadata count' if @meta > 1;
            # Historical user transport marker.  The normal PC92 decoder
            # discards it (it is not an IP address); it must not reject C.
            return '' if $flag eq '1' && lc($first) eq 'ax25';
            return 'ip' unless ($first =~ /[.,]/ && is_ipaddr(_pc92_acd_ip($first)));
        }
    }
    return '';
}

# Accept the original integer build and the historical 0.nn / 0.nnn
# build encodings. This is shared by PC92 A/C/D and K wire preflights.
sub _pc92_acd_build { defined($_[0]) && $_[0] =~ /\A(?:[0-9]+|0\.[0-9]{2,3})\z/; }

sub _pc92_acd_ip { my $ip = shift; $ip =~ tr/,/:/; return $ip; }

# Cheap, read-only time window gate before scanning A/C/D OBJECTs.
# Same day-wrap/tolerance formula as check_pc9x_t.
sub _pc92_acd_early_time_invalid
{
    my ($t) = @_;
    return 1 unless defined $t && $t =~ /\A(?:0|[1-9][0-9]{0,4})(?:\.0[1-9]|\.[1-9][0-9])?\z/ && $t < 86400;
    my $now = $main::systime - $main::systime_daystart;
    my $diff = abs($now - $t);
    # An ID close to the end of yesterday is only admissible during the
    # first three seconds after UTC midnight, never for the whole tolerance.
    return 1 if $t > $now && $t > 86400 - $pc9x_time_tolerance
        && $now > 3;
    return ($diff < $pc9x_time_tolerance || 86400 - $diff < $pc9x_time_tolerance) ? 0 : 1;
}

# Read-only, constant-cost PC92 A/C/D sequence gate. No Route/DXUser mutation.
# Preserve the exact modulo-day comparison used by check_pc9x_t.
sub _pc92_acd_early_duplicate
{
    my ($origin, $t) = @_;
    return 0 unless defined $origin && length $origin;
    return 0 unless defined $t && $t =~ /\A\d+(?:\.\d+)?\z/ && $t >= 0 && $t < 86400;
    return 0 if $origin eq $main::mycall;
    my $node = Route::Node::get($origin);
    return 0 unless $node;
    my $lastid = $node->lastid;
    return 0 unless defined $lastid;
    if ($t < $lastid) {
        return $t + 86400 - $lastid > $pc9x_past_age ? 1 : 0;
    }
    return 1 if $t == $lastid;
    return $lastid + 86400 - $t < $pc9x_past_age ? 1 : 0;
}

use Scalar::Util ();

# Queue externally visible route events until the SQL savepoint has been released.
# The queue is dynamically scoped to the guarded A/C/D handler.
our $pc92_acd_deferred_routes;
our $pc92_acd_accepted;
our $pc92_acd_reject_reason;
our $pc92_c_recovery_candidates;
# Dynamically scoped only after the guarded A/C/D wire preflight succeeds.
our $pc92_acd_prevalidated;
sub _pc92_acd_route_event
{
    my ($chan, $method, @args) = @_;
    if ($pc92_acd_deferred_routes) {
        push @$pc92_acd_deferred_routes, [$chan, $method, @args];
        return;
    }
    return $chan->$method(@args);
}

sub _pc92_acd_broadcast
{
    my ($chan, $sort, $pcall, $line) = @_;
    if ($pc92_acd_deferred_routes) {
        push @$pc92_acd_deferred_routes, [$chan, 'broadcast_route_pc9x', $pcall, undef, $line, 0,
                                          '__pc92_broadcast_metrics__', $sort, length($line)];
        return 0;
    }
    return $chan->broadcast_route_pc9x($pcall, undef, $line, 0);
}

sub _pc92_snapshot_value
{
    my ($value, $seen) = @_;
    my $kind = ref($value);
    # Route objects are shared graph identities, not value containers.
    # Keep blessed references intact; their fields are snapshotted separately.
    return $value if Scalar::Util::blessed($value);
    return $value unless $kind eq 'HASH' || $kind eq 'ARRAY';
    my $id = "$value";
    return $seen->{$id} if exists $seen->{$id};
    if ($kind eq 'HASH') {
        my $copy = {};
        $seen->{$id} = $copy;
        $copy->{$_} = _pc92_snapshot_value($value->{$_}, $seen) for keys %$value;
        return $copy;
    }
    my $copy = [];
    $seen->{$id} = $copy;
    # Fast path for flat arrays (typically routing callsign lists).
    # Scalars and blessed/opaque references are immutable snapshot values;
    # only unblessed HASH/ARRAY children require recursive cloning.
    my $has_containers = 0;
    for my $item (@$value) {
        my $kind = ref($item);
        if ($kind eq 'HASH' || $kind eq 'ARRAY') {
            $has_containers = 1;
            last;
        }
    }
    if (!$has_containers) {
        @$copy = @$value;
        return $copy;
    }
    push @$copy, _pc92_snapshot_value($_, $seen) for @$value;
    return $copy;
}

sub _pc92_route_object_snapshot
{
    my ($obj) = @_;
    my %fields;
    my %seen;
    $fields{$_} = _pc92_snapshot_value($obj->{$_}, \%seen) for keys %$obj;
    return \%fields;
}

# C updates can persist DXUser rows before a later route operation fails.
# Use a nested SQL SAVEPOINT on the existing DXUser connection (do not commit
# DXSpider's outer transaction). This is only enabled for SQLite; fail closed
# on unsupported persistence rather than falsely promising an atomic C.

# Snapshot only DXUser identities reachable from this PC92 transaction.
# Restore original blessed objects in place to preserve DXChannel references.
sub _pc92_acd_user_checkpoint
{
    my ($pc) = @_;
    # DXUser writes in the A/C/D handler are confined to advertised OBJECTs:
    # _add_thingy calls check_add_user/close/put for each added OBJECT;
    # the C metadata reconciliation also touches only advertised nodes.
    # _del_thingy changes routing but does not write DXUser.  In contrast,
    # graph->{nodes/users} contains *all reachable descendants*, whose
    # DXUser records are not mutated by this packet.  Do not fetch/cache
    # thousands of unrelated DXUser records before every small PC92 update.
    my %calls;
    for my $entry (@$pc[5 .. $#$pc - 1]) {
        my ($call) = _decode_pc92_call($entry);
        $calls{$call} = 1 if $call;
    }
    if (length($pc->[4] || '')) {
        my ($relay) = _decode_pc92_call($pc->[4]);
        $calls{$relay} = 1 if $relay && $relay ne $pc->[1];
    }
    my %saved;
    for my $call (keys %calls) {
        my $user = DXUser::get_current($call);
        $saved{$call} = [$user, $user ? _pc92_route_object_snapshot($user) : undef];
    }
    return \%saved;
}

sub _pc92_acd_user_restore
{
    my ($saved) = @_;
    for my $call (keys %$saved) {
        my ($original, $fields) = @{$saved->{$call}};
        if ($original) {
            %$original = %{_pc92_route_object_snapshot($fields)};
            $DXUser::lru->put($call, $original) if $DXUser::lru;
        } else {
            $DXUser::lru->remove($call) if $DXUser::lru;
        }
    }
}

package DXProt::PC92Journal;
use strict;
use warnings;
use Scalar::Util qw(refaddr);

sub new { bless { objects => {}, order => [], registry => {}, reg_order => [] }, shift }
sub touch {
    my ($self, $obj) = @_;
    return unless $obj;
    my $id = refaddr($obj);
    return if exists $self->{objects}{$id};
    my $fields = DXProt::_pc92_route_object_snapshot($obj);
    $self->{objects}{$id} = [$obj, $fields];
    push @{$self->{order}}, $id;
    DXProt::_pc92_cpu_gate_event('journal_object') if $DXProt::checkcpu >= 2;
}
sub registry {
    my ($self, $type, $call) = @_;
    my $key = "$type\0$call";
    return if exists $self->{registry}{$key};
    my $table = $type eq 'node' ? \%Route::Node::list : \%Route::User::list;
    $self->{registry}{$key} = [$table, $call, exists $table->{$call}, $table->{$call}];
    push @{$self->{reg_order}}, $key;
    DXProt::_pc92_cpu_gate_event('journal_registry') if $DXProt::checkcpu >= 2;
}
sub restore {
    my ($self) = @_;
    for my $id (reverse @{$self->{order}}) {
        my ($obj, $fields) = @{$self->{objects}{$id}};
        %$obj = %{DXProt::_pc92_route_object_snapshot($fields)};
    }
    for my $key (reverse @{$self->{reg_order}}) {
        my ($table, $call, $exists, $obj) = @{$self->{registry}{$key}};
        if ($exists) { $table->{$call} = $obj } else { delete $table->{$call} }
    }
}
1;
package DXProt;

# Optional PC92 diagnostic levels: 0=off, 1=light, 2=detail.
# Set/var $DXProt::checkcpu = 0|1|2; see docs/PC92_CPU_GATE.txt.
our $checkcpu = 0;
our (%pc92_cpu_gate, $pc92_cpu_gate_since);
our $pc92_cpu_gate_seq = 0;
sub _pc92_cpu_gate_event
{
    my ($name) = @_;
    return unless $checkcpu >= 2;
    ++$pc92_cpu_gate{"$name.events"};
}
sub _pc92_cpu_gate_record
{
    my ($phase, $elapsed) = @_;
    return unless $checkcpu;
    my $now = Time::HiRes::time();
    $pc92_cpu_gate_since ||= $now;
    my $us = int($elapsed * 1_000_000 + 0.5);
    ++$pc92_cpu_gate{"$phase.count"};
    $pc92_cpu_gate{"$phase.us"} += $us;
    my $maxkey = "$phase.max";
    $pc92_cpu_gate{$maxkey} = $us if $us > ($pc92_cpu_gate{$maxkey} || 0);
    ++$pc92_cpu_gate{"$phase.slow"} if $us >= 10_000;
    return if $now - $pc92_cpu_gate_since < 60;
    my $seconds = int($now - $pc92_cpu_gate_since);
    my @names = qw(preflight dxuser_snapshot handler sql_commit transaction rollback);
    my @parts;
    for my $name (@names) {
        my $n = $pc92_cpu_gate{"$name.count"} || 0;
        my $total = $pc92_cpu_gate{"$name.us"} || 0;
        push @parts, "$name=$n/$total";
    }
    dbg('PC92_CPU_GATE seconds=' . $seconds . ' units=count/us ' . join(' ', @parts));
    if ($checkcpu >= 2) {
        my @detail;
        for my $name (@names) {
            push @detail, "$name=" . ($pc92_cpu_gate{"$name.max"} || 0)
                . '/' . ($pc92_cpu_gate{"$name.slow"} || 0);
        }
        dbg('PC92_CPU_DETAIL seconds=' . $seconds . ' units=max_us/slow_ge_10ms ' . join(' ', @detail));
        dbg('PC92_JOURNAL_DETAIL seconds=' . $seconds
            . ' objects=' . ($pc92_cpu_gate{'journal_object.events'} || 0)
            . ' registry=' . ($pc92_cpu_gate{'journal_registry.events'} || 0)
            . ' rollback=' . ($pc92_cpu_gate{'rollback.count'} || 0));
        # /proc is optional. Read once per report, never once per packet.
        my ($rss_kib, $cpu_ms);
        if (open my $fh, '<', '/proc/self/status') {
            while (my $line = <$fh>) {
                if ($line =~ /^VmRSS:\s+(\d+)\s+kB/) { $rss_kib = $1; last }
            }
            close $fh;
        }
        my @times = times();
        $cpu_ms = int(($times[0] + $times[1]) * 1000 + 0.5);
        dbg('PC92_RESOURCE seconds=' . $seconds . ' rss_kib='
            . (defined $rss_kib ? $rss_kib : 'NA')
            . ' cpu_total_ms=' . $cpu_ms . ' cpu_scope=process_cumulative');
    }
    %pc92_cpu_gate = ();
    $pc92_cpu_gate_since = $now;
}

# Read-only, bounded admission diagnostics for PC92 A/C/D.
# Only checkcpu=2 emits; never include raw packets or user-supplied free text.
sub _pc92_admission_trace
{
    my ($self, $pc, $reason) = @_;
    return unless $checkcpu >= 2;
    my $safe = sub {
        my ($v) = @_;
        $v = '?' unless defined $v;
        $v =~ s/[^A-Za-z0-9_.-]/_/g;
        return substr($v, 0, 40);
    };
    dbg('PC92_ADMISSION decision=reject type=' . $safe->($pc->[3])
        . ' origin=' . $safe->($pc->[1])
        . ' peer=' . $safe->($self->{call})
        . ' reason=' . $safe->($reason));
}

# A/C/D atomic handling: mutation journal for routing and bounded DXUser cache
# snapshot, with SQLite SAVEPOINT for persistent changes.
sub _pc92_acd_guarded
{
    my ($self, $pcno, $line, $origin, $pc) = @_;
    require Time::HiRes if $checkcpu;
    return _pc92_handle_92_original(@_) unless $pc && ($pc->[3] || '') =~ /\A[ACDK]\z/;
    if (($pc->[3] || '') eq 'K') {
        my $reason = _pc92_k_preflight($pc);
        if ($reason) {
            my %field = (
                'invalid origin' => 1, 'invalid id' => 2,
                'invalid node' => 4, 'invalid node count' => 5,
                'invalid user count' => 6, 'invalid K IP' => 7,
                'invalid K metadata' => 8, 'invalid hops' => $#$pc,
            );
            my $bad = exists $field{$reason} ? $pc->[$field{$reason}] : undef;
            $bad = 'fields=' . scalar(@$pc) if $reason eq 'invalid field count';
            $bad = 'fields=' . scalar(@$pc) if $reason eq 'missing fields';
            return _pc92_malformed_reject($self, $pc, $reason, $bad);
        }
        return _pc92_handle_92_original(@_);
    }
    # Validate malformed A/C/D before duplicate/time gates, with a reason.
    my $cpu_start = $checkcpu ? Time::HiRes::time() : undef;
    my $bad_object;
    my $format_reason = _pc92_acd_preflight($pc, \$bad_object);
    _pc92_cpu_gate_record('preflight', Time::HiRes::time() - $cpu_start) if $checkcpu;
    return _pc92_malformed_reject($self, $pc, $format_reason, $bad_object) if $format_reason;
    my $pcall = $pc->[1];
    my $t = $pc->[2];
    # Every D admission gate reports its exact reason, independently of the
    # bounded post-commit audit counter. No routing or SQLite mutation here.
    if (_pc92_acd_early_duplicate($pcall, $t)) {
        _pc92_admission_trace($self, $pc, 'early_duplicate');
        return;
    }
    if (_pc92_acd_early_time_invalid($t)) {
        _pc92_admission_trace($self, $pc, 'early_time_invalid');
        return;
    }
    my $owner = $pcall;
    if (length($pc->[4] || '')) {
        my ($call) = _decode_pc92_call($pc->[4]);
        $owner = $call if $call;
    }
    if ($owner ne $pcall && !Route::Node::get($owner)
        && $pc->[3] ne 'A' && $pc->[3] ne 'C') {
        _pc92_admission_trace($self, $pc, 'relay_parent_absent');
        return;
    }
    if ($owner eq $main::mycall || $owner eq $main::myalias) {
        _pc92_admission_trace($self, $pc, 'local_owner');
        return;
    }
    if ($pcall eq $main::mycall || $pcall eq $main::myalias) {
        _pc92_admission_trace($self, $pc, 'local_origin');
        return;
    }
    if ($self->{state} ne 'init' && !$self->{do_pc9x}) {
        _pc92_admission_trace($self, $pc, 'pc9x_disabled');
        return;
    }
    for my $i (5 .. $#$pc - 1) {
        my ($flag, $call) = $pc->[$i] =~ /\A([0-7])([^:]+)/;
        unless (defined $flag && defined $call) {
            _pc92_admission_trace($self, $pc, 'object_decode_failed');
            return;
        }
        if ($call eq $main::mycall
            || ($call eq $main::myalias && ($flag & 4))
            || (!($flag & 4) && ($flag & 2))
            || (!($flag & 4) && _pc92_user_is_known_node($call, undef, $self, $pc->[3]))) {
            _pc92_admission_trace($self, $pc, 'object_conflict');
            return;
        }
    }
    # A D for an absent ORIGIN has no parent from which any advertised OBJECT
    # can be removed. Treat each removal as a successful no-op, not a rejection:
    # count the admitted packet and forward it under the ordinary A/D policy.
    # No Route::Node or DXUser record is created merely to process a deletion.
    if ($pc->[3] eq 'D' && !Route::Node::get($pcall)) {
        DXHealth::pc92_physical_in($self->{call}, 'D', length($line));
        _pc92_acd_metric('pc92_received', 'D', length($line));
        _pc92_acd_metric('protocol_origin_inc', 'accepted', $pcall, 92, length($line));
        if ($pc92_ad_enabled) {
            my $sent = _pc92_acd_broadcast($self, 'D', $pcall, $line);
            if ($sent) {
                DXHealth::pc92_forwarded('D', length($line));
                DXHealth::protocol_origin_inc('forwarded', $pcall, 92, length($line));
            }
        }
        return;
    }
    # SQLite writes made by DXUser::put() are protected by a nested SAVEPOINT.
    # Fail closed for unsupported storage; do not claim graph+SQL atomicity there.
    my $dbh = $DXUser::dbh;
    unless ($dbh && ($main::userdsn || '') =~ /:sqlite:/i) {
        _pc92_admission_trace($self, $pc, 'sqlite_unavailable');
        return;
    }
    my $sp = 'pc92_acd_guard';
    my $started = eval { local $SIG{__DIE__} = sub {};
        my $rv = $dbh->do("SAVEPOINT $sp");
        die "SAVEPOINT failed: " . ($dbh->errstr // "unknown DBI error") unless defined $rv;
        1;
    };
    unless ($started) {
        _pc92_admission_trace($self, $pc, 'sql_savepoint_failed');
        LogDbg('err', "PC92 A/C/D SQL savepoint failed: $@");
        return;
    }
    my $users;
    my $journal = DXProt::PC92Journal->new;
    local $Route::pc92_mutation_journal = $journal;
    my $saved_channel_state = $self->{state};
    my $saved_channel_do_pc9x = $self->{do_pc9x};
    local $pc92_acd_accepted = 0;
    local $pc92_acd_reject_reason = 'handler_return_unknown';
    my @recovery_candidates;
    local $pc92_c_recovery_candidates = ($checkcpu >= 2 && $pc->[3] eq 'C') ? \@recovery_candidates : undef;
    my @deferred_logs;
    local $pc92_acd_deferred_logs = \@deferred_logs;
    my @deferred_metrics;
    local $pc92_acd_deferred_metrics = \@deferred_metrics;
    my @deferred_buddies;
    local $pc92_acd_deferred_buddies = \@deferred_buddies;
    my @deferred_routes;
    local $pc92_acd_deferred_routes = \@deferred_routes;
    # Slugging tables are mutable global side effects, restore on failure.
    my %saved_things_add = %things_add;
    my %saved_things_del = %things_del;
    # Diagnostic correlation only: no routing or transaction state is changed.
    my $cpu_trace_id = $checkcpu >= 2 ? ++$pc92_cpu_gate_seq : undef;
    my $cpu_failure_stage = 'dxuser_snapshot';
    my $cpu_tx_start = $checkcpu ? Time::HiRes::time() : undef;
    my $ok = eval { local $SIG{__DIE__} = sub {};
        # Capture only objects actually mutated; no predictive graph traversal.
        my $cpu_phase_start = $checkcpu ? Time::HiRes::time() : undef;
        $users = _pc92_acd_user_checkpoint($pc);
        _pc92_cpu_gate_record('dxuser_snapshot', Time::HiRes::time() - $cpu_phase_start) if $checkcpu;
        $cpu_phase_start = Time::HiRes::time() if $checkcpu;
        $cpu_failure_stage = 'handler' if $checkcpu >= 2;
        {
            # Limit the preflight bypass strictly to this already-validated call.
            # Post-commit callbacks must never inherit the bypass.
            local $pc92_acd_prevalidated = 1;
            _pc92_handle_92_original(@_);
        }
        _pc92_cpu_gate_record('handler', Time::HiRes::time() - $cpu_phase_start) if $checkcpu;
        die "PC92 A/C/D rejected after admission checkpoint" unless $pc92_acd_accepted;
        $cpu_phase_start = Time::HiRes::time() if $checkcpu;
        $cpu_failure_stage = 'sql_commit' if $checkcpu >= 2;
        my $rv = $dbh->do("RELEASE SAVEPOINT $sp");
        die "RELEASE failed: " . ($dbh->errstr // "unknown DBI error") unless defined $rv;
        _pc92_cpu_gate_record('sql_commit', Time::HiRes::time() - $cpu_phase_start) if $checkcpu;
        1;
    };
    _pc92_cpu_gate_record('transaction', Time::HiRes::time() - $cpu_tx_start) if $checkcpu;
    unless ($ok) {
        my $cpu_rollback_start = $checkcpu ? Time::HiRes::time() : undef;
        my $err = $@;
        $self->{state} = $saved_channel_state;
        $self->{do_pc9x} = $saved_channel_do_pc9x;
        %things_add = %saved_things_add;
        %things_del = %saved_things_del;
        my $sql_ok = eval { local $SIG{__DIE__} = sub {};
            my $rollback = $dbh->do("ROLLBACK TO SAVEPOINT $sp");
            die "ROLLBACK failed: " . ($dbh->errstr // "unknown DBI error") unless defined $rollback;
            my $release = $dbh->do("RELEASE SAVEPOINT $sp");
            die "rollback RELEASE failed: " . ($dbh->errstr // "unknown DBI error") unless defined $release;
            1;
        };
        my $sql_err = $@;
        my $graph_ok = eval { local $SIG{__DIE__} = sub {}; $journal->restore; 1 };
        my $graph_err = $@;
        my $users_ok = eval { local $SIG{__DIE__} = sub {}; _pc92_acd_user_restore($users) if $users; 1 };
        my $users_err = $@;
        _pc92_cpu_gate_record('rollback', Time::HiRes::time() - $cpu_rollback_start) if $checkcpu;
        if ($checkcpu >= 2) {
            # Classify the real exception; do not emit unbounded exception text,
            # packet contents, passwords, or raw user-provided strings.
            my $reason = 'exception';
            $reason = ($pc92_acd_reject_reason || 'handler_return_unknown') if $err =~ /PC92 A\/C\/D rejected after admission checkpoint/;
            $reason = 'sql_release_failed' if $err =~ /\ARELEASE failed:/;
            $reason = 'sql_error' if $err =~ /(?:SQLite|DBI|SQL|database)/i && $reason eq 'exception';
            my $safe = sub {
                my ($v) = @_;
                $v = '?' unless defined $v;
                $v =~ s/[^A-Za-z0-9_.-]/_/g;
                return substr($v, 0, 40);
            };
            dbg('PC92_ROLLBACK_DETAIL id=' . $cpu_trace_id
                . ' type=' . $safe->($pc->[3])
                . ' origin=' . $safe->($pc->[1])
                . ' peer=' . $safe->($self->{call})
                . ' stage=' . $cpu_failure_stage
                . ' reason=' . $reason
                . ' sql=' . ($sql_ok ? 'OK' : 'FAIL')
                . ' journal=' . ($graph_ok ? 'OK' : 'FAIL')
                . ' dxuser=' . ($users_ok ? 'OK' : 'FAIL'));
        }
        LogDbg('err', "PC92 A/C/D failure: $err; sql_rollback=" . ($sql_ok ? 'OK' : $sql_err) .
                      '; graph_rollback=' . ($graph_ok ? 'OK' : $graph_err) .
                      '; user_cache_rollback=' . ($users_ok ? 'OK' : $users_err));
        return;
    }
    # Read-only commit outcome trace for every accepted PC92 A/C/D, including
    # transactions with no deferred callbacks and no C recovery candidates.
    # This records a local SQLite savepoint release, not remote delivery.
    if ($checkcpu >= 2) {
        my $safe = sub {
            my ($v) = @_;
            $v = '?' unless defined $v;
            $v =~ s/[^A-Za-z0-9_.-]/_/g;
            return substr($v, 0, 40);
        };
        dbg('PC92_TX_COMMIT id=' . $cpu_trace_id
            . ' type=' . $safe->($pc->[3])
            . ' origin=' . $safe->($pc->[1])
            . ' peer=' . $safe->($self->{call})
            . ' sql_savepoint=RELEASED'
            . ' route_journal=RETAINED'
            . ' deferred_logs=' . scalar(@deferred_logs)
            . ' deferred_metrics=' . scalar(@deferred_metrics)
            . ' deferred_routes=' . scalar(@deferred_routes)
            . ' deferred_buddies=' . scalar(@deferred_buddies));
    }
    # Diagnostic only: verify missing-before C entities after SQL commit.
    # No changes to routing, admission, or broadcast decisions.
    if ($pc92_c_recovery_candidates && @recovery_candidates) {
        my ($created_nodes, $created_users, $missing_nodes, $missing_users) = (0, 0, 0, 0);
        my @examples;
        for my $item (@recovery_candidates) {
            my ($type, $call, $owner) = @$item;
            my $obj = $type eq 'node' ? Route::Node::get($call) : Route::User::get($call);
            if ($obj) {
                $type eq 'node' ? ++$created_nodes : ++$created_users;
            } else {
                $type eq 'node' ? ++$missing_nodes : ++$missing_users;
            }
            push @examples, $type . ':' . $call if @examples < 4;
        }
        # Read-only reciprocal Route linkage audit for newly recovered C entities.
        # Never infer missing links from a missing owner: report it separately.
        my ($links_ok, $links_missing, $owners_missing, $links_unknown) = (0, 0, 0, 0);
        my @link_examples;
        for my $item (@recovery_candidates) {
            my ($type, $call, $owner) = @$item;
            my $obj = $type eq 'node' ? Route::Node::get($call) : Route::User::get($call);
            my $parent = Route::Node::get($owner);
            if (!$parent) { ++$owners_missing; next; }
            if (!$obj) { ++$links_unknown; next; }
            my $forward = $type eq 'node' ? $parent->{nodes} : $parent->{users};
            my $reverse = $obj->{parent};
            if (ref($forward) ne 'ARRAY' || ref($reverse) ne 'ARRAY') {
                ++$links_unknown;
                next;
            }
            my $f = scalar grep { defined $_ && $_ eq $call } @$forward;
            my $r = scalar grep { defined $_ && $_ eq $owner } @$reverse;
            if ($f && $r) { ++$links_ok; }
            else {
                ++$links_missing;
                if (@link_examples < 4) {
                    my $safe_call = $call;
                    $safe_call =~ s/[^A-Za-z0-9-]/_/g;
                    push @link_examples, $type . ':' . substr($safe_call, 0, 20)
                        . ':f' . ($f ? 1 : 0) . 'r' . ($r ? 1 : 0);
                }
            }
        }
        dbg('PC92_C_LINKS id=' . $cpu_trace_id
            . ' origin=' . $pcall
            . ' peer=' . $self->{call}
            . ' reciprocal_ok=' . $links_ok
            . ' reciprocal_missing=' . $links_missing
            . ' owner_missing=' . $owners_missing
            . ' unknown=' . $links_unknown
            . ' examples=' . join(',', @link_examples));
        dbg('PC92_C_RECOVERY id=' . $cpu_trace_id
            . ' origin=' . $pcall
            . ' peer=' . $self->{call}
            . ' new_nodes=' . $created_nodes
            . ' new_users=' . $created_users
            . ' absent_after_nodes=' . $missing_nodes
            . ' absent_after_users=' . $missing_users
            . ' examples=' . join(',', @examples));
    }
    # Post-commit callbacks may themselves invoke PC92 routing/notifications.
    # Disable the dynamically scoped queues before dispatch: otherwise nested
    # callbacks append to a queue that is already being flushed (or lose events).
    $Route::pc92_mutation_journal = undef;
    $pc92_acd_deferred_routes = undef;
    $pc92_acd_deferred_buddies = undef;
    $pc92_acd_deferred_logs = undef;
    $pc92_acd_deferred_metrics = undef;
    # Diagnostic counters only; never change callback dispatch decisions.
    my ($post_logs_fail, $post_metrics_fail, $post_routes_fail, $post_routes_sent, $post_buddies_fail) = (0, 0, 0, 0, 0);
    for my $event (@deferred_logs) {
        eval { local $SIG{__DIE__} = sub {}; Log(@$event); 1 }
            or do { ++$post_logs_fail; LogDbg('err', "PC92 post-commit Log failed: $@"); };
    }
    for my $event (@deferred_metrics) {
        my ($method, @args) = @$event;
        eval { local $SIG{__DIE__} = sub {}; my $cb = DXHealth->can($method) or die "Unknown DXHealth metric $method"; $cb->(@args); 1 }
            or do { ++$post_metrics_fail; LogDbg('err', "PC92 post-commit metric $method failed: $@"); };
    }
    # Dispatch only after successful SQL RELEASE. Errors here are logged,
    # never used to attempt an impossible rollback of already sent messages.
    for my $event (@deferred_routes) {
        my ($chan, $method, @args) = @$event;
        if ($method eq 'broadcast_route_pc9x') {
            my ($pcall, $unused, $line, $zero, $marker, $sort, $len) = @args;
            my $sent = eval { local $SIG{__DIE__} = sub {}; $chan->broadcast_route_pc9x($pcall, undef, $line, 0) };
            if ($@) { ++$post_routes_fail; LogDbg('err', "PC92 post-commit broadcast failed: $@"); }
            elsif ($sent) {
                ++$post_routes_sent;
                DXHealth::pc92_forwarded($sort, $len);
                DXHealth::protocol_origin_inc('forwarded', $pcall, 92, $len);
            }
        } else {
            eval { local $SIG{__DIE__} = sub {}; $chan->$method(@args); 1 }
                or do { ++$post_routes_fail; LogDbg('err', "PC92 post-commit $method failed: $@"); };
        }
    }
    for my $event (@deferred_buddies) {
        my ($chan, @args) = @$event;
        eval { local $SIG{__DIE__} = sub {}; $chan->tell_buddies(@args); 1 }
            or do { ++$post_buddies_fail; LogDbg('err', "PC92 buddy notification failed after commit: $@"); };
    }
    if ($checkcpu >= 2 && (@deferred_logs || @deferred_metrics || @deferred_routes || @deferred_buddies)) {
        dbg('PC92_POSTCOMMIT id=' . $cpu_trace_id
            . ' type=' . $pc->[3]
            . ' logs=' . scalar(@deferred_logs)
            . ' metrics=' . scalar(@deferred_metrics)
            . ' routes=' . scalar(@deferred_routes)
            . ' routes_sent=' . $post_routes_sent
            . ' buddies=' . scalar(@deferred_buddies)
            . ' logs_fail=' . $post_logs_fail
            . ' metrics_fail=' . $post_metrics_fail
            . ' routes_fail=' . $post_routes_fail
            . ' buddies_fail=' . $post_buddies_fail);
    }
    return;
}

sub handle_92 { return _pc92_acd_guarded(@_); }

sub _pc92_handle_92_original
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	my (@radd, @rdel);

	my $pcall = $pc->[1];
	my $t = $pc->[2];
	my $sort = $pc->[3];
	my $hops = $pc->[-1];

	# Physical transport accounting precedes duplicate rejection; it does not
	# inspect RELAY or OBJECTs.
	DXHealth::pc92_physical_in($self->{call}, $sort, length($line));

	# Cheap read-only duplicate/old-ID rejection before RELAY or OBJECT work.
	# check_pc9x_t remains the authoritative admission/update after validation.
	if (($sort eq 'A' || $sort eq 'C' || $sort eq 'D')
	    && _pc92_acd_early_duplicate($pcall, $t)) {
        $pc92_acd_reject_reason = 'duplicate_after_checkpoint' if $pc92_acd_prevalidated;
		return;
	}

	# Reject stale/out-of-window IDs before walking potentially large OBJECT arrays.
	# The authoritative check_pc9x_t retains its own time check.
	if (($sort eq 'A' || $sort eq 'C' || $sort eq 'D')
	    && _pc92_acd_early_time_invalid($t)) {
        $pc92_acd_reject_reason = 'time_invalid_after_checkpoint' if $pc92_acd_prevalidated;
		return;
	}

	# A/C/D preflight precedes sequence and route mutations.
	if (($sort eq 'A' || $sort eq 'C' || $sort eq 'D') && !$pc92_acd_prevalidated) {
		my $reason = _pc92_acd_preflight($pc);
		if ($reason) {
			dbg("PCPROT: rejected PC92$sort from $pcall: $reason") if isdbg('chanerr') || isdbg('routelow');
			return;
		}
	}

	# this catches loops of A/Ds
#	if (eph_dup($line, $pc9x_dupe_age)) {
#		return;
#	}

	if ($pcall eq $main::mycall) {
		LogDbg('err', "PCPROT: looped back, ignored");
		return;
	}

	if ($pcall eq $main::myalias) {
		LogDbg('err', "PCPROT: looped back to \$myalias ($main::myalias), misconfiguration ignored");
		return;
	}

	if ($pcall eq $self->{call} && $self->{state} eq 'init') {
		if ($self->{isolate}) {
			dbg("DXPROT: PC9x received, but $pcall is isolated, ignored");
			return;
		} elsif (!$self->user->wantpc9x) {
			dbg("DXPROT: PC9x explicitly switched off on $pcall, ignored");
			return;
		} else {
			$self->state('init92');
			$self->{do_pc9x} = 1;
			dbg("DXPROT: Do pc9x set on $pcall");
		}
	}
	unless ($self->{do_pc9x}) {
		dbg("PCPROT: PC9x come in from non-PC9x node, ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	# ORIGIN owns the sequence; RELAY, when different, owns configuration.
	my $pc92_owner_call = $pcall;
	if ($sort eq 'A' || $sort eq 'C' || $sort eq 'D') {
		my $relay = $pc->[4];
		if (length $relay) {
			my ($relay_call) = _decode_pc92_call($relay);
			$pc92_owner_call = $relay_call;
		}
		# A/C can recover a missing RELAY through _add_thingy below, using
		# the same journalled Route/DXUser path as an advertised NODE OBJECT.
		# D must not create a missing RELAY merely to delete its children.
		if ($sort eq 'D' && $pc92_owner_call ne $pcall && !Route::Node::get($pc92_owner_call)) {
			$pc92_acd_reject_reason = 'relay_parent_absent' if $pc92_acd_prevalidated;
			dbg("PCPROT: PC92D unknown RELAY $pc92_owner_call, ignored") if isdbg('routelow');
			return;
		}
	}

	# A/C/D: reject the entire packet before lastid, Route or DXUser changes.
	# Do not silently filter conflicting identities from a full C snapshot.
	if ($sort eq 'A' || $sort eq 'C' || $sort eq 'D') {
		for my $i (5 .. $#$pc - 1) {
			my ($flag, $call) = $pc->[$i] =~ /\A([0-7])([^:]+)/;
			return unless defined $flag && defined $call;
			if ($call eq $main::mycall ||
			    ($call eq $main::myalias && ($flag & 4)) ||
			    (!($flag & 4) && ($flag & 2)) ||
			    (!($flag & 4) && _pc92_user_is_known_node($call, undef, $self, $sort))) {
				dbg("PCPROT: PC92$sort rejected conflicting OBJECT $call") if isdbg('routelow');
				return;
			}
		}
	}

	# Decode all advertised OBJECTs before check_pc9x_t can mutate lastid.
	# A failed decode must reject the entire A/C/D message, never silently
	# remove an OBJECT from a C snapshot after sequence admission.
	my @pc92_acd_decoded;
	if ($sort eq 'A' || $sort eq 'C' || $sort eq 'D') {
		for my $i (5 .. $#$pc - 1) {
			my @slot = _decode_pc92_call($pc->[$i]);
			unless (@slot && defined $slot[0] && length $slot[0]) {
				dbg("PCPROT: PC92$sort undecodable OBJECT at index $i, rejected") if isdbg('chanerr') || isdbg('routelow');
				return;
			}
			push @pc92_acd_decoded, \@slot;
		}
	}

	# don't create routing entries for D records that don't already exist
	# this is what causes all those PC92 loops!
	my $parent = check_pc9x_t($pcall, $t, 92, $sort ne 'D', 1);
    unless ($parent) {
        $pc92_acd_reject_reason = 'check_pc9x_t_rejected' if $pc92_acd_prevalidated;
        return;
    }
	my $oparent = $parent;

	$parent->do_pc9x(1);
	$parent->via_pc92(1);
	my @pc92_relay_added;
	if (($sort eq 'A' || $sort eq 'C') && $pc92_owner_call ne $pcall) {
		my @relay_slot = _decode_pc92_call($pc->[4]);
		# RELAY is an advertised child of ORIGIN, not an OBJECT of itself.
		# Attach it using the same routing/DXUser path as a node OBJECT.
		@pc92_relay_added = _add_thingy($parent, \@relay_slot, $self, $hops, $sort);
	}
	if (($sort eq 'A' || $sort eq 'C' || $sort eq 'D') && $pc92_owner_call ne $pcall) {
		$parent = Route::Node::get($pc92_owner_call);
		# D of an already absent RELAY is an idempotent no-op.
		unless ($parent || ($sort eq 'D' && $#$pc == 5)) {
            $pc92_acd_reject_reason = 'relay_parent_absent' if $pc92_acd_prevalidated;
            return;
        }
		$parent ||= $oparent;
	}

	if ($sort eq 'F' || $sort eq 'R') {

		# this is the route finding section
		# here is where the consequences of the 'find' command
		# are dealt with

		my $from = $pc->[4];
		my $target = $pc->[5];

		if ($sort eq 'F') {
			my $flag;
			my $ref;
			my $dxchan;
			if ($ref = DXChannel::get($target)) {
				$flag = 1;		# we are directly connected
			} else {
				$ref = Route::get($target);
				$dxchan = $ref->dxchan;
				$flag = 2;
			}
			if ($ref && $flag && $dxchan) {
				$self->send(pc92r($from, $target, $flag, int($dxchan->{pingave}*1000)));
				return;
			}
		} elsif ($sort eq 'R') {
			if (my $dxchan = DXChannel::get($from)) {
				handle_pc92_find_reply($dxchan, $pcall, $from, $target, @$pc[6,7]);
			} else {
				my $ref = Route::get($from);
				if ($ref) {
					my @dxchan = grep {$_->do_pc9x} $ref->alldxchan;
					if (@dxchan) {
						$_->send($line) for @dxchan;
					} else {
						dbg("PCPROT: $self->{call} : type R no return route, ignored") if isdbg('chanerr') || isdbg('route');
					}
				} else {
					dbg("PCPROT: $self->{call} : type R no return route, ignored") if isdbg('chanerr') || isdbg('route');
				}
			}
			return;
		}

	} elsif ($sort eq 'K') {
		$pc92Kin += length $line;

		# remember the last channel we arrived on
		$parent->PC92C_dxchan($self->{call}, $hops) unless $self->{call} eq $parent->call;

		my @ent = _decode_pc92_call($pc->[4]);

		if (@ent) {
			my $add;

			($parent, $add) = $self->pc92_handle_first_slot(\@ent, $parent, $t, $hops);
			return unless $parent; # dupe

			push @radd, $add if $add;
			$parent->reset_obs;
			# PC92K fields 5/6 are the remote node's advertised node/user
			# counts (DXProtout::pc92k).  Keep them only in bounded DXHealth
			# telemetry; do not alter Route::Node/DXUser/routing semantics.
			DXHealth::pc92k_advertised($parent->call, $pc->[5], $pc->[6]);
			my $call = $parent->call;
			my $version = $ent[4] || 0;
			my $build = $ent[5] ||  0;
			$build =~ s/^0\.//;
			my $oldbuild = $parent->build || 0;
			my $oldversion = $parent->version || 0;
			my $user = check_add_user($parent->call, 'S');
			my $oldsort = $user->sort // '';
			my $ipaddr = @ent > 10 ? $ent[9] : '';
			my ($gitbranch, $gitversion);
			if (defined $pc->[8] && length $pc->[8] && $pc->[8] =~ m{^(.+)/([^/]+)$}) {
				($gitbranch, $gitversion) = ($1, $2);
			}

			dbg("PCPROT: PC92 K v: $version ov: $oldversion b: $build ob: $oldbuild pk: " . ($parent->K || '0') . " uk: " . ($user->K || 0)) if isdbg('pc92k');

			{
				my $changed = 0;
				# Missing/zero fields are not announcements.  Validate each field
				# independently, preserving the last known value of the other.
				if (defined $version && $version =~ /^\d+(?:\.\d+)?$/ && $version > 0) {
					$parent->version($version) if $oldversion != $version;
					if (!defined $user->version || $user->version != $version) {
						$user->version($version);
						++$changed;
					}
				}
				if (defined $build && $build =~ /^\d+(?:\.\d+)?$/ && $build > 0) {
					$parent->build($build) if $oldbuild != $build;
					if (!defined $user->build || $user->build != $build) {
						$user->build($build);
						++$changed;
					}
				}

				# PC92 K already carries gitbranch/gitversion in field 8. Keep it
				# as live route metadata; do not persist it into DXUser.
				$parent->gitbranch($gitbranch);
				$parent->gitversion($gitversion);

				unless ($user->is_spider || $user->is_ccluster) {
					$user->sort('S');
					dbg(sprintf "PCPROT: PC92 K rec, node $call updated sort: $oldsort->S");
					++$changed;
				}

				if ($self->is_ccluster && $self->state ne 'normal') {
					$self->state('normal');
					dbg(sprintf "PCPROT: PC92 K rec, node $call updated state now 'normal'");
				}

				unless (DXChannel::get($user->call)) { # only do this if not connected
					my $oldpriv = $user->priv;
					my $oldlock = $user->lockout;
					my $lastchanged = $changed;
					$user->priv(1), ++$changed unless defined $oldpriv && $oldpriv;
					$user->lockout(1), ++$changed unless defined $oldlock;
					dbg(sprintf "PCPROT: PC92 K rec, node $call updated priv: '$oldpriv'->%d lockout: '$oldlock'->%s", $user->priv || 0, $user->lockout || 0) if $lastchanged != $changed;
				}
				unless ($user->K) {
					dbg(sprintf "PCPROT: PC92 K rec, node $call updated - marked as sending PC92 K records priv: %d lockout: %d ", $user->priv || 0, $user->lockout || 0);
					$user->K(1);
					++$changed;
				}
				$user->put if $changed;
				$parent->K(1); # mark this as come in on a K
			}
			dbg("ROUTE: reset obscount on $call now " . $parent->obscount) if isdbg('obscount');
		}
	} elsif ($sort eq 'A' || $sort eq 'D' || $sort eq 'C') {

		$pc92Ain += length $line if $sort eq 'A';
		$pc92Cin += length $line if $sort eq 'C';
		$pc92Din += length $line if $sort eq 'D';

		# remember the last channel we arrived on
		$parent->PC92C_dxchan($self->{call}, $hops) unless $self->{call} eq $parent->call;

		# this is the main route section
		# here is where all the routes are created and destroyed

		# The header origin owns every advertised connection. Field 4 may
		# be empty, a redundant origin, or an ordinary legacy user entry.
		# The old relay-node case was rejected before check_pc9x_t.
		push @radd, @pc92_relay_added if @pc92_relay_added;
		my @ent = @pc92_acd_decoded;
		# Only the owner NODE self-description is redundant. A USER with
		# the identical full CALL is a different typed routing identity.
		@ent = grep { !($_->[0] eq $parent->call && $_->[1]) } @ent;

		# do a pass through removing any references to either mycall
		my @nent;
		for (@ent) {
			my $dxc;
			next unless $_ && @$_;
			if ($_->[0] eq $main::mycall) {
				dbg("PCPROT: $self->{call} : type $sort $_->[0] refers to me, ignored") if isdbg('route');
				next;
			}

			my $isnode = ($_->[1] | $_->[2]);
			if (($_->[0] eq $main::myalias && $isnode) || ($_->[0] eq $main::mycall && !$isnode)) {
				LogDbg('err',"PCPROT: $self->{call} : type $sort $_->[0] trying to change type to " . $_->[1]?"Node":"User" . ", ignored");
				next;
			}

			push @nent, $_;
		}

		if ($sort eq 'A') {
			for (@nent) {
				push @radd, _add_thingy($parent, $_, $self, $hops, 'A');
			}
		} elsif ($sort eq 'D') {
			for (@nent) {
				push @rdel, _del_thingy($parent, $_, $self);
			}
			# A classical D with only RELAY removes ORIGIN -> RELAY.
			# Route::Node::del cascades only when no other parents remain.
			if (!@nent && $pc92_owner_call ne $pcall) {
				my $relay = Route::Node::get($pc92_owner_call);
				if ($relay && grep { $_ eq $pcall } @{$relay->{parent} || []}) {
					push @rdel, _del_thingy($oparent, [$pc92_owner_call, 1], $self);
				}
			}
		} elsif ($sort eq 'C') {
			my (@nodes, @users);
			my @accepted_pc92c_nodes;

			# we reset obscounts on config records as well as K records
			$parent->reset_obs;
			dbg("ROUTE: reset obscount on $parent->{call} now " . $parent->obscount) if isdbg('obscount');

			#
			# All OBJECT identities were validated before check_pc9x_t.
			# Never turn an invalid full snapshot into a partial snapshot.
			foreach my $r (@nent) {
				#			my ($call, $is_node, $is_extnode, $here, $version, $build) = _decode_pc92_call($_);
				if ($r->[0]) {
					if ($r->[1]) {
						push @accepted_pc92c_nodes, $r;
						push @nodes, $r->[0];
					} else {
						push @users, $r->[0];
					}
				} else {
					dbg("PCPROT: $self->{call} :  pc92 call entry '$_' not decoded, ignored") if isdbg('chanerr') || isdbg('route');
				}
			}

			# Reconcile accepted existing children independently of whether
			# this C carries a version (IP-only C entries have none).
			# K metadata in DXUser is authoritative; C must not replace it.
			my %existing_nodes = map { $_ => 1 } $parent->nodes;
			foreach my $slot (@accepted_pc92c_nodes) {
				my ($call, undef, undef, undef, $version, $build) = @$slot;
				next unless $call && $existing_nodes{$call};
				next unless is_callsign($call) && normalise_call($call) eq $call;
				my $node = Route::Node::get($call) || next;
				next if DXChannel::get($call); # direct node owns its metadata
				my $user = DXUser::get_current($call);
				if ($user && $user->K) {
					my $saved_version = $user->version;
					my $saved_build = $user->build;
					if (defined $saved_version && is_numeric($saved_version) && $saved_version > 0
					    && ($node->version || 0) != $saved_version) {
						$node->version($saved_version);
						dbg("PCPROT: PC92C restored K version $call -> $saved_version") if isdbg('route');
					}
					if (defined $saved_build && is_numeric($saved_build) && $saved_build > 0
					    && ($node->build || 0) != $saved_build) {
						$node->build($saved_build);
					}
					$node->K(1) unless $node->K;
					next;
				}
				next if $node->K; # no K-backed DXUser data: do not trust C
				# Version and build are independent optional updates.
				my $has_version = defined $version && is_numeric($version) && $version > 0;
				my $has_build = defined $build && is_numeric($build) && $build > 0;
				next unless $has_version || $has_build;
				# A Route::Node can exist without its DXUser. Create the latter
				# only when there is accepted metadata to persist.
				$user ||= check_add_user($call, 'S');
				my $changed = 0;
				if ($has_version) {
					my $old = $node->version || 0;
					if ($old != $version) {
						$node->version($version);
						dbg("PCPROT: PC92C metadata $call version $old -> $version via " . $parent->call) if isdbg('route');
					}
					if (!defined $user->version || $user->version != $version) {
						$user->version($version);
						++$changed;
					}
				}
				if ($has_build) {
					$node->build($build) if ($node->build || 0) != $build;
					if (!defined $user->build || $user->build != $build) {
						$user->build($build);
						++$changed;
					}
				}
				$user->put if $changed;
			}

			my ($dnodes, $dusers, $nnodes, $nusers) = $parent->calc_config_changes(\@nodes, \@users);
			my %pc92c_new_node = map { $_ => 1 } @$nnodes;
			my %pc92c_new_user = map { $_ => 1 } @$nusers;

            # Capture only identities absent from the entire live graph before
            # the C additions. The post-commit verifier is read-only.
            if ($pc92_c_recovery_candidates) {
                my %seen;
                for my $r (@nent) {
                    my ($call, $is_node) = @$r;
                    next unless defined $call && length $call;
                    my $type = $is_node ? 'node' : 'user';
                    next if $seen{"$type:$call"}++;
                    next unless $is_node ? $pc92c_new_node{$call} : $pc92c_new_user{$call};
                    next if $is_node ? Route::Node::get($call) : Route::User::get($call);
                    push @$pc92_c_recovery_candidates, [$type, $call, $parent->call];
                }
            }
			# add users here
			foreach my $r (@nent) {
				my $call = $r->[0];
				if ($call) {
					push @radd,_add_thingy($parent, $r, $self, $hops, 'C') if ($r->[1] ? $pc92c_new_node{$call} : $pc92c_new_user{$call});
				}
			}
			# del users here
			foreach my $r (@$dnodes) {
				push @rdel,_del_thingy($parent, [$r, 1], $self);
			}
			foreach my $r (@$dusers) {
				push @rdel,_del_thingy($parent, [$r, 0], $self);
			}

			# remember this last PC92C for rebroadcast on demand
			$parent->last_PC92C($line);
		} else {
			dbg("PCPROT: unknown action '$sort', ignored") if isdbg('chanerr') || isdbg('routelow');
			return;
		}

		foreach my $r (@rdel) {
			next unless $r;

			_pc92_acd_route_event($self, 'route_pc21', $pcall, undef, $r) if $r->isa('Route::Node');
			_pc92_acd_route_event($self, 'route_pc17', $pcall, undef, $parent, $r) if $r->isa('Route::User');
		}
		my @pc19 = grep { $_ && $_->isa('Route::Node') } @radd;
		my @pc16 = grep { $_ && $_->isa('Route::User') } @radd;
		unshift @pc19, $parent if $self->{state} eq 'init92' && $oparent == $parent;
		_pc92_acd_route_event($self, 'route_pc19', $pcall, undef, @pc19) if @pc19;
		_pc92_acd_route_event($self, 'route_pc16', $pcall, undef, $parent, @pc16) if @pc16;
	}

	# Mark successful A/C/D admission only after all routing operations.
	$pc92_acd_accepted = 1 if $sort eq 'A' || $sort eq 'C' || $sort eq 'D';
	# Reaching here means an A/D/C/K survived the logical handling above.
	_pc92_acd_metric('pc92_received', $sort, length($line));
	# For A/C/D/K the first PC92 field is the protocol-defined originating
	# node (pcall). Forwarding preserves the original line, so this is a
	# logical origin and must not be replaced by the direct neighbour.
	_pc92_acd_metric('protocol_origin_inc', 'accepted', $pcall, 92, length($line));

	# broadcast it if we get here (but not if it's an A or D record and pc92_ad_enabled isn't set;
	if ($sort eq 'A' || $sort eq 'D') {
		return unless $pc92_ad_enabled;
	}
	my $sent = _pc92_acd_broadcast($self, $sort, $pcall, $line);
	if ($sent) {
		DXHealth::pc92_forwarded($sort, length($line));
		DXHealth::protocol_origin_inc('forwarded', $pcall, 92, length($line));
	}
}

# get all the routes for a thing, bearing in mind that the thing (e.g. a user)
# might be on two or more nodes at the same time or that there may be more than
# one equal distance neighbour to a node.
#
# What this means that if sh/route g1tlh shows that he is on (say) two nodes, then
# a Route::findroutes is done on each of those two nodes, the best route(s) taken from
# each and then combined to give a set of dxchans to send the PC9x record down
#
sub find_pc9x_routes
{
	my $to = shift;
	my $ref = Route::get($to);
	my @parent;
	my %cand;

	if ($ref->isa('Route::User')) {
		my $dxchan = DXChannel::get($to);
		push @parent, $to if $dxchan;
		push @parent, $ref->parents;
	} else {
		@parent = $to;
	}
	foreach my $p (@parent) {
		my $lasthops;
		my @routes = Route::findroutes($p);
		foreach my $r (@routes) {
			$lasthops = $r->[0] unless defined $lasthops;
			if ($r->[0] == $lasthops) {
				$cand{$r->[1]->call} = $r->[1];
			} else {
				last;
			}
		}
	}
	return values %cand;
}

# find all the users that need to see this chat group
sub find_chat_group_users
{
	my $group = shift;
	my @out;
	foreach my $dxchan (DXChannel::get_all_users()) {
		next unless $dxchan->{group} && ref($dxchan->{group}) eq 'ARRAY';
		push @out, $dxchan if grep { defined $_ && uc($_) eq uc($group) } @{$dxchan->{group}};
	}
	return @out;
}

sub handle_93
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	#	$self->{do_pc9x} ||= 1;

	return if $self->check_available($origin, $pcno);

	my $pcall = $pc->[1];			# this is now checked earlier

	# remember that we are converting PC10->PC93 and self will be $main::me if it
	# comes from us
	unless ($self->{do_pc9x}) {
		dbg("PCPROT: PC9x come in from non-PC9x node, ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	my $t = $pc->[2];
	my $parent = check_pc9x_t($pcall, $t, 93, 1) || return;

	my $to = uc $pc->[3];
	my $from = uc $pc->[4];
	my $via = uc $pc->[5];
	my $text = $pc->[6];
	my $onode = uc $pc->[7];
	my $ipaddr = $pc->[8];

	$onode = undef unless $onode && is_callsign($onode);
	$onode //= $pcall;
	$ipaddr = undef unless $ipaddr && is_ipaddr($ipaddr);

	# this is catch loops caused by bad software ...
	if (eph_dup("PC93|$from|$text|$onode", $pc10_dupe_age)) {
		return;
	}

	if (isdbg('progress')) {
		my $vs = $via ne '*' ? " via $via" : '';
		my $s = "ANNTALK: $from\@$onode$vs -> $to '$text' route: $origin";
		dbg($s);
	}

	# if this is a 'bad node' user then ignore it
	if ($badnode->in($onode, $preserve_node_ssid)) {
		DXHealth::operator_event('badlist', 'badnode', $self->{call}, $onode, 'PC93');
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Bad Node $onode, dropped");
		return;
	}

	# if this is a 'bad spotter' user then ignore it
	if ($badspotter->in($from)) {
		DXHealth::operator_event('badlist', 'badspotter', $self->{call}, $onode, 'PC93');
		dbg($line) if isdbg('nologchan');
		dbg("PCPROT: Bad Spotter $from, dropped");
		return;
	}

	# ignore PC93 coming in from outside this node with a target of local
	if ($to eq 'LOCAL' && $self != $main::me) {
		dbg("PCPROT: incoming LOCAL chat not from local node, ignored") if isdbg('chanerr') || isdbg('routelow');
		return;
	}

	# will we allow it at all?
	if ($censorpc) {
		my @bad;
		if (@bad = BadWords::check($text)) {
			DXHealth::operator_event('badlist', 'badword', $self->{call}, $onode, 'PC93');
			my $bw = join ', ', @bad;
			dbg($line) if isdbg('nologchan');
			dbg("PCPROT: Badwords: '$bw', dropped");
			return;
		}
	}

	if ($self == $main::me) {
		DXHealth::protocol_logical_origin_line('generated', $onode, $line);
	} else {
		DXHealth::protocol_logical_origin_line('accepted', $onode, $line);
	}

	$self->populate_routing_table($onode, $from, $ipaddr) if $pc61_extract_route;

	# if it is routeable then then treat it like a talk
	my $ref = Route::get($to);
	if ($ref && is_callsign($to)) {
		my $dxchan;

		# convert to PC10 or local talks where appropriate
		# PC93 capable nodes of the same hop count all get a copy
		# if there is a PC10 node then it will get a copy and that
		# will be it. Hopefully such a node will not figure highly
		# in the route list, unless it is local, 'cos it don't issue PC92s!
		# note that both local and PC93s at the same time are possible if the
		# user on more than one node.
		my @routes = find_pc9x_routes($to);
		
		my $lasthops;
		foreach $dxchan (@routes) {
			if (ref $dxchan && $dxchan->isa('DXChannel')) {
				if ($dxchan->{do_pc9x}) {
					$dxchan->send($line);
				} elsif (is_callsign($to)) {
					$dxchan->talk($from, $to, $via, $text, $onode);
				} else {
					$dxchan->chat($from, $to, $via, $text, $onode);
				}
			} else {
				dbg("ERROR: $to -> $dxchan is not a DXChannel! (convert to pc10)");
			}
		}
		return;

	} elsif (!is_callsign($to) && $text =~ /^#\d+ /) {
		# PC93 chat messages are identified by their message ID, including
		# those addressed to SYSOP or WX. Classify before announcements.
		$self->send_chat(1, $line, $from, '*', $text, $to, $pcall, '0');
		Web::publish_network_chat('ERROR', $from, $text, $onode) if $to eq 'ERROR' && Web->can('publish_network_chat');
		return if $via eq 'LOCAL';
	} elsif ($to eq '*' || $to eq 'SYSOP' || $to eq 'WX') {
		# announces
		my $sysop = $to eq 'SYSOP' ? '*' : ' ';
		my $wx = $to eq 'WX' ? '1' : '0';
		my $local = $via eq 'LOCAL' ? '*' : $via;

		$self->send_announce(1, pc12($from, $text, $local, $sysop, $wx, $pcall), $from, $local, $text, $sysop, $pcall, $wx, $via eq 'LOCAL' ? $via : undef);
		Web::publish_network_chat('SYSOP', $from, $text, $onode) if $to eq 'SYSOP' && Web->can('publish_network_chat');
		return if $via eq 'LOCAL';
	}

	# broadcast this chat sentence everywhere unless it is targetted to 'LOCAL'
	$self->broadcast_route_pc9x($pcall, undef, $line, 0) unless $to eq 'LOCAL' || $via eq 'LOCAL';
}

# if get here then rebroadcast the thing with its Hop count decremented (if
# there is one). If it has a hop count and it decrements to zero then don't
# rebroadcast it.
#
# NOTE - don't arrive here UNLESS YOU WANT this lump of protocol to be
#        REBROADCAST!!!!
#

sub handle_default
{
	my $self = shift;
	my $pcno = shift;
	my $line = shift;
	my $origin = shift;
	my $pc = shift;

	unless (eph_dup($line)) {
		if ($pcno >= 90) {
			my $pcall = $pc->[1];
			unless (is_callsign($pcall)) {
				dbg("PCPROT: invalid callsign string '$pc->[1]', ignored") if isdbg('chanerr') || isdbg('routelow');
				return;
			}
			my $t = $pc->[2];
			my $parent = check_pc9x_t($pcall, $t, $pcno, 1) || return;
			$self->broadcast_route_pc9x($pcall, undef, $line, 0);
		} else {
			unless ($self->{isolate}) {
				DXChannel::broadcast_nodes($line, $self) if $line =~ /\^H\d+\^?~?$/; # send it to everyone but me
			}
		}
	}
}

# does what it says on the tin..
sub populate_routing_table
{
	my ($self, $node, $user, $ip) = @_;

	my $rn = Route::Node::get($node);
	unless ($rn) {
		$rn = Route::Node->new($node);
		dbg("ROUTE $self->{call}: ADD NEW node: $node") if isdbg('spot');
	}

	my $ru;
	if ($user ne $node) {
		$ru = Route::User::get($user);
		unless ($ru) {
			$rn->add_user($user, 0, undef);
			dbg("ROUTE $self->{call}: ADD NEW user: $user -> $node") if isdbg('spot');
		}
		$ru = Route::User::get($user);
	}

	# Add/Change any IP address info

	# as we have a route to a user, if it (or the node) does not exist then create them
	# link the user to the node if not already done.
	# then add or alter the IP address
	if ($ip && is_ipaddr($ip)) {
		my $new = $ip;
		if ($ru) {
			if ($ru->ip ne $new) {
				if ($ru->ip) {
					my $old = $ru->ip;
					$ru->ip($new);
					dbg("ROUTE $self->{call}: ALTER IP node: $node user: $user old IP: '$old'-> new IP: '$new'") if isdbg('spot');
				} else{
					$ru->ip($new);
					dbg("ROUTE $self->{call}: NEW IP node: $node user: $user IP: '$new'") if isdbg('spot');
				}
			}
		} else {
			dbg("ROUTE $self->{call}: ADD Failed for node $node user $user") if isdbg('spot');
		}
	}
}

1;
