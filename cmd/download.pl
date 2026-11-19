#
# download a file from t'internet
#
# A build in, non-spawning, wget -Qn
#
# Copyright 2023 Dirk Koopman G1TLH
#

#use IO::Socket::SSL;
use File::Copy;

my %h;

sub handle
{
	my $self = shift;
	return (1, $self->msg('e5')) if $self->priv < 9 || $self->remotecmd;
	my $url = unpad(shift);
	my $dest = unpad(shift) if @_;
	dbg("download: url $url");
	my $ua = Mojo::UserAgent->new->insecure(1)->max_redirects(5);
	my $tx = $ua->get($url => sub {finish(@_, $self)});
	$self->{$tx} = {ua => $ua, tx => $tx};
	dbg("ua $ua start: $url") if isdbg('download');
}

sub finish {
	my ($ua, $tx, $self) = @_;

#	$DB::single = 1;
	
	my $res = $tx->res;
	
	if ($res->is_success) {
		#dbg("body: " . $res->body) if isdbg('download');
		my $tmp = localdata("tmp");
		mkdir $tmp, 0777 unless -e $tmp;
		my $path = $tx->req->url->to_abs->path;
		my @parts = split m|/|, $path;
		my $fn = $parts[-1];
		dbg("ua $ua temp file: $tmp/$fn") if isdbg('download');
		$res->save_to("$tmp/$fn");
		my $target = localdata($fn);
		if (-e "$tmp/$fn") {
			LogDbg('dxcommand', "moving $tmp/$fn -> $target from ");
			move "$tmp/$fn", $target;
			unlink "$tmp/$fn";
		}
		dbg("download: $target successfully downloaded") if isdbg('progress')
	} else {
		my $err = $tx->error;
		if ($err) {
			my $message = $err->{message} // 'unknown error';
			my $code = $err->{code};
			dbg("download: " . (defined $code ? "HTTP $code: " : "connection error: ") . $message);
		} else {
			dbg("download: unexpected response " . ($res->code // 'without HTTP status'));
		}
	}
	delete $self->{$tx};
}
