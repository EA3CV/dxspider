#!/usr/bin/perl
#
# This module impliments the message handling for a dx cluster
#
# Copyright (c) 1998 Dirk Koopman G1TLH
#
#
#
#
# Notes for implementors:-
#
# PC28 field 11 is the RR required flag
# PC28 field 12 is a VIA routing (ie it is a node call) 
#

package DXMsg;

use DXUtil;
use DXChannel;
use DXUser;
use DXM;
use DXProtVars;
use DXProtout;
use DXDebug;
use DXLog;
use IO::File;
use Fcntl;

eval {
	require Net::SMTP;
};

use strict;

use vars qw(%work @msg $msgdir %valid %busy $maxage $last_clean $residencetime
			@badmsg @swop $swopfn $badmsgfn $forwardfn @forward $timeout $waittime
			$email_server $email_prog $email_from
		    $queueinterval $lastq $importfn $minchunk $maxchunk $bulltopriv);

%work = ();						# outstanding jobs
@msg = ();						# messages we have
%busy = ();						# station interlocks
$msgdir = "$main::root/msg";	# directory contain the msgs
$maxage = 30 * 86400;			# the maximum age that a message shall live for if not marked 
$last_clean = 0;				# last time we did a clean
@forward = ();                  # msg forward table
@badmsg = ();					# bad message table
@swop = ();						# swop table
$timeout = 30*60;               # forwarding timeout
$waittime = 30*60;              # time an aborted outgoing message waits before trying again
$queueinterval = 1*60;          # run the queue every 1 minute
$lastq = 0;

$minchunk = 4800;               # minimum chunk size for a split message
$maxchunk = 6000;               # maximum chunk size
$bulltopriv = 1;				# convert msgs with callsigns to private if they are bulls
$residencetime = 2*86400;       # keep deleted messages for this amount of time
$email_server = undef;			# DNS address of smtp server if 'smtp'
$email_prog = undef;			# program name + args for sending mail
$email_from = undef;			# the from address the email will appear to be from

$badmsgfn = "$msgdir/badmsg.pl";    # list of TO address we wont store
$forwardfn = "$msgdir/forward.pl";  # the forwarding table
$swopfn = "$msgdir/swop.pl";        # the swopping table
$importfn = "$msgdir/import";       # import directory


%valid = (
		  'read' => '5,Times read',
		  count => '5,Gob Linecnt',
		  delete => '5,Awaiting Delete,yesno',
		  deletetime => '5,Deletion Time,cldatetime',
		  file => '5,File?,yesno',
		  from => '0,From',
		  fromnode => '5,From Node',
		  gotit => '5,Got it Nodes,parray',
		  keep => '0,Keep this?,yesno',
		  lastt => '5,Last processed,cldatetime',
		  lines => '5,Data',
		  lines => '5,Lines,parray',
		  linesreq => '0,Lines per Gob',
		  msgno => '0,Msgno',
		  origin => '0,Origin',
		  private => '5,Private,yesno',
		  rrreq => '5,Read Confirm,yesno',
		  size => '0,Size',
		  stream => '9,Stream No',
		  subject => '0,Subject',
		  t => '0,Msg Time,cldatetime',
		  to => '0,To',
		  tonode => '5,To Node',
		  waitt => '5,Wait until,cldatetime',
		 );

# fix up the default sendmail if available
for (qw(/usr/sbin/sendmail /usr/lib/sendmail /usr/sbin/sendmail)) {
	if (-e $_) {
		$email_prog = $_;
		last;
	}
}

# allocate a new object
# called fromnode, tonode, from, to, datetime, private?, subject, nolinesper  
sub alloc                  
{
	my $pkg = shift;
	my $self = bless {}, $pkg;
	$self->{msgno} = shift;
	my $to = shift;
	#  $to =~ s/-\d+$//o;
	$self->{to} = ($to eq $main::mycall) ? $main::myalias : $to;
	my $from = shift;
	$self->{from} = uc $from;
	$self->{t} = shift;
	$self->{private} = shift;
	$self->{subject} = shift;
	$self->{origin} = shift;
	$self->{'read'} = shift;
	$self->{rrreq} = shift;
	$self->{delete} = shift;
	$self->{deletetime} = shift || ($self->{t} + $maxage);
	$self->{keep} = shift;
	$self->{gotit} = [];
#	$self->{lastt} = $main::systime;
	$self->{lines} = [];
	$self->{private} = 1 if $bulltopriv && DXUser::get_current($self->{to});
    
	return $self;
}


sub process
{
	# this is periodic processing
	if ($main::systime >= $lastq + $queueinterval) {

		# queue some message if the interval timer has gone off
		queue_msg(0);
		
		# import any messages in the import directory
		import_msgs();
		
		$lastq = $main::systime;
	}

	# clean the message queue
	if ($main::systime >= $last_clean+3600) {
		clean_old();
		$last_clean = $main::systime;
	}
	
	# actual remove all the 'deleted' messages in one hit.
	# this has to be delayed until here otherwise it only does one at 
	# a time because @msg is rewritten everytime del_msg is called.
	my @del = grep {!$_->{tonode} && $_->{delete} && !$_->{keep} && $_->{deletetime} < $main::systime} @msg;
	for (@del) {
		$_->del_msg;
	}
	
}

# incoming message
sub handle_28
{
	my $dxchan = shift;
	my ($tonode, $fromnode) = @_[1..2];

	# sort out various extant protocol errors that occur
	my $origin = $_[13];
	$origin = $dxchan->call unless $origin && $origin gt ' ';

	# first look for any messages in the busy queue 
	# and cancel them this should both resolve timed out incoming messages
	# and crossing of message between nodes, incoming messages have priority

	my $ref = get_busy($fromnode);
	if ($ref) {
		my $otonode = $ref->{tonode} || "unknown";
		dbg("Busy, stopping msgno: $ref->{msgno} $fromnode->$otonode") if isdbg('msg');
		$ref->stop_msg($fromnode);
	}

	my $t = cltounix($_[5], $_[6]);
	my $stream = next_transno($fromnode);
	$ref = DXMsg->alloc($stream, uc $_[3], $_[4], $t, $_[7], $_[8], $origin, '0', $_[11]);
			
	# fill in various forwarding state variables
	$ref->{fromnode} = $fromnode;
	$ref->{tonode} = $tonode;
	$ref->{rrreq} = $_[11];
	$ref->{linesreq} = $_[10];
	$ref->{stream} = $stream;
	$ref->{count} = 0;			# no of lines between PC31s
	dbg("new message from $_[4] to $_[3] '$_[8]' stream $fromnode/$stream\n") if isdbg('msg');
	Log('msg', "Incoming message $_[4] to $_[3] '$_[8]' origin: $origin" );
	set_fwq($fromnode, $stream, $ref); # store in work
	set_busy($fromnode, $ref);	# set interlock
	$dxchan->send(DXProt::pc30($fromnode, $tonode, $stream)); # send ack
	$ref->{lastt} = $main::systime;

	# look to see whether this is a non private message sent to a known callsign
	my $uref = DXUser::get_current($ref->{to});
	if (is_callsign($ref->{to}) && !$ref->{private} && $uref && $uref->homenode) {
		$ref->{private} = 1;
		dbg("set bull to $ref->{to} to private") if isdbg('msg');
		Log('msg', "set bull to $ref->{to} to private");
	}
}
		
# incoming text
sub handle_29
{
	my $dxchan = shift;
	my ($tonode, $fromnode, $stream) = @_[1..3];
	
	my $ref = get_fwq($fromnode, $stream);
	if ($ref) {
		$_[4] =~ s/\%5E/~/g;
		if (@{$ref->{lines}}) {
			push @{$ref->{lines}}, $_[4];
		} else {
			# temporarily store any R: lines so that we end up with 
			# only the first and last ones stored.
			if ($_[4] =~ m|^R:\d{6}/\d{4}|) {
				push @{$ref->{tempr}}, $_[4];
			} else {
				if (exists $ref->{tempr}) {
					push @{$ref->{lines}}, shift @{$ref->{tempr}};
					push @{$ref->{lines}}, pop @{$ref->{tempr}} if @{$ref->{tempr}};
					delete $ref->{tempr};
				}
				push @{$ref->{lines}}, $_[4];
			} 
		}
		$ref->{count}++;
		if ($ref->{count} >= $ref->{linesreq}) {
			$dxchan->send(DXProt::pc31($fromnode, $tonode, $stream));
			dbg("stream $stream: $ref->{count} lines received\n") if isdbg('msg');
			$ref->{count} = 0;
		}
		$ref->{lastt} = $main::systime;
	} else {
		dbg("PC29 from unknown stream $stream from $fromnode") if isdbg('msg');
		$dxchan->send(DXProt::pc42($fromnode, $tonode, $stream));	# unknown stream
	}
}
		
# this is a incoming subject ack
sub handle_30
{
	my $dxchan = shift;
	my ($tonode, $fromnode, $stream) = @_[1..3];

	my $ref = get_fwq($fromnode); # note no stream at this stage
	if ($ref) {
		del_fwq($fromnode);
		$ref->{stream} = $stream;
		$ref->{count} = 0;
		$ref->{linesreq} = 5;
		set_fwq($fromnode, $stream, $ref); # new ref
		set_busy($fromnode, $ref); # interlock
		dbg("incoming subject ack stream $stream\n") if isdbg('msg');
		$ref->{lines} = [ $ref->read_msg_body ];
		$ref->send_tranche($dxchan);
		$ref->{lastt} = $main::systime;
	} else {
		dbg("PC30 from unknown stream $stream from $fromnode") if isdbg('msg');
		$dxchan->send(DXProt::pc42($fromnode, $tonode, $stream));	# unknown stream
	} 
}
		
# acknowledge a tranche of lines
sub handle_31
{
	my $dxchan = shift;
	my ($tonode, $fromnode, $stream) = @_[1..3];

	my $ref = get_fwq($fromnode, $stream);
	if ($ref) {
		dbg("tranche ack stream $stream\n") if isdbg('msg');
		$ref->send_tranche($dxchan);
		$ref->{lastt} = $main::systime;
	} else {
		dbg("PC31 from unknown stream $stream from $fromnode") if isdbg('msg');
		$dxchan->send(DXProt::pc42($fromnode, $tonode, $stream));	# unknown stream
	} 
}
		
# incoming EOM
sub handle_32
{
	my $dxchan = shift;
	my ($tonode, $fromnode, $stream) = @_[1..3];

	dbg("stream $stream: EOM received\n") if isdbg('msg');
	my $ref = get_fwq($fromnode, $stream);
	if ($ref) {
		$dxchan->send(DXProt::pc33($fromnode, $tonode, $stream));	# acknowledge it
				
		# get the next msg no - note that this has NOTHING to do with the stream number in PC protocol
		# store the file or message
		# remove extraneous rubbish from the hash
		# remove it from the work in progress vector
		# stuff it on the msg queue
		if ($ref->{lines}) {
			if ($ref->{file}) {
				$ref->store($ref->{lines});
			} else {

				# is it too old
				if ($ref->{t}+$maxage < $main::systime ) {
					$ref->stop_msg($fromnode);
					dbg("old message from $ref->{from} -> $ref->{to} " . atime($ref->{t}) . " ignored") if isdbg('msg');
					Log('msg', "old message from $ref->{from} -> $ref->{to} " . cldatetime($ref->{t}) . " ignored");
					return;
				}

				# does an identical message already exist?
				my $m;
				for $m (@msg) {
					if (substr($ref->{subject},0,28) eq substr($m->{subject},0,28) && $ref->{t} == $m->{t} && $ref->{from} eq $m->{from} && $ref->{to} eq $m->{to}) {
						$ref->stop_msg($fromnode);
						my $msgno = $m->{msgno};
						dbg("duplicate message from $ref->{from} -> $ref->{to} to msg: $msgno") if isdbg('msg');
						Log('msg', "duplicate message from $ref->{from} -> $ref->{to} to msg: $msgno");
						return;
					}
				}

				# swop addresses
				$ref->swop_it($dxchan->call);
						
				# look for 'bad' to addresses 
				if ($ref->dump_it($dxchan->call)) {
					$ref->stop_msg($fromnode);
					dbg("'Bad' message $ref->{to}") if isdbg('msg');
					Log('msg', "'Bad' message $ref->{to}");
					return;
				}

				# check the message for bad words 
				my @bad;
				my @words;
				@bad = BadWords::check($ref->{subject});
				push @words, [$ref->{subject}, @bad] if @bad; 
				for (@{$ref->{lines}}) {
					@bad = BadWords::check($_);
					push @words, [$_, @bad] if @bad;
				}
				if (@words) {
					LogDbg('msg',"$ref->{from} swore: $ref->{to} origin: $ref->{origin} via " . $dxchan->call);
					LogDbg('msg',"subject: $ref->{subject}");
					for (@words) {
						my $r = $_;
						my $line = shift @$r;
						LogDbg('msg', "line: $line (using words: ". join(',', @$r).")");
					}
					$ref->stop_msg($fromnode);
					return;
				}
							
				$ref->{msgno} = next_transno("Msgno");
				push @{$ref->{gotit}}, $fromnode; # mark this up as being received
				$ref->store($ref->{lines});
				$ref->notify;
				add_dir($ref);
				Log('msg', "Message $ref->{msgno} from $ref->{from} received from $fromnode for $ref->{to}");
			}
		}
		$ref->stop_msg($fromnode);
	} else {
		dbg("PC32 from unknown stream $stream from $fromnode") if isdbg('msg');
		$dxchan->send(DXProt::pc42($fromnode, $tonode, $stream));	# unknown stream
	}
	# queue_msg(0);
}
		
# acknowledge the end of message
sub handle_33
{
	my $dxchan = shift;
	my ($tonode, $fromnode, $stream) = @_[1..3];
	
	my $ref = get_fwq($fromnode, $stream);
	if ($ref) {
		if ($ref->{private}) {	# remove it if it private and gone off site#
			Log('msg', "Message $ref->{msgno} from $ref->{from} sent to $fromnode and deleted");
			$ref->mark_delete;
		} else {
			Log('msg', "Message $ref->{msgno} from $ref->{from} sent to $fromnode");
			push @{$ref->{gotit}}, $fromnode; # mark this up as being received
			$ref->store($ref->{lines});	# re- store the file
		}
		$ref->stop_msg($fromnode);
	} else {
		dbg("PC33 from unknown stream $stream from $fromnode") if isdbg('msg');
		$dxchan->send(DXProt::pc42($fromnode, $tonode, $stream));	# unknown stream
	} 

	# send next one if present
	queue_msg(0);
}
		
# this is a file request
sub handle_40
{
	my $dxchan = shift;
	my ($tonode, $fromnode) = @_[1..2];
	
	$_[3] =~ s/\\/\//og;		# change the slashes
	$_[3] =~ s/\.//og;			# remove dots
	$_[3] =~ s/^\///o;			# remove the leading /
	$_[3] = lc $_[3];			# to lower case;
	dbg("incoming file $_[3]\n") if isdbg('msg');
	$_[3] = 'packclus/' . $_[3] unless $_[3] =~ /^packclus\//o;
			
	# create any directories
	my @part = split /\//, $_[3];
	my $part;
	my $fn = "$main::root";
	pop @part;					# remove last part
	foreach $part (@part) {
		$fn .= "/$part";
		next if -e $fn;
		last SWITCH if !mkdir $fn, 0777;
		dbg("created directory $fn\n") if isdbg('msg');
	}
	my $stream = next_transno($fromnode);
	my $ref = DXMsg->alloc($stream, "$main::root/$_[3]", $dxchan->call, time, !$_[4], $_[3], ' ', '0', '0');
			
	# forwarding variables
	$ref->{fromnode} = $tonode;
	$ref->{tonode} = $fromnode;
	$ref->{linesreq} = $_[5];
	$ref->{stream} = $stream;
	$ref->{count} = 0;			# no of lines between PC31s
	$ref->{file} = 1;
	$ref->{lastt} = $main::systime;
	set_fwq($fromnode, $stream, $ref); # store in work
	$dxchan->send(DXProt::pc30($fromnode, $tonode, $stream)); # send ack 
}
		
# abort transfer
sub handle_42
{
	my $dxchan = shift;
	my ($tonode, $fromnode, $stream) = @_[1..3];
	
	dbg("stream $stream: abort received\n") if isdbg('msg');
	my $ref = get_fwq($fromnode, $stream);
	if ($ref) {
		$ref->stop_msg($fromnode);
		$ref = undef;
	}
}

# global delete on subject
sub handle_49
{
	my $dxchan = shift;
	my $line = shift;
	
	for (@msg) {
		if ($_->{from} eq $_[1] && $_->{subject} eq $_[2]) {
			$_->mark_delete;
			Log('msg', "Message $_->{msgno} from $_->{from} ($_->{subject}) fully deleted");
			DXChannel::broadcast_nodes($line, $dxchan);
		}
	}
}



sub notify
{
	my $ref = shift;
	my $to = $ref->{to};
	my $uref = DXUser::get_current($to);
	my $dxchan = DXChannel::get($to);
	if (((*Net::SMTP && $email_server) || $email_prog) && $uref && $uref->wantemail) {
		my $email = $uref->email;
		if ($email) {
			my @rcpt = ref $email ? @{$email} : $email;
			my $fromaddr = $email_from || $main::myemail;
			my @headers = ("To: $ref->{to}", 
						   "From: $fromaddr",
						   "Subject: [DXSpider: $ref->{from}\@$ref->{origin}] $ref->{subject}", 
						   "X-DXSpider-To: $ref->{to}",
						   "X-DXSpider-From: $ref->{from}\@$ref->{origin}", 
						   "X-DXSpider-Gateway: $main::mycall"
						  );
			my @data = ("Msgno: $ref->{msgno} To: $to From: $ref->{from}\@$ref->{origin} Gateway: $main::mycall", 
						"", 
						$ref->read_msg_body
					   );
			my $msg;
			undef $!;
			if (*Net::SMTP && $email_server) {
				$msg = Net::SMTP->new($email_server);
				if ($msg) {
					$msg->mail($fromaddr);
					$msg->to(@rcpt);
					$msg->data(map {"$_\n"} @headers, '', @data);
					$msg->quit;
				}
			} elsif ($email_prog) {
				$msg = new IO::File "|$email_prog " . join(' ', @rcpt);
				if ($msg) {
					print $msg map {"$_\r\n"} @headers, '', @data, '.';
					$msg->close;
				}
			}
			dbg("email forwarding error $!") if isdbg('msg') && !$msg && defined $!; 
		}
	}
	$dxchan->send($dxchan->msg('m9')) if $dxchan && $dxchan->is_user;
}

# store a message away on disc or whatever
#
# NOTE the second arg is a REFERENCE not a list
sub store
{
	my $ref = shift;
	my $lines = shift;

	if ($ref->{file}) {			# a file
		dbg("To be stored in $ref->{to}\n") if isdbg('msg');
		
		my $fh = new IO::File "$ref->{to}", "w";
		if (defined $fh) {
			my $line;
			foreach $line (@{$lines}) {
				print $fh "$line\n";
			}
			$fh->close;
			dbg("file $ref->{to} stored\n") if isdbg('msg');
			Log('msg', "file $ref->{to} from $ref->{from} stored" );
		} else {
			confess "can't open file $ref->{to} $!";  
		}
	} else {					# a normal message

		# attempt to open the message file
		my $fn = filename($ref->{msgno});
		
		dbg("To be stored in $fn\n") if isdbg('msg');
		
		# now save the file, overwriting what's there, YES I KNOW OK! (I will change it if it's a problem)
		my $fh = new IO::File "$fn", "w";
		if (defined $fh) {
			my $rr = $ref->{rrreq} ? '1' : '0';
			my $priv = $ref->{private} ? '1': '0';
			my $del = $ref->{delete} ? '1' : '0';
			my $delt = $ref->{deletetime} || ($ref->{t} + $maxage);
			my $keep = $ref->{keep} || '0';
			print $fh "=== $ref->{msgno}^$ref->{to}^$ref->{from}^$ref->{t}^$priv^$ref->{subject}^$ref->{origin}^$ref->{'read'}^$rr^$del^$delt^$keep\n";
			print $fh "=== ", join('^', @{$ref->{gotit}}), "\n";
			my $line;
			$ref->{size} = 0;
			foreach $line (@{$lines}) {
				$line =~ s/[\x00-\x08\x0a-\x1f\x80-\x9f]/./g;
				$ref->{size} += (length $line) + 1;
				print $fh "$line\n";
			}
			$fh->close;
			dbg("msg $ref->{msgno} stored\n") if isdbg('msg');
			Log('msg', "msg $ref->{msgno} from $ref->{from} to $ref->{to} stored" );
		} else {
			confess "can't open msg file $fn $!";  
		}
	}

}

# delete a message
sub del_msg
{
	my $self = shift;
	my $dxchan = shift;
	my $call = '';
	$call = ' by ' . $dxchan->call if $dxchan;
	
	if ($self->{tonode}) {
		$self->{delete}++;
		$self->{deletetime} = 0;
		dbg("Msgno $self->{msgno} but marked as expunged$call") if isdbg('msg');
	} else {
		# remove it from the active message list
		@msg = grep { $_ != $self } @msg;

		Log('msg', "Msgno $self->{msgno} expunged$call");
		dbg("Msgno $self->{msgno} expunged$call") if isdbg('msg');
		
		# remove the file
		unlink filename($self->{msgno});
	}
}

sub mark_delete
{
	my $ref = shift;
	my $t = shift;

	return if $ref->{keep};
	
	$t = $main::systime + $residencetime unless defined $t;
	
	$ref->{delete}++;
	$ref->{deletetime} = $t;
	$ref->store( [$ref->read_msg_body] );
}

sub unmark_delete
{
	my $ref = shift;
	my $t = shift;
	$ref->{delete} = 0;
	$ref->{deletetime} = 0;
}

# clean out old messages from the message queue
sub clean_old
{
	my $ref;
	
	# mark old messages for deletion
	foreach $ref (@msg) {
		if (ref($ref) && !$ref->{keep} && $ref->{deletetime} < $main::systime) {

			# this is for IMMEDIATE destruction
			$ref->{delete}++;
			$ref->{deletetime} = 0;
		}
	}
}

# read in a message header
sub read_msg_header
{ 
	my $fn = shift;
	my $file;
	my $line;
	my $ref;
	my @f;
	my $size;
	
	$file = new IO::File "$fn";
	if (!$file) {
	    dbg("Error reading $fn $!");
	    Log('err', "Error reading $fn $!");
		return undef;
	}
	$size = -s $fn;
	$line = <$file>;			# first line
	if ($size == 0 || !$line) {
	    dbg("Empty $fn $!");
	    Log('err', "Empty $fn $!");
		return undef;
	}
	chomp $line;
	$size -= length $line;
	if ($line !~ /^===/o) {
		dbg("corrupt first line in $fn ($line)");
		Log('err', "corrupt first line in $fn ($line)");
		return undef;
	}
	$line =~ s/^=== //o;
	@f = split /\^/, $line;
	$ref = DXMsg->alloc(@f);
	
	$line = <$file>;			# second line
	chomp $line;
	$size -= length $line;
	if (! $line =~ /^===/o) {
	    dbg("corrupt second line in $fn ($line)");
	    Log('err', "corrupt second line in $fn ($line)");
		return undef;
	}
	$line =~ s/^=== //o;
	$ref->{gotit} = [];
	@f = split /\^/, $line;
	push @{$ref->{gotit}}, @f;
	$ref->{size} = $size;
	
	close($file);
	
	return $ref;
}

# read in a message header
sub read_msg_body
{
	my $self = shift;
	my $msgno = $self->{msgno};
	my $file;
	my $line;
	my $fn = filename($msgno);
	my @out;
	
	$file = new IO::File;
	if (!open($file, $fn)) {
		dbg("Error reading $fn $!");
		Log('err' ,"Error reading $fn $!");
		return ();
	}
	@out = map {chomp; $_} <$file>;
	close($file);
	
	shift @out if $out[0] =~ /^=== /;
	shift @out if $out[0] =~ /^=== /;
	return @out;
}

# send a tranche of lines to the other end
sub send_tranche
{
	my ($self, $dxchan) = @_;
	my @out;
	my $to = $self->{tonode};
	my $from = $self->{fromnode};
	my $stream = $self->{stream};
	my $lines = $self->{lines};
	my ($c, $i);
	
	for ($i = 0, $c = $self->{count}; $i < $self->{linesreq} && $c < @$lines; $i++, $c++) {
		push @out, DXProt::pc29($to, $from, $stream, $lines->[$c]);
    }
    $self->{count} = $c;

    push @out, DXProt::pc32($to, $from, $stream) if $i < $self->{linesreq};
	$dxchan->send(@out);
}

	
# find a message to send out and start the ball rolling
sub queue_msg
{
	my $sort = shift;
	my $ref;
	my $clref;
	
	# bat down the message list looking for one that needs to go off site and whose
	# nearest node is not busy.

	dbg("queue msg ($sort)\n") if isdbg('msg');
	my @nodelist = DXChannel::get_all_nodes;
	foreach $ref (@msg) {

		# ignore 'delayed' messages until their waiting time has expired
		if (exists $ref->{waitt}) {
			next if $ref->{waitt} > $main::systime;
			delete $ref->{waitt};
		} 

		# any time outs?
		if (exists $ref->{lastt} && $main::systime >= $ref->{lastt} + $timeout) {
			my $node = $ref->{tonode};
			dbg("Timeout, stopping msgno: $ref->{msgno} -> $node") if isdbg('msg');
			Log('msg', "Timeout, stopping msgno: $ref->{msgno} -> $node");
			$ref->stop_msg($node);
			
			# delay any outgoing messages that fail
			$ref->{waitt} = $main::systime + $waittime + int rand(120) if $node ne $main::mycall;
			delete $ref->{lastt};
			next;
		}

		# is it being sent anywhere currently?
		next if $ref->{tonode};	          # ignore it if it already being processed
		
		# is it awaiting deletion?
		next if $ref->{delete};
		
		# firstly, is it private and unread? if so can I find the recipient
		# in my cluster node list offsite?

		# deal with routed private messages
		my $dxchan;
		if ($ref->{private}) {
			next if $ref->{'read'};           # if it is read, it is stuck here
			$clref = Route::get($ref->{to});
			if ($clref) {
				$dxchan = $clref->dxchan;
				if ($dxchan) {
					if ($dxchan->is_node) {
						next if $clref->call eq $main::mycall;  # i.e. it lives here
						next if $dxchan->is_arcluster;			# don't even go there, idiot people send the header in the wrong order and won't/can't fix it
						next if $dxchan->isolate;				# there is no mechanism for sending messages to isolated nodes. 
						$ref->start_msg($dxchan) if !get_busy($dxchan->call)  && $dxchan->state eq 'normal';
					}
				} else {
					dbg("Route: No dxchan for $ref->{to} " . ref($clref) ) if isdbg('msg');
				}
			}
		} else {
			
			# otherwise we are dealing with a bulletin or forwarded private message
			# compare the gotit list with
			# the nodelist up above, if there are sites that haven't got it yet
			# then start sending it - what happens when we get loops is anyone's
			# guess, use (to, from, time, subject) tuple?
			foreach $dxchan (@nodelist) {
				my $call = $dxchan->call;
				next unless $call;
				next if $call eq $main::mycall;
				next if ref $ref->{gotit} && grep $_ eq $call, @{$ref->{gotit}};
				next unless $ref->forward_it($call);    # check the forwarding file
				next if $ref->{tonode};	                # ignore it if it already being processed
				next if $dxchan->is_arcluster;			# don't even go there, idiot people send the header in the wrong order and won't/can't fix it
				next if $dxchan->isolate;				# there is no mechanism for sending messages to isolated nodes. 
				
				# if we are here we have a node that doesn't have this message
				if (!get_busy($call)  && $dxchan->state eq 'normal') {
					$ref->start_msg($dxchan);
					last;
				}
			}
		}

		# if all the available nodes are busy then stop
		last if @nodelist == scalar grep { get_busy($_->call) } @nodelist;
	}

	
}

# is there a message for me?
sub for_me
{
	my $call = uc shift;
	my $ref;
	my $count;
	
	foreach $ref (@msg) {
		# is it for me, private and unread? 
		if ($ref->{to} eq $call && $ref->{private}) {
		   $count++ unless $ref->{'read'} || $ref->{delete};
		}
	}
	return $count;
}

# start the message off on its travels with a PC28
sub start_msg
{
	my ($self, $dxchan) = @_;
	
	confess("trying to start started msg $self->{msgno} nodes: $self->{fromnode} -> $self->{tonode}") if $self->{tonode};
	dbg("start msg $self->{msgno}\n") if isdbg('msg');
	$self->{linesreq} = 10;
	$self->{count} = 0;
	$self->{tonode} = $dxchan->call;
	$self->{fromnode} = $main::mycall;
	set_busy($self->{tonode}, $self);
	set_fwq($self->{tonode}, undef, $self);
	$self->{lastt} = $main::systime;
	my ($fromnode, $origin);
	$fromnode = $self->{fromnode};
	$origin = $self->{origin};
	$dxchan->send(DXProt::pc28($self->{tonode}, $fromnode, $self->{to}, $self->{from}, $self->{t}, $self->{private}, $self->{subject}, $origin, $self->{rrreq}));
}

# get the ref of a busy node
sub get_busy
{
	my $call = shift;
	return $busy{$call};
}

sub set_busy
{
	my $call = shift;
	return $busy{$call} = shift;
}

sub del_busy
{
	my $call = shift;
	return delete $busy{$call};
}

# get the whole busy queue
sub get_all_busy
{
	return keys %busy;
}

# get a forwarding queue entry
sub get_fwq
{
	my $call = shift;
	my $stream = shift || '0';
	return $work{"$call,$stream"};
}

# delete a forwarding queue entry
sub del_fwq
{
	my $call = shift;
	my $stream = shift || '0';
	return delete $work{"$call,$stream"};
}

# set a fwq entry
sub set_fwq
{
	my $call = shift;
	my $stream = shift || '0';
	return $work{"$call,$stream"} = shift;
}

# get the whole forwarding queue
sub get_all_fwq
{
	return keys %work;
}

# stop a message from continuing, clean it out, unlock interlocks etc
sub stop_msg
{
	my $self = shift;
	my $node = shift;
	my $stream = $self->{stream};
	
	
	dbg("stop msg $self->{msgno} -> node $node\n") if isdbg('msg');
	del_fwq($node, $stream);
	$self->workclean;
	del_busy($node);
}

sub workclean
{
	my $ref = shift;
	delete $ref->{lines};
	delete $ref->{linesreq};
	delete $ref->{tonode};
	delete $ref->{fromnode};
	delete $ref->{stream};
	delete $ref->{file};
	delete $ref->{count};
	delete $ref->{tempr};
	delete $ref->{lastt};
	delete $ref->{waitt};
}

# get a new transaction number from the file specified
sub next_transno
{
	my $name = shift;
	$name =~ s/\W//og;			# remove non-word characters
	my $fn = "$msgdir/$name";
	my $msgno;
	
	my $fh = new IO::File;
	if (sysopen($fh, $fn, O_RDWR|O_CREAT, 0666)) {
		$fh->autoflush(1);
		$msgno = $fh->getline || '0';
		chomp $msgno;
		$msgno++;
		seek $fh, 0, 0;
		$fh->print("$msgno\n");
		dbg("msgno $msgno allocated for $name\n") if isdbg('msg');
		$fh->close;
	} else {
		confess "can't open $fn $!";
	}
	return $msgno;
}

# initialise the message 'system', read in all the message headers
sub init
{
	my $dir = new IO::File;
	my @dir;
	my $ref;
		
	# load various control files
	dbg("load badmsg: " . (load_badmsg() or "Ok"));
	dbg("load forward: " . (load_forward() or "Ok"));
	dbg("load swop: " . (load_swop() or "Ok"));

	# read in the directory
	opendir($dir, $msgdir) or confess "can't open $msgdir $!";
	@dir = readdir($dir);
	closedir($dir);

	@msg = ();
	for (sort @dir) {
		next unless /^m\d\d\d\d\d\d$/;
		
		$ref = read_msg_header("$msgdir/$_");
		unless ($ref) {
			dbg("Deleting $_");
			Log('err', "Deleting $_");
			unlink "$msgdir/$_";
			next;
		}
		
		# delete any messages to 'badmsg.pl' places
		if ($ref->dump_it('')) {
			dbg("'Bad' TO address $ref->{to}") if isdbg('msg');
			Log('msg', "'Bad' TO address $ref->{to}");
			$ref->del_msg;
			next;
		}

		# add the message to the available queue
		add_dir($ref); 
	}
}

# add the message to the directory listing
sub add_dir
{
	my $ref = shift;
	confess "tried to add a non-ref to the msg directory" if !ref $ref;
	push @msg, $ref;
}

# return all the current messages
sub get_all
{
	return @msg;
}

# get a particular message
sub get
{
	my $msgno = shift;
	for (@msg) {
		return $_ if $_->{msgno} == $msgno;
		last if $_->{msgno} > $msgno;
	}
	return undef;
}

# return the official filename for a message no
sub filename
{
	return sprintf "$msgdir/m%06d", shift;
}

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

#
# send a message state machine
sub do_send_stuff
{
	my $self = shift;
	my $line = shift;
	my @out;
	
	if ($self->state eq 'send1') {
		#  $DB::single = 1;
		confess "local var gone missing" if !ref $self->{loc};
		my $loc = $self->{loc};
		if (my @ans = BadWords::check($line)) {
			$self->{badcount} += @ans;
			Log('msg', $self->call . " used badwords: @ans to @{$loc->{to}} in msg");
			$loc->{reject}++;
		}
		$loc->{subject} = $line;
		$loc->{lines} = [];
		$self->state('sendbody');
		#push @out, $self->msg('sendbody');
		push @out, $self->msg('m8');
	} elsif ($self->state eq 'sendbody') {
		confess "local var gone missing" if !ref $self->{loc};
		my $loc = $self->{loc};
		if ($line eq "\032" || $line eq '%1A' || uc $line eq "/EX") {
			my $to;
			unless ($loc->{reject}) {
				foreach $to (@{$loc->{to}}) {
					my $ref;
					my $systime = $main::systime;
					my $mycall = $main::mycall;
					$ref = DXMsg->alloc(DXMsg::next_transno('Msgno'),
										uc $to,
										exists $loc->{from} ? $loc->{from} : $self->call, 
										$systime,
										$loc->{private}, 
										$loc->{subject}, 
										exists $loc->{origin} ? $loc->{origin} : $mycall,
										'0',
										$loc->{rrreq});
					$ref->swop_it($self->call);
					$ref->store($loc->{lines});
					$ref->add_dir();
					push @out, $self->msg('m11', $ref->{msgno}, $to);
					#push @out, "msgno $ref->{msgno} sent to $to";
					$ref->notify;
				}
			} else {
				LogDbg('msg', $self->call . " swore to @{$loc->{to}} subject: '$loc->{subject}' in msg, REJECTED");
			}
			
			delete $loc->{lines};
			delete $loc->{to};
			delete $self->{loc};
			$self->func(undef);
			
			$self->state('prompt');
		} elsif ($line eq "\031" || uc $line eq "/ABORT" || uc $line eq "/QUIT") {
			#push @out, $self->msg('sendabort');
			push @out, $self->msg('m10');
			delete $loc->{lines};
			delete $loc->{to};
			delete $self->{loc};
			$self->func(undef);
			$self->state('prompt');
		} elsif ($line =~ m|^/+\w+|) {
			# this is a command that you want display for your own reference
			# or if it has TWO slashes is a command 
			$line =~ s|^/||;
			my $store = $line =~ s|^/+||;
			my @in = $self->run_cmd($line);
			push @out, @in;
			if ($store) {
				foreach my $l (@in) {
					if (my @ans = BadWords::check($l)) {
						$self->{badcount} += @ans;
						Log('msg', $self->call . " used badwords: @ans to @{$loc->{to}} subject: '$loc->{subject}' in msg") unless $loc->{reject};
						Log('msg', "line: $l");
						$loc->{reject}++;
					} 
					push @{$loc->{lines}}, length($l) > 0 ? $l : " ";
				}
			}
		} else {
			if (my @ans = BadWords::check($line)) {
				$self->{badcount} += @ans;
				Log('msg', $self->call . " used badwords: @ans to @{$loc->{to}} subject: '$loc->{subject}' in msg") unless $loc->{reject};
				Log('msg', "line: $line");
				$loc->{reject}++;
			}

			if ($loc->{lines} && @{$loc->{lines}}) {
				push @{$loc->{lines}}, length($line) > 0 ? $line : " ";
			} else {
				# temporarily store any R: lines so that we end up with 
				# only the first and last ones stored.
				if ($line =~ m|^R:\d{6}/\d{4}|) {
					push @{$loc->{tempr}}, $line;
				} else {
					if (exists $loc->{tempr}) {
						push @{$loc->{lines}}, shift @{$loc->{tempr}};
						push @{$loc->{lines}}, pop @{$loc->{tempr}} if @{$loc->{tempr}};
						delete $loc->{tempr};
					}
					push @{$loc->{lines}}, length($line) > 0 ? $line : " ";
				} 
			}
			
			# i.e. it ain't and end or abort, therefore store the line
		}
	}
	return @out;
}

# return the standard directory line for this ref 
sub dir
{
	my $ref = shift;
	my $flag = $ref->{private} && $ref->{read} ? '-' : ' ';
	if ($ref->{keep}) {
		$flag = '!';
	} elsif ($ref->{delete}) {
		$flag = $ref->{deletetime} > $main::systime ? 'D' : 'E'; 
	}
	return sprintf("%6d%s%s%5d %8.8s %8.8s %-6.6s %5.5s %-30.30s", 
				   $ref->{msgno}, $flag, $ref->{private} ? 'p' : ' ', 
				   $ref->{size}, $ref->{to}, $ref->{from}, cldate($ref->{t}), 
				   ztime($ref->{t}), $ref->{subject});
}

# load the forward table
sub load_forward
{
	my @out;
	my $s = readfilestr($forwardfn);
	if ($s) {
		eval $s;
		push @out, $@ if $@;
	}
	return @out;
}

# load the bad message table
sub load_badmsg
{
	my @out;
	my $s = readfilestr($badmsgfn);
	if ($s) {
		eval $s;
		push @out, $@ if $@;
	}
	return @out;
}

# load the swop message table
sub load_swop
{
	my @out;
	my $s = readfilestr($swopfn);
	if ($s) {
		eval $s;
		push @out, $@ if $@;
	}
	return @out;
}

#
# forward that message or not according to the forwarding table
# returns 1 for forward, 0 - to ignore
#

sub forward_it
{
	my $ref = shift;
	my $call = shift;
	my $i;
	
	for ($i = 0; $i < @forward; $i += 5) {
		my ($sort, $field, $pattern, $action, $bbs) = @forward[$i..($i+4)]; 
		my $tested;
		
		# are we interested?
		next if $ref->{private} && $sort ne 'P';
		next if !$ref->{private} && $sort ne 'B';
		
		# select field
		$tested = $ref->{to} if $field eq 'T';
		$tested = $ref->{from} if $field eq 'F';
		$tested = $ref->{origin} if $field eq 'O';
		$tested = $ref->{subject} if $field eq 'S';

		if (!$pattern || $tested =~ m{$pattern}i) {
			return 0 if $action eq 'I';
			return 1 if !$bbs || grep $_ eq $call, @{$bbs};
		}
	}
	return 0;
}

#
# look down the forward table to see whether this is a valid bull
# or not (ie it will forward somewhere even if it is only here)
#
sub valid_bull_addr
{
	my $call = shift;
	my $i;
	
	unless (@forward) {
		return 1 if $call =~ /^ALL/;
		return 1 if $call =~ /^DX/;
		return 0;
	}
	
	for ($i = 0; $i < @forward; $i += 5) {
		my ($sort, $field, $pattern, $action, $bbs) = @forward[$i..($i+4)]; 
		if ($field eq 'T') {
			if (!$pattern || $call =~ m{$pattern}i) {
				return 1;
			}
		}
	}
	return 0;
}

sub dump_it
{
	my $ref = shift;
	my $call = shift;
	my $i;
	
	for ($i = 0; $i < @badmsg; $i += 3) {
		my ($sort, $field, $pattern) = @badmsg[$i..($i+2)]; 
		my $tested;
		
		# are we interested?
		next if $ref->{private} && $sort ne 'P';
		next if !$ref->{private} && $sort ne 'B';
		
		# select field
		$tested = $ref->{to} if $field eq 'T';
		$tested = $ref->{from} if $field eq 'F';
		$tested = $ref->{origin} if $field eq 'O';
		$tested = $ref->{subject} if $field eq 'S';
		$tested = $call if $field eq 'I';

		if (!$pattern || $tested =~ m{$pattern}i) {
			return 1;
		}
	}
	return 0;
}

sub swop_it
{
	my $ref = shift;
	my $call = shift;
	my $i;
	my $count = 0;
	
	for ($i = 0; $i < @swop; $i += 5) {
		my ($sort, $field, $pattern, $tfield, $topattern) = @swop[$i..($i+4)]; 
		my $tested;
		my $swop;
		my $old;
		
		# are we interested?
		next if $ref->{private} && $sort ne 'P';
		next if !$ref->{private} && $sort ne 'B';
		
		# select field
		$tested = $ref->{to} if $field eq 'T';
		$tested = $ref->{from} if $field eq 'F';
		$tested = $ref->{origin} if $field eq 'O';
		$tested = $ref->{subject} if $field eq 'S';

		# select swop field
		$old = $swop = $ref->{to} if $tfield eq 'T';
		$old = $swop = $ref->{from} if $tfield eq 'F';
		$old = $swop = $ref->{origin} if $tfield eq 'O';
		$old = $swop = $ref->{subject} if $tfield eq 'S';

		if ($tested =~ m{$pattern}i) {
			if ($tested eq $swop) {
				$swop =~ s{$pattern}{$topattern}i;
			} else {
				$swop = $topattern;
			}
			Log('msg', "Msg $ref->{msgno}: $tfield $old -> $swop");
			Log('dbg', "Msg $ref->{msgno}: $tfield $old -> $swop");
			$ref->{to} = $swop if $tfield eq 'T';
			$ref->{from} = $swop if $tfield eq 'F';
			$ref->{origin} = $swop if $tfield eq 'O';
			$ref->{subject} = $swop if $tfield eq 'S';
			++$count;
		}
	}
	return $count;
}

# import any msgs in the import directory
# the messages are in BBS format (but may have cluster extentions
# so SB UK < GB7TLH is legal
sub import_msgs
{
	# are there any to do in this directory?
	return unless -d $importfn;
	unless (opendir(DIR, $importfn)) {
		dbg("can\'t open $importfn $!") if isdbg('msg');
		Log('msg', "can\'t open $importfn $!");
		return;
	} 

	my @names = readdir(DIR);
	closedir(DIR);
	my $name;
	foreach $name (@names) {
		next if $name =~ /^\./;
		my $splitit = $name =~ /^split/;
		my $fn = "$importfn/$name";
		next unless -f $fn;
		unless (open(MSG, $fn)) {
	 		dbg("can\'t open import file $fn $!") if isdbg('msg');
			Log('msg', "can\'t open import file $fn $!");
			unlink($fn);
			next;
		}
		my @msg = map { chomp; $_ } <MSG>;
		close(MSG);
		unlink($fn);
		my @out = import_one($main::me, \@msg, $splitit);
		Log('msg', @out);
	}
}

# import one message as a list in bbs (as extended) mode
# takes a reference to an array containing the whole message
sub import_one
{
	my $dxchan = shift;
	my $ref = shift;
	my $splitit = shift;
	my $private = '1';
	my $rr = '0';
	my $notincalls = 1;
	my $from = $dxchan->call;
	my $origin = $main::mycall;
	my @to;
	my @out;
				
	# first line;
	my $line = shift @$ref;
	my @f = split /([\s\@\$])/, $line;
	@f = map {s/\s+//g; length $_ ? $_ : ()} @f;

 	unless (@f && $f[0] =~ /^(:?S|SP|SB|SEND)$/ ) {
		my $m = "invalid first line in import '$line'";
		dbg($m) if isdbg('msg');
		return (1, $m);
	}
	while (@f) {
		my $f = uc shift @f;
		next if $f eq 'SEND';

		# private / noprivate / rr
		if ($notincalls && ($f eq 'B' || $f eq 'SB' || $f =~ /^NOP/oi)) {
			$private = '0';
		} elsif ($notincalls && ($f eq 'P' || $f eq 'SP' || $f =~ /^PRI/oi)) {
			;
		} elsif ($notincalls && ($f eq 'RR')) {
			$rr = '1';
		} elsif (($f =~ /^[\@\.\#\$]$/ || $f eq '.#') && @f) {       # this is bbs syntax, for AT
			shift @f;
		} elsif ($f eq '<' && @f) {     # this is bbs syntax  for from call
			$from = uc shift @f;
		} elsif ($f =~ /^\$/) {     # this is bbs syntax  for a bid
			next;
		} elsif ($f =~ /^<(\S+)/) {     # this is bbs syntax  for from call
			$from = $1;
		} elsif ($f =~ /^\$\S+/) {     # this is bbs syntax for bid
			;
		} else {

			# callsign ?
			$notincalls = 0;

			# is this callsign a distro?
			my $fn = "$msgdir/distro/$f.pl";
			if (-e $fn) {
				my $fh = new IO::File $fn;
				if ($fh) {
					local $/ = undef;
					my $s = <$fh>;
					$fh->close;
					my @call;
					@call = eval $s;
					return (1, "Error in Distro $f.pl:", $@) if $@;
					if (@call > 0) {
						push @f, @call;
						next;
					}
				}
			}
			
			if (grep $_ eq $f, @DXMsg::badmsg) {
				push @out, $dxchan->msg('m3', $f);
			} else {
	 			push @to, $f;
			}
		}
	}
	
	# subject is the next line
	my $subject = shift @$ref;
	
	# strip off trailing lines 
	pop @$ref while (@$ref && $$ref[-1] =~ /^\s*$/);
	
	# strip off /EX or /ABORT
	return ("aborted") if @$ref && $$ref[-1] =~ m{^/ABORT$}i; 
	pop @$ref if (@$ref && $$ref[-1] =~ m{^/EX$}i);									 

	# sort out any splitting that needs to be done
	my @chunk;
	if ($splitit) {
		my $lth = 0;
		my $lines = [];
		for (@$ref) {
			if ($lth >= $maxchunk || ($lth > $minchunk && /^\s*$/)) {
				push @chunk, $lines;
				$lines = [];
				$lth = 0;
			} 
			push @$lines, $_;
			$lth += length; 
		}
		push @chunk, $lines if @$lines;
	} else {
		push @chunk, $ref;
	}

	# does an identical message already exist?
	my $m;
	for $m (@msg) {
		if (substr($subject,0,28) eq substr($m->{subject},0,28) && $from eq $m->{from} && grep $m->{to} eq $_, @to) {
			my $msgno = $m->{msgno};
			dbg("duplicate message from $from -> $m->{to} to msg: $msgno") if isdbg('msg');
			Log('msg', "duplicate message from $from -> $m->{to} to msg: $msgno");
			return;
		}
	}

    # write all the messages away
	my $i;
	for ( $i = 0;  $i < @chunk; $i++) {
		my $chunk = $chunk[$i];
		my $ch_subject;
		if (@chunk > 1) {
			my $num = " [" . ($i+1) . "/" . scalar @chunk . "]";
			$ch_subject = substr($subject, 0, 27 - length $num) .  $num;
		} else {
			$ch_subject = $subject;
		}
		my $to;
		foreach $to (@to) {
			my $systime = $main::systime;
			my $mycall = $main::mycall;
			my $mref = DXMsg->alloc(DXMsg::next_transno('Msgno'),
									$to,
									$from, 
									$systime,
									$private, 
									$ch_subject, 
									$origin,
									'0',
									$rr);
			$mref->swop_it($main::mycall);
			$mref->store($chunk);
			$mref->add_dir();
			push @out, $dxchan->msg('m11', $mref->{msgno}, $to);
			#push @out, "msgno $ref->{msgno} sent to $to";
			$mref->notify;
		}
	}
	return @out;
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

__END__
