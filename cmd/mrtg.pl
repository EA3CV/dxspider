#
# This is a local command to generate the various statistics that
# can then be displayed on an MRTG plot
#
# Your mrtg binary must live in one of the standard places
#
# The arguments (keywords) to the mrtg command are these
#
# a) content          (you always get the node users and nodes and data in/out)
#    proc             - get the processor usage
#    agw              - include the AGW stats separately 
#    totalspots       - all spots
#    hfvhf            - all spots split into HF and VHF
#    wwv              - two graphs of WWV, one SFI and R other A and K
#    wcy              - WCY A and K 
#    pc92             - PC92 C and K, PC92 A and D
#    all              - all of the above 
#    
# b) actions          
#    test             - do everything except check for and run mrtg
#    nomrtg           - ditto (better name)
#    dataonly         - only generate the data files for mrtg
#    cfgonly          - only generate the mrtg.cfg file (like cfgmaker)
#    runmrtg          - run mrtg, this is probably used with dataonly
#                     - together with a home rolled mrtg.cfg 
#
# Copyright (c) 2002 Dirk Koopman G1TLH
#
#
#

sub handle
{
	my ($self, $line) = @_;

#	$DB::single = 1;
	
	# create the arg list
	my %want;
	for (split /\s+/, $line) { $want{lc $_} = 1};
	$want{nomrtg} = 1 if $want{cfgonly} || $want{test};
	
	return (1, "MRTG not installed") unless $want{nomrtg} || -e '/usr/bin/mrtg' || -e '/usr/local/bin/mrtg';
	return (1, "MRTG requires top to be installed") unless $want{nomrtg} || -e '/usr/bin/top' || -e '/usr/local/bin/top';

	my @out = do_it(%want);
	
	return (1, @out);
}


sub do_it
{
	my %want = @_;
	
	my $mc = new Mrtg or return (1, "cannot initialise Mrtg $!");

	# do Data in / out totals
	my $din = $Msg::total_in;
	my $dout = $Msg::total_out;

	$mc->cfgprint('msg', [ qw(integer) ], 64000, 
				  "Cluster Data <font color=#00cc00>in</font> and <font color=#0000ff>out</font> of $main::mycall",
				  'Bytes / Sec', 'Bytes In', 'Bytes Out') unless $want{dataonly};
	$mc->data('msg', $din, $dout, "Data in and out of $main::mycall") unless $want{cfgonly};
	dbg("mrtg: din: $din dout: $dout") if isdbg("mrtg");

	# do AGW stats if they apply
	if ($want{agw}) {
		$mc->cfgprint('agw', [], 64000, 
					  "AGW Data <font color=#00cc00>in</font> and <font color=#0000ff>out</font> of $main::mycall",
					  'Bytes / Sec', 'Bytes In', 'Bytes Out') unless $want{dataonly};
		$mc->data('agw', $AGWMsg::total_in, $AGWMsg::total_out, "AGW Data in and out of $main::mycall") unless $want{cfgonly};
		dbg("mrtg: agwin: $AGWMsg::total_in  agwout: $AGWMsg::total_out") if isdbg("mrtg");
	}

	if (!$main::is_win && ($want{proc} || $want{all})) {
		my $secs = $main::clssecs + $main::cldsecs;

		dbg "mrtg: proc: cluster=$main::clssecs children=$main::cldsecs clock=$secs" if isdbg('mrtg');
		
		$mc->cfgprint('proc', [qw(unknaszero withzeroes perminute)], 600, 
					  "CPU Usage of <font color=#00cc00>node</font> and its <font color=#0000ff>children</font> in seconds",
					  'CPU Secs/min', 'Node Secs 10ths', 'Child Secs 10ths', 0.1) unless $want{dataonly};
		$mc->data('proc', int($main::clssecs*10+0.5), int($main::cldsecs*10+0.5), "Processor Usage") unless $want{cfgonly};
	}

	# do the users and nodes
	my $users = DXChannel::get_all_users();
	my $nodes = DXChannel::get_all_nodes();

	$mc->cfgprint('users', [qw(unknaszero gauge integer)], 1800, 
				  "<font color=#00cc00>Users</font> and <font color=#0000ff>Nodes</font> on $main::mycall",
				  'Users / Nodes', 'Users', 'Nodes') unless $want{dataonly};
	$mc->data('users', $users, $nodes, 'Users / Nodes') unless $want{cfgonly};
	dbg("mrtg: din: $din dout: $dout") if isdbg("mrtg");

	# do the  total users and nodes
	if ($want{totalusers} || $want{all}) {
		$nodes = Route::Node::count();
		$users = Route::User::count();
		$mc->cfgprint('totalusers', [qw(integer unknaszero gauge)], 10000, 
					  'Total <font color=#00cc00>Users</font> and <font color=#0000ff>Nodes</font> in the Visible Cluster Network',
					  'Users / Nodes', 'Users', 'Nodes') unless $want{dataonly};
		$mc->data('totalusers', $users, $nodes, 'Total Users and Nodes in the Visible Cluster Network') unless $want{cfgonly};
		dbg("mrtg: users: $users nodes: $nodes") if isdbg("mrtg");
	}

	# do the total spots
	if ($want{totalspots} || $want{all}) {
		$mc->cfgprint('totalspots',  [qw(integer withzeroes unknaszero noi perminute)], 1000, 'Total Spots',
					  'Spots / min', 'Spots', 'Spots') unless $want{dataonly};
		$mc->data('totalspots', $Spot::totalspots, $Spot::totalspots, 'Total Spots') unless $want{cfgonly};
		dbg("mrtg: total spots: $Spot::totalspots") if isdbg("mrtg");
		#$Spot::totalspots = 0;
	}

	# do the HF and VHF spots
	if ($want{hfvhf} || $want{all}) {
		$mc->cfgprint('hfspots', [qw(integer withzeroes unknaszero perminute)], 1000, '<font color=#00cc00>HF</font> and <font color=#0000ff>VHF+</font> Spots',
					  'Spots / min', 'HF', 'VHF') unless $want{dataonly};
		$mc->data('hfspots', $Spot::hfspots, $Spot::vhfspots, 'HF and VHF+ Spots') unless $want{cfgonly};
		dbg("mrtg: hfspots: $Spot::hfspots vhfspots: $Spot::vhfspots") if isdbg("mrtg");
		#$Spot::hfspots = $Spot::vhfspots = 0;
	}

	# wwv stuff
	if ($want{wwv} || $want{all}) {
		$mc->cfgprint('wwvsfi', [qw(integer gauge)], 1000, 'WWV <font color=#00cc00>SFI</font> and <font color=#0000ff>R</font>', 'SFI / R', 'SFI', 'R') unless $want{dataonly};
		$mc->data('wwvsfi', ($Geomag::sfi || $WCY::sfi), ($Geomag::r || $WCY::r), 'WWV SFI and R') unless $want{cfgonly};
		$mc->cfgprint('wwvka', [qw(gauge)], 1000, 'WWV <font color=#00cc00>A</font> and <font color=#0000ff>K</font>',
					  'A / K', 'A', 'K') unless $want{dataonly};
		$mc->data('wwvka', $Geomag::a, $Geomag::k, 'WWV A and K') unless $want{cfgonly};
		dbg("mrtg: WWV A: $Geomag::a K: $Geomag::k") if isdbg("mrtg");
	}

	# WCY stuff
	if ($want{wcy} || $want{all}) {
		$mc->cfgprint('wcyka', [qw(integer gauge)], 1000, 'WCY <font color=#00cc00>A</font> and <font color=#0000ff>K</font>',
					  'A / K', 'A', 'K') unless $want{dataonly};
		$mc->data('wcyka', $WCY::a, $WCY::k, 'WCY A and K') unless $want{cfgonly};
		dbg("mrtg: WCY A: $WCY::a K: $WCY::k") if isdbg("mrtg");
	}

	if ($want{pc92} || $want{all}) {

		$mc->cfgprint('pc92ck', [qw(integer)], 1024000,
					  "PC92 <font color=#00cc00>C</font> and <font color=#0000ff>K</font> records into $main::mycall",
					  'Bytes / Sec', 'C', 'K') unless $want{dataonly};
		$mc->data('pc92ck', $DXProt::pc92Cin, $DXProt::pc92Kin, "PC92 C and K into $main::mycall") unless $want{cfgonly};
		#	$DXProt::pc92Cin = $DXProt::pc92Kin = 0;

		$mc->cfgprint('pc92ad', [qw(integer)], 1024000,
					  "PC92 <font color=#00cc00>A</font> and <font color=#0000ff>D</font> records into $main::mycall",
					  'Bytes / Sec', 'A', 'D') unless $want{dataonly};
		$mc->data('pc92ad', $DXProt::pc92Ain, $DXProt::pc92Din, "PC92 A and D into $main::mycall") unless $want{cfgonly};
		#	$DXProt::pc92Ain = $DXProt::pc92Din = 0;
		dbg("mrtg: PC92 C: $DXProt::pc92Cin K: $DXProt::pc92Kin A: $DXProt::pc92Ain D: $DXProt::pc92Din") if isdbg("mrtg");
	}

		# 
	# do the mrtg thing
	#

	my @out;
	{
		local %ENV;
		$ENV{LANG} = 'C';
		@out = $mc->run unless $want{nomrtg};
	}

	return @out;
}

