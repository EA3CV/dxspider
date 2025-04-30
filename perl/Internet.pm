# 
# in order for you to use the internet accessing routines you
# need to set various flags and things in this file
#
# BUT DO NOT ALTER THIS FILE! It will be overwritten on every update
#
# COPY this file to ../local, alter it there and restart the software
#
# Copyright (c) 2000 Dirk Koopman G1TLH
#
#
#

package Internet;

#
# set this flag to 1 if you want to allow internet commands
#

$allow = 0;

#
# QRZ.com user id 
#
# set this to your QRZ user name (you need this for the sh/qrz 
# command)
#
# eg 
# $qrz_uid = 'gb7xxx';
#


$qrz_uid = undef;

#
# QRZ.com password - this goes with your user id above
#
# eg 
# $qrz_pw = 'fishhooks';
#

$qrz_pw = undef;

#
# the address of any HTTP proxy you might be using
#
# leave as is unless you need one
#
# eg:  $http_proxy = 'wwwcache.demon.co.uk';
#

$http_proxy = undef;

#
# HTTP proxy port - again leave alone unless you need this
#
# eg: $http_proxy_port = 8080;
#

$http_proxy_port = undef;

#
# list of urls and other things that are used in commands, here so that they
# can be changed if necessary.
#

$qrz_url = 'xmldata.qrz.com';     # used by show/qrz
$wm7d_url = 'www.wm7d.net';   # used by show/wm7d
$db0sdx_url = 'www.qslinfo.de'; # used by show/db0sdx
$db0sdx_path = '/qslinfo';
$db0sdx_suffix = '.asmx';
$dx425_url = 'https://www.425dxn.org/';		# used by show/425
$contest_host = 'contest.dxtron.com';         # used by show/contest
#$contest_url = "/contest/text";         # used by show/contest
$ipaddr_host = 'ipinfo.io';	# used by set/external_ip
$ipaddr_url = '/ip';	# used by set/external_ip


#SHOW/IK3QAR <callsign> Show the 5 most recent informations found on IK3QAR
##Callsign Database about QSL Manager, Manager address and comments. This
##command works for sysop subscribed for the service at:
##    http://www.ik3qar.it/manager/dxc.php
##Write the given password below in $ik3qar_pw
#
$ik3qar_url = 'www.ik3qar.it';    # used by show/ik3qar
$ik3qar_pw = 'PUT-PASSWORD-HERE';    # used by show/ik3qar

#
# webserver stuff
#
our $server_app = "$root/web_server/script/web_server";

# NOTE: you must copy $ik3qar_* lines to local/Internet.pm for them to have
# any effect on an already running node.
#
#
# end
#

1;
