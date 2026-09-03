#!/usr/bin/perl -w
#
# Local 'autoqsl' module for DXSpider
#
# Copyright (c) 2003 Dirk Koopman G1TLH
#

package QSL;

use strict;
use SysVar;
use DXUtil;
use DXDebug;
use Prefix;
use DXJSON;
use DBI;
use Fcntl qw(O_RDONLY);
use Data::Structure::Util qw(unbless);

use vars qw($qslfn $dbm $maxentries);
$qslfn = 'dxqsl';
$dbm = undef;
$maxentries = 50;

my $json;
my $readonly;
my $dsn;
my ($get_sth, $put_sth);

localdata_mv("$qslfn.v1j");

sub _dsn
{
    return $main::qsldsn if defined $main::qsldsn && $main::qsldsn;
    return "dbi:SQLite:dbname=" . localdata("$qslfn.db");
}

sub _sqlite_path
{
    my $d = shift;
    my ($path) = $d =~ /dbname=([^;]+)/i;
    die "QSL: cannot determine SQLite path from '$d'" unless defined $path && length $path;
    return $path;
}

sub _dsn_for_path
{
    my ($d, $path) = @_;
    my $copy = $d;
    $copy =~ s/(dbname=)[^;]+/$1$path/i
        or die "QSL: cannot replace SQLite path in '$d'";
    return $copy;
}

sub _connect
{
    my ($d, $ro) = @_;
    my %attr = (
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    );
    $attr{sqlite_open_flags} = 1 if $ro; # SQLITE_OPEN_READONLY

    my $dbh = DBI->connect($d, '', '', \%attr)
        or die "QSL: SQLite connect failed for $d: $DBI::errstr";
    $dbh->do('PRAGMA busy_timeout = 5000');
    return $dbh;
}

sub _create_schema
{
    my $dbh = shift;
    $dbh->do(q{CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)});
}

sub _integrity_ok
{
    my $dbh = shift;
    my ($r) = $dbh->selectrow_array('PRAGMA integrity_check');
    return defined $r && lc($r) eq 'ok';
}

sub _migrate_legacy
{
    my ($legacy, $dest_dsn) = @_;
    my $dest = _sqlite_path($dest_dsn);
    return 0 if -e $dest;
    return 0 unless -e $legacy;

    # DB_File is required only for the one-time migration. Normal SQLite
    # operation does not load or depend on Berkeley DB.
    eval { require DB_File; 1 }
        or die "QSL: DB_File is required to migrate $legacy: $@";

    my $tmp = "$dest.new";
    unlink $tmp if -e $tmp;

    my %old;
    tie %old, 'DB_File', $legacy, O_RDONLY, 0, $DB_File::DB_BTREE
        or die "QSL: cannot open legacy database $legacy: $!";

    my $tdsn = _dsn_for_path($dest_dsn, $tmp);
    my $dbh = _connect($tdsn, 0);
    _create_schema($dbh);
    my $sth = $dbh->prepare(q{INSERT INTO kv (key,value) VALUES (?,?)});
    my $count = 0;

    my $ok = eval {
        $dbh->begin_work;
        while (my ($key, $value) = each %old) {
            $sth->execute($key, $value);
            ++$count;
        }
        $dbh->commit;
        1;
    };
    unless ($ok) {
        my $err = $@ || 'unknown migration error';
        eval { $dbh->rollback };
        $sth = undef;
        $dbh->disconnect;
        untie %old;
        unlink $tmp;
        die "QSL: migration failed: $err";
    }

    untie %old;
    my ($sql_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM kv');
    die "QSL: migration count mismatch ($count != $sql_count)"
        unless $count == $sql_count;
    die "QSL: SQLite integrity_check failed for $tmp" unless _integrity_ok($dbh);
    $sth = undef;
    $dbh->disconnect;

    rename $tmp, $dest or die "QSL: cannot rename $tmp to $dest: $!";
    return $count;
}

sub init
{
    my $mode = shift;
    $json = DXJSON->new;

    Prefix::load() unless Prefix::loaded();
    finish() if $dbm;

    $readonly = !$mode;
    $dsn = _dsn();
    die "QSL: only SQLite is supported by qsldsn" unless $dsn =~ /^dbi:SQLite:/i;

    my $path = _sqlite_path($dsn);
    my $legacy = localdata("$qslfn.v1j");
    my $migrated = _migrate_legacy($legacy, $dsn) unless -e $path;
    dbg("QSL migrated $migrated records from $legacy to $path") if $migrated && isdbg('sql');

    unless (-e $path) {
        # A fresh installation is valid even when QSL is opened read-only.
        # Create the empty schema once, then reopen it with the requested mode.
        my $dbh = _connect($dsn, 0);
        _create_schema($dbh);
        die "QSL: SQLite integrity_check failed for new database $path"
            unless _integrity_ok($dbh);
        $dbh->disconnect;
    }

    $dbm = _connect($dsn, $readonly);
    my ($table) = $dbm->selectrow_array(
        q{SELECT name FROM sqlite_master WHERE type='table' AND name='kv'}
    );
    die "QSL: missing kv table in $path" unless defined $table;
    return $dbm;
}

sub finish
{
    dbg("DXQSL finished");
    $get_sth = undef;
    $put_sth = undef;
    $dbm->disconnect if $dbm;
    undef $dbm;
}

sub new
{
    my ($pkg, $call) = @_;
    return bless [uc $call, []], $pkg;
}

# called $self->update(comment, time, spotter)
# $self has the callsign as the first argument in an array of array references
# the format of each entry is [manager, times found, last time, last reporter]
sub update
{
    return unless $dbm && !$readonly;
    my $self = shift;
    my $line = shift;
    my $t = shift;
    my $by = shift;
    my $changed;
    return unless length $line && $line =~ /\b(?:QSL|VIA)\b/i;
    foreach my $man (split /\b/, uc $line) {
        my $tok;

        if (is_callsign($man) && !is_qra($man)) {
            my @pre = Prefix::extract($man);
            $tok = $man if @pre && $pre[0] ne 'Q';
        } elsif ($man =~ /^BUR/) {
            $tok = 'BUREAU';
        } elsif ($man =~ /^LOTW/) {
            $tok = 'LOTW';
        } elsif ($man eq 'HC' || $man =~ /^HOM/ || $man =~ /^DIR/) {
            $tok = 'HOME CALL';
        } elsif ($man =~ /^QRZ/) {
            $tok = 'QRZ.com';
        } else {
            next;
        }
        if ($tok) {
            my ($r) = grep {$_->[0] eq $tok} @{$self->[1]};
            if ($r) {
                $r->[1]++;
                if ($t > $r->[2]) {
                    $r->[2] = $t;
                    $r->[3] = $by;
                }
                $changed++;
            } else {
                $r = [$tok, 1, $t, $by];
                unshift @{$self->[1]}, $r;
                $changed++;
            }
            pop @{$self->[1]} while (@{$self->[1]} > $maxentries);
        }
    }
    $self->put if $changed;
}

sub get
{
    return undef unless $dbm;
    my $key = uc shift;
    $get_sth ||= $dbm->prepare(q{SELECT value FROM kv WHERE key = ?});
    $get_sth->execute($key);
    my ($value) = $get_sth->fetchrow_array;
    return undef unless defined $value;
    return decode($value);
}

sub put
{
    return unless $dbm && !$readonly;
    my $self = shift;
    my $key = $self->[0];
    my $value = encode($self);
    $put_sth ||= $dbm->prepare(q{INSERT OR REPLACE INTO kv (key,value) VALUES (?,?)});
    return $put_sth->execute($key, $value);
}

sub remove_files
{
    finish() if $dbm;
    unlink "$main::data/$qslfn.v1j";
    unlink "$main::local_data/$qslfn.v1j";

    my $path = _sqlite_path(_dsn());
    unlink $path;
    unlink "$path-journal";
    unlink "$path-wal";
    unlink "$path-shm";
    unlink "$path.new";
}

sub decode
{
    return $json->decode($_[0], __PACKAGE__);
}

sub encode
{
    return $json->encode($_[0]);
}

sub END
{
    if ($dbm) {
        dbg "DXQSL ENDing";
        finish();
    }
}

1;
