# Per-process, bounded admission and authentication rate controls.
package DXWeb::Admission;
use strict;
use warnings;
use Time::HiRes qw(time);
sub new {
    my ($class,%args)=@_;
    return bless {connections=>{},attempts=>{},%args},$class;
}
sub _prune {
    my ($self,$now)=@_;
    # Periodic bounded retention; no unbounded per-IP history.
    return if $now - ($self->{last_prune}//0) < 30;
    $self->{last_prune}=$now;
    for my $ip (keys %{$self->{attempts}}) {
        my $a=$self->{attempts}{$ip};
        delete $self->{attempts}{$ip} if $now-$a->{start}>$self->{window}*2;
    }
}
sub connect {
    my ($self,$ip)=@_;
    my $now=time; $self->_prune($now);
    return 0 if ($self->{connections}{$ip}//0) >= $self->{per_ip};
    $self->{connections}{$ip}++;
    return 1;
}
sub disconnect {
    my ($self,$ip)=@_;
    return unless exists $self->{connections}{$ip};
    --$self->{connections}{$ip};
    delete $self->{connections}{$ip} if $self->{connections}{$ip}<=0;
}
sub auth_allowed {
    my ($self,$ip)=@_;
    my $now=time; $self->_prune($now);
    my $a=$self->{attempts}{$ip};
    if (!$a || $now-$a->{start}>=$self->{window}) {
        $a=$self->{attempts}{$ip}={start=>$now,count=>0};
    }
    return 0 if $a->{count}>=$self->{max_auth};
    ++$a->{count}; return 1;
}
1;
