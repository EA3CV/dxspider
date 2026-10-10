#
# accept/reject filter commands
#
# Copyright (c) 2000 Dirk Koopman G1TLH
#
#
#

my ($self, $line) = @_;
my $type = 'accept';
my $sort  = 'route';
return (1, $self->msg('e5')) if $self->remotecmd;
return (1, $self->msg('e5')) if $self->priv < 6;

my ($r, $filter, $fno) = $DXProt::pc92filterdef->cmd($self, $sort, $type, $line);
return (1, $r ? $filter : $self->msg('filter1', $fno, $filter->{name})); 
