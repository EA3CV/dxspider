#!/usr/bin/env perl
#
# this is the operators console.
#
# Calling syntax is:-
#
# console.pl [callsign] 
#
# if the callsign isn't given then the sysop callsign in DXVars.pm is assumed
#
# Copyright (c) 1999 Dirk Koopman G1TLH
#
#
# 

require 5.16.1;
use strict;
use warnings;

our $root;
our $is_win;
our $myalias;
our $mycall;
our $clusteraddr;
our $clusterport;
our $maxshist;
our $maxkhist;
our $foreground;
our $background;
our $mycallcolor;
our @colors;
our $data;
our $local_data;

# search local then perl directories
BEGIN {
	# root of directory tree for this system
	$root = "/spider"; 
	$root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};
	$local_data = "$root/local_data";
	$data = "$root/data";
	
	unshift @INC, "$root/perl";	# this IS the right way round!
	unshift @INC, "$root/local";
	$is_win = ($^O =~ /^MS/ || $^O =~ /^OS-2/) ? 1 : 0; # is it Windows?
}


use Mojo::IOLoop;

use DXVars;
use SysVar;

use Msg;
use IntMsg;
use DXDebug;
use DXUtil;
use DXDebug;
use IO::File;
use Time::HiRes qw(gettimeofday tv_interval);
use Curses 1.06;
use Text::Wrap qw(wrap);

use Console;

#
# initialisation
#

$clusteraddr //= '127.0.0.1';
$clusterport //= 27754;

our $call = "";                     # the callsign being used
our $node = "";                     # the node callsign being used
our $conn = 0;                      # the connection object for the cluster
our $lasttime = time;               # lasttime something happened on the interface

our $connsort = "local";
our @kh = ();
our @sh = ();
our $kpos = 0;
our $inbuf = "";
our $idle = 0;
our $inscroll = 0;

my $top;
my $bot;
my $lines;
my $scr;
my $cols;
my $pagel;
my $has_colors;
our $pos;
our $lth;
my $sh;

our $spos = $pos = $lth = 0;



#$SIG{WINCH} = sub {@time = gettimeofday};

$DXDebug::no_stdout = 1;

# do the screen initialisation
sub do_initscr
{
	$scr = new Curses;
	if ($has_colors) {
		start_color();
		init_pair(0, $foreground, $background);
#		init_pair(0, $background, $foreground);
		init_pair(1, COLOR_RED, $background);
		init_pair(2, COLOR_YELLOW, $background);
		init_pair(3, COLOR_GREEN, $background);
		init_pair(4, COLOR_CYAN, $background);
		init_pair(5, COLOR_BLUE, $background);
		init_pair(6, COLOR_MAGENTA, $background);
		init_pair(7, COLOR_RED, COLOR_BLUE);
		init_pair(8, COLOR_YELLOW, COLOR_BLUE);
		init_pair(9, COLOR_GREEN, COLOR_BLUE);
		init_pair(10, COLOR_CYAN, COLOR_BLUE);
		init_pair(11, COLOR_BLUE, COLOR_RED);
		init_pair(12, COLOR_MAGENTA, COLOR_BLUE);
		init_pair(13, COLOR_YELLOW, COLOR_GREEN);
		init_pair(14, COLOR_RED, COLOR_GREEN);
		eval { assume_default_colors($foreground, $background) } unless $is_win;
	}

	$top = $scr->subwin($lines-4, $cols, 0, 0);
	$top->intrflush(0);
	$top->scrollok(0);
	$top->idlok(1);
	$top->meta(1);
	$top->leaveok(1);
	$top->clrtobot();
#	$top->setscrreg(0, $lines-5);
	
	$bot = $scr->subwin(3, $cols, $lines-3, 0);
	$bot->intrflush(0);
	$bot->scrollok(1);
	$bot->keypad(1);
	$bot->move(1,0);
	$bot->meta(1);
	$bot->nodelay(1);
	$bot->clrtobot();
	$scr->refresh();
	
	
	$pagel = $lines-4;
	$mycallcolor = COLOR_PAIR(1) unless $mycallcolor;
}

sub doresize
{
	endwin() if $scr;
	initscr();
	raw();
	noecho();
	nonl();
 	$lines = LINES;
	$cols = COLS;
	$has_colors = has_colors();
	do_initscr();

	$inscroll = 0;
	$spos = @sh < $pagel ? 0 :  @sh - $pagel;
	show_screen();
	$conn->send_later("C$call|$cols") if $conn;
}

# cease communications
sub cease
{
	my $sendz = shift;
	$conn->disconnect if $conn;
	endwin();
	dbgclose();
	print @_ if @_;
	exit(0);	
}

# terminate program from signal
sub sig_term
{
	cease(1, @_);
}

# determine the colour of the line
sub setattr
{
	if ($has_colors) {
		foreach my $ref (@colors) {
			if ($_[0] =~ m{$$ref[0]}) {
				$top->attrset($$ref[1]);
				last;
			}
		}
	}
}


# display the top screen
sub show_screen
{
	if ($inscroll) {
		
		dbg("B: s:$spos h:" . scalar @sh) if isdbg('console');
		my ($i, $l);

		$spos = 0 if $spos < 0;
		my $y = $spos;
		$top->move(0, 0);
		$top->attrset(COLOR_PAIR(0)) if $has_colors;
		$top->clrtobot();
		for ($i = 0; $i < $pagel && $y < @sh; ++$y) {
			my $line = $sh[$y];
			my $lines = 1;
			$top->move($i, 0);
			dbg("C: s:$spos y:$i sh:" . scalar @sh . " l:" . length($line) . " '$line'") if isdbg('console');
			setattr($line);
			$top->addstr($line);
			$top->attrset(COLOR_PAIR(0)) if $has_colors;
			$i += $lines;
		}
		if ($y >= @sh) {
			$inscroll = 0;
			$spos = @sh;
		}
	}	elsif ($spos < @sh || $spos < $pagel) {
		# if we really are scrolling thru at the end of the history
		while ($spos < @sh) {
			my $line = $sh[$spos];
			my $y = $spos;
			if ($y >= $pagel) {
				$top->scrollok(1);
				$top->scrl(1);
				$top->scrollok(0);
				$y = $pagel-1;
			}
			$top->move($y, 0);
			dbg("A: s:$spos sh:" . scalar @sh . " y:$y l:" . length($line) . " '$line'") if isdbg('console');
			$top->refresh;
			setattr($line);
			$line =~ s/\n//s;
			$top->addstr($line);
			$top->attrset(COLOR_PAIR(0)) if $has_colors;
			++$spos;
		}
		shift @sh while @sh > $maxshist;
		$spos = @sh;
	}

	$top->refresh;
    my $shl = @sh;
	my $size = $lines . 'x' . $cols . '-'; 
	my $add = "-$spos-$shl";
    my $time = ztime(time);
	my $c = "$call\@$node";
	my $str =  "-" . $time . '-' . ($inscroll ? 'S':'-') . '-' x ($cols - (length($size) + length($c) + length($add) + length($time) + 3));
	$scr->addstr($lines-4, 0, $str);
	
	$scr->addstr($size);
	$scr->attrset($mycallcolor) if $has_colors;
	$scr->addstr($c);
	$scr->attrset(COLOR_PAIR(0)) if $has_colors;
    $scr->addstr($add);
	$scr->refresh();
#	$top->refresh();
}

sub rec_stdin
{
	my $r = shift;
	
	dbg("KEY: " . unpack("H*", $r). " '$r'") if isdbg('console');

	#  my $prbuf;
	#  $prbuf = $buf;
	#  $prbuf =~ s/\r/\\r/;
	#  $prbuf =~ s/\n/\\n/;
	#  print "sys: $r ($prbuf)\n";
	if (defined $r) {

		$r = '0' if !$r;

		if ($r eq KEY_ENTER || $r eq "\n" || $r eq "\r") {
			
			# save the lines
			$inbuf = " " unless length $inbuf;

			# check for a pling and do a search back for a command
			if ($inbuf =~ /^!/o) {
				my $i;
				$inbuf =~ s/^!//o;
				for ($i = $#kh; $i >= 0; $i--) {
					if ($kh[$i] =~ /^$inbuf/) {
						$inbuf = $kh[$i];
						last;
					}
				}
				if ($i < 0) {
					beep();
					return;
				}
			}
			push @kh, $inbuf if length $inbuf;
			shift @kh if @kh > $maxkhist;
			$kpos = @kh;
			$bot->move(0,0);
			$bot->clrtoeol();
			$bot->addstr(substr($inbuf, 0, $cols));

			if ($inscroll && $spos < @sh) {
				$spos = @sh - $pagel;
				$inscroll = 0;
				show_screen();
			}

			addtotop(' ', $inbuf);
		
			# send it to the cluster
			$conn->send_later("I$call|$inbuf");
			$inbuf = "";
			$pos = $lth = 0;
		} elsif ($r eq KEY_UP || $r eq "\020") {
			if ($kpos > 0) {
				--$kpos;
				$inbuf = $kh[$kpos];
				$pos = $lth = length $inbuf;
			} else {
				beep();
			}
		} elsif ($r eq KEY_DOWN || $r eq "\016") {
			if ($kpos < @kh - 1) {
				++$kpos;
				$inbuf = $kh[$kpos];
				$pos = $lth = length $inbuf;
			} else {
				beep();
			}
		} elsif ($r eq KEY_PPAGE || $r eq "\032") {
			if ($spos > 0 && @sh > $pagel) {
				$spos -= $pagel+int($pagel/2); 
				$spos = 0 if $spos < 0;
				$inscroll = 1;
				show_screen();
			} else {
				beep();
			}
		} elsif ($r eq KEY_NPAGE || $r eq "\026") {
			if ($inscroll && $spos < @sh) {

				dbg("NPAGE sp:$spos $sh:". scalar @sh . " pl: $pagel") if isdbg('console');
				$spos += int($pagel/2);
				if ($spos > @sh - $pagel) {
					$spos = @sh - $pagel;
				} 
				show_screen();
				if ($spos >= @sh) {
					$spos = @sh;
					$inscroll = 0;
				}
			} else {
				beep();
			}
		} elsif ($r eq KEY_LEFT || $r eq "\002") {
			if ($pos > 0) {
				--$pos;
			} else {
				beep();
			}
		} elsif ($r eq KEY_RIGHT || $r eq "\006") {
			if ($pos < $lth) {
				++$pos;
			} else {
				beep();
			}
		} elsif ($r eq KEY_HOME || $r eq "\001") {
			$pos = 0;
		} elsif ($r eq KEY_END || $r eq "\005") {
			$pos = $lth;
		} elsif ($r eq KEY_BACKSPACE || $r eq "\010" || $r eq "\x7f") {
			if ($pos > 0) {
				my $a = substr($inbuf, 0, $pos-1);
				my $b = substr($inbuf, $pos) if $pos < $lth;
				$b = "" unless $b;
				
				$inbuf = $a . $b;
				--$lth;
				--$pos;
			} else {
				beep();
			}
		} elsif ($r eq KEY_DC || $r eq "\004") {
			if ($pos < $lth) {
				my $a = substr($inbuf, 0, $pos);
				my $b = substr($inbuf, $pos+1) if $pos < $lth;
				$b = "" unless $b;
				
				$inbuf = $a . $b;
				--$lth;
			} else {
				beep();
			}
		} elsif ($r eq KEY_RESIZE || $r eq "\0632") {
			doresize();
			return;
		} elsif ($r eq "\x12" || $r eq "\x0c") {
			dbg("REDRAW called") if isdbg('console');
			doresize();
			return;
		} elsif ($r eq "\013") {
			$inbuf = substr($inbuf, 0, $pos);
			$lth = length $inbuf;
		} elsif (defined $r && is_pctext($r)) {
			# move the top screen back to the bottom if you type something
			
			if ($inscroll && $spos < @sh) {
				$spos = @sh - $pagel;
				$inscroll = 0;
				show_screen();
			}

		#	$r = ($r lt ' ' || $r gt "\x7e") ? sprintf("'%x", ord $r) : $r;
			
			# insert the character into the keyboard buffer
			if ($pos < $lth) {
				my $a = substr($inbuf, 0, $pos);
				my $b = substr($inbuf, $pos);
				$inbuf = $a . $r . $b;
			} else {
				$inbuf .= $r;
			}
			$pos++;
			$lth++;
		} else {
			beep();
		}

		$bot->move(1, 0);
		$bot->clrtobot();
		$bot->addstr($inbuf);
	} 
	$bot->move(1, $pos);
	$bot->refresh();
}


# add a line to the end of the top screen
sub addtotop
{
	my $sort = shift;
	while (@_) {
		my $inbuf = shift;
		my $l = length $inbuf;
		if ($l > $cols) {
			$inbuf =~ s/\s+/ /g;
			if (length $inbuf > $cols) {
				$Text::Wrap::columns = $cols;
				my $token;
				($token) = $inbuf =~ m!^(.* de [-\w\d/\#]+:?\s+|\w{9}\@\d\d:\d\d:\d\d )!;
				$token ||= ' ' x 19;
				push @sh, split /\n/, wrap('', ' ' x length($token), $inbuf);
			} else {
				push @sh, $inbuf;
			}
		} else {
			push @sh, $inbuf;
		}
	}
	
	show_screen() unless $inscroll;
}

# handle incoming messages
sub rec_socket
{
	my ($con, $msg, $err) = @_;
	if (defined $err && $err) {
		cease(1);
	}
	if (defined $msg) {
		my ($sort, $incall, $line) = $msg =~ /^(\w)([^\|]+)\|(.*)$/;
		dbg("msg: " . length($msg) . " '$msg'") if isdbg('console');
		if ($line =~ s/\x07+$//) {
			beep();
		}
		$line =~ s/[\r\n]+//s;

		# change my call if my node says "tonight Michael you are Jane" or something like that...
		$call = $incall if $call ne $incall;
		
		$line =~ s/[\x00-\x06\x08\x0a-\x19\x1b-\x1f\x80-\x9f]/./g;         # immutable CSI sequence + control characters
		if ($sort && $sort eq 'Z') { # end, disconnect, go, away .....
			cease(0);
		} else {
			$line = " " unless length($line);
			addtotop($sort, $line);
		}

	} else {
		cease(0);
	}
	$top->refresh();
	$lasttime = time; 
}

my $lastmin = 0;

sub idle_loop
{
	my $t;
	
	$t = time;
	if ($t > $lasttime) {
		my ($min)= (gmtime($t))[1];
		if ($min != $lastmin) {
			show_screen() unless $inscroll;
			$lastmin = $min;
		}
		$lasttime = $t;
	}
	my $ch = $bot->getch();		# this is here just to catch RESIZE events
	if (defined $ch) {
		if ($ch eq KEY_RESIZE) {
			doresize();
		} else {
			rec_stdin($ch) unless $ch eq '-1';
		}
	}
	$top->refresh() if $top->is_wintouched;
	$bot->refresh();
}

sub on_connect
{
	my $conn = shift;
	$conn->send_later("A$call|$connsort width=$cols enhanced");
	$conn->send_later("I$call|set/page " . ($maxshist-5));
	$conn->send_later("I$call|set/nobeep");
}

sub on_disconnect
{
	$conn = shift;
	Mojo::IOLoop->remove($idle);
	Mojo::IOLoop->stop;
}

#
# deal with args
#


while (@ARGV && $ARGV[0] =~ /^-/) {
	my $arg = shift;
	if ($arg eq '-x') {
		dbginit('console');
		dbgadd('console');
		$maxshist = 200;
	}
}

$call = uc shift @ARGV if @ARGV;
$call = uc $myalias unless $call;
$node = uc $mycall unless $node;

$call = normalise_call($call);

if ($call eq $mycall) {
	print "You cannot connect as your cluster callsign ($mycall)\n";
	exit(0);
}

unless ($DB::VERSION) {
	$SIG{'INT'} = \&sig_term;
	$SIG{'TERM'} = \&sig_term;
}

$SIG{'HUP'} = \&sig_term;


# start upb
$Text::Wrap::columns = $cols;
doresize();

$SIG{__DIE__} = \&sig_term;

$conn = IntMsg->connect($clusteraddr, $clusterport, rproc => \&rec_socket);
$conn->{on_connect} = \&on_connect;
$conn->{on_disconnect} = \&on_disconnect;

my $timer = Mojo::IOLoop->recurring(1, sub {DXLog::flushall()}) if $DXDebug::fp;

$idle = Mojo::IOLoop->recurring(0.100 => \&idle_loop);
Mojo::IOLoop->singleton->reactor->io(\*STDIN => sub {
	my $ch = $bot->getch();
	if (defined $ch) {
		if ($ch ne '-1') {
			rec_stdin($ch);
		}
	}
})->watch(\*STDIN, 1, 0);


Mojo::IOLoop->start;


cease(0);
