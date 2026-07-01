9th July 2020
-------------

There are the notes for upgrading to the mojo branch. PLEASE NOTE
THERE HAVE BEEN CHANGES FOR all MOJO BRANCH USERS. See APPENDIX(i) at
the end of this document.

There is NO POINT in doing this at the moment unless you are running a
node with many (>50) users. It is the future, but at the moment I am
testing larger and larger installations to check that it a) still
works as people imagine it should and b) it provides the improvement
in scaling that I am anticipating. There are no significant new
features - yet.

The BIG TICKET ITEM in this branch is that (potentially) "long lived"
commands such as sh/dx and commands that poll external internet
resources now don't halt the flow of data through the node. I am also
using a modern, event driven, web socket "manager" called Mojolicious
which is considerably more efficient than what went before (but is not
necessary for small nodes). There are some 200-400 user nodes out
there that will definitely see the difference in terms of both CPU
usage and general responsiveness. Using Mojolicious also brings the
tantalising possibility of grafting on a web frontend, as it were, to
the "side" of a DXSpider node. But serious work on this won't start
until we have a stable base to work on. Apart from anything else there
will, almost certainly, need to be some internal data structure
reorganisation before a decent web frontend could be constructed.

*IMPORTANT* There is an action needed to go from mojo build 228 and
*below. See items marked IMPORTANT* below.

Upgrading is not for the faint of heart. There is no installation
script (but there will be) so, for the time being, you need to do some
manual editing. Also, while there is a backward path, it will involve
moving various files from their new home (/spider/local_data), back to
where they came from (/spider/data).

Prerequisites:

	A supply of good, strong tea - preferably in pint mugs. A tin hat,
	stout boots, a rucksack with survival rations and a decent miners'
	lamp might also prove comforting. I enclose this link:
	http://www.noswearing.com/dictionary in case you run out of swear
	words.

	An installed and known working git based installation. Mojo is not
	supported under CVS or installation from a tarball.

	perl 5.10.1, preferably 5.14.1 or greater. This basically means
	running ubuntu 12.04 or later (or one of the other linux distros
	of similar age or later). The install instructions are for debian
	based systems. IT WILL NOT WORK WITHOUT A "MODERN" PERL. Yes, you
	can use bleadperl if you know how to use it and can get it to run
	the node under it as a daemon without resorting the handy URL
	supplied above. Personally, I wouldn't bother. It's easier and
	quicker just to upgrade your linux distro. Apart from anything
	else things like ssh ntpd are broken on ALL older systems and will
	allow the ungodly in more easily than something modern.

Install cpamminus:

	sudo apt-get install cpanminus
or
    wget -O - https://cpanmin.us | perl - --sudo App::cpanminus
or
	sudo apt-get install curl
	curl -L https://cpanmin.us | perl - --sudo App::cpanminus

You will need the following CPAN packages:

	If you are on a Debian based system (Devuan, Ubuntu, Mint etc)
	that is reasonably new (I use Ubuntu 18.04 and Debian 10) then you
	can simply do:

	sudo apt-get install libev-perl libmojolicious-perl libjson-perl libjson-xs-perl libdata-structure-util-perl libmath-round-perl libnet-cidr-lite-perl libdbd-sqlite3-perl libdbi-perl

    or on Redhat based systems you can install the very similarly (but
	not the same) named packages. I don't know the exact names but
	using anything less than Centos 7 is likely to cause a world of
	pain. Also I doubt that EV and Mojolicious are packaged for Centos
	at all.

	If in doubt or it is taking too long to find the packages you
	should build from CPAN. Note: you may need to install the
	essential packages to build some of these. At the very least you
	will need to install 'make' (sudo apt-get install make) or just
	get everything you are likely to need with:
	
	sudo apt-get install build-essential.

	sudo cpanm EV Mojolicious JSON JSON::XS Data::Structure::Util Math::Round Net::CIDR::Lite DBD::SQLite3 DBI
	
	# just in case it's missing (top, that is)
	sudo apt-get install procps

Please make sure that, if you insist on using operating system
packages, that your Mojolicious is at least version
7.26. Mojo::IOLoop::ForkCall is NOT LONGER IN USE! The current version
at time of writing is 8.36.

Login as the sysop user.

Edit your /spider/local/DXVars.pm so that the bottom of the file is
changed from something like:

---- old ----

	 # the port number of the cluster (just leave this, unless it REALLY matters to you)
	 $clusterport = 27754;

	 # your favorite way to say 'Yes'
	 $yes = 'Yes';

	 # your favorite way to say 'No'
	 $no = 'No';

	 # the interval between unsolicited prompts if not traffic
	 $user_interval = 11*60;

	 # data files live in 
	 $data = "$root/data";

	 # system files live in
	 $system = "$root/sys";

	 # command files live in
	 $cmd = "$root/cmd";

	 # local command files live in (and overide $cmd)
	 $localcmd = "$root/local_cmd";

	 # where the user data lives
	 $userfn = "$data/users";

	 # the "message of the day" file
	 $motd = "$data/motd";

	 # are we debugging ?
	 @debug = qw(chan state msg cron );

---- to this: ----

	 # the port number of the cluster (just leave this, unless it REALLY matters to you)
	 $clusterport = 27754;

	 # your favorite way to say 'Yes'
	 $yes = 'Yes';

	 # your favorite way to say 'No'
	 $no = 'No';

	 # this is where the paths used to be which you have just removed
	 
	 # are we debugging ?
	 @debug = qw(chan state msg cron );

---- new  ------

There may be other stuff after this in DXVars.pm, that doesn't
matter. The point is to remove all the path definitions in
DXVars.pm. If this isn't clear to you then it would be better if you
asked on dxspider-support for help before attempting to go any
further.

One of the things that will happen is that several files currently in
/spider/data will be placed in /spider/local_data. These include the
user, qsl and usdb data files, the band and prefix files, and various
"bad" data files. I.e. everything that is modified from the base git
distribution.

Now run the console program or telnet localhost and login as the sysop
user.

	export_users
	bye

as the sysop user:

   sudo service dxspider stop
   or
   sudo systemctl stop dxspider

having stopped the node:

   mkdir /spider/local_data
   git reset --hard
   git pull --all
   git checkout --track -b mojo origin/mojo

if you have not already done this:

   sudo ln -s /spider/perl/console.pl /usr/local/bin/dx
   sudo ln -s /spider/perl/*dbg /usr/local/bin

Now in another window run:

	watchdbg

and finally:

   sudo service dxspider start
   or
   sudo service systemctl start dxspider

You should be aware that this code base is now under active
development and, if you do a 'git pull', what you get may be
broken. But, if this does happen, the likelihood is that I am actively
working on the codebase and any brokenness may be fixed (maybe in
minutes) with another 'git pull'.

I try very hard not to leave it in a broken state...

Dirk G1TLH

APPENDIX(i)

Before shutting down to do the update, do a 'sh/ver' and take node of
the current git revision number (the hex string after "git: mojo/" and
the "[r]"). Also do an 'export_users' (belt and braces).

With this revision of the code, the users.v3 file will be replaced
with users.v3j.  On restarting the node, the users.v3j file will be
generated from the users.v3 file. The users.v3 file is not changed.
The process of generation will take up to 30 seconds depending on the
number of users in your file, the speed of your disk(s) and the CPU
speed (probably in that order. On my machine, it takes about 5
seconds, on an RPi??? This is a reversable change. Simply checkout the
revision you noted down before ("git checkout <reversion>") and email
me should anything go wrong.

Part of this process may clear out some old records or suggest that
there might errors. DO NOT BE ALARM. This is completely normal.

This change not only should make the rebuilding of the users file
(much) less likely, but tests suggest that access to the users file is
about 2.5 times quicker. How much difference this makes in practise
remains to be seen.

When you done this, in another shell, run
/spider/perl/create_dxsql.pl. This will convert the DXQSL system to
dxqsl.v1j (for the sh/dxqsl <call> command). When this is finished,
run 'load/dxqsl' in a console (or restart the node, but it isn't
necessary).

This has been done to remove Storable - completely - from active use
in DXSpider. I have started to get more reports of user file
corruptions in the last year than I ever saw in the previous 10. One
advantage of this is that change is that user file access is now 2.5
times faster. So things like 'export_users' should not stop the node
for anything like as long as the old version.

On the subject of export_users. Once you are happy with the stability
of the new version, you can clean out all your user_asc.* files (I'd
keep the 'user_asc' that you just created for emergencies). The modern
equivalent of this file is now called 'user_json' and can used in
exactly the same way as 'user_asc' to restore the users.v3j file (stop
the node; cd /spider/local_data; perl user_json; start the node).


