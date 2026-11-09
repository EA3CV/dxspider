#
# This is a template Local module
#
# DON'T CHANGE THIS, copy it to ../local/ and change it
# there
#
# You can add whatever code you like in here, you can also declare
# new subroutines in addition to the ones here, include other packages
# or do whatever you like. This is your spring board.
#

package Local;

use DXVars;
use DXDebug;
use DXUtil;

# DON'T REMOVE THIS LINE
use strict;


# declare any global variables you use in here
use vars qw{ };

# called at initialisation time
#sub init
#{
#
#}

# called once every second
#sub process
#{
#
#}

# called just before the ending of the program
#sub finish
#{
#
#}

# called after an incoming PC line has been split up, return 0 if you want to
# continue and 1 if you wish the PC Protocol line to be ignored completely
#
# Parameters:-
# $self      - the DXChannel object
# $pcno      - the no of the PC field
# $line      - the actual incoming line with its hop count already decremented
# @field     - the spot exactly as is, split up into fields
#              $field[0] will be PC11 or PC26
#sub pcprot
#{

#	my ($self, $pcno, $line, @field) = @_;

	# take out any switches that aren't interesting to you.
# SWITCH: {
#		if ($pcno == 10) {		# incoming talk
#			last SWITCH;
#		}

#		if ($pcno == 11 || $pcno == 26) { # dx spot
#			last SWITCH;
#		}

#		if ($pcno == 12) {		# announces
#			last SWITCH;
#		}

#		if ($pcno == 13) {
#			last SWITCH;
#		}
#		if ($pcno == 14) {
#			last SWITCH;
#		}
#		if ($pcno == 15) {
#			last SWITCH;
#		}

#		if ($pcno == 16) {		# add a user
#			last SWITCH;
#		}

#		if ($pcno == 17) {		# remove a user
#			last SWITCH;
#		}

#		if ($pcno == 18) {		# link request
#			last SWITCH;
#		}

#		if ($pcno == 19) {		# incoming cluster list
#			last SWITCH;
#		}

#		if ($pcno == 20) {		# send local configuration
#			last SWITCH;
#		}

#		if ($pcno == 21) {		# delete a cluster from the list
#			last SWITCH;
#		}

#		if ($pcno == 22) {
#			last SWITCH;
#		}

#		if ($pcno == 23 || $pcno == 27) { # WWV info
#			last SWITCH;
#		}

#		if ($pcno == 24) {		# set here status
#			last SWITCH;
#		}

#		if ($pcno == 25) {      # merge request
#			last SWITCH;
#		}

#		if (($pcno >= 28 && $pcno <= 33) || $pcno == 40 || $pcno == 42 || $pcno == 49) { # mail/file handling
#			last SWITCH;
#		}

#		if ($pcno == 34 || $pcno == 36) { # remote commands (incoming)
#			last SWITCH;
#		}

#		if ($pcno == 35) {		# remote command replies
#			last SWITCH;
#		}

#		if ($pcno == 37) {
#			last SWITCH;
#		}

#		if ($pcno == 38) {		# node connected list from neighbour
#			last SWITCH;
#		}

#		if ($pcno == 39) {		# incoming disconnect
#			last SWITCH;
#		}

#		if ($pcno == 41) {		# user info
#			last SWITCH;
#		}
#		if ($pcno == 43) {
#			last SWITCH;
#		}
#		if ($pcno == 44) {
#			last SWITCH;
#		}
#		if ($pcno == 45) {
#			last SWITCH;
#		}
#		if ($pcno == 46) {
#			last SWITCH;
#		}
#		if ($pcno == 47) {
#			last SWITCH;
#		}
#		if ($pcno == 48) {
#			last SWITCH;
#		}

#		if ($pcno == 50) {		# keep alive/user list
#			last SWITCH;
#		}

#		if ($pcno == 51) {		# incoming ping requests/answers
#			last SWITCH;
#		}
#	}
#	return 0;
#}

# called after the spot has been stored but before it is broadcast,
# you can do funky routing here that is non-standard. 0 carries on
# after this, 1 stops dead and no routing is done (this could mean
# that YOU have done some routing or other instead
#
# Parameters:-
# $self      - the DXChannel object
# $freq      - frequency
# $spotted   - the spotted callsign
# $d         - the date in unix time format
# $text      - the text of the spot
# $spotter   - who spotted it
# $orignode  - the originating node
#
#sub spot
#{
#	return 0;
#}

# called after the announce has been stored but before it is broadcast,
# you can do funky routing here that is non-standard. 0 carries on
# after this, 1 stops dead and no routing is done (this could mean
# that YOU have done some routing or other instead
#
# Parameters:-
# $self      - the DXChannel object
# $line      - the input PC12 line
# $announcer - the call that announced this
# $via       - the destination * = everywhere, callsign - just to that node
# $text      - the text of the chat
# $flag      - ' ' - normal announce, * - SYSOP, else CHAT group
# $origin    - originating node
# $wx        - 0 - normal, 1 - WX
#sub ann
#{
#	return 0;
#}


# called after the wwv has been stored but before it is broadcast,
# you can do funky routing here that is non-standard. 0 carries on
# after this, 1 stops dead and no routing is done (this could mean
# that YOU have done some routing or other instead
#
# Parameters:-
# $self      - the DXChannel object
# The rest the same as for Geomag::update
#sub wwv
#{
#	return 0;
#}

# same for wcy broadcasts
#sub wcy
#{
#	return 0;
#}

# no idea what or when these are called yet
#sub userstart
#{
#	return 0;
#}

#sub userline
#{
#	return 0;
#}

#sub userfinish
#{
#	return 0;
#}
1;
__END__
