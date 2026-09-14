#
# Module for SQLite DXSql variants
#
# Stuff like table creates and (later) alters
#
# Copyright (c) 2005 Dirk Koopman G1TLH
# Modifications made for Pg, Copyright (c) 2012 Wijnand Modderman-Lenstra PD0MZ
#

package DXSql::Pg;

use DXDebug;

use vars qw(@ISA);
@ISA = qw{DXSql};

sub show_tables
{
	my $self = shift;
	#my $s = q(show tables);
    my $s = q(SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';);
	my $sth = $self->prepare($s);
	$sth->execute;
	my @out;
	while (my @t = $sth->fetchrow_array) {
		push @out, @t;
	}
	$sth->finish;
	return @out;
}

sub has_ipaddr
{
	my $self = shift;
	my $s = q(SELECT column_name FROM information_schema.columns WHERE table_name = 'spot');
	my $sth = $self->prepare($s);
	$sth->execute;
	while (my @t = $sth->fetchrow_array) {
		if ($t[0] eq 'ipaddr') {
			$sth->finish;
			return 1;
		}
	}
	$sth->finish;
	return undef;
}

sub add_ipaddr
{
	my $self = shift;
	my $s = q(alter table spot add column ipaddr varchar(40));
	$self->do($s);
}

sub spot_create_table
{
	my $self = shift;
	my $s = q{create table spot (
rowid bigserial primary key,
freq real not null,
spotcall varchar(14) not null,
time int not null,
comment varchar(255),
spotter varchar(14) not null,
spotdxcc smallint,
spotterdxcc smallint,
origin varchar(14),
spotitu smallint,
spotcq smallint,
spotteritu smallint,
spottercq smallint,
spotstate char(2),
spotterstate char(2),
ipaddr varchar(40)
)};
	$self->do($s);
}

sub spot_add_indexes
{
	my $self = shift;
	#dbg('adding spot index ix1');
	#$self->do('create index spot_ix1 on spot(time desc)');
	#dbg('adding spot index ix2');
	#$self->do('create index spot_ix2 on spot(spotcall asc)');
}

sub spot_insert_prepare
{
	my $self = shift;
	return $self->prepare(q{
		insert into spot
		(freq,spotcall,time,comment,spotter,spotdxcc,spotterdxcc,origin,
		 spotitu,spotcq,spotteritu,spottercq,spotstate,spotterstate,ipaddr)
		values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
	});
}

sub spot_insert
{
	my ($self, $spot, $sth) = @_;
	push @$spot, undef while @$spot < 15;
	pop @$spot while @$spot > 15;
	$sth ||= $self->spot_insert_prepare;
	my $r = $sth->execute(@$spot);
	die "DXSql PostgreSQL spot insert failed: " . ($sth->errstr || 'unknown SQL error')
		unless defined $r;
	return $r;
}

1;  
