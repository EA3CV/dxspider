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
# 20261106 v1.6: Web user Telegram notifications and Mojo HTTPS transport
#

package Local;
use strict;
use warnings;
use utf8;
use 5.10.1;
use DXVars;
use DXDebug;
use DXUtil;
use DXLog ();
use JSON::PP ();
use POSIX ();
use Errno qw(EINTR);

# Set these here; no changes to DXVars.pm are required.
our $export_backend = 'none';   # none | mqtt | redis
our $telegram_enable = 0;

# Telegram credentials are read from DXVars.pm:
# $main::reg_telegram_token and $main::reg_telegram_chatid.
our $mqtt_host = '127.0.0.1';
our $mqtt_port = 1883;
our $mqtt_topic = 'spider/raw/node-X';
our $redis_host = '127.0.0.1';
our $redis_port = 6379;
our $redis_channel = 'spider/raw/node-X';
our $max_queue = 200;

my @queue;
my $child_pid;
my $hooked;
my $original_writeunix;
our $inside_log;
my $dropped = 0;
my $web_hooks_installed;

sub init {
    return if $hooked;
    return if !$telegram_enable && $export_backend eq 'none';
    # The existing DXLog::Log remains the authoritative logger.
    # Hooking is limited to the current process, and can be disabled by config.
    {
        no warnings 'redefine';
        $original_writeunix = \&DXLog::writeunix;
        *DXLog::writeunix = sub {
            my @args = @_;
            my $ret = $original_writeunix->(@args);
            if (!$inside_log && $telegram_enable && $args[0] == $DXLog::log) {
                local $inside_log = 1;
                eval { log_msg(undef, $args[1], $args[2]) };
            }
            return $ret;
        };
    }
    $hooked = 1;
    _install_web_hooks();
}

sub _install_web_hooks {
    return if $web_hooks_installed;
    return unless defined &Web::_user_add && defined &Web::_remove_user;
    my $original_add = \&Web::_user_add;
    my $original_remove = \&Web::_remove_user;
    {
        no warnings 'redefine';
        *Web::_user_add = sub {
            my ($self) = @_;
            my %before = map { $_ => 1 } keys %{ $self->{web_users} || {} };
            my $result = $original_add->(@_);
            for my $call (keys %{ $self->{web_users} || {} }) {
                next if $before{$call};
                my $owned = $self->{web_users}{$call};
                next unless $owned && $owned->{authenticated} && $owned->{channel};
                _web_notice($call, 'connected');
            }
            return $result;
        };
        *Web::_remove_user = sub {
            my ($self, $call) = @_;
            my $owned = $self->{web_users}{$call};
            my $notify = $owned && $owned->{authenticated} && $owned->{channel}
                && !$owned->{web_removing};
            my $result = $original_remove->(@_);
            _web_notice($call, 'disconnected') if $notify && $result;
            return $result;
        };
    }
    $web_hooks_installed = 1;
}

sub _web_notice {
    my ($call, $action) = @_;
    return unless $telegram_enable && defined $call && $call !~ /\A#WEB-/i;
    my $node = $main::mycall || 'DXSpider';
    my $symbol = $action eq 'connected' ? '✅' : '❌';
    my $verb = $action eq 'connected' ? 'Connect' : 'Disconnect';
    telegram("*$node*   $symbol  *$call* $verb (*W*)");
}

sub _enqueue {
    my ($job) = @_;
    return unless $job;
    if (@queue >= $max_queue) { ++$dropped; return; }
    push @queue, $job;
}

sub process {
    _install_web_hooks() if !$web_hooks_installed && $telegram_enable;
    if ($child_pid) {
        my $r = waitpid($child_pid, POSIX::WNOHANG());
        return if $r == 0;
        $child_pid = undef;
    }
    return unless @queue;
    my $job = shift @queue;
    my $pid = fork();
    if (!defined $pid) { ++$dropped; return; }
    if ($pid == 0) {
        # Child is isolated: any network delay never blocks the DXSpider event loop.
        eval { _deliver($job) };
        POSIX::_exit(0);
    }
    $child_pid = $pid;
}

sub finish {
    # Do not wait for external services during shutdown.
    @queue = ();
}

sub _deliver {
    my ($job) = @_;
    if ($job->{type} eq 'telegram') {
        # Reuse Mojolicious already required by DXSpider; no Mozilla::CA dependency.
        # This runs only in the forked child, never in the event loop.
        require Mojo::UserAgent;
        my $url = 'https://api.telegram.org/bot' . $main::reg_telegram_token . '/sendMessage';
        my $ua = Mojo::UserAgent->new;
        $ua->connect_timeout(3);
        $ua->request_timeout(5);
        $ua->max_redirects(0);
        # Avoid printing HTTP errors or exception text containing the bot token.
        eval {
            $ua->post($url => form => {
                chat_id => $main::reg_telegram_chatid,
                text => $job->{text},
                parse_mode => 'Markdown',
            });
        };
    } elsif ($job->{type} eq 'export') {
        if ($export_backend eq 'mqtt') {
            require Net::MQTT::Simple;
            my $mqtt = Net::MQTT::Simple->new("$mqtt_host:$mqtt_port");
            $mqtt->publish($mqtt_topic, $job->{json});
        } elsif ($export_backend eq 'redis') {
            require IO::Socket::INET;
            my $sock = IO::Socket::INET->new(PeerAddr => $redis_host,
                PeerPort => $redis_port, Proto => 'tcp', Timeout => 3) or return;
            my @args = ('PUBLISH', $redis_channel, $job->{json});
            my $wire = '*' . @args . "\r\n";
            $wire .= '$' . length($_) . "\r\n" . $_ . "\r\n" for @args;
            print {$sock} $wire;
            close $sock;
        }
    }
}

sub telegram {
    my ($text) = @_;
    return 0 unless $telegram_enable && defined($main::reg_telegram_token) && length($main::reg_telegram_token)
        && defined($main::reg_telegram_chatid) && length($main::reg_telegram_chatid);
    _enqueue({type => 'telegram', text => $text});
    return 1;
}

sub _export {
    my ($kind, $payload) = @_;
    return if $export_backend eq 'none';
    return unless $export_backend eq 'mqtt' || $export_backend eq 'redis';
    my $json = JSON::PP->new->canonical(1)->utf8(1)->encode({$kind => $payload});
    _enqueue({type => 'export', json => $json});
}

sub pcprot {
    my ($self, $pcno, $line, @field) = @_;
    my %k = (11=>'SPOTS', 26=>'SPOTS', 61=>'SPOTS',
             12=>'ANN', 93=>'ANN', 23=>'WWV', 27=>'WWV', 73=>'WCY');
    _export($k{$pcno}, $line) if exists $k{$pcno};
    return 0;
}

# Format notifications exactly as the former Telegram notifier did.
# The Markdown parse mode is set in _deliver(), not in the event-loop hook.
sub log_msg {
    my ($self, $t, $line) = @_;
    return 0 unless $telegram_enable && defined $line;
    my @f = split /\^/, $line, -1;
    my ($category, $message) = @f >= 3 ? @f[1,2] : ('', '');
    my $node = $main::mycall || 'DXSpider';
    my ($call, $action);

    if ($category eq 'DXCommand' || $category eq 'DXProt') {
        # Only report events whose callsign and action are present in the log.
        if ($message =~ /\b([A-Z0-9]{1,3}[A-Z0-9\/]*[A-Z0-9](?:-\d{1,2})?)\s+(connected|disconnected)\b/i) {
            ($call, $action) = ($1, lc($2));
            my $kind = $category eq 'DXProt' ? 'N' : 'U';
            my $symbol = $action eq 'connected' ? '✅' : '❌';
            my $verb = $action eq 'connected' ? 'Connect' : 'Disconnect';
            telegram("*$node*   $symbol  *$call* $verb (*$kind*)");
        }
    } elsif ($category eq 'RBN') {
        if ($message =~ /disconnecting/i) {
            telegram("*$node*   ❌  *RBN* Disconnect (*U*)");
        }
    } elsif ($category eq 'cluster') {
        if ($message =~ /\bstarted\b/i) {
            telegram("*$node*   ⬆️  Cluster *UP*");
        } elsif ($message =~ /\bended\b/i) {
            telegram("*$node*   ⬇️  Cluster *DOWN*");
        }
    } elsif ($category eq '' && $message =~ /\b([A-Z0-9]+(?:-\d{1,2})?)\s+has too many connections\b/i) {
        telegram("*$node*   ❎  *$1* Many connections");
    }
    return 0;
}

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

1;
