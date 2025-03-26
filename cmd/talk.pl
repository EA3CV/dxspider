#
# The talk command (improved)
#
# Copyright (c) 1998 Dirk Koopman G1TLH
#
#
#

my ($self, $inline) = @_;
my $to;
my $via;
my $line;
my $from = $self->call;
my @out;
return (1, $self->msg('e5')) if $self->remotecmd || $self->inscript;

# analyse the line there are four situations...
# 1) talk call
# 2) talk call <text>
# 3) talk call>node  **via ignored
# 4) talk call>node text **ditto
#

# via is deprecated / ignored
$inline =~ s/(?:\s*>([A-Za-z0-9\-]+))\s*//;

($to, $line) = $inline =~ /^\s*([A-Za-z0-9\-]+)\s*(.*)?$/;

#$DB::single = 1;

return (1, $self->msg('e8')) unless $to;

$to = uc $to;

return (1, $self->msg('e22', $to)) unless is_callsign($to);
return (1, $self->msg('e28')) unless $self->isregistered || $to eq $main::myalias;

#$via = uc $via if $via;
#my $call = $via || $to;
#my $clref = Route::get($call);     # try an exact call
#my $dxchan = $clref->dxchan if $clref;
#push @out, $self->msg('e7', $call) unless $dxchan;

my $call = $to;

#$DB::single = 1;

# default the 'via'
$via ||= '*';

my $ipaddr = alias_localhost($self->hostname || '127.0.0.1');

# if there is a line send it, otherwise add this call to the talk list
# and set talk mode for command mode
my @bad;
if (@bad = BadWords::check($line)) {
	$self->badcount(($self->badcount||0) + @bad);
	LogDbg('DXCommand', "$self->{call} swore: $line (with words:" . join(',', @bad) . ")");
}

my $dxchan;

if ($line) {
	Log('talk', $to, $from, '>' . ($via || ($dxchan && $dxchan->call) || '*'), $line);
	#$main::me->normal(DXProt::pc93($to, $self->call, $via, $line, undef, $ipaddr));
	$self->send_talks($to, $line);
} else {
	my $s = $to;
	my $ref = $self->talklist;
	if ($ref) {
		unless (grep { $_ eq $s } @$ref) {
			$main::me->normal(DXProt::pc93($to, $self->call, $via, $self->msg('talkstart'), undef,  $ipaddr));
			$self->state('talk');
			push @$ref, $s;
		}
	} else { 
		$self->talklist([ $s ]);
		$main::me->normal(DXProt::pc93($to, $self->call, $via, $self->msg('talkstart'), undef, $ipaddr));
		push @out, $self->msg('talkinst');
		$self->state('talk');
	}
	Log('talk', $to, $from, '>' . ($via || ($dxchan && $dxchan->call) || '*'), $self->msg('talkstart'), undef, $ipaddr);
	push @out, $self->talk_prompt;
}

return (1, @out);

