package DXHistoryRankShadow;
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Exporter 'import';
use DXHistoryCodec qw(unpack_bytes);
our @EXPORT_OK = qw(install rebuild query compare);

sub _day { return int($_[0] / 86400) * 86400 }
sub install {
 my ($db)=@_;
 $db->begin_work;
 eval {
  $db->do('CREATE TABLE IF NOT EXISTS dxh_rank_dirty (day INTEGER PRIMARY KEY, generation INTEGER NOT NULL DEFAULT 1)');
  $db->do('CREATE TABLE IF NOT EXISTS dxh_rank_daily (day INTEGER PRIMARY KEY, payload TEXT NOT NULL, sample_count INTEGER NOT NULL)');
  $db->do(q{CREATE TRIGGER IF NOT EXISTS dxh_rank_insert AFTER INSERT ON samples WHEN NEW.kind='spot_ranks' BEGIN INSERT INTO dxh_rank_dirty(day) VALUES(CAST(NEW.collected_at/86400 AS INTEGER)*86400) ON CONFLICT(day) DO UPDATE SET generation=generation+1; END});
  $db->do(q{CREATE TRIGGER IF NOT EXISTS dxh_rank_delete AFTER DELETE ON samples WHEN OLD.kind='spot_ranks' BEGIN INSERT INTO dxh_rank_dirty(day) VALUES(CAST(OLD.collected_at/86400 AS INTEGER)*86400) ON CONFLICT(day) DO UPDATE SET generation=generation+1; END});
  $db->do(q{CREATE TRIGGER IF NOT EXISTS dxh_rank_update AFTER UPDATE ON samples WHEN OLD.kind='spot_ranks' OR NEW.kind='spot_ranks' BEGIN INSERT INTO dxh_rank_dirty(day) SELECT CAST(OLD.collected_at/86400 AS INTEGER)*86400 WHERE OLD.kind='spot_ranks' ON CONFLICT(day) DO UPDATE SET generation=generation+1; INSERT INTO dxh_rank_dirty(day) SELECT CAST(NEW.collected_at/86400 AS INTEGER)*86400 WHERE NEW.kind='spot_ranks' ON CONFLICT(day) DO UPDATE SET generation=generation+1; END});
  $db->do(q{INSERT OR IGNORE INTO dxh_rank_dirty(day) SELECT DISTINCT CAST(collected_at/86400 AS INTEGER)*86400 FROM samples WHERE kind='spot_ranks' AND CAST(collected_at/86400 AS INTEGER)*86400 NOT IN (SELECT day FROM dxh_rank_daily)});
  $db->commit;
  1;
 } or do { my $e=$@; eval {$db->rollback}; die $e };
}
sub _empty { return {total=>0,overflow=>0,by_dx=>{},by_spotter=>{},by_origin_node=>{}} }
sub _merge {
 my ($dst,$src)=@_;
 for my $scalar (qw(total overflow)) {$dst->{$scalar} += 0 + ($src->{$scalar} || 0)}
 for my $field (qw(by_dx by_spotter by_origin_node)) {
  next unless ref($src->{$field}) eq 'HASH';
  for my $name (keys %{$src->{$field}}) {$dst->{$field}{$name} += 0 + ($src->{$field}{$name} || 0)}
 }
}
sub _aggregate {
 my ($rows)=@_; my $out=_empty();
 for my $r (@$rows) {
  my $p=eval {decode_json($r->[0])};
  next unless ref($p) eq 'HASH';
  my $sr=ref($p->{spot_ranks}) eq 'HASH' ? $p->{spot_ranks} : $p;
  _merge($out,$sr);
 }
 return $out;
}
sub _raw {
 my ($db,$from,$to)=@_;
 my ($version)=$db->selectrow_array('PRAGMA user_version');
 my $rows=$db->selectall_arrayref($version == 2
   ? q{SELECT payload,codec FROM samples WHERE kind='spot_ranks' AND collected_at>=? AND collected_at<?}
   : q{SELECT payload_json FROM samples WHERE kind='spot_ranks' AND collected_at>=? AND collected_at<?},undef,$from,$to);
 if ($version == 2) {
   my @decoded=map { [unpack_bytes($_->[1],$_->[0])] } @$rows;
   return (_aggregate(\@decoded),scalar @$rows);
 }
 return (_aggregate($rows),scalar @$rows);
}
sub rebuild {
 my ($db,$limit)=@_; $limit ||= 100;
 my $days=$db->selectcol_arrayref('SELECT day FROM dxh_rank_dirty ORDER BY day LIMIT ?',undef,$limit);
 my $n=0;
 for my $day (@$days) {
  $db->begin_work;
  eval {
   my ($sum,$count)=_raw($db,$day,$day+86400);
   if ($count) {
    $db->do(q{INSERT INTO dxh_rank_daily(day,payload,sample_count) VALUES(?,?,?) ON CONFLICT(day) DO UPDATE SET payload=excluded.payload,sample_count=excluded.sample_count},undef,$day,encode_json($sum),$count);
   } else {$db->do('DELETE FROM dxh_rank_daily WHERE day=?',undef,$day)}
   $db->do('DELETE FROM dxh_rank_dirty WHERE day=?',undef,$day);
   $db->commit; 1;
  } or do {my $e=$@; eval {$db->rollback}; die $e};
  $n++;
 }
 return $n;
}
sub query {
 my ($db,$from,$to)=@_;
 my $out=_empty(); my $used=0; my $fallback=0; my $empty=0;
 return ($out,0,0,0) if $to <= $from;
 for(my $day=_day($from);$day<$to;$day+=86400) {
  my $start=$from>$day?$from:$day;
  my $end=$to<$day+86400?$to:$day+86400;
  my ($dirty)=$db->selectrow_array('SELECT 1 FROM dxh_rank_dirty WHERE day=?',undef,$day);
  my ($json)=$db->selectrow_array('SELECT payload FROM dxh_rank_daily WHERE day=?',undef,$day);
  if ($start==$day && $end==$day+86400 && !$dirty && defined $json) {
   _merge($out,decode_json($json)); $used++;
  } else {
   # Empty periods are not fallbacks: avoid JSON decoding and misleading
   # year-long fallback counts when the database only contains recent days.
   my ($exists)=$db->selectrow_array(q{SELECT 1 FROM samples WHERE kind='spot_ranks' AND collected_at>=? AND collected_at<? LIMIT 1},undef,$start,$end);
   if ($exists) { my ($raw)=_raw($db,$start,$end); _merge($out,$raw); $fallback++; }
   else { $empty++; }
  }
 }
 return ($out,$used,$fallback,$empty);
}
sub _top {
 my ($h)=@_;
 my @keys=sort {($h->{$b}||0)<=>($h->{$a}||0) || $a cmp $b} keys %$h;
 $#keys=29 if @keys>30;
 return [map {{name=>$_,count=>0+($h->{$_}||0)}} @keys];
}
sub _view {
 my ($a)=@_;
 return {total=>0+$a->{total},overflow=>0+$a->{overflow},top_dx=>_top($a->{by_dx}),top_spotters=>_top($a->{by_spotter}),top_origin_nodes=>_top($a->{by_origin_node})};
}
sub _canon {
 my ($x)=@_;
 return $x unless ref $x;
 return [map {_canon($_)} @$x] if ref($x) eq 'ARRAY';
 return [map {[$_,_canon($x->{$_})]} sort keys %$x] if ref($x) eq 'HASH';
 die 'unsupported reference';
}
sub compare {
 my ($db,$from,$to)=@_;
 # Snapshot protects comparison against concurrent writes on live WAL databases.
 $db->begin_work;
 my ($ok,$detail);
 eval {
  my ($raw,$count)=_raw($db,$from,$to);
  my ($fast,$used,$fallback,$empty)=query($db,$from,$to);
  $ok=encode_json(_canon(_view($raw))) eq encode_json(_canon(_view($fast)));
  $detail={equal=>$ok?1:0,raw_rows=>$count,rollup_days=>$used,fallback_days=>$fallback,empty_days=>$empty};
  $db->commit; 1;
 } or do {my $e=$@; eval {$db->rollback}; die $e};
 return $detail;
}
1;
