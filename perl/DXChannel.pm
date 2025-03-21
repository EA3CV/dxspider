#
# module to manage channel lists & data
#
# This is the base class for all channel operations, which is everything to do 
# with input and output really.
#
# The instance variable in the outside world will be generally be called $dxchan
#
# This class is 'inherited' (if that is the goobledegook for what I am doing)
# by various other modules. The point to understand is that the 'instance variable'
# is in fact what normal people would call the state vector and all useful info
# about a connection goes in there.
#
# Another point to note is that a vector may contain a list of other vectors. 
# I have simply added another variable to the vector for 'simplicity' (or laziness
# as it is more commonly called)
#
# PLEASE NOTE - I am a C programmer using this as a method of learning perl
# firstly and OO about ninthly (if you don't like the design and you can't 
# improve it with better OO and thus make it smaller and more efficient, then tough). 
#
# Copyright (c) 1998-2016 - Dirk Koopman G1TLH
#
#
#
package DXChannel;

use Msg;
use DXM;
use DXUtil;
use DXVars;
use DXDebug;
use Filter;
use Prefix;
use Route;
use DXLog;


use strict;
use vars qw(%channels %valid @ISA $count $maxerrors);

%channels = ();
$count = 0;

%valid = (
		  'sort' => '5,Type of Channel',
		  ann => '0,Want Announce,yesno',
		  ann_talk => '0,Suppress Talk Anns,yesno',
		  annfilter => '5,Ann Filt-out',
		  badcount => '1,Bad Word Count',
		  badip => '9,BAD IP address',
		  beep => '0,Want Beeps,yesno',
		  build => '1,Node Build',
		  call => '0,Callsign',
		  cmdcount => '5,Cmds in cmdinterval',
		  cmdintstart => '5,Cmd int start,atime',
		  cluster => '5,Cluster data',
		  conf => '0,In Conference?,yesno',
		  conn => '9,Msg Conn ref',
		  consort => '5,Connection Type',
		  cq => '0,CQ Zone',
		  delayed => '5,Delayed messages,parray',
		  disconnecting => '9,Disconnecting,yesno',
		  do_pc9x => '9,Handles PC9x,yesno',
		  do_pc91 => '9,Handles PC91 Spots,yesno',
		  dx => '0,DX Spots,yesno',
		  dxcc => '0,Country Code',
		  edit => '7,Edit Function',
		  enhanced => '5,Enhanced Client,yesno',
		  errors => '9,Errors',
		  func => '5,Function',
		  group => '0,Access Group,parray',
		  gtk => '5,Using GTK,yesno',
		  handle_xml => '9,Handles XML,yesno',
		  here => '0,Here?,yesno',
		  hostname => '0,Hostname',
		  inannfilter => '5,Ann Filt-inp',
		  inpc92filter => '5,PC92 Route Filt-inp',
		  inqueue => '9,Input Queue,parray',
		  inrbnfilter => '5,RBN Filt-inp',
		  inroutefilter => '5,Route Filt-inp',
		  inscript => '9,In a script,yesno',
		  inspotsfilter => '5,Spot Filt-inp',
		  inwcyfilter => '5,WCY Filt-inp',
		  inwwvfilter => '5,WWV Filt-inp',
		  isbasic => '9,Internal Connection', 
		  isolate => '5,Isolate network,yesno',
		  isslugged => '9,Still Slugged,yesno',
		  itu => '0,ITU Zone',
		  K => '9,Seen on PC92 K,yesno',
		  lang => '0,Language',
		  lastmsgpoll => '0,Last Msg Poll,atime',
		  lastping => '5,Ping last sent,atime',
		  lastread => '5,Last Msg Read',
		  list => '9,Dep Chan List',
		  loc => '9,Local Vars', # used by func to store local variables in
		  logininfo => '9,Login info req,yesno',
		  metric => '1,Route metric',
		  name => '0,User Name',
		  newroute => '1,New Style Routing,yesno',
		  next_pc92_keepalive => '9,Next PC92 KeepAlive,atime',
		  next_pc92_update => '9,Next PC92 Update,atime',
		  nopings => '5,Ping Obs Count',
		  oldstate => '5,Last State',
		  outbound => '5,outbound?,yesno',
		  pagedata => '9,Page Data Store',
		  pagelth => '0,Page Length',
		  passwd => '9,Passwd List,yesno',
		  pc50_t => '5,Last PC50 Time,atime',
		  pc92filter => '5,PC92 Route Filt-out',
		  pingave => '0,Ping ave time',
		  pingint => '5,Ping Interval ',
		  pingtime => '5,Ping totaltime,parray',
		  priv => '9,Privilege',
		  prompt => '0,Required Prompt',
		  rbnfilter => '5,RBN Filt-out',
		  rbnseeme => '0,RBN See Me,yesno',
		  redirect => '0,Redirect messages to',
		  registered => '9,Registered?,yesno',
		  remotecmd => '9,doing rcmd,yesno',
		  route => '9,Route Data',
		  routefilter => '5,Route Filt-out',
		  senddbg => '8,Sending Debug,yesno',
		  sluggedpcs => '9,Slugged PCxx Queue,parray',
		  spotsfilter => '5,Spot Filt-out',
		  startt => '0,Start Time,atime',
		  state => '0,Current State',
		  t => '9,Time,atime',
		  talk => '0,Want Talk,yesno',
		  talklist => '0,Talk List,parray',
		  user => '9,DXUser ref',
		  user_interval => '0,Prompt Idle Time',
		  ve7cc => '0,VE7CC program special,yesno',
		  verified => '9,Verified?,yesno',
		  version => '1,Node Version',
		  wcy => '0,Want WCY,yesno',
		  wcyfilter => '5,WCY Filt-out',
		  width => '0,Column Width',
		  wwv => '0,Want WWV,yesno',
		  wwvfilter => '5,WWV Filt-out',
		  wx => '0,Want WX,yesno',		  
		 );

$maxerrors = 10;				# the maximum number of concurrent errors allowed before disconnection

# object destruction
sub DESTROY
{
	my $self = shift;
	for (keys %$self) {
		if (ref($self->{$_})) {
			delete $self->{$_};
		}
	}
	dbg("DXChannel $self->{call} destroyed ($count)") if isdbg('chan');
	$count--;
}

# create a new channel object [$obj = DXChannel->new($call, $msg_conn_obj, $user_obj)]
sub alloc
{
	my ($pkg, $call, $conn, $user) = @_;
	my $self = {};
  
	die "trying to create a duplicate channel for $call" if $channels{$call};
	$self->{call} = $call;
	$self->{priv} = 0;
	$self->{conn} = $conn if defined $conn;	# if this isn't defined then it must be a list
	if (defined $user) {
		$self->{user} = $user;
		$self->{lang} = $user->lang;
		$user->new_group unless $user->group;
		$user->new_buddies unless $user->buddies;
		$self->{group} = $user->group;
		$self->{sort} = $user->sort;
		$self->{width} = $user->width;
	}
	$self->{startt} = $self->{t} = $main::systime;
	$self->{state} = 0;
	$self->{oldstate} = 0;
	$self->{lang} = $main::lang if !$self->{lang};
	$self->{func} = "";
	$self->{width} ||=  80;
	$self->{_nospawn} = 0;

	# add in all the dxcc, itu, zone info
	my @dxcc = Prefix::extract($call);
	if (@dxcc > 0) {
		$self->{dxcc} = $dxcc[1]->dxcc;
		$self->{itu} = $dxcc[1]->itu;
		$self->{cq} = $dxcc[1]->cq;
	}
	$self->{inqueue} = [];

	if ($conn) {
		$self->{hostname} = $self->{conn}->peerhost;
		$self->{sockhost} = $self->{conn}->sockhost;
	}

	$count++;
	dbg("DXChannel $self->{call} created ($count)") if isdbg('chan');
	bless $self, $pkg; 
	return $channels{$call} = $self;
}

# count errors and disconnect if too many
# this has to be here because it can come from rcmd (DXProt) as
# well as DXCommandmode.
sub _error_out
{
	my $self = shift;
	my $e = shift;
	if ($self != $main::me && ++$self->{errors} > $maxerrors) {
		$self->send($self->msg('e26'));
		LogDbg('err', "DXChannel $self->{call}: too many errors ($self->{errors} > $maxerrors), disconnecting");
		$self->disconnect;
		return ();
	} else {
		return ($e ? $self->msg($e) : '');
	}
}

# rebless this channel as something else
sub rebless
{
	my $self = shift;
	my $class = shift;
	return $channels{$self->{call}} = bless $self, $class;
}

sub rec	
{
	my ($self, $msg) = @_;
	
	# queue the message and the channel object for later processing
	if (defined $msg) {
		push @{$self->{inqueue}}, $msg;
	}
	$self->process_one;
}

# obtain a channel object by callsign [$obj = DXChannel::get($call)]
sub get
{
	my $call = shift;
	return $channels{$call};
}

# obtain all the channel objects
sub get_all
{
	return values(%channels);
}

#
# gimme all the ak1a nodes
#
sub get_all_nodes
{
	my $ref;
	my @out;
	foreach $ref (values %channels) {
		push @out, $ref if $ref->is_node;
	}
	return @out;
}

# return a list of node calls
sub get_all_node_calls
{
	my $ref;
	my @out;
	foreach $ref (values %channels) {
		push @out, $ref->{call} if $ref->is_node;
	}
	return @out;
}

# return a list of all users
sub get_all_users
{
	my $ref;
	my @out;
	foreach $ref (values %channels) {
		push @out, $ref if $ref->is_user;
	}
	return @out;
}

# return a list of all user callsigns
sub get_all_user_calls
{
	my $ref;
	my @out;
	foreach $ref (values %channels) {
		push @out, $ref->{call} if $ref->is_user;
	}
	return @out;
}

# obtain a channel object by searching for its connection reference
sub get_by_cnum
{
	my ($pkg, $conn) = @_;
	my $self;
  
	foreach $self (values(%channels)) {
		return $self if ($self->{conn} == $conn);
	}
	return undef;
}

# get rid of a channel object [$obj->del()]
sub del
{
	my $self = shift;

	$self->{group} = undef;		# belt and braces
	delete $channels{$self->{call}};
}

# is it a bbs
sub is_bbs
{
	return $_[0]->{sort} eq 'B';
}

sub is_node
{
	return $_[0]->{sort} =~ /^[ACRSXL]$/;
}
# is it an ak1a node ?
sub is_ak1a
{
	return $_[0]->{sort} eq 'A';
}

# is it a user?
sub is_user
{
	return $_[0]->{sort} =~ /^[UW]$/;
}

# is it a clx node
sub is_clx
{
	return $_[0]->{sort} eq 'C';
}

# it is a Web connected user
sub is_web
{
	return $_[0]->{sort} eq 'W';
}

# is it a spider node
sub is_spider
{
	return $_[0]->{sort} eq 'S';
}

# is it a DXNet node
sub is_dxnet
{
	return $_[0]->{sort} eq 'X';
}

# is it a ar-cluster node
sub is_arcluster
{
	return $_[0]->{sort} eq 'R';
}

sub is_rbn
{
	return $_[0]->{sort} eq 'N';
}

sub is_ccluster
{
	return $_[0]->{sort} eq 'L';
}

# for perl 5.004's benefit
sub sort
{
	my $self = shift;
	return @_ ? $self->{sort} = shift : $self->{sort} ;
}

# find out whether we are prepared to believe this callsign on this interface
sub is_believed
{
	my $self = shift;
	my $call = shift;
	
	return grep $call eq $_, $self->user->believe;
}

# handle out going messages, immediately without waiting for the select to drop
# this could, in theory, block
sub send_now
{
	my $self = shift;
	my $conn = $self->{conn};
	return unless $conn;
	my $sort = shift;
	my $call = $self->{call};
	
	for (@_) {
#		chomp;
        my @lines = split /\n/;
		for (@lines) {
			$conn->send_now("$sort$call|$_");
			# debug log it, but not if it is a log message
			dbg("-> $sort $call $_") if $sort ne 'L' && isdbg('chan');
		}
	}
	$self->{t} = time;
}

#
# send later with letter (more control)
#

sub send_later
{
	my $self = shift;
	my $conn = $self->{conn};
	return unless $conn;
	my $sort = shift;
	my $call = $self->{call};
	
	for (@_) {
#		chomp;
        my @lines = split /\n/;
		for (@lines) {
			$conn->send_later("$sort$call|$_");
			# debug log it, but not if it is a log message
			dbg("-> $sort $call $_") if $sort ne 'L' && isdbg('chan');
		}
	}
	$self->{t} = time;
}

#
# the normal output routine
#
sub send						# this is always later and always data
{
	my $self = shift;
	my $conn = $self->{conn};
	return unless $conn;
	my $call = $self->{call};

	foreach my $l (@_) {
		for (ref $l ? @$l : $l) {
			my @lines = split /\n/;
			for (@lines) {
				$conn->send_later("D$call|$_");
				dbg("-> D $call $_") if isdbg('chan');
			}
		}
	}
	$self->{t} = $main::systime;
}

# send a file (always later)
sub send_file
{
	my ($self, $fn) = @_;
	my $call = $self->{call};
	my $conn = $self->{conn};
	my @buf;
  
	open(F, $fn) or die "can't open $fn for sending file ($!)";
	@buf = <F>;
	close(F);
	$self->send(@buf);
}

# this will implement language independence (in time)
sub msg
{
	my $self = shift;
	return DXM::msg($self->{lang}, @_);
}

# stick a broadcast on the delayed queue (but only up to 20 items)
sub delay
{
	my $self = shift;
	my $s = shift;
	
	$self->{delayed} = [] unless $self->{delayed};
	push @{$self->{delayed}}, $s;
	if (@{$self->{delayed}} >= 20) {
		shift @{$self->{delayed}};   # lose oldest one
	}
}

# change the state of the channel - lots of scope for debugging here :-)
sub state
{
	my $self = shift;
	if (@_) {
		$self->{oldstate} = $self->{state};
		$self->{state} = shift;
		$self->{func} = '' unless defined $self->{func};
		dbg("$self->{call} channel func $self->{func} state $self->{oldstate} -> $self->{state}\n") if isdbg('state');

		# if there is any queued up broadcasts then splurge them out here
		if ($self->{delayed} && ($self->{state} eq 'prompt' || $self->{state} eq 'talk')) {
			$self->send (@{$self->{delayed}});
			delete $self->{delayed};
		}
	}
	return $self->{state};
}

# disconnect this channel
sub disconnect
{
	my $self = shift;
	my $user = $self->{user};
	
	$user->close($self->{startt}, $self->{hostname}) if defined $user;
	$self->{conn}->disconnect if $self->{conn};
	$self->del();
}

#
# just close all the socket connections down without any fiddling about, cleaning, being
# nice to other processes and otherwise telling them what is going on.
#
# This is for the benefit of forked processes to prepare for starting new programs, they
# don't want or need all this baggage.
#

sub closeall
{
	my $ref;
	foreach $ref (values %channels) {
		$ref->{conn}->disconnect() if $ref->{conn};
	}
}

#
# Tell all the users that we have come in or out (if they want to know)
#
sub tell_login
{
	my ($self, $m, $call) = @_;
	
	$call ||= $self->{call};
	
	# send info to all logged in thingies
	my @dxchan = get_all_users();
	my $dxchan;
	foreach $dxchan (@dxchan) {
		next if $dxchan == $self;
		next if $dxchan->{call} eq $main::mycall;
		$dxchan->send($dxchan->msg($m, $call)) if $dxchan->{logininfo};
	}
}

#
# Tell all the users if a buddy is logged or out
#
sub tell_buddies
{
	my ($self, $m, $call, $node) = @_;
	
	$call ||= $self->{call};
	$call =~ s/-\d+$//;
	$m .= 'n' if $node;
	
	# send info to all logged in thingies
	my @dxchan = get_all_users();
	my $dxchan;
	foreach $dxchan (@dxchan) {
		next if $dxchan == $self;
		next if $dxchan->{call} eq $main::mycall;
		$dxchan->send($dxchan->msg($m, $call, $node)) if grep $_ eq $call, @{$dxchan->{user}->{buddies}} ;
	}
}

# various access routines

#
# return a list of valid elements 
# 

sub fields
{
	return keys(%valid);
}

#
# return a prompt for a field
#

sub field_prompt
{ 
	my ($self, $ele) = @_;
	return $valid{$ele};
}

# take a standard input message and decode it into its standard parts
sub decode_input
{
	my $dxchan = shift;
	my $data = shift;
	my ($sort, $call, $line) = $data =~ /^([A-Z])(#?[A-Z0-9\/\-]{3,25})\|(.*)$/;

	my $chcall = (ref $dxchan) ? $dxchan->call : "UN.KNOWN";
	
	# the above regexp must work
	unless (defined $sort && defined $call && defined $line) {
#		$data =~ s/([\x00-\x1f\x7f-\xff])/uc sprintf("%%%02x",ord($1))/eg;
		dbg("DUFF Line on $chcall: $data");
		return ();
	}

	if(ref($dxchan) && $call ne $chcall) {
		dbg("DUFF Line come in for $call on wrong channel $chcall");
		return();
	}
	
	return ($sort, $call, $line);
}

# broadcast a message to all clusters taking into account isolation
# [except those mentioned after buffer]
sub broadcast_nodes
{
	my $s = shift;				# the line to be rebroadcast
	my @except = @_;			# to all channels EXCEPT these (dxchannel refs)
	my @dxchan = get_all_nodes();
	my $dxchan;
	
	# send it if it isn't the except list and isn't isolated and still has a hop count
	foreach $dxchan (@dxchan) {
		next if grep $dxchan == $_, @except;
		next if $dxchan == $main::me;
		
		my $routeit = $dxchan->can('adjust_hops') ? $dxchan->adjust_hops($s) : $s;      # adjust its hop count by node name

		$dxchan->send($routeit) unless $dxchan->{isolate} || !$routeit;
	}
}

# broadcast a message to all clusters ignoring isolation
# [except those mentioned after buffer]
sub broadcast_all_nodes
{
	my $s = shift;				# the line to be rebroadcast
	my @except = @_;			# to all channels EXCEPT these (dxchannel refs)
	my @dxchan = get_all_nodes();
	my $dxchan;
	
	# send it if it isn't the except list and isn't isolated and still has a hop count
	foreach $dxchan (@dxchan) {
		next if grep $dxchan == $_, @except;
		next if $dxchan == $main::me;

		my $routeit = $dxchan->can('adjust_hops') ? $dxchan->adjust_hops($s) : $s;      # adjust its hop count by node name
		$dxchan->send($routeit);
	}
}

# broadcast to all users
# storing the spot or whatever until it is in a state to receive it
sub broadcast_users
{
	my $s = shift;				# the line to be rebroadcast
	my $sort = shift;           # the type of transmission
	my $fref = shift;           # a reference to an object to filter on
	my @except = @_;			# to all channels EXCEPT these (dxchannel refs)
	my @dxchan = get_all_users();
	my $dxchan;
	my @out;
	
	foreach $dxchan (@dxchan) {
		next if grep $dxchan == $_, @except;
		push @out, $dxchan;
	}
	broadcast_list($s, $sort, $fref, @out);
}


# broadcast to a list of users
sub broadcast_list
{
	my $s = shift;
	my $sort = shift;
	my $fref = shift;
	my $dxchan;
	
	foreach $dxchan (@_) {
		my $filter = 1;
		next if $dxchan == $main::me;
		
		if ($sort eq 'dx') {
		    next unless $dxchan->{dx};
			($filter) = $dxchan->{spotsfilter}->it($fref) if $dxchan->{spotsfilter} && ref $fref;
			next unless $filter;
		}
		next if $sort eq 'ann' && !$dxchan->{ann} && $s !~ /^To\s+LOCAL\s+de\s+(?:$main::myalias|$main::mycall)/i;
		next if $sort eq 'wwv' && !$dxchan->{wwv};
		next if $sort eq 'wcy' && !$dxchan->{wcy};
		next if $sort eq 'wx' && !$dxchan->{wx};

		$s =~ s/\a//og unless $dxchan->{beep};

		if ($dxchan->{state} eq 'prompt' || $dxchan->{state} eq 'talk') {
			$dxchan->send($s);	
		} else {
			$dxchan->delay($s);
		}
	}
}

sub process_one
{
	my $self = shift;

	while (my $data = shift @{$self->{inqueue}}) {
		my ($sort, $call, $line) = $self->decode_input($data);
		next unless defined $sort;

		if ($sort ne 'D') {
			if (isdbg('chan')) {
				if (($self->is_rbn && isdbg('rbnchan')) || !$self->is_rbn) {
					dbg("<- $sort $call $line") if isdbg('chan'); # you may think this is tautology, but it's needed get the correct label on the debug line
				}
			}
		}
		
		# handle A records
		my $user = $self->user;
		if ($sort eq 'I') {
			die "\$user not defined for $call" unless defined $user;
			
			# normal input
			$self->normal($line);
		} elsif ($sort eq 'G') {
			$self->enhanced($line);
		} elsif ($sort eq 'A' || $sort eq 'O' || $sort eq 'W') {
			$self->start($line, $sort);
		} elsif ($sort eq 'C') {
			$self->width($line); # change number of columns
		} elsif ($sort eq 'Z') {
			$self->disconnect;
		} elsif ($sort eq 'D') {
			;				# ignored (an echo)
		} else {
			dbg atime . " DXChannel::process_one: Unknown command letter ($sort) received from $call\n";
		}
	}
}

sub process
{
	foreach my $dxchan (values %channels) {
		next if $dxchan->{disconnecting};
		$dxchan->process_one;
	}
}

sub handle_xml
{
	my $self = shift;
	my $r = 0;
	
	if (DXXml::available()) {
		$r = $self->{handle_xml} || 0;
	} else {
		delete $self->{handle_xml} if exists $self->{handle_xml};
	}
	return $r;
}

sub error_handler
{
	my $self = shift;
	my $error = shift || '';
	dbg("$self->{call} ERROR '$error', closing") if isdbg('chan');
	$self->{conn}->set_error(undef) if exists $self->{conn};
	$self->disconnect(1);
}

sub refresh_user
{
	my $call = shift;
	my $user = shift;
	return unless $call && $user && ref $user;
	my $self = DXChannel::get($call);
	$self->{user} = $user;
	return $user;
}

sub isregistered
{
	my $self = shift;

	# the sysop is registered!
	return 1 if $self->{call} eq $main::myalias || $self->{call} eq $main::mycall;
	
	if ($main::reqreg) {
		return $self->{registered};
	} else {
		return 1;
	}
}

# try to replace the in-core version of the dxchan with the one that has been modified with items like filters
sub replace
{
	my $self = shift;
	my $call = shift;
	if (ref $self) {
		$call ||= $self->{call};
		$channels{$call} = $self; 
	} 
}

#no strict;
sub AUTOLOAD
{
	no strict;
	my $name = $AUTOLOAD;
	return if $name =~ /::DESTROY$/;
	$name =~ s/^.*:://o;
  
	confess "Non-existant field '$AUTOLOAD'" if !$valid{$name};

	# this clever line of code creates a subroutine which takes over from autoload
	# from OO Perl - Conway
	*$AUTOLOAD = sub {@_ > 1 ? $_[0]->{$name} = $_[1] : $_[0]->{$name}};
	goto &$AUTOLOAD;
}


1;
__END__;
