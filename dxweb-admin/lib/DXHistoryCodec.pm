package DXHistoryCodec;
use strict;
use warnings;
use Exporter 'import';
use Compress::Zlib ();
use Encode qw(is_utf8 encode FB_CROAK);
our @EXPORT_OK = qw(pack_bytes unpack_bytes);
our $VERSION = '0.34';
sub pack_bytes {
    my ($raw) = @_;
    die 'payload_undefined' unless defined $raw && !ref($raw);
    $raw = encode('UTF-8',$raw,FB_CROAK) if is_utf8($raw);
    my $zip = Compress::Zlib::compress($raw,6);
    die 'compress_failed' unless defined $zip;
    return length($raw)>=128 && length($zip)+16<length($raw) ? (1,$zip) : (0,$raw);
}
sub unpack_bytes {
    my ($codec,$blob,$limit) = @_;
    die 'payload_undefined' unless defined $blob;
    die 'invalid_codec' unless defined $codec && $codec =~ /\A[01]\z/;
    $limit = 64*1024*1024 unless defined $limit;
    die 'invalid_limit' unless $limit =~ /\A[0-9]+\z/ && $limit>0;
    return length($blob)<=$limit ? $blob : die 'limit_exceeded' if $codec==0;
    my ($inf,$status) = Compress::Zlib::inflateInit();
    die 'inflate_init_failed' unless $status == Compress::Zlib::Z_OK();
    my $out='';
    while (length $blob) {
        my $part=substr($blob,0,8192,'');
        my ($chunk,$st)=$inf->inflate($part);
        die 'inflate_failed' unless defined $chunk && ($st==Compress::Zlib::Z_OK() || $st==Compress::Zlib::Z_STREAM_END());
        $out.=$chunk;
        die 'limit_exceeded' if length($out)>$limit;
        if ($st==Compress::Zlib::Z_STREAM_END()) {
            die 'trailing_bytes' if length($blob);
            return $out;
        }
    }
    die 'incomplete_stream';
}
1;
