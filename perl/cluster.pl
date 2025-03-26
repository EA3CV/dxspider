#!/usr/bin/env perl
#
# This is the DX cluster 'daemon'. It sits in the middle of its little
# web of client routines sucking and blowing data where it may.
#
# Hence the name of 'spider' (although it may become 'dxspider')
#
# Copyright (c) 1998 Dirk Koopman G1TLH
#
#
#

package main;

require 5.16.1;

use warnings;

use vars qw($root $is_win $systime $lockfn @inqueue $starttime $lockfn @outstanding_connects
			$zombies @listeners $lang $myalias @debug $userfn $clusteraddr
			$clusterport $mycall $decease $routeroot $me $reqreg $bumpexisting
			$allowdxby $dbh $dsn $dbuser $dbpass $do_xml $systime_days $systime_daystart
			$can_encode $maxconnect_user $maxconnect_node $idle_interval $log_flush_interval
			$broadcast_debug $yes $no $user_interval
		   );

#$lang = 'en';					# default language
#$clusteraddr = '127.0.0.1';		# cluster tcp host address - used for things like console.pl
#$clusterport = 27754;			# cluster tcp port
#$yes = 'Yes';					# visual representation of yes
#$no = 'No';						# ditto for no
#$user_interval = 11*60;			# the interval between unsolicited prompts if no traffic

package main;

# set default paths, these should be overwritten by DXVars.pm
use vars qw($data $system $cmd $localcmd $userfn $clusteraddr $clusterport $yes $no $user_interval $lang $local_data);

$lang = 'en';                   # default language
$yes = 'Yes';                   # visual representation of yes
$no = 'No';                     # ditto for no
$user_interval = 11*60;         # the interval between unsolicited prompts if no traffic


# make sure that modules are searched in the order local then perl
BEGIN {
	umask 002;
	$SIG{'__WARN__'} = sub { warn $_[0] if $DOWARN };
			
	# take into account any local::lib that might be present
	eval {
		require local::lib;
	};
	unless ($@) {
#		import local::lib;
		import local::lib qw(/spider/perl5lib);
	} 

	# root of directory tree for this system
	$root = "/spider";
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};

	unshift @INC, "$root/perl5lib" unless grep {$_ eq "$root/perl5lib"} @INC;
	unshift @INC, "$root/perl";	# this IS the right way round!
	unshift @INC, "$root/local";

	# do some validation of the input
	die "The directory $root doesn't exist, please RTFM" unless -d $root;
	die "$root/local doesn't exist, please RTFM" unless -d "$root/local";
	die "$root/local/DXVars.pm doesn't exist, please RTFM" unless -e "$root/local/DXVars.pm";

	# create some directories
	mkdir "$root/local_cmd", 02774 unless -d "$root/local_cmd";

	# locally stored data lives here
	$local_data = "$root/local_data";
	mkdir $local_data, 02774 unless -d $local_data;
	$data = "$root/data";
	$system = "$root/sys";
	$cmd = "$root/cmd";
	$localcmd = "$root/local_cmd";
	$userfn = "$data/users";

	# try to create and lock a lockfile (this isn't atomic but
	# should do for now
	$lockfn = "$root/local_data/cluster.lck";       # lock file name
	if (-w $lockfn) {
		open(CLLOCK, "$lockfn") or die "Can't open Lockfile ($lockfn) $!";
		my $pid = <CLLOCK>;
		if ($pid) {
			chomp $pid;
			if (kill 0, $pid) {
				warn "Lockfile ($lockfn) and process $pid exist, another cluster running?\n";
				exit 1;
			}
		}
		unlink $lockfn;
		close CLLOCK;
	}
	open(CLLOCK, ">$lockfn") or die "Can't open Lockfile ($lockfn) $!";
	print CLLOCK "$$\n";
	close CLLOCK;

	$is_win = ($^O =~ /^MS/ || $^O =~ /^OS-2/) ? 1 : 0; # is it Windows?
	$systime = time;
	
}


use DXVars;
use SysVar;

# order here is important - DXDebug snarfs Carp et al so that Mojo errors go into the debug log
use Mojolicious 7.26;
use Mojo::IOLoop;
$DOWARN = 1;

use Msg;
use IntMsg;
use Internet;
use Listeners;
use ExtMsg;
use AGWConnect;
use AGWMsg;
use DXLog;
use DXLogPrint;
use DXUtil;
use DXChannel;
use DXUser;
use DXM;
use DXCommandmode;
use DXProtVars;
use DXProtout;
use DXProt;
use DXMsg;
use DXCron;
use DXConnect;
use DXBearing;
use DXDb;
use DXHash;
use DXDupe;
use Script;
use Prefix;
use Spot;
use Bands;
use Keps;
use Minimuf;
use Sun;
use Geomag;
use CmdAlias;
use Filter;
use AnnTalk;
use BBS;
use WCY;
use BadWords;
use DXTimer;
use Route;
use Route::Node;
use Route::User;
use Editable;
use Mrtg;
use USDB;
use UDPMsg;
use QSL;
use DXXml;
use DXSql;
use IsoTime;
use BPQMsg;
use RBN;
use DXCIDR;
use DXDebug;

use Data::Dumper;
use IO::File;
use Sys::Hostname;
use Fcntl ':flock';
use POSIX ":sys_wait_h";
use Web;

use strict;

use Local;

$lang //= 'en';					# default language
$clusteraddr //= '127.0.0.1';   # cluster tcp host address - used for things like console.pl
$clusterport //= 27754;			# cluster tcp port
$yes //= 'Yes';					# visual representation of yes
$no //= 'No';				    # ditto for no
$user_interval //= 11*60;		# the interval between unsolicited prompts if no traffic

@inqueue = ();					# the main input queue, an array of hashes
$systime = 0;					# the time now (in seconds)
$starttime = 0;                 # the starting time of the cluster
@outstanding_connects = ();     # list of outstanding connects
@listeners = ();				# list of listeners
$reqreg = 0;					# 1 = registration required, 2 = deregister people
$bumpexisting = 1;				# 1 = allow new connection to disconnect old, 0 - don't allow it
our $allowmultiple = 0;				# This is used in conjunction with $bumpexisting, in a rather weird way.
our $min_reconnection_rate = 5*60;		# minimum value of seconds between connections per user to allow co-existing users
our $max_ssid = 15;					# highest ssid to be searched for a spare one on multiple connections

# If $allowmultiple > 0 and the $reconnection_rate is some value of seconds
# based on the average connection time calculated from the $user->conntimel entries / frequency is
# less than $reconnection_rate then we assume that there is more than one device (probably HRD) trying
# to connect "at once". In which case we probe for a spare SSID for a user callsign to allow up to 
# $allowmultiple connections per callsign. 

$allowdxby = 0;					# 1 = allow "dx by <othercall>", 0 - don't allow it
$maxconnect_user = 3;			# the maximum no of concurrent connections a user can have at a time
$maxconnect_node = 0;			# Ditto but for nodes. In either case if a new incoming connection
								# takes the no of references in the routing table above these numbers
								# then the connection is refused. This only affects INCOMING connections.
$idle_interval = 0.500;	        # the wait between invocations of the main idle loop processing.
$log_flush_interval = 2;		# interval to wait between log flushes

our $ending;					# signal that we are ending;
our $broadcast_debug;			# allow broadcasting of debug info down "enhanced" user connections
our $clssecs;					# the amount of cpu time the DXSpider process have consumed
our $cldsecs;					# the amount of cpu time any child processes have consumed
our $allowslashcall;			# Allow / in connecting callsigns (ie PA0/G1TLH, or even PA0/G1TLH/2) 

our @localhost_names = qw(127.0.0.1 ::1); # all ip addresses that will need to be aliased below (ipv4 or ipv6)

our $localhost_alias_ipv4;		# these are the IPV4 & 6 aliases for localhost connected clients
our $localhost_alias_ipv6;		# for things (PC92, PC61 etc) that expose IP addresses. These *may*
                                # be set by Msg.pm stuff if they are left undefined but, if you need
                                # certanty then set/var them in the startup file.

our $save_route_cache;			# save and restore route cache on restart. Probably only useful for G1TLH testing
our $local_ipaddr;


use vars qw($version $subversion $build $gitversion $gitbranch);



# send a message to call on conn and disconnect
sub already_conn
{
	my ($conn, $call, $mess) = @_;

	$conn->disable_read(1);
	dbg("-> D $call $mess\n") if isdbg('chan');
	$conn->send_now("D$call|$mess");
	sleep(2);
	$conn->disconnect;
}

# handle incoming messages
sub new_channel
{
	my ($conn, $msg) = @_;
	my ($sort, $call, $line) = DXChannel::decode_input(0, $msg);
	return unless defined $sort;

	my ($dxchan, $user);
	
	if (is_webcall($call) && $conn->isa('IntMsg')) {
		my $newcall = find_next_webcall();
		unless ($newcall) {
			already_conn($conn, $call, "Maximum no of web connected connects ($Web::maxssid) exceeded");
			return;
		}
		$call = base_call($newcall);
		
		$user = DXUser::get_current($call);
		unless ($user) {
			$user = DXUser->new($call);
			$user->sort('W');
			$user->wantbeep(0);
			$user->name('web');
			$user->qth('on the web');
			$user->homenode($main::mycall);
			$user->lat($main::mylatitude);
			$user->long($main::mylongitude);
			$user->qra($main::mylocator);
		}
		$user->startt($main::systime);	
		$conn->conns($call);
		$dxchan = Web->new($call, $conn, $user);
		$dxchan->enhanced(1);
		$dxchan->ve7cc(1);
		$msg =~ s/^A#WEB|/A$call|/;
		$conn->send_now("C$call");
	} else {
		# "Normal" connections

		# normalise calls like G1TST-0/G1TST-00/G1TST-01 to G1TST and G1TST-1 respectively
		my $ncall = normalise_call($call);
		if ($call ne $ncall) {
			LogDbg('err', "new_channel login invalid $call converted to $ncall");
			$msg =~ s/$call/$ncall/;
			$call = $ncall;
		}
		# is it a valid callsign (in format)?
		unless (is_callsign($call)) {
			already_conn($conn, $call, DXM::msg($lang, "illcall", $call));
			return;
		}

		# is he locked out ?
		my $lock;
		$conn->conns($call);
		$user = DXUser::get_current($call);
		my $basecall = $call;
		$basecall =~ s/-\d+$//;	# remember this for later multiple user processing, it's used for other stuff than checking lockout status
		if ($user) {
			# make sure we act on any locked status that the actual incoming call has.
			$lock = $user->lockout;
		} elsif ($basecall ne $call) {
			# if there isn't a SSID on the $call, then try the base
			my $luser = DXUser::get_current($basecall);
			$lock = $luser->lockout if $luser;
		}

		# now deal with the lock
		my $host = $conn->peerhost;
		if ($lock) {
			LogDbg('', "$call on $host is locked out, disconnected");
			$conn->disconnect;
			return;
		}

		# Is he from a badip?
		if (DXCIDR::find($host)) {
			LogDbg('', "$call on $host is from a badip $host, disconnected");
			$conn->disconnect;
			return;
		}

		# set up the basic channel info for "Normal" Users
		# is there one already connected to me - locally?

		$dxchan = DXChannel::get($call);
		my $newcall = $call;
		if ($dxchan) {
			if ($user && $user->is_node) {
				already_conn($conn, $call, DXM::msg($lang, 'conother', $call, $main::mycall));
				return;
			}
			if ($allowmultiple && $user->is_user) {
				# determine whether we are a candidate, have we flip-flopped frequently enough?
				my @lastconns = @{$user->connlist} if $user->connlist;
				my $allow = 0;
				if (@lastconns >= $DXUser::maxconnlist) {
					$allow = $lastconns[-1]->[0] - $lastconns[0]->[0] < $min_reconnection_rate;
				} 
				# search for a spare ssid
			L1:	for (my $count = $call =~ /-\d+$/?0:1; $allow && $count < $allowmultiple; ) { # remember we have one call already
					my $lastid = 1;
					for (; $lastid < $max_ssid && $count < $allowmultiple; ++$lastid) {
						my $chan = DXChannel::get("$basecall-$lastid");
						if ($chan) {
							++$count;
							next;
						}
						# we have a free call-ssid, save it
						$newcall = "$basecall-$lastid";
						last L1;
					}
				}
			}

			# handle "normal" (non-multiple) connections in the existing way
			if ($call eq $newcall) {
				if ($bumpexisting) {
					my $ip = $dxchan->hostname;
					$dxchan->send_now('D', DXM::msg($lang, 'conbump', $call, $ip));
					LogDbg('', "$call bumped off by $ip, disconnected");
					$dxchan->disconnect;
				} else {
					already_conn($conn, $call, DXM::msg($lang, 'conother', $call, $main::mycall));
					return;
				}
			}

			# make sure that the conn has the (possibly) new callsign
			$conn->conns($newcall);
			$msg =~ s/$call/$newcall/;
		}


		# (fairly) politely disconnect people that are connected to too many other places at once
		my $r = Route::get($call);
		if ($conn->{sort} && $conn->{sort} =~ /^I/ && $r && $user) {
			my @n = $r->parents;
			my $m = $r->isa('Route::Node') ? $maxconnect_node : $maxconnect_user;
			my $c = $user->maxconnect;
			my $v;
			$v = defined $c ? $c : $m;
			if ($v && @n >= $v+$allowmultiple) {
				my $nodes = join ',', @n;
				LogDbg('', "$call has too many connections ($v) at $nodes - disconnected");
				already_conn($conn, $call, DXM::msg($lang, 'contomany', $call, $v, $nodes));
				return;
			}
		}
		
		if ($user) {
			$user->{lang} = $main::lang if !$user->{lang}; # to autoupdate old systems
		} else {
			$user = DXUser->new($call);
		}

		# create the channel
		# NOTE we are SHARING the same $user if $allowmultiple is > 1
		
		$user->startt($systime); # mark the start time of this connection
		if ($user->is_node) {
			$dxchan = DXProt->new($call, $conn, $user);	
		} elsif ($user->is_rbn) {
			$dxchan = RBN->new($newcall, $conn, $user);
		} elsif ($user->is_user) {
			$dxchan = DXCommandmode->new($newcall, $conn, $user);
		} else {
			die "Invalid sort of user on $call = $sort";
		}
	}
	

	# set callbacks
	$conn->set_error(sub {my $err = shift; LogDbg('', "Comms error '$err' received for call $dxchan->{call}"); $dxchan->disconnect(1);});
	$conn->set_on_eof(sub {$dxchan->disconnect});
	$conn->set_rproc(sub {my ($conn,$msg) = @_; $dxchan->rec($msg);});
	if ($sort eq 'W') {
		$dxchan->enhanced(1);
		$dxchan->sort('W');
	}
	$dxchan->rec($msg);
}


sub login
{
	return \&new_channel;
}

my $ceasing;

# cease running this program, close down all the connections nicely
sub cease
{
	my $dxchan;

	cluck("ceasing") if $ceasing; 
	
	return if $ceasing++;

	dbg("DXSpider Ceasing");
	
	unless ($is_win) {
		$SIG{'TERM'} = 'IGNORE';
		$SIG{'INT'} = 'IGNORE';
	}


	if (defined &Local::finish) {
		eval {
			Local::finish();   # end local processing
		};
		dbg("Local::finish error $@") if $@;
	}


	# disconnect AGW
	AGWMsg::finish();
	BPQMsg::finish();

	# disconnect UDP customers
	UDPMsg::finish();

	# end everything else
	QSL::finish();
	RBN::finish();
	DXDupe::finish();

	# close all databases
	DXDb::closeall;

	# Write route cache
	Route::write_cache() if $save_route_cache;
	
	# close all listeners
	foreach my $l (@listeners) {
		$l->close_server;
	}

	DXUser::finish();

	LogDbg('cluster', "DXSpider v$version build $build (git: $gitbranch/$gitversion) using perl $^V on $^O ended");
	dbg("bye bye everyone - bye bye");
	dbgclose();
	Logclose();

	$dbh->finish if $dbh;

	unlink $lockfn;
}

# the reaper of children
sub reap
{
	my $cpid;
	while (($cpid = waitpid(-1, WNOHANG)) > 0) {
		dbg("cpid: $cpid") if isdbg('reap');
#		Msg->pid_gone($cpid);
		$zombies-- if $zombies > 0;
	}
	dbg("cpid: $cpid") if isdbg('reap');
}

# this is where the input queue is dealt with and things are dispatched off to other parts of
# the cluster

sub uptime
{
	my $t = $systime - $starttime;
	my $days = int $t / 86400;
	$t -= $days * 86400;
	my $hours = int $t / 3600;
	$t -= $hours * 3600;
	my $mins = int $t / 60;
	return sprintf "%d %02d:%02d", $days, $hours, $mins;
}

sub AGWrestart
{
	AGWMsg::init(\&new_channel);
}

sub setup_start
{
	#############################################################
	#
	# The start of the main line of code
	#
	#############################################################

	chdir $root;
	
	$starttime = $systime = time;
	$systime_days = int ($systime / 86400);
	$systime_daystart = $systime_days * 86400;
	$lang = 'en' unless $lang;

	unless ($DB::VERSION) {
		$SIG{INT} = $SIG{TERM} = \&cease;
	}

	# open the debug file, set various FHs to be unbuffered
	dbginit(undef, $broadcast_debug ? \&DXCommandmode::broadcast_debug : undef);
	foreach (@debug) {
		dbgadd($_);
	}
	STDOUT->autoflush(1);

	# log our path
	dbg "Perl path: " . join(':', @INC);
	
	# try to load Encode and Git
	{
		local $^W = 0;
		my $w = $SIG{__DIE__};
		$SIG{__DIE__} = 'IGNORE';
		eval { require Encode; };
		unless ($@) {
			import Encode;
			$can_encode = 1;
		}

		$gitbranch = 'none';
		$gitversion = 'none';
		
		# determine the real Git build number and branch
		my $desc;
		eval {$desc = `git --git-dir=$root/.git describe --long`};
		if (!$@ && $desc) {
			my ($v, $s, $b, $g) = $desc =~ /^([\d\.]+)(?:\.(\d+))?-(\d+)-g([0-9a-f]+)/;
			$version = $v;
			my $subversion = $s || 0; # not used elsewhere
			$build = $b || 0;
			$gitversion = "$g\[r]";
		}
		if (!$@) {
			my @branch;

			eval {@branch = `git --git-dir=$root/.git branch`};
			unless ($@) {
				for (@branch) {
					my ($star, $b) = split /\s+/;
					if ($star eq '*') {
						$gitbranch = $b;
						last;
					}
				}
			}
		}

		$SIG{__DIE__} = $w;
	}

	unless ($is_win) {
		$SIG{HUP} = 'IGNORE';
		$SIG{CHLD} = sub { $zombies++ };

		$SIG{PIPE} = sub { 	dbg("Broken PIPE signal received"); };
		$SIG{IO} = sub { 	dbg("SIGIO received"); };
		$SIG{WINCH} = $SIG{STOP} = $SIG{CONT} = 'IGNORE';
		$SIG{KILL} = 'DEFAULT';	# as if it matters....

		# catch the rest with a hopeful message
		for (keys %SIG) {
			if (!$SIG{$_}) {
				#		dbg("Catching SIG $_") if isdbg('chan');
				$SIG{$_} = sub { my $sig = shift;	DXDebug::confess("Caught signal $sig");  };
			}
		}
	}


	# banner
	my ($year) = (gmtime)[5];
	$year += 1900;
	LogDbg('cluster', "DXSpider v$version build $build (git: $gitbranch/$gitversion) using perl $^V on $^O started");
	LogDbg('cluster', "Copyright (c) 1998-$year Dirk Koopman G1TLH");
	LogDbg('cluster', "Capabilities: ve7cc rbn");

	# prime some signals
	unless ($DB::VERSION) {
		$SIG{INT} = $SIG{TERM} = sub { $ending = 10; };
	}


	# setup location of motd & issue
	localdata_mv($motd);
	$motd = localdata($motd);
	localdata_mv("issue");
	

	# try to load XML::Simple
	DXXml::init();


	# load Prefixes
	dbg("loading prefixes ...");
	dbg(USDB::init());
	my $r = Prefix::init();
	confess $r if $r;

	# load band data
	dbg("loading band data ...");
	Bands::load();

	# initialise User file system
	dbg("loading user file system ...");
	DXUser::init(4);			# version 4 == json format

	Filter::init();				# doesn't do much, but has to be done


	# look for the sysop and the alias user and complain if they aren't there
	{
		die "\$myalias \& \$mycall are the same ($mycall)!, they must be different (hint: make \$mycall = '${mycall}-2';). Oh and don't forget to rerun create_sysop.pl!" if $mycall eq $myalias;
		my $ref = DXUser::get($mycall);
		die "\$mycall missing, run the create_sysop.pl script and please RTFM" unless $ref && $ref->priv == 9;
		my $oldsort = $ref->sort;
		if ($oldsort ne 'S') {
			$ref->sort('S');
			dbg("Resetting node type from $oldsort -> DXSpider ('S')");
		}
		$ref = DXUser::get($myalias);
		die "\$myalias missing, run the create_sysop.pl script and please RTFM" unless $ref && $ref->priv == 9;
		$oldsort = $ref->sort;
		if ($oldsort ne 'U') {
			$ref->sort('U');
			dbg("Resetting sysop user type from $oldsort -> User ('U')");
		}
	}

	# make sure that mycall, myalias and homenode are upper case;
	my $flag = 0;
	if ($mycall =~ /[a-z]/) {
		LogDbg('err', "\$mycall '$mycall' contains lower case letters, correcting");
		$mycall = uc $mycall;
		++$flag;
	}
	if ($myalias =~ /[a-z]/) {
		LogDbg('err', "\$myalias '$myalias' contains lower case letters, correcting");
		$myalias = uc $myalias;
		++$flag;
	}
	if ($flag) {
		LogDbg('err', "DXVars.pm has $flag errors. See above. Please edit DXVars.pm to correct");
		sleep 10;
	}
	
	# read any route cache there might be
	Route::read_cache() if $save_route_cache;
	
	# start listening for incoming messages/connects
	dbg("starting listeners ...");
	my $conn = IntMsg->new_server($clusteraddr, $clusterport, \&login);
	$conn->conns("Server $clusteraddr/$clusterport using IntMsg");
	push @listeners, $conn;
	dbg("Internal port: $clusteraddr $clusterport using IntMsg");
	foreach my $l (@main::listen) {
		no strict 'refs';
		my $pkg = $l->[2] || 'ExtMsg';
		my $login = $l->[3] || 'login';

		$conn = $pkg->new_server($l->[0], $l->[1], \&{"${pkg}::${login}"});
		$conn->conns("Server $l->[0]/$l->[1] using ${pkg}::${login}");
		dbg("External Port: $l->[0] $l->[1] using ${pkg}::${login}");
		push @listeners, $conn;
	}

	dbg("AGW Listener") if $AGWMsg::enable;
	AGWrestart();

	dbg("BPQ Listener") if $BPQMsg::enable;
	BPQMsg::init(\&new_channel);

	dbg("UDP Listener") if $UDPMsg::enable;
	UDPMsg::init(\&new_channel);

	# start dupe system
	dbg("Starting Dupe system");
	DXDupe::init();

	# read in system messages
	dbg("Read in Messages");
	DXM->init();

	# read in command aliases
	dbg("Read in Aliases");
	CmdAlias->init();

	# initialise the protocol engine
	dbg("Start Protocol Engines ...");
	DXProt->init();

	# read startup script
	my $script = new Script "startup";
	$script->run($main::me) if $script;


	# initialise the Geomagnetic data engine
	dbg("Start WWV system");
	Geomag->init();
	dbg("Start WCY system");
	WCY->init();
	dbg("Start Announce and Talk system");
	AnnTalk::init();			# initialise announce cache
   

	# put in a DXCluster node for us here so we can add users and take them away
	$routeroot = Route::Node->new($mycall, $version*100+5300, Route::here($main::me->here)|Route::conf($main::me->conf));
	$routeroot->do_pc9x(1);
	$routeroot->via_pc92(1);

	# make sure that there is a routing OUTPUT node default file
	#unless (Filter::read_in('route', 'node_default', 0)) {
	#	my $dxcc = $main::me->dxcc;
	#	$Route::filterdef->cmd($main::me, 'route', 'accept', "node_default call $mycall" );
	#}

	# initial the Spot stuff
	dbg("Starting DX Spot system");
	Spot->init();

	# try to load the spot database if present
	if (DXSql::init($dsn)) {
		$dbh = DXSql->new($dsn);
		$dbh = $dbh->connect($dsn, $dbuser, $dbpass) if $dbh;
	}


	# read in any existing message headers and clean out old crap
	dbg("Reading existing Message/Bulletine headers ...");
	DXMsg->init();
	DXMsg::clean_old();

	# read in any cron jobs
	dbg("Reading cron jobs ...");
	DXCron->init();

	# read in database desriptors
	dbg("Reading database descriptors ...");
	DXDb::load();

	dbg("Starting RBN ...");
	RBN::init();

	# starting local stuff
	dbg("Starting DXQsl system");
	QSL::init(1);

	# load bad words
	BadWords::load();

	# get any bad IPs 
	DXCIDR::init();

	dbg("Doing local initialisations ...");
	if (defined &Local::init) {
		eval {
			Local::init();
		};
		dbg("Local::init error $@") if $@;
	}

	$local_ipaddr = find_local_ipaddr();
	push @localhost_names, $local_ipaddr if $local_ipaddr;

	# this, such as it is, is the main loop!
	dbg("Orft we jolly well go ...");

	#open(DB::OUT, "|tee /tmp/aa");
}

our $io_disconnected;

sub idle_loop
{
	BPQMsg::process();
#	DXCommandmode::process(); # process ongoing command mode stuff
#	DXProt::process();		# process ongoing ak1a pcxx stuff

	if (defined &Local::process) {
		eval {
			Local::process();	# do any localised processing
		};
		dbg("Local::process error $@") if $@;
	}

	while ($ending) {
		my $dxchan;

		dbg("DXSpider Ending $ending");

		unless ($io_disconnected++) {

			# disconnect users
			foreach $dxchan (DXChannel::get_all_users) {
				$dxchan->disconnect;
			}

			# disconnect nodes
			foreach $dxchan (DXChannel::get_all_nodes) {
				next if $dxchan == $main::me;
				$dxchan->disconnect(2);
			}
			$main::me->disconnect;
		}

		Mojo::IOLoop->stop_gracefully if --$ending <= 0;
	}
}

sub per_sec
{
	my $timenow = time;

	reap() if $zombies;
	$systime = $timenow;
	my $days = int ($systime / 86400);
	if ($systime_days != $days) {
		$systime_days = $days;
		$systime_daystart = $days * 86400;
	}
	IsoTime::update($systime);
	DXCommandmode::process(); # process ongoing command mode stuff
	DXProt::process();		# process ongoing ak1a pcxx stuff
	DXXml::process();
	DXConnect::process();
	DXMsg::process();
	DXDb::process();
	DXUser::process();
	IsoTime::update($systime);
	DXConnect::process();
	DXUser::process();
	AGWMsg::process();
	DXCron::process();			# do cron jobs
	RBN::process();

	DXTimer::handler();
	DXLog::flushall();
}

sub per_5_sec
{
	DXDupe::clean();
}

sub per_10_sec
{
#	DXDupe::clean();
}

sub per_minute
{
	RBN::per_minute();
}

sub per_5_minute
{
#	DXProt::evey_5_minutes();
}

sub per_10_minute
{
	RBN::per_10_minute();
	Route::write_cache() if $save_route_cache;
}

sub per_hour
{
	RBN::per_hour();
}

sub per_day
{

}

sub start_node
{
	dbg("Before Web::start_node");

	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

	dbg("After Web::start_node");

}

setup_start();

my $main_loop = Mojo::IOLoop->recurring($idle_interval => \&idle_loop);
my $log_flush_loop = Mojo::IOLoop->recurring($log_flush_interval => \&DXLog::flushall);
my $cpusecs_loop = Mojo::IOLoop->recurring(5 => sub {my @t = times; $clssecs = $t[0]+$t[1]; $cldsecs = $t[2]+$t[3]});
my $persec =  Mojo::IOLoop->recurring(1 => \&per_sec);
my $per5sec =  Mojo::IOLoop->recurring(5 => \&per_5_sec);
my $per10sec =  Mojo::IOLoop->recurring(10 => \&per_10_sec);
my $permin =  Mojo::IOLoop->recurring(60 => \&per_minute);
my $per5min =  Mojo::IOLoop->recurring(600 => \&per_5_minute);
my $per10min =  Mojo::IOLoop->recurring(600 => \&per_10_minute);
my $perhour =  Mojo::IOLoop->recurring(3600 => \&per_hour);
my $perday =  Mojo::IOLoop->recurring(86400 => \&per_day);

start_node();

cease(0);

exit(0);

sub END
{
	unless ($ceasing) {
		print "DXSpider Ending\n";
		cease();
	}
}
