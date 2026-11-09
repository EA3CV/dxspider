#
# show/topologyaudit
#
# RX-only audit of the live Route::Node topology.
# Runs in the DXSpider process; no I/O, persistence or routing mutation.
#
use strict;
use Route::Node;
use DXChannel;

sub _audit_bool { $_[0] ? 'yes' : 'no' }
sub _audit_num  { defined $_[0] ? $_[0] : 0 }

sub handle
{
    my ($self, $line) = @_;
    return (0, 'sysop only') unless ($self->{priv} || 0) >= 9;

    # Optional read-only node detail. No change to the original global audit.
    if (defined $line && $line =~ /\S/) {
        my @calls = map { uc $_ } grep { length $_ } split /\s+/, $line;
        return (0, 'Usage: show/topologyaudit [CALL ...]')
            if @calls > 10 || grep { !/^[A-Z0-9][A-Z0-9-]*$/ } @calls;
        my @out = ('DXSpider live topology node detail v0.1 (RX-only)');
        for my $call (@calls) {
            my $n = Route::Node::get($call);
            if (!$n) {
                push @out, "$call: not found";
                next;
            }
            my @parents = sort $n->parents;
            my @children = sort $n->nodes;
            my @users = sort $n->users;
            my $count = $n->usercount;
            push @out, '';
            push @out, "Node: $call";
            push @out, sprintf('PC9X: %s  via92: %s  K: %s  obs: %s',
                _audit_bool($n->do_pc9x), _audit_bool($n->via_pc92),
                _audit_num($n->{K}), _audit_num($n->{obscount}));
            push @out, sprintf('PC92 advertised: nodes=%s users=%s',
                defined $n->{pc92_nodes} ? $n->{pc92_nodes} : '-',
                defined $n->{pc92_users} ? $n->{pc92_users} : '-');
            push @out, sprintf('Last PC92C: %s',
                defined $n->{last_PC92C} ? $n->{last_PC92C} : '-');
            push @out, sprintf('Parents (%d): %s', scalar @parents,
                @parents ? join(', ', @parents) : '-');
            push @out, sprintf('Children (%d): %s', scalar @children,
                @children ? join(', ', @children) : '-');
            push @out, sprintf('Users: materialized=%d usercount=%s',
                scalar @users, defined $count ? $count : '-');
            push @out, sprintf('User calls (%d): %s', scalar @users,
                @users ? join(', ', @users) : '-');
        }
        return (1, @out);
    }

    my @nodes = sort { ($a->{call} || '') cmp ($b->{call} || '') } Route::Node::get_all();
    my %known = map { (($_->{call} || '') => 1) } @nodes;
    my (%child_rel, %parent_rel, %direct, %children, %parents);
    my ($pc9x, $nonpc9x) = (0,0);
    my ($material_users,$stored_usercount,$user_mismatch)=(0,0,0);

    for my $c (DXChannel::get_all()) {
        next unless eval { $c->is_node };
        $direct{$c->{call}}=1 if $c->{call};
    }

    for my $n (@nodes) {
        my $call=$n->{call}||next;
        my @c=eval{$n->nodes}; @c=() if $@;
        my @p=eval{$n->parents}; @p=() if $@;
        my @u=eval{$n->users}; @u=() if $@;
        my $uc=eval{$n->usercount}; $uc=0 if $@ || !defined $uc;
        $children{$call}=[@c]; $parents{$call}=[@p];
        $child_rel{"$call\0$_"}=1 for grep {defined($_)&&length($_)} @c;
        $parent_rel{"$_\0$call"}=1 for grep {defined($_)&&length($_)} @p;
        eval{$n->do_pc9x}?$pc9x++:$nonpc9x++;
        $material_users+=@u; $stored_usercount+=$uc; $user_mismatch++ if @u != $uc;
    }

    my @nodes_only=sort grep{!$parent_rel{$_}}keys%child_rel;
    my @parent_only=sort grep{!$child_rel{$_}}keys%parent_rel;
    my @symmetric=grep{$parent_rel{$_}}keys%child_rel;
    my @missing;
    for my $call(sort keys%children){
        push @missing,"$call child $_" for grep{!$known{$_}}@{$children{$call}};
        push @missing,"$call parent $_" for grep{!$known{$_}}@{$parents{$call}};
    }

    my @orphans;
    for my $n(@nodes){
        my $call=$n->{call}||next;
        next if $call eq ($main::mycall||'') || $direct{$call};
        next if @{$children{$call}||[]} || @{$parents{$call}||[]};
        push @orphans,$n;
    }

    my $MAX=650; my @snap=@nodes; splice(@snap,$MAX) if @snap>$MAX;
    my %included=map{(($_->{call}||'')=>1)}@snap;
    my(%snap_degree,%full_degree);
    for my $k(keys%child_rel){
        my($a,$b)=split(/\0/,$k,2);$full_degree{$a}++;$full_degree{$b}++;
        if($included{$a}&&$included{$b}){$snap_degree{$a}++;$snap_degree{$b}++}
    }
    my @snapshot_isolated=map{$_->{call}}sort{($a->{call}||'')cmp($b->{call}||'')}grep{
        my$c=$_->{call}||'';$c ne ''&&$included{$c}&&($full_degree{$c}||0)>0&&($snap_degree{$c}||0)==0
    }@snap;

    # USER-NODE ASSOCIATION AUDIT v0.1: read-only, in-memory checks.
    # Compare each edge in both directions, not merely aggregate counts.
    my @route_users = Route::User::get_all();
    my %user_by_call = map { (($_->{call} || '') => $_) } @route_users;
    my (%node_user_edge, %user_parent_edge, %multiplicity);
    my ($node_duplicate_edges, $parent_duplicate_edges) = (0, 0);
    for my $n (@nodes) {
        my $ncall = $n->{call} || next;
        my %seen;
        for my $ucall ($n->users) {
            next unless defined $ucall && length $ucall;
            $node_duplicate_edges++ if $seen{$ucall}++;
            $node_user_edge{"$ncall\0$ucall"} = 1;
        }
    }
    for my $u (@route_users) {
        my $ucall = $u->{call} || next;
        my %seen;
        my @up = $u->parents;
        $multiplicity{scalar @up}++;
        for my $ncall (@up) {
            next unless defined $ncall && length $ncall;
            $parent_duplicate_edges++ if $seen{$ncall}++;
            $user_parent_edge{"$ncall\0$ucall"} = 1;
        }
    }
    my @node_only_user = sort grep { !$user_parent_edge{$_} } keys %node_user_edge;
    my @parent_only_user = sort grep { !$node_user_edge{$_} } keys %user_parent_edge;
    my @missing_user = grep {
        my (undef, $ucall) = split /\0/, $_, 2;
        !$user_by_call{$ucall}
    } keys %node_user_edge;
    my @missing_node = grep {
        my ($ncall) = split /\0/, $_, 2;
        !$known{$ncall}
    } keys %user_parent_edge;
    my $unique_users = scalar @route_users;
    my $extra_associations = $material_users - $unique_users;
    my @out;
    push @out,'DXSpider live topology audit v0.3.1 (RX-only)';
    push @out,sprintf('Route nodes: %d  PC9X: %d  Non-PC9X: %d  Direct: %d',scalar(@nodes),$pc9x,$nonpc9x,scalar(keys%direct));
    push @out,sprintf('Relations nodes[]: %d  parent[]: %d  symmetric: %d',scalar(keys%child_rel),scalar(keys%parent_rel),scalar(@symmetric));
    push @out,sprintf('nodes-only: %d  parent-only: %d  absent refs: %d  true orphans: %d',scalar(@nodes_only),scalar(@parent_only),scalar(@missing),scalar(@orphans));
    push @out,sprintf('users[] total: %d  usercount total: %d  mismatching nodes: %d',$material_users,$stored_usercount,$user_mismatch);
    push @out, sprintf('Unique route users: %d  User-node associations: %d  Extra: %+d',
        $unique_users, $material_users, $extra_associations);
    push @out, sprintf('User links: node-only=%d parent-only=%d missing-user=%d missing-node=%d',
        scalar(@node_only_user), scalar(@parent_only_user),
        scalar(@missing_user), scalar(@missing_node));
    push @out, sprintf('Duplicate links: node users[]=%d user parents[]=%d',
        $node_duplicate_edges, $parent_duplicate_edges);
    push @out, 'Users by parent count: ' . join('  ',
        map { "$_=$multiplicity{$_}" } sort { $a <=> $b } keys %multiplicity);
    for my $spec (
        ['node-only user links', \@node_only_user],
        ['parent-only user links', \@parent_only_user],
        ['missing user links', \@missing_user],
        ['missing node links', \@missing_node],
    ) {
        my ($label, $edges) = @$spec;
        next unless @$edges;
        my @examples = map {
            my ($n, $u) = split /\0/, $_, 2;
            "$n/$u"
        } @$edges[0 .. ($#$edges < 9 ? $#$edges : 9)];
        push @out, "$label examples: " . join(' ', @examples);
    }

    push @out,sprintf('Current 650-node snapshot: selected=%d truncated=%s snapshot-only isolated=%d',scalar(@snap),@nodes>$MAX?'yes':'no',scalar(@snapshot_isolated));

    if(@orphans){
        push @out,'';
        push @out,'TRUE ORPHAN DETAILS';
        push @out,'CALL             pc9x via92 K   obs   parents children users usercount';
        for my $n(@orphans){
            my $call=$n->{call}||'';
            my @u=eval{$n->users}; @u=() if $@;
            my $uc=eval{$n->usercount};$uc=0 if $@||!defined$uc;
            my $obs=defined($n->{obscount})?$n->{obscount}:'-';
            my $k=defined($n->{K})?$n->{K}:'-';
            push @out,sprintf('%-16s %-5s %-5s %-3s %-5s %-7d %-8d %-5d %d',
                $call,_audit_bool(eval{$n->do_pc9x}),_audit_bool(eval{$n->via_pc92}),
                $k,$obs,scalar(@{$parents{$call}||[]}),scalar(@{$children{$call}||[]}),scalar(@u),$uc);
        }

        my @expired=grep{
            (eval{$_->do_pc9x}||eval{$_->via_pc92}) &&
            defined($_->{obscount}) && $_->{obscount} <= 0
        }@orphans;
        push @out,'';
        push @out,sprintf('Orphans PC9X/via92 with obscount <= 0: %d',scalar(@expired));
        push @out,'Expired orphan calls: '.join(' ',map{$_->{call}}@expired) if @expired;
    }

    if(@snapshot_isolated){
        push @out,'Snapshot-only isolated: '.join(' ',@snapshot_isolated);
    }
    if(@nodes_only){
        my @x=map{my($a,$b)=split(/\0/,$_,2);"$a->$b"}@nodes_only[0..($#nodes_only<19?$#nodes_only:19)];
        push @out,'nodes-only examples: '.join(' ',@x);
    }
    if(@parent_only){
        my @x=map{my($a,$b)=split(/\0/,$_,2);"$a->$b"}@parent_only[0..($#parent_only<19?$#parent_only:19)];
        push @out,'parent-only examples: '.join(' ',@x);
    }
    return (1,@out);
}
1;
