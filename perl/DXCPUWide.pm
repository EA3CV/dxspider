package DXCPUWide;
use strict;
use warnings;
use Time::HiRes ();
# All calls remain in the original Perl calling context, with the original @_ aliases.
# The lexical scope guard measures on normal return and exception unwinding.
my %targets = (
    'DXProtHandle' => [qw(handle_61 handle_92 _pc92_handle_92_original _pc92_acd_preflight _pc92_k_preflight _pc92_acd_guarded _pc92_acd_route_event _pc92_acd_broadcast _pc92_acd_early_duplicate _pc92_acd_early_time_invalid _pc92_c_graph_checkpoint _pc92_c_graph_restore _pc92_acd_user_checkpoint _pc92_acd_user_restore _add_thingy _del_thingy gen_pc92_changes populate_routing_table find_pc9x_routes)],
    'DXProtout' => [qw(pc61 pc91 pc92a pc92c pc92d pc92k _gen_pc92)],
    'DXProt' => [qw(check normal route send_dx_spot dx_spot send_prot_line route_pc92a route_pc92c route_pc92d broadcast_route_pc9x send_route_pc92 broadcast_pc92_update broadcast_pc92_keepalive time_out_pc92_routes eph_dup eph_clean)],
    'DXChannel' => [qw(process_one process rec send send_now send_later decode_input broadcast_nodes broadcast_all_nodes broadcast_users broadcast_list get_all get_all_users get_all_nodes)],
    'Route::Node' => [qw(new add del delete del_nodes add_user del_user calc_config_changes _addparent _delparent _addnode _delnode _adduser _deluser write_cache read_cache)],
    'Route::User' => [qw(new del addparent delparent write_cache read_cache)],
    'Route' => [qw(read_cache findroutes)],
    'DXDupe' => [qw(check_add find add del)],
    'Spot' => [qw(add_local prepare dup_add dup_find dup_new clean_cache)],
    'DXCIDR' => [qw(find covered _spec_interval add _sort clean_prep reload)],
    'DXUser' => [qw(get put new sync get_all_calls)],
    'Filter' => [qw(it getfilters load_dxchan)],
    'RBN' => [qw(normal send_dx_spot dx_spot send_final write_cache)],
    'DXHealth' => [qw(protocol_reject_unknown protocol_reject_malformed protocol_physical_in_line)],
    'Local' => [qw(pcprot)],
    'DXTimer' => [qw()],
    'DXCron' => [qw()],
    'DXLog' => [qw()],
    'DXDb' => [qw()],
    'DXCommandmode' => [qw()],
    'DXConnect' => [qw()],
 );

# Additional targets derived from real 2026-11-13 source definitions, not guessed APIs.
my %deep_targets = (
    'DXCIDR' => [qw(_fn _read _load _put append add clean_prep _sort list find _spec_interval covered status covered_suffix valid_spec _interval_cidrs remove init _touch reload)],
    'DXChannel' => [qw(alloc check_cnum_debugging _error_out rebless rec del sort sleep send_now send_later send send_file msg delay state disconnect closeall tell_login tell_buddies fields field_prompt decode_input broadcast_nodes broadcast_all_nodes broadcast_users broadcast_list process_one process handle_xml error_handler refresh_user replace)],
    'DXCommandmode' => [qw(start normal special_prompt talk_prompt chat_prompt send_ans run_cmd run_cmd_with_status process disconnect prompt broadcast run_script search clear_cmd_cache valid_package_name find_cmd_name send local_send announce talk chat send_talks send_chats format_dx_spot dx_spot wwv wcy broadcast_debug do_entry_stuff store_startup_script import_cmd print_find_reply send_motd spawn_cmd user_count)],
    'DXConnect' => [qw(init process)],
    'DXCron' => [qw(init cread parse process connected present presentish present_on presentish_on last_connect disconnect start_connect spawn spawn_cmd rcmd run_cmd)],
    'DXDb' => [qw(newstream delstream load save open close closeall putkey delete normal process handle_37 handle_44 handle_45 handle_46 handle_47 handle_48 sendremote print fields field_prompt)],
    'DXDupe' => [qw(init finish check_add find add del clean listdups)],
    'DXHash' => [qw(put add del in _list_files _list_read _list_write _list_command unset show)],
    'DXHealth' => [qw(metrics_collection_enabled _bounded_inc operator_event local_duplicate_spot connection_badip _snapshot_dimension operator_snapshot protocol_reject_unknown protocol_reject_malformed _connection_host _connection_direction _connection_touch _connection_kind logical_web_up logical_web_down logical_web_snapshot connection_attempt connection_rapid_throttled connection_incoming_success connection_up connection_down connection_too_many _connection_prune connection_snapshot _pc_from_line _protocol_inc protocol_physical_in_line protocol_physical_out_line local_spot_generated protocol_logical_inc protocol_logical_line protocol_logical_origin_line protocol_origin_inc protocol_snapshot _sort _line_sort _inc pc92_generated pc92_generated_line pc92_received pc92_forwarded pc92_physical_in pc92_physical_out pc92_physical_out_line _copy_bucket pc92k_advertised pc92k_advertised_get pc92_snapshot pc92_reset _spot_rank_inc accepted_spot_rank spot_rank_take_snapshot)],
    'DXLog' => [qw(_genfn open fn delete mtime openprev opennext unixtoj write writenow writeunix close flushall Log LogDbg Logclose)],
    'DXProt' => [qw(check update_pc92_next update_pc92_keepalive init start sendinit normal process send_dx_spot dx_spot send_prot_line send_wwv_spot wwv send_wcy_spot wcy send_announce nextchatmsgid send_chat announce chat send_local_config gen_my_pc92_config send_last_pc92_config send_pc92_config broadcast_pc92_update broadcast_pc92_keepalive time_out_pc92_routes route adjust_hops load_hops process_rcmd send_rcmd_reply spawn_cmd process_rcmd_reply addrcmd disconnect talk send_route broadcast_route broadcast_route_nopc9x send_route_pc92 broadcast_route_pc9x route_pc16 route_pc17 route_pc19 route_pc21 route_pc24 route_pc41 route_pc50 route_pc92c route_pc92a route_pc92d in_filter_route eph_dup eph_del_regex eph_clean eph_list run_cmd import_chat start_pc92_find handle_pc92_find_reply clean_pc92_find)],
    'DXProtHandle' => [qw(check_available handle_10 handle_11 pc11_process handle_12 handle_15 handle_16 handle_17 handle_18 check_add_user handle_19 handle_20 handle_21 handle_22 handle_23 handle_24 handle_25 handle_26 handle_27 handle_28 handle_29 handle_30 handle_31 handle_32 handle_33 handle_34 handle_35 handle_36 handle_37 handle_38 handle_39 handle_40 handle_41 handle_42 handle_44 handle_45 handle_46 handle_47 handle_48 handle_49 handle_50 handle_51 handle_61 handle_75 handle_73 handle_84 handle_85 _decode_pc92_call _encode_pc92_call _pc92_user_is_known_node _pc92_invalid_extnode_user _pc92_acd_log _pc92_acd_metric _pc92_acd_tell_buddies _add_thingy _del_thingy gen_pc92_changes clear_pc92_changes last_pc9x_id gen_pc9x_t check_pc9x_t pc92_handle_first_slot _pc92_k_preflight _pc92_malformed_reject _pc92_acd_preflight _pc92_acd_wire_object _pc92_acd_ip _pc92_acd_early_time_invalid _pc92_acd_early_duplicate _pc92_acd_route_event _pc92_acd_broadcast _pc92_snapshot_value _pc92_route_object_snapshot _pc92_c_graph_checkpoint _pc92_acd_user_checkpoint _pc92_acd_user_restore _pc92_c_graph_restore _pc92_acd_guarded handle_92 _pc92_handle_92_original find_pc9x_routes find_chat_group_users handle_93 handle_default populate_routing_table)],
    'DXProtout' => [qw(pc10 pc11 pc61 pc12 pc16 pc17 pc18 pc19 pc20 pc21 pc22 pc24 pc26 pc27 pc28 pc29 pc30 pc31 pc32 pc33 pc34 pc35 pc38 pc39 pc40 pc41 pc42 pc44 pc45 pc46 pc49 pc50 pc51 pc84 pc85 pc91 _gen_pc92 gen_pc92_with_time pc92a pc92d pc92c pc92k pc92f pc92r pc93 _encode_maybe_rfc1918_ip)],
    'DXSupervisor' => [qw(_num _qlen _bool _maybe_bool _dxspider_version _kind _base capabilities status _configured_peers connections traffic web rbn topology spot_ranks self_health snapshot)],
    'DXTimer' => [qw(del handler)],
    'DXUser' => [qw(init using_database open_database _create_table _table_exists del_file process alloc put interate decode encode del close sync _import_from_v3j fields add_group del_group in_group new_group new_buddies field_prompt sort _want _wantnot wantbeep wantann wantwwv wantwcy wantecho wantwx wantdx wanttalk wantgrid wantemail wantann_talk wantpc16 wantsendpc16 wantroutepc16 wantusstate wantdxcq wantdxitu wantgtk wantpc9x wantlogininfo unset_passwd unset_passphrase unset_believe believe lastping export export_preamble recover finish)],
    'Filter' => [qw(init compile read_in write it print install load_dxchan delete encode_regex decode_regex include_regex parse cmd it print)],
    'RBN' => [qw(init start normal send_dx_spot dx_spot send_final process per_minute per_10_minute per_hour finish write_cache check_cache add_seeme del_seeme)],
    'Route' => [qw(_addlist _dellist here conf parents user_call config cluster findroutes alldxchan dxchan delete_interface basecall_no fields field_prompt write_cache read_cache)],
    'Route::Node' => [qw(count max add del delete del_nodes _del_users add_user del_user usercount users nodes rnodes calc_config_changes _addparent _delparent _addnode _delnode _adduser _deluser dec_obs reset_obs measure_pc9x_t PC92C_dxchan TO_JSON write_cache read_cache)],
    'Route::User' => [qw(count max del addparent delparent TO_JSON write_cache read_cache)],
    'Spot' => [qw(decodefreq filterrbnspot init prefix prepare add_local search ftor formatl dup_add handle_dupecalls dup_find dup_new listdups genstats checkstats daily _cachek clean_cache)],
 );
my $deep_enabled = 0;
my $config_file = '/spider/local_data/cpu-wide-control.conf';
my $last_config = -1;
sub _read_config {
    my $mtime = (stat($config_file))[9] // 0;
    return if $mtime == $last_config;
    $last_config = $mtime;
    my $deep = 0;
    if (open my $fh, '<', $config_file) {
        while (my $line = <$fh>) { $deep = $1 if $line =~ /^\s*deep\s*=\s*([01])\s*$/; }
        close $fh;
    }
    $deep_enabled = $deep;
    main::LogDbg('cpu', "CPU_WIDE_CONFIG deep=$deep_enabled");
}
sub _measure_memory {
    my %v;
    if (open my $fh, '<', '/proc/self/status') {
        while (<$fh>) { $v{$1} = $2 if /^(VmRSS|VmHWM|VmSize|RssAnon|RssFile|RssShmem|VmData):\s+(\d+)\s+kB/; }
        close $fh;
    }
    my $timers = eval { scalar @DXTimer::timerchain };
    $v{timers} = $timers if defined $timers;
    main::LogDbg('cpu', 'CPU_WIDE_MEMORY ' . join(' ', map { "$_=$v{$_}" } sort keys %v));
}

our %stats;
our @stack;
my $installed = 0;
my $enabled = 1;
sub _cpu { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_PROCESS_CPUTIME_ID()) }
sub _wall { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) }
sub install {
    no strict 'refs';
    no warnings 'redefine';
    _read_config();
    my %seen;
    for my $group (['base', \%targets], ['deep', \%deep_targets]) {
        my ($level, $set) = @$group;
        for my $pkg (sort keys %$set) {
            for my $name (@{$set->{$pkg}}) {
                # DXProtHandle.pm and DXProtout.pm declare package DXProt.
                # Their filenames are not Perl namespaces.
                my $real_pkg = ($pkg eq 'DXProtHandle' || $pkg eq 'DXProtout') ? 'DXProt' : $pkg;
                my $full = "${real_pkg}::${name}";
                next if $seen{$full}++;
                my $orig = *{$full}{CODE};
                next unless $orig;
                my $is_deep = $level eq 'deep';
                *{$full} = sub {
                    return &$orig if $is_deep && !$deep_enabled;
                    my $guard = DXCPUWide::Guard->new($full);
                    return &$orig;
                };
                ++$installed;
            }
        }
    }
    main::LogDbg('cpu', "CPU_WIDE_INSTALLED functions=$installed deep=$deep_enabled");
}
sub snapshot {
    my ($window, $duration) = @_;
    _read_config();
    _measure_memory();
    my $n = 0;
    for my $fn (sort { $stats{$b}{self} <=> $stats{$a}{self} } keys %stats) {
        my $s = $stats{$fn};
        main::LogDbg('cpu', sprintf('CPU_WIDE_FN window=%d fn=%s calls=%d cpu_self_ms=%.3f cpu_total_ms=%.3f wall_ms=%.3f max_wall_ms=%.3f max_cpu_ms=%.3f',
            $window, $fn, $s->{calls}, $s->{self}*1000, $s->{total}*1000, $s->{wall}*1000, $s->{maxwall}*1000, ($s->{maxcpu}//0)*1000));
        ++$n;
    }
    for my $phase (sort keys %DXCPUWide::normal_phases) {
        my $s = $DXCPUWide::normal_phases{$phase};
        main::LogDbg('cpu', sprintf('CPU_NORMAL_PHASE window=%d phase=%s calls=%d cpu_ms=%.3f max_cpu_ms=%.3f',
            $window, $phase, $s->{calls}, $s->{cpu}*1000, $s->{max}*1000));
    }
    %DXCPUWide::normal_phases = ();
    %stats = ();
    my @counts;
    for my $entry (
        ['route_nodes', sub { Route::Node::count() }],
        ['route_users', sub { Route::User::count() }],
        ['channels', sub { scalar(DXChannel::get_all()) }],
    ) {
        my ($name, $fn) = @$entry;
        my $v = eval { $fn->() };
        push @counts, "$name=$v" if !$@ && defined($v) && $v =~ /^\d+$/;
    }
    main::LogDbg('cpu', 'CPU_WIDE_TABLES window=' . $window . ' ' . join(' ', @counts));
}
package DXCPUWide::Guard;
sub new {
    my ($class, $name) = @_;
    my $frame = {name=>$name, cpu=>DXCPUWide::_cpu(), wall=>DXCPUWide::_wall(), child=>0};
    push @DXCPUWide::stack, {child=>0};
    return bless $frame, $class;
}
sub DESTROY {
    my ($self) = @_;
    my $cpu = DXCPUWide::_cpu() - $self->{cpu};
    my $wall = DXCPUWide::_wall() - $self->{wall};
    my $frame = pop @DXCPUWide::stack;
    return unless $frame;
    $DXCPUWide::stack[-1]{child} += $cpu if @DXCPUWide::stack;
    my $s = ($DXCPUWide::stats{$self->{name}} ||= {calls=>0,self=>0,total=>0,wall=>0,maxwall=>0,maxcpu=>0});
    ++$s->{calls};
    $s->{total} += $cpu;
    $s->{self} += $cpu > $frame->{child} ? $cpu - $frame->{child} : 0;
    $s->{wall} += $wall;
    $s->{maxcpu} = $cpu if $cpu > ($s->{maxcpu} // 0);
    $s->{maxwall} = $wall if $wall > $s->{maxwall};
}package DXCPUWide;
our %normal_phases;
package DXCPUWide::NormalPhase;
sub new {
    my $class = shift;
    return bless {last=>DXCPUWide::_cpu(), stage=>'entry'}, $class;
}
sub mark {
    my ($self,$next) = @_;
    my $now = DXCPUWide::_cpu();
    my $delta = $now - $self->{last};
    my $s = ($DXCPUWide::normal_phases{$self->{stage}} ||= {calls=>0,cpu=>0,max=>0});
    ++$s->{calls}; $s->{cpu} += $delta;
    $s->{max} = $delta if $delta > $s->{max};
    $self->{last} = $now; $self->{stage} = $next;
}
sub DESTROY { $_[0]->mark('end') }
1;
