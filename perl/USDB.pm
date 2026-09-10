#
# Package to handle US Callsign -> City, State translations
#
# Copyright (c) 2002 Dirk Koopman G1TLH
#

package USDB;

use strict;

use DXVars;
use SysVar;
use DXDebug;
use DXUtil;
use DBI;
use Fcntl qw(O_RDONLY);
use IO::File;
use File::Copy qw(copy);

use vars qw(%db $present $dbfn);

%db = ();                       # retained for external compatibility; storage is SQLite
$present = undef;
localdata_mv("usdb.v1");
$dbfn = localdata("usdb.v1");

my $dsn;
my $dbh;
my ($get_sth, $put_sth, $del_sth);

sub _dsn
{
    return $main::usdbdsn if defined $main::usdbdsn && $main::usdbdsn;
    return "dbi:SQLite:dbname=" . localdata("usdb.db");
}

sub _sqlite_path
{
    my $d = shift;
    my ($path) = $d =~ /dbname=([^;]+)/i;
    die "USDB: cannot determine SQLite path from '$d'" unless defined $path && length $path;
    return $path;
}

sub _dsn_for_path
{
    my ($d, $path) = @_;
    my $copy = $d;
    $copy =~ s/(dbname=)[^;]+/$1$path/i
        or die "USDB: cannot replace SQLite path in '$d'";
    return $copy;
}

sub _connect
{
    my $d = shift;
    my $h = DBI->connect($d, '', '', {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    }) or die "USDB: SQLite connect failed for $d: $DBI::errstr";
    $h->do('PRAGMA busy_timeout = 5000');
    return $h;
}

sub _create_schema
{
    my $h = shift;
    $h->do(q{CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)});
}

sub _integrity_ok
{
    my $h = shift;
    my ($r) = $h->selectrow_array('PRAGMA integrity_check');
    return defined $r && lc($r) eq 'ok';
}

sub _migrate_legacy
{
    my ($legacy, $dest_dsn) = @_;
    my $dest = _sqlite_path($dest_dsn);
    return 0 if -e $dest;
    return 0 unless -e $legacy;

    # DB_File is loaded only for the one-time legacy import.
    eval { require DB_File; 1 }
        or die "USDB: DB_File is required to migrate $legacy: $@";

    my $tmp = "$dest.new";
    unlink $tmp if -e $tmp;

    my %old;
    tie %old, 'DB_File', $legacy, O_RDONLY, 0, $DB_File::DB_BTREE
        or die "USDB: cannot open legacy database $legacy: $!";

    my $tdsn = _dsn_for_path($dest_dsn, $tmp);
    my $h = _connect($tdsn);
    _create_schema($h);
    my $sth = $h->prepare(q{INSERT INTO kv (key,value) VALUES (?,?)});
    my $count = 0;

    my $ok = eval {
        $h->begin_work;
        while (my ($key, $value) = each %old) {
            $sth->execute($key, $value);
            ++$count;
        }
        $h->commit;
        1;
    };
    unless ($ok) {
        my $err = $@ || 'unknown migration error';
        eval { $h->rollback };
        $sth = undef;
        $h->disconnect;
        untie %old;
        unlink $tmp;
        die "USDB: migration failed: $err";
    }

    untie %old;
    my ($sql_count) = $h->selectrow_array('SELECT COUNT(*) FROM kv');
    die "USDB: migration count mismatch ($count != $sql_count)"
        unless $count == $sql_count;
    die "USDB: SQLite integrity_check failed for $tmp" unless _integrity_ok($h);
    $sth = undef;
    $h->disconnect;

    rename $tmp, $dest or die "USDB: cannot rename $tmp to $dest: $!";
    return $count;
}

sub init
{
    end();
    $dsn = _dsn();
    die "USDB: only SQLite is supported by usdbdsn" unless $dsn =~ /^dbi:SQLite:/i;

    my $path = _sqlite_path($dsn);
    my $migrated = _migrate_legacy($dbfn, $dsn) unless -e $path;
    dbg("USDB migrated $migrated KV records from $dbfn to $path") if $migrated && isdbg('sql');

    unless (-e $path) {
        # Missing legacy data is a valid fresh-install state.
        # Create an empty SQLite KV store so callers see normal "not found"
        # semantics instead of a missing backend.
        my $h = _connect($dsn);
        _create_schema($h);
        die "USDB: SQLite integrity_check failed for new database $path"
            unless _integrity_ok($h);
        $h->disconnect;
    }

    $dbh = _connect($dsn);
    my ($table) = $dbh->selectrow_array(
        q{SELECT name FROM sqlite_master WHERE type='table' AND name='kv'}
    );
    die "USDB: missing kv table in $path" unless defined $table;

    $present = 1;
    return "US Database loaded";
}

sub end
{
    $get_sth = undef;
    $put_sth = undef;
    $del_sth = undef;
    $dbh->disconnect if $dbh;
    undef $dbh;
    undef $present;
}

sub _get_value
{
    my ($h, $sth_ref, $key) = @_;
    $$sth_ref ||= $h->prepare(q{SELECT value FROM kv WHERE key = ?});
    $$sth_ref->execute($key);
    my ($value) = $$sth_ref->fetchrow_array;
    return $value;
}

sub _put_value
{
    my ($h, $sth_ref, $key, $value) = @_;
    $$sth_ref ||= $h->prepare(q{INSERT OR REPLACE INTO kv (key,value) VALUES (?,?)});
    return $$sth_ref->execute($key, $value);
}

sub get
{
    return () unless $present;
    my $ctyn = _get_value($dbh, \$get_sth, $_[0]);
    return () unless $ctyn;
    my $value = _get_value($dbh, \$get_sth, $ctyn);
    return () unless defined $value;
    return split /\|/, $value;
}

sub _add
{
    my ($h, $get_ref, $put_ref, $call, $city, $state) = @_;

    my $s = uc "$city|$state";
    my $ctyn = _get_value($h, $get_ref, $s);
    unless ($ctyn) {
        my $no = _get_value($h, $get_ref, '##') || 1;
        $ctyn = "#$no";
        _put_value($h, $put_ref, $s, $ctyn);
        _put_value($h, $put_ref, $ctyn, $s);
        ++$no;
        _put_value($h, $put_ref, '##', "$no");
    }
    _put_value($h, $put_ref, uc $call, $ctyn);
    return $ctyn;
}

sub add
{
    return unless $present;
    my $ret;
    my $ok = eval {
        $dbh->begin_work;
        $ret = _add($dbh, \$get_sth, \$put_sth, @_);
        $dbh->commit;
        1;
    };
    unless ($ok) {
        my $err = $@ || 'unknown USDB add error';
        eval { $dbh->rollback };
        die $err;
    }
    return $ret;
}

sub getstate
{
    return () unless $present;
    my @s = get($_[0]);
    return @s ? $s[1] : undef;
}

sub getcity
{
    return () unless $present;
    my @s = get($_[0]);
    return @s ? $s[0] : undef;
}

sub del
{
    return unless $present;
    my $call = uc shift;
    my $old = _get_value($dbh, \$get_sth, $call);
    return undef unless defined $old;
    $del_sth ||= $dbh->prepare(q{DELETE FROM kv WHERE key = ?});
    $del_sth->execute($call);
    return $old;
}

sub _open_input
{
    my $ofn = shift;
    return (undef, "Cannot find $ofn") unless -r $ofn;

    if ($ofn =~ /\.gz$/i) {
        my $gz;
        eval qq{use Compress::Zlib; \$gz = gzopen(\$ofn, "rb")};
        return (undef, "Cannot read compressed files $@ $!") if $@ || !$gz;
        return ({ gz => $gz, name => $ofn }, undef);
    }

    my $fh = IO::File->new($ofn);
    return (undef, "Cannot read $ofn $!") unless $fh;
    return ({ fh => $fh, name => $ofn }, undef);
}

sub _each_line
{
    my ($input, $cb) = @_;
    if ($input->{fh}) {
        while (defined(my $line = $input->{fh}->getline)) {
            $cb->($line);
        }
        $input->{fh}->close;
        return;
    }

    my $gz = $input->{gz};
    my ($len, $buf, $pending) = (0, '', '');
    while (($len = $gz->gzread($buf)) > 0) {
        $pending .= $buf;
        while ($pending =~ s/^(.*?\n)//) {
            $cb->($1);
        }
    }
    $cb->($pending) if length $pending;
    $gz->gzclose;
}

# Rebuild the complete database from standard CALL|CITY|STATE files.
# Input files are never removed by this implementation.
sub load
{
    return "Need a filename" unless @_;
    $dsn = _dsn();
    die "USDB: only SQLite is supported by usdbdsn" unless $dsn =~ /^dbi:SQLite:/i;

    my @files = @_;
    for my $f (@files) {
        return "Cannot find $f" unless -r $f;
    }

    my $path = _sqlite_path($dsn);
    my $tmp = "$path.new";
    unlink $tmp if -e $tmp;
    my $tdsn = _dsn_for_path($dsn, $tmp);
    my $h;
    my $count = 0;

    my $ok = eval {
        $h = _connect($tdsn);
        _create_schema($h);
        my ($gst, $pst);
        $h->begin_work;

        for my $ofn (@files) {
            my ($input, $err) = _open_input($ofn);
            die "$err\n" if $err;
            _each_line($input, sub {
                my $line = shift;
                $line =~ s/[\r\n]+$//;
                my ($call, $city, $state) = split /\|/, $line, 3;
                _add($h, \$gst, \$pst, $call, $city, $state);
                ++$count;
            });
        }

        $h->commit;
        die "USDB: SQLite integrity_check failed for $tmp" unless _integrity_ok($h);
        $gst = $pst = undef;
        $h->disconnect;
        undef $h;
        1;
    };
    unless ($ok) {
        my $err = $@ || 'USDB rebuild failed';
        eval { $h->rollback if $h };
        eval { $h->disconnect if $h };
        unlink $tmp;
        return $err;
    }

    end();
    my $old = "$path.old";
    my $had_old = -e $path;
    if ($had_old) {
        unlink $old if -e $old;
        rename $path, $old or return "cannot rename $path -> $old $!";
    }
    unless (rename $tmp, $path) {
        my $err = $!;
        rename $old, $path if $had_old && -e $old && !-e $path;
        return "cannot rename $tmp -> $path $err";
    }

    init();
    return "$count records";
}

1;
