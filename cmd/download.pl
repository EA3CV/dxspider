#
# download a file from t'internet
#
# A build in, non-spawning, wget -Qn
#
# Copyright 2023 Dirk Koopman G1TLH
#

use strict;
use warnings;
use File::Temp qw(tempfile);
use Socket qw(AF_INET AF_INET6 inet_pton);

# Repo Kin - secondary public DXSpider download mirror.
my $kin_repo = "https://raw.githubusercontent.com/dxspider-official/download/main/";

# Explicit download candidates, not a remote directory listing.
# The IP lists are documented; the native hash names come from initial_data.
# badw_regex and badip.vpn are supported local families, not confirmed URLs.
# A missing remote file is reported and leaves the local file untouched.
# Keep repository-specific additions here. Fallback is limited to these names.
my @common_badlists = qw(
    baddx badip.global badip.torexit badip.torrelay badip.vpn
    badnode badspotter badw_regex badword
);
my %catalogue = (
    'www.dxspider.net/download/' => [@common_badlists],
    'dxspider.net/download/' => [@common_badlists],
    'dxspider.dxcluster.net/download/' => [sort @common_badlists, 'badip.curated'],
);

sub download_expand {
    my ($url) = @_;
    die "expected an HTTP or HTTPS URL\n" unless $url =~ m{\Ahttps?://[^/\s]+/[^\s]+\z}i;
    # A query string is not a glob. Only '*' in the final path component
    # is supported, to avoid confusing '?' with an HTTP query delimiter.
    my ($path) = split /[?#]/, $url, 2;
    return ([$url, undef]) unless $path =~ /\*/;
    my ($base, $pattern) = $url =~ m{\A(https?://[^/\s]+/(?:[^?#]*/)?)([A-Za-z0-9_.+*-]+)\z}i;
    die "wildcards are only supported in the filename, without query or fragment\n"
        unless defined $base && $base !~ /\*/;
    my $key = $base;
    $key =~ s{\Ahttps?://}{}i;
    $key = lc $key;
    my $names = $catalogue{$key} or die "no download catalogue for $base\n";
    my $re = quotemeta($pattern);
    $re =~ s/\\\*/.*/g;
    my @jobs = map { [$base . $_, $_] } grep { /\A$re\z/ } @$names;
    die "no catalogue entries match $pattern\n" unless @jobs;
    return @jobs;
}

# Only exact known repository paths are eligible for fallback. Arbitrary URLs
# retain the original download semantics (including empty files).
sub download_mirror_name {
    my ($url) = @_;
    my ($base, $name) = $url =~ m{\Ahttps?://([^/]+/download/)([A-Za-z0-9_.-]+)\z}i;
    return unless defined $base;
    my $names = $catalogue{lc $base} or return;
    return scalar(grep { $_ eq $name } @$names) ? $name : undef;
}

sub download_valid {
 my ($n,$s)=@_; return 0 unless length($s) && $s !~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/ && $s !~ /<(?:!DOCTYPE|html|head|body)\b/i;
 if ($n =~ /^badip\./) {
  my $count=0;
  for (split /\r?\n/,$s) {
   s/^\s+|\s+$//g; next if /^(?:#|$)/;
   my ($ip,$bits)= /\A([0-9a-fA-F:.]+)(?:\/([0-9]{1,3}))?\z/;
   return 0 unless defined $ip;
   my $family = index($ip, ':') >= 0 ? AF_INET6 : AF_INET;
   return 0 unless inet_pton($family,$ip) && (!defined($bits) || $bits <= ($family == AF_INET6 ? 128 : 32));
   ++$count;
  }
  return $count>0;
 }
 if ($n eq 'badw_regex') {
  # Legacy BadWords loader treats whitespace-separated tokens literally.
  # Reject control characters and markup; require at least one token.
  return 0 if $s =~ /[<>]/;
  return scalar grep { /\S/ && !/^\s*#/ } split /\r?\n/, $s;
 }
 my $body;
 if ($s =~ /\A\s*bless\s*\(\s*\{(.*)\}\s*,\s*'DXHash'\s*\)\s*;?\s*\z/s) { $body=$1; }
 elsif ($s =~ /\A\s*\{(.*)\}\s*;?\s*\z/s) { $body=$1; }
 else { return 0; }
 my ($named,$count)=(0,0);
 while ($body =~ /\S/) {
  if ($body =~ s/\A\s*(?:name|'name')\s*=>\s*'\Q$n\E'\s*(?:,|\z)//) { return 0 if $named++; }
  elsif ($body =~ s/\A\s*(?:[A-Za-z_][A-Za-z_0-9]*|'(?:[^'\\\r\n]|\\['\\])*')\s*=>\s*(?:[0-9]+|'[0-9]+')\s*(?:,|\z)//) { ++$count; }
  else { return 0; }
 }
 return $named==1 && $count>0;
}

sub download_store {
    my ($res, $fn, $validate) = @_;
    return (undef, 'invalid destination filename') unless defined($fn) && $fn =~ /\A[A-Za-z0-9][A-Za-z0-9_.+%-]*\z/;
    my $dir = $main::local_data;
    return (undef, 'local_data not initialized') unless defined($dir) && -d $dir;
    my $target = "$dir/$fn";
    return (undef, "destination is not a regular file: $fn") if -l $target || (-e $target && !-f $target);
    my ($fh, $tmp, $failure);
    my $ok;
    {
        # DXDebug's global __DIE__ hook logs even caught exceptions.
        # Scope suppression to this synchronous I/O operation only.
        local $SIG{__DIE__} = 'DEFAULT';
        $ok = eval {
            ($fh, $tmp) = tempfile('.download-XXXXXXXX', DIR => $dir, UNLINK => 0);
            close $fh or die "close temporary file: $!\n";
            my $size = $res->content->asset->size;
            $res->save_to($tmp);
            die "incomplete temporary file\n" unless -f $tmp && -s $tmp == $size;
            if ($validate) {
                open my $in, '<:raw', $tmp or die "read temporary file: $!\n";
                my $bytes = do { local $/; <$in> // '' };
                close $in or die "close temporary input: $!\n";
                # A rejected remote list is an ordinary result, not an exception.
                $failure = "invalid list content: $fn" unless download_valid($fn, $bytes);
            }
            unless (defined $failure) {
                if (-e $target) {
                    my $mode = (stat($target))[2];
                    chmod($mode & 0777, $tmp) or die "chmod temporary file: $!\n";
                } else {
                    chmod(0666 & ~umask(), $tmp) or die "chmod temporary file: $!\n";
                }
                rename($tmp, $target) or die "rename temporary file: $!\n";
            }
            1;
        };
        $failure = $@ || 'download write failed' unless $ok;
    }
    unlink $tmp if defined($tmp) && -e $tmp;
    return (undef, $failure) if defined $failure;
    return ($target, undef);
}

sub download_report {
    my ($state, $msg) = @_;
    LogDbg('dxcommand', $msg);
    # Cron uses the internal channel; keep its output in the native log.
    eval { $state->{self}->send($msg) } if $state->{self} != $main::me;
}

sub download_next {
    my ($state) = @_;
    my $job = shift @{$state->{jobs}};
    unless ($job) {
        download_report($state, "download: finished OK=$state->{ok} FAILED=$state->{failed}");
        return;
    }
    my ($url, $name, $fallback) = @$job;
    my $mirror_name = $fallback ? $name : download_mirror_name($url);
    $name = $mirror_name if defined $mirror_name;
    my $retry = sub {
        my ($err) = @_;
        $err ||= 'unknown error'; $err =~ s/[\r\n]+/ /g;
        if (!$fallback && defined $mirror_name) {
            download_report($state, "download: $url failed ($err); trying mirror");
            unshift @{$state->{jobs}}, [$kin_repo . $mirror_name, $mirror_name, 1];
        } else {
            ++$state->{failed};
            download_report($state, "download: ERROR $url: $err");
        }
    };
    my $self = $state->{self};
    my $ua = $fallback ? $state->{mirror_ua} : $state->{ua};
    my $started = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        my $tx = $ua->get($url => sub {
            my ($agent, $tx) = @_;
            my ($target, $failure);
            my $ok;
            {
                local $SIG{__DIE__} = 'DEFAULT';
                $ok = eval {
                    my $res = $tx->res;
                    my $err = $tx->error;
                    if ($err) {
                        $failure = $err->{message} // 'HTTP/connection error';
                    } elsif (!$res->is_success) {
                        $failure = 'HTTP response not successful';
                    } else {
                        my $fn = $name;
                        unless (defined $fn) {
                            my $path = $tx->req->url->to_abs->path;
                            ($fn) = "$path" =~ m{([^/]+)\z};
                        }
                        ($target, $failure) = download_store($res, $fn, defined $mirror_name);
                    }
                    1;
                };
                $failure = $@ || 'download callback failed' unless $ok;
            }
            delete $self->{$tx};
            if (defined $target && !defined $failure) {
                ++$state->{ok};
                download_report($state, "download: $target successfully downloaded" . ($fallback ? " (mirror)" : ""));
            } else {
                $retry->($failure);
            }
            download_next($state);
        });
        $self->{$tx} = {ua => $ua, tx => $tx};
        1;
    };
    unless ($started) {
        $retry->($@ || 'request failed');
        download_next($state);
    }
}

sub handle
{
    my ($self, $line) = @_;
    return (1, $self->msg('e5')) if $self->priv < 9 || $self->remotecmd;
    my $url = unpad($line // '');
    my @jobs = eval { download_expand($url) };
    if ($@) { my $err = $@; chomp $err; return (1, "download: ERROR $err") }
    my $batch = $url =~ /\*/ && defined($jobs[0][1]);
    my $ua = Mojo::UserAgent->new->insecure(1)->max_redirects(5);
    my $mirror_ua = Mojo::UserAgent->new->insecure(0)->max_redirects(0)->request_timeout(30);
    my $state = {self => $self, ua => $ua, mirror_ua => $mirror_ua, jobs => \@jobs, batch => $batch, ok => 0, failed => 0};
    my $count = scalar @jobs;
    download_next($state);
    return $batch ? (1, "download: started ($count files, result follows)") : (1);
}
