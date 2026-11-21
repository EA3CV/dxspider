#!/usr/bin/perl
#
# Database update routine
#
# Copyright (c) 1999 Dirk Koopman G1TLH
#
my ($self, $line) = @_;
my ($name) = split /\s+/, $line;
my @out;

return (1, $self->msg('e5')) if $self->priv < 9;
return(1, "usage: dbremove <database name>" ) unless $name;

my $db = DXDb::getdesc($name);
if ($db) {
	$db->delete;
	push @out, $self->msg('db9', $name);
} else {
	return (1, $self->msg('db3', $name)) unless $db;
}

return (1, @out);
