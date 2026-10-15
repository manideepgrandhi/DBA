include "versions" {search: "./"};   # lib/versions.jq (shared): version parsing + minor candidate selection
# lib/report.jq - row building, filtering, summary and rendering for rds_pending_maintenance_report.sh
# Modes ($mode):
#   rows     : one (profile, region) collection dir -> array of rows      (slurpfiles pma/instances/clusters/versions)
#   finalize : {meta, rows, errors} -> filtered, sorted, summarised report (--argjson f FILTERS)
#   text|csv|html|alert : render a finalized report
# Run with TZ set to the display time zone (default Asia/Kolkata): "local" times use strflocaltime.

def ts:
  if . == null or . == "" then null else
    (sub("\\.[0-9]+"; "") | sub("Z$"; "+00:00")) as $s
    | ([$s | capture("^(?<d>[0-9-]{10}T[0-9:]{8})(?<sg>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")] | .[0]) as $c
    | if $c == null then (($s[0:19] + "Z") | fromdateiso8601)
      else (($c.d + "Z") | fromdateiso8601) - (if $c.sg == "-" then -1 else 1 end) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60) end
  end;
def fu: if . == null then "" else strftime("%Y-%m-%d %H:%M UTC") end;
def fl: if . == null then "" else strflocaltime("%Y-%m-%d %H:%M %Z") end;
def r1: (. * 10 | round) / 10;
def sev: {"OK":0, "INFO":1, "WARN":2, "ERROR":3, "CRIT":4}[.] // 0;
def urg_sev: {"OVERDUE":"CRIT", "CRIT":"CRIT", "WARN":"WARN", "INFO":"INFO", "OPTIONAL":"INFO"}[.];
def urg_rank: {"OVERDUE":0, "CRIT":1, "WARN":2, "INFO":3, "OPTIONAL":4}[.] // 9;
def glob2re: "^" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
def gmatch($globs): . as $v | ($globs | length) == 0 or any($globs[]; . as $g | ($v // "") | test($g | glob2re; "i"));

# ------------------------------------------------------------------ maintenance window
def dayn: {"sun":0, "mon":1, "tue":2, "wed":3, "thu":4, "fri":5, "sat":6}[ascii_downcase];
# "sun:20:00-sun:20:30" -> {start, end} epoch of the next occurrence at/after $now (UTC)
def next_window($now):
  (split("-") | map(split(":") | (.[0] | dayn) * 1440 + (.[1] | tonumber) * 60 + (.[2] | tonumber))) as $w
  | ($now | gmtime) as $g | ($g[6] * 1440 + $g[3] * 60 + $g[4]) as $nm
  | (((($w[0] - $nm) % 10080) + 10080) % 10080) as $delta
  | (((($w[1] - $w[0]) % 10080) + 10080) % 10080) as $len
  | (($now / 60 | floor) * 60 + $delta * 60) as $s
  | {start: $s, end: ($s + $len * 60)};

# ------------------------------------------------------------------ engine versions
# vkey / minor_select live in lib/versions.jq: same major line for every engine, Oracle same patch line
# (mrp/rur/plain RU/spb) unless --oracle-any-patch-line (--argjson oracle_any true)
def vsvc($engine): if $engine == "docdb" then "docdb" elif $engine == "neptune" then "neptune" else "rds" end;
# minor-version info for one resource; $V = {"svc|engine|version": {error, targets}} or null when the check is off
def minor_info($res; $V):
  ($res.Engine // "") as $e | ($res.EngineVersion // "") as $v
  | (if $res == null then {status: "resource not found"}
     elif $V == null then {status: "not checked"}
     elif $e == "" or $v == "" then {status: "unknown version"}
     else ($V["\(vsvc($e))|\($e)|\($v)"]) as $x
       | if $x == null then {status: "not checked"}
         elif $x.error != null then {status: "lookup failed", error: $x.error}
         else {status: "checked",
               sel: ($x.targets | minor_select($e; $v; null; ($ARGS.named.oracle_any // false)))}
           | . + {targets: .sel.versions} end end) as $m
  | ($m.targets // []) as $t
  | { auto_minor_upgrade: (if $res == null or $res.AutoMinorVersionUpgrade == null then "" else ($res.AutoMinorVersionUpgrade | tostring) end),
      minor_version_status: (if $m.status != "checked" then $m.status elif ($t | length) == 0 then "up to date" else "behind" end),
      minor_targets: $t, minor_behind: (($t | length) > 0),
      next_minor_version: (if $m.status != "checked" then $m.status elif ($t | length) == 0 then "up to date" else $t[0] end),
      latest_minor_version: (if ($t | length) > 0 then $t[-1] else "" end),
      minor_versions_available: (if ($t | length) == 0 then ""
                                 elif ($t | length) <= 6 then ($t | join(", "))
                                 else ($t[0:3] + ["...", $t[-2], $t[-1]] | join(", ")) + " (\($t | length) versions)" end),
      minor_lookup_error: ($m.error // ""),
      minor_excluded: ([($m.sel.excluded // [])[] | .reason] | join("; ")),
      minor_version_warnings: ($m.sel.warnings // []) };

# ------------------------------------------------------------------ role / patch sequence
# $res = the instance or cluster; $CI = clusters by identifier (incl. clusters of pending member instances)
# -> {role, patch_sequence (1 = first, 2 = last, null = unknown), patch_group, sequence_note}
def role_info($type; $id; $res; $CI):
  if $res == null then {role: "unknown", patch_sequence: null, patch_group: $id, sequence_note: "resource not found; role unknown"}
  elif $type == "cluster" then
    ([$res.DBClusterMembers[]? | select(.IsClusterWriter == true)] | length > 0) as $has_writer
    | if ($res.GlobalClusterIdentifier // "") != "" and ($has_writer | not) then
        {role: "cluster (global secondary)", patch_sequence: 1, patch_group: $id,
         sequence_note: "secondary cluster of global database \($res.GlobalClusterIdentifier): patch secondaries before the primary cluster"}
      elif ($res.GlobalClusterIdentifier // "") != "" then
        {role: "cluster (global primary)", patch_sequence: 2, patch_group: $id,
         sequence_note: "primary cluster of global database \($res.GlobalClusterIdentifier): patch after its secondary clusters (other regions)"}
      elif ($res.ReplicationSourceIdentifier // "") != "" then
        {role: "cluster (replica)", patch_sequence: 1, patch_group: $id,
         sequence_note: "cross-region replica cluster of \($res.ReplicationSourceIdentifier): patch before its source"}
      else {role: "cluster", patch_sequence: 1, patch_group: $id,
            sequence_note: "cluster-level action: applies to the whole cluster at once (\($res.DBClusterMembers // [] | length) member(s)); no per-instance order"} end
  elif ($res.DBClusterIdentifier // "") != "" then
    ($res.DBClusterIdentifier) as $cl
    | ([$CI[$cl].DBClusterMembers[]? | select(.DBInstanceIdentifier == $id)] | .[0]) as $m
    | if $m == null then {role: "cluster member (role unknown)", patch_sequence: null, patch_group: $cl,
                          sequence_note: "cluster \($cl) not described; check DBClusterMembers for the writer"}
      elif $m.IsClusterWriter then {role: "primary (writer)", patch_sequence: 2, patch_group: $cl,
                          sequence_note: "writer of \($cl): patch last, after the readers (a failover to a patched reader is possible)"}
      else {role: "replica (reader)", patch_sequence: 1, patch_group: $cl,
            sequence_note: "reader of \($cl): patch readers first, one at a time, then the writer"} end
  elif ($res.ReadReplicaSourceDBInstanceIdentifier // "") != "" then
    ($res.ReadReplicaSourceDBInstanceIdentifier) as $src
    | {role: ("replica" + (if $res.MultiAZ then " (Multi-AZ)" else "" end)), patch_sequence: 1,
       patch_group: (if ($src | contains(":")) then $id else $src end),
       sequence_note: ("read replica of \($src)" + (if ($src | contains(":")) then " (cross-region)" else "" end) + ": patch replicas before the source")}
  else
    ($res.ReadReplicaDBInstanceIdentifiers // []) as $reps
    | {role: ("primary" + (if $res.MultiAZ then " (Multi-AZ)" else "" end)), patch_sequence: 2, patch_group: $id,
       sequence_note: (if ($reps | length) > 0 then "source of \($reps | length) read replica(s) (\($reps | join(", "))): patch the replicas first, then this primary"
                       else "standalone primary, no read replicas" end
                       + (if $res.MultiAZ then "; Multi-AZ: the standby is patched first, then a failover (short outage)" else "" end))} end;

# ------------------------------------------------------------------ mode: rows
def rows:
  $ARGS.named as $A
  | (if $A.versions == null then null
     else (($A.versions[0] // []) | map({key: "\(.svc)|\(.engine)|\(.version)", value: .}) | from_entries) end) as $V
  | (($A.instances[0] // []) | map({key: .DBInstanceArn, value: .}) | from_entries) as $I
  | (($A.clusters[0] // []) | map({key: .DBClusterArn, value: .}) | from_entries) as $C
  | (($A.clusters[0] // []) | map({key: .DBClusterIdentifier, value: .}) | from_entries) as $CI
  | [ ($A.pma[0] // [])[] as $r
      | ($r.ResourceIdentifier | split(":")) as $p
      | (if $p[5] == "cluster" then "cluster" elif $p[5] == "db" then "instance" else $p[5] end) as $type
      | (if $type == "cluster" then $C[$r.ResourceIdentifier] else $I[$r.ResourceIdentifier] end) as $res
      | (($res.TagList // []) | map({key: .Key, value: .Value}) | from_entries) as $tags
      | ($res.PreferredMaintenanceWindow // null) as $mw
      | (if $mw then ($mw | next_window($now)) else null end) as $nw
      | $r.PendingMaintenanceActionDetails[]
      | (.AutoAppliedAfterDate | ts) as $auto | (.ForcedApplyDate | ts) as $forced | (.CurrentApplyDate | ts) as $cur
      | (.OptInStatus // "") as $opt
      | ( if $cur != null then {e: $cur, basis: "current-apply-date"}
          elif $opt == "next-maintenance" and $nw != null then {e: $nw.start, basis: "next-window (opted in)"}
          elif $opt == "immediate" then {e: $now, basis: "immediate (opted in)"}
          elif ([$auto, $forced] | map(select(. != null)) | length) > 0 then
            ([{e: $auto, basis: "auto-applied-after"}, {e: $forced, basis: "forced-apply"}] | map(select(.e != null)) | min_by(.e))
          else {e: null, basis: "none"} end ) as $eff
      | (if $eff.e == null then null else (($eff.e - $now) / 86400) end) as $days
      | ( if $days == null then "OPTIONAL" elif $days < 0 then "OVERDUE" elif $days <= $crit_days then "CRIT"
          elif $days <= $warn_days then "WARN" else "INFO" end ) as $urg
      | { account: $A.account, profile: $A.profile, region: $A.region, source: ($r._source // "rds"),
          resource_type: $type, identifier: ($p[6:] | join(":")),
          cluster: (if $type == "instance" then ($res.DBClusterIdentifier // "") else "" end),
          engine: ($res.Engine // "unknown"), engine_version: ($res.EngineVersion // ""),
          instance_class: (if $type == "instance" then ($res.DBInstanceClass // "")
                           else ($res.DBClusterInstanceClass // (if $res.ServerlessV2ScalingConfiguration then
                                 "serverless v2 \($res.ServerlessV2ScalingConfiguration.MinCapacity)-\($res.ServerlessV2ScalingConfiguration.MaxCapacity) ACU"
                                 else "" end)) end),
          resolved: ($res != null), tags: $tags, tag_columns: ($tagcols | map({key: ., value: ($tags[.] // "")}) | from_entries),
          action: (.Action // ""), description: (.Description // ""), opt_in_status: $opt,
          auto_applied_after: $auto, forced_apply: $forced, current_apply: $cur,
          effective_apply: $eff.e, effective_basis: $eff.basis,
          days_until: (if $days == null then null else ($days | r1) end), urgency: $urg, severity: ($urg | urg_sev),
          maint_window_utc: ($mw // ""), next_window_start: ($nw.start // null), next_window_end: ($nw.end // null),
          arn: $r.ResourceIdentifier } + minor_info($res; (if ($A.vc // 0) == 1 then $V else null end))
        + role_info($type; ($p[6:] | join(":")); $res; $CI)
        + {source_instance: ($res.ReadReplicaSourceDBInstanceIdentifier // "")} ];

# ------------------------------------------------------------------ printed commands (never run by the report)
# POSIX shell quoting: plain if only safe characters, else single-quoted with ' -> '\''
def sq: tostring | if test("^[A-Za-z0-9_./:=@,+%-]+$") then . else "'" + gsub("'"; "'\\''") + "'" end;
def cli_service: if .source == "docdb" or .engine == "docdb" then "docdb" elif .engine == "neptune" then "neptune" else "rds" end;
# argv words -> one copy-pasteable command; --region always (known), --profile only when -P was used
def mk_cmd($words):
  ($words + (if (.region // "") != "" then ["--region", .region] else [] end)
          + (if (.profile // "") != "" and .profile != "default" then ["--profile", .profile] else [] end))
  | map(sq) | join(" ");
def immediate_cmd:
  mk_cmd(["aws", cli_service, "apply-pending-maintenance-action", "--resource-identifier", .arn, "--apply-action", .action, "--opt-in-type", "immediate"]);
# status: current state incl. maintenance in progress (Status upgrading / maintenance / rebooting / modifying ...)
def status_query_instance: "DBInstances[0].{Status:DBInstanceStatus,PendingModified:PendingModifiedValues,MaintWindow:PreferredMaintenanceWindow,Engine:Engine,EngineVersion:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,AutoMinorUpgrade:AutoMinorVersionUpgrade,CACert:CACertificateIdentifier,Cluster:DBClusterIdentifier}";
def status_query_cluster: "DBClusters[0].{Status:Status,Engine:Engine,EngineVersion:EngineVersion,MaintWindow:PreferredMaintenanceWindow,PendingModified:PendingModifiedValues,MultiAZ:MultiAZ,Members:DBClusterMembers[].{Instance:DBInstanceIdentifier,Writer:IsClusterWriter}}";
def status_cmd:
  if .resource_type == "cluster" then
    mk_cmd(["aws", cli_service, "describe-db-clusters", "--db-cluster-identifier", .identifier, "--query", status_query_cluster, "--output", "table"])
  else
    mk_cmd(["aws", cli_service, "describe-db-instances", "--db-instance-identifier", .identifier, "--query", status_query_instance, "--output", "table"])
  end;
def pending_cmd: mk_cmd(["aws", cli_service, "describe-pending-maintenance-actions", "--resource-identifier", .arn, "--output", "table"]);
# minor upgrade: the engine version belongs to the cluster for Aurora / DocumentDB / Neptune / Multi-AZ DB clusters
def upgrade_target: if .resource_type == "cluster" then {kind: "cluster", id: .identifier}
                    elif (.cluster // "") != "" then {kind: "cluster", id: .cluster} else {kind: "instance", id: .identifier} end;
def minor_cmd:
  upgrade_target as $u
  | if $u.kind == "cluster" then mk_cmd(["aws", cli_service, "modify-db-cluster", "--db-cluster-identifier", $u.id, "--engine-version", .latest_minor_version])
    else mk_cmd(["aws", cli_service, "modify-db-instance", "--db-instance-identifier", $u.id, "--engine-version", .latest_minor_version]) end;
def minor_commands:
  if .minor_behind then
    {minor_upgrade_command: minor_cmd,
     minor_upgrade_note: ("upgrades \(upgrade_target | "\(.kind) \(.id)") \(.engine_version) -> \(.latest_minor_version); applies in the next maintenance window unless --apply-immediately is added (restart / failover)"
                         + (if (.minor_excluded // "") != "" then "; " + .minor_excluded else "" end))}
  else {minor_upgrade_command: "", minor_upgrade_note: (.minor_excluded // "")} end;
def apply_commands:
  if .resolved | not then {apply_immediate_command: "",
       apply_note: "resource not found by describe-db-instances/clusters (deleted or renamed?) - verify before applying"}
  elif (.action // "") == "" or (.arn // "") == "" then {apply_immediate_command: "", apply_note: "no action/ARN reported"}
  elif .opt_in_status == "immediate" then {apply_immediate_command: "",
       apply_note: "already opted in (immediate): being applied now, cannot be changed"}
  else {apply_immediate_command: immediate_cmd,
        apply_note: ( if .opt_in_status == "next-maintenance" then "already scheduled for the next window; immediate applies it now - may restart/fail over"
                      else "applies as soon as possible - may restart/fail over; check impact first" end )} end;
# backup before maintenance: manual snapshot named pre-maint-<id>-<UTC YYYYMMDD-HHMM>, timestamp taken when the
# command RUNS ($(date -u ...)); the name is kept in a shell variable SNAP_<id> for the wait command
def snap_id: tostring | gsub("[^A-Za-z0-9-]"; "-") | gsub("-+"; "-") | sub("^-+"; "") | .[0:231] | sub("-+$"; "")
                      | if . == "" then "db" else . end;
def backup_target:
  if (.resolved | not) then null
  elif .resource_type == "cluster" then {kind: "cluster", id: .identifier}
  elif (.cluster // "") != "" then {kind: "cluster", id: .cluster}
  elif (.source_instance // "") != "" then (if (.source_instance | contains(":")) then {kind: "none"} else {kind: "instance", id: .source_instance} end)
  else {kind: "instance", id: .identifier} end;
def backup_commands:
  backup_target as $t
  | if $t == null then {backup_snapshot_name: "", backup_command: "", backup_wait_command: "", backup_note: "resource not found - nothing to back up"}
    elif $t.kind == "none" then {backup_snapshot_name: "", backup_command: "", backup_wait_command: "",
         backup_note: "cross-region read replica of \(.source_instance): snapshot the source in its own region (a snapshot of the replica is optional)"}
    else ($t.id | snap_id) as $sid | ("SNAP_" + ($sid | gsub("-"; "_"))) as $var
      | ("\"$" + $var + "\"") as $ref
      | (if $t.kind == "cluster" then
           {create: mk_cmd(["aws", cli_service, "create-db-cluster-snapshot", "--db-cluster-identifier", $t.id, "--db-cluster-snapshot-identifier", "@@SNAP@@"]),
            wait: mk_cmd(["aws", "rds", "wait", "db-cluster-snapshot-available", "--db-cluster-snapshot-identifier", "@@SNAP@@"])}
         else
           {create: mk_cmd(["aws", cli_service, "create-db-snapshot", "--db-instance-identifier", $t.id, "--db-snapshot-identifier", "@@SNAP@@"]),
            wait: mk_cmd(["aws", "rds", "wait", "db-snapshot-available", "--db-snapshot-identifier", "@@SNAP@@"])} end) as $c
      | {backup_snapshot_name: "pre-maint-\($sid)-YYYYMMDD-HHMM",
         backup_command: ($var + "=\"pre-maint-" + $sid + "-$(date -u +%Y%m%d-%H%M)\" && " + ($c.create | sub("@@SNAP@@"; $ref))),
         backup_wait_command: ($c.wait | sub("@@SNAP@@"; $ref)),
         backup_note: ( (if $t.kind == "cluster" and .resource_type == "cluster" then "cluster snapshot"
                         elif $t.kind == "cluster" then "\(.role // "member") of \($t.id): instance snapshots are not possible for cluster members; the cluster snapshot covers all members"
                         elif $t.id != .identifier then "read replica: the snapshot is taken of its source \($t.id); a snapshot of the replica itself is optional"
                         else "instance snapshot" end)
                        + "; timestamp = UTC when the command runs; run the wait command in the same shell (uses $\($var))") } end;
# status / pending-actions commands are read-only lookups: shown even for unresolved ARNs
def commands:
  apply_commands
  + {status_command: (if (.identifier // "") != "" then status_cmd else "" end),
     pending_actions_command: (if (.arn // "") != "" then pending_cmd else "" end)}
  + minor_commands
  + backup_commands;

# ------------------------------------------------------------------ mode: finalize
def decorate:
  . + { auto_applied_after_utc: (.auto_applied_after | fu), forced_apply_utc: (.forced_apply | fu),
        current_apply_utc: (.current_apply | fu), effective_apply_utc: (.effective_apply | fu),
        effective_apply_local: (.effective_apply | fl),
        maint_window_local: (if .next_window_start then (.next_window_start | strflocaltime("%a %H:%M")) + "-"
                             + (.next_window_end | strflocaltime("%a %H:%M %Z")) else "" end),
        next_window_local: (.next_window_start | fl) }
  | . + commands;
def counts(f): group_by(f) | map({key: (.[0] | f), value: length}) | sort_by(-.value) | from_entries;
def behind_count: map(select(.minor_behind)) | map([.account, .region, (upgrade_target | .kind, .id)]) | unique | length;
# one section per engine (ascending, case-insensitive); rows stay in the flat .rows array
def section_stats($rows):
  $rows | group_by(.engine | ascii_downcase)
  | map({engine: .[0].engine, anchor: ("eng-" + (.[0].engine | ascii_downcase | gsub("[^a-z0-9]+"; "-"))),
         total: length, resources: (map(.arn) | unique | length),
         by_urgency: (counts(.urgency) | to_entries | sort_by(.key | urg_rank) | from_entries),
         by_action: counts(.action), behind_latest_minor: behind_count,
         groups: (map(.patch_group // .identifier) | unique | length)});
def finalize:
  . as $r
  | ($r.rows | map(select((.engine | gmatch($f.engines)) and (.action | gmatch($f.actions))
                          and ((.identifier | gmatch($f.identifiers)) or (.cluster != "" and (.cluster | gmatch($f.identifiers))))
                          and (.urgency as $u | ($f.urgency | length) == 0 or any($f.urgency[]; ascii_upcase == $u))
                          and (. as $row | all($f.tags[]; . as $t | ($row.tags[$t.k] // null) as $v | $v != null and ($v | gmatch([$t.v])))) ))
       # patching order: engine, cluster / server group, patch_sequence (replicas first), instance (case-insensitive)
       | sort_by([(.engine | ascii_downcase), (.patch_group // .identifier | ascii_downcase), .account, .region,
                  (.patch_sequence // 9), (.identifier | ascii_downcase), (.effective_apply // 1e18), .action]) | map(decorate)) as $rows
  | ( if ($rows | map(.severity) | index("CRIT")) then "CRIT" elif ($r.errors | length) > 0 then "ERROR"
      elif ($rows | length) > 0 then "WARN" else "OK" end ) as $ov
  | $r + { rows: $rows,
           summary: { overall: $ov, exit_code: {"CRIT":11, "ERROR":3, "WARN":10, "OK":0}[$ov],
                      total: ($rows | length), resources: ($rows | map(.arn) | unique | length),
                      unfiltered_total: ($r.rows | length),
                      by_urgency: (($rows | counts(.urgency)) | to_entries | sort_by(.key | urg_rank) | from_entries), by_action: ($rows | counts(.action)),
                      by_engine: ($rows | counts(.engine)), by_region: ($rows | counts(.region)),
                      by_account: ($rows | counts(.account)), errors: ($r.errors | length),
                      sections: section_stats($rows),
                      # servers = upgrade targets (cluster, or standalone instance) behind their latest minor version
                      behind_latest_minor: ($rows | behind_count),
                      behind_latest_minor_servers: ($rows | map(select(.minor_behind)) | map(upgrade_target.id + " (" + .engine_version + " -> " + .latest_minor_version + ")") | unique) } };

# ------------------------------------------------------------------ renderers
def pad($n): tostring | if length >= $n then .[0:$n] else . + (" " * ($n - length)) end;
def cut($n): tostring | if length > $n then .[0:($n - 2)] + ".." else . end;
def kv: to_entries | map("\(.key)=\(.value)") | join(", ");
def text_header($r):
  ("URGENCY" | pad(9)) + ("DAYS" | pad(7)) + ("APPLY (\($r.meta.tz_abbr))" | pad(22)) + ("ACCOUNT" | pad(13)) + ("REGION" | pad(15))
  + ("TYPE" | pad(9)) + ("SEQ" | pad(4)) + ("ROLE" | pad(19)) + ("IDENTIFIER" | pad(30)) + ("ENGINE" | pad(24)) + ("ACTION" | pad(24)) + ("OPT-IN" | pad(17))
  + ($r.meta.tag_columns | map(pad(13)) | join(""));
def text_row:
  (.urgency | pad(9)) + ((.days_until // "-") | tostring | pad(7)) + ((.effective_apply_local | if . == "" then "-" else .[0:16] end) | pad(22))
  + (.account | pad(13)) + (.region | pad(15)) + (.resource_type | pad(9)) + ((.patch_sequence // "-") | tostring | pad(4))
  + (.role | cut(18) | pad(19))
  + ((.identifier + (if .cluster != "" then " (\(.cluster))" else "" end)) | cut(29) | pad(30))
  + ("\(.engine) \(.engine_version)" | cut(23) | pad(24)) + (.action | pad(24)) + ((.opt_in_status | if . == "" then "-" else . end) | pad(17))
  + ([.tag_columns[]] | map(cut(12) | pad(13)) | join(""))
  + "\n         sequence : " + (.sequence_note // "")
  + "\n         version  : " + (if .engine_version == "" then "-" else .engine_version end)
    + (if .minor_behind then " -> next \(.next_minor_version), latest \(.latest_minor_version) (available: \(.minor_versions_available))"
       else " (\(.next_minor_version))" end)
    + (if .auto_minor_upgrade != "" then " | auto minor upgrade: \(.auto_minor_upgrade)" else "" end)
  + (if .backup_command != "" then "\n         backup   : " + .backup_command + "\n         wait     : " + .backup_wait_command else "" end)
  + (if .backup_note != "" then "\n         bkp note : " + .backup_note else "" end)
  + "\n         immediate: " + (if .apply_immediate_command != "" then .apply_immediate_command + "   # may restart/fail over NOW" else "-" end)
  + (if .status_command != "" then "\n         status   : " + .status_command else "" end)
  + (if .pending_actions_command != "" then "\n         pending  : " + .pending_actions_command else "" end)
  + (if .minor_upgrade_command != "" then "\n         minor upg: " + .minor_upgrade_command + "   # next maintenance window" else "" end)
  + (if .apply_note != "" then "\n         note     : " + .apply_note else "" end);
def text:
  . as $r
  | [ "RDS pending maintenance report - \($r.meta.script) v\($r.meta.version)",
      "Generated : \($r.meta.generated_utc) / \($r.meta.generated_local)",
      "Accounts  : \($r.meta.accounts | map("\(.account) (\(.profile))") | join(", "))",
      "Regions   : \($r.meta.regions | join(", "))",
      (if ($r.meta.filters_text // "") != "" then "Filters   : \($r.meta.filters_text)" else empty end),
      (if ($r.rows | length) > 0 then "Engines   : " + ($r.summary.sections | map("\(.engine) (\(.total))") | join(", ")) else empty end),
      "Order     : per engine; by cluster / server, then SEQ (1 = replicas / readers first, 2 = primary / writer last), then instance",
      "",
      ( if ($r.rows | length) == 0 then "No pending maintenance actions found."
        else ( $r.summary.sections[] as $s
               | ("=" * 100),
                 "ENGINE: \($s.engine) - \($s.total) pending action(s) on \($s.resources) resource(s) in \($s.groups) cluster/server group(s); urgency \($s.by_urgency | kv)"
                   + (if $r.meta.version_check != false then "; \($s.behind_latest_minor) behind latest minor" else "" end),
                 ("=" * 100),
                 text_header($r),
                 ($r.rows[] | select(.engine == $s.engine) | text_row),
                 "" ) end ),
      (if ($r.rows | length) > 0 then "Commands are printed only (never run). backup + wait: manual snapshot before patching (name pre-maint-<id>-<UTC time when run>; run both in the same shell). immediate (--opt-in-type immediate) starts the maintenance now and may restart/fail over the DB; status/pending are read-only lookups; minor upg (modify ... --engine-version) applies in the next maintenance window unless --apply-immediately is added." else empty end),
      "",
      "SUMMARY: \($r.summary.total) pending action(s) on \($r.summary.resources) resource(s)"
        + (if $r.summary.unfiltered_total != $r.summary.total then " (\($r.summary.unfiltered_total) before filters)" else "" end),
      "  by urgency : \($r.summary.by_urgency | kv)",
      "  by action  : \($r.summary.by_action | kv)",
      "  by engine  : \($r.summary.by_engine | kv)",
      "  by region  : \($r.summary.by_region | kv)",
      "  by account : \($r.summary.by_account | kv)",
      "  minor ver. : " + (if $r.meta.version_check == false then "not checked (--no-version-check)"
                           else "\($r.summary.behind_latest_minor) server(s) behind the latest minor version"
                                + (if $r.summary.behind_latest_minor > 0 then ": " + ($r.summary.behind_latest_minor_servers | join(", ")) else "" end) end),
      ( if ($r.errors | length) > 0 then "", "ERRORS (report incomplete):",
          ($r.errors[] | "  \(.account) \(.profile) \(.region) \(.call): \(.message)") else empty end ),
      "",
      "Overall: \($r.summary.overall) (exit \($r.summary.exit_code))"
    ] | .[];   # one string per line: same bytes as join("\n") under jq -r, without O(n^2) concatenation

def csv:
  (["account_id","profile","region","resource_type","identifier","cluster","engine","engine_version","instance_class"]
   + (.meta.tag_columns | map("tag:" + .))
   + ["action","description","opt_in_status","auto_applied_after_utc","forced_apply_utc","current_apply_utc",
      "effective_apply_utc","effective_apply_\(.meta.tz_abbr | ascii_downcase)","days_until","urgency",
      "maint_window_utc","maint_window_\(.meta.tz_abbr | ascii_downcase)","next_window_\(.meta.tz_abbr | ascii_downcase)","source","arn","apply_immediate_command","apply_note","status_command","pending_actions_command",
      "auto_minor_upgrade","next_minor_version","latest_minor_version","minor_versions_available","minor_upgrade_command","minor_upgrade_note",
      "patch_group","role","patch_sequence","sequence_note","backup_snapshot_name","backup_command","backup_wait_command","backup_note"]) as $h
  | ($ARGS.named.only_engine // null) as $only
  | ($h | @csv),
    (.rows[] | select($only == null or .engine == $only) | ([.account, .profile, .region, .resource_type, .identifier, .cluster, .engine, .engine_version, .instance_class]
               + [.tag_columns[]]
               + [.action, .description, .opt_in_status, .auto_applied_after_utc, .forced_apply_utc, .current_apply_utc,
                  .effective_apply_utc, .effective_apply_local, .days_until, .urgency, .maint_window_utc, .maint_window_local,
                  .next_window_local, .source, .arn, .apply_immediate_command, .apply_note, .status_command, .pending_actions_command,
                  .auto_minor_upgrade, .next_minor_version, .latest_minor_version, .minor_versions_available, .minor_upgrade_command, .minor_upgrade_note,
                  .patch_group, .role, .patch_sequence, .sequence_note, .backup_snapshot_name, .backup_command, .backup_wait_command, .backup_note]) | @csv);
# json output: the finalized report + rows grouped per engine (flat .rows kept for compatibility)
def json_out: . as $r | $r + {engines: [$r.summary.sections[] as $s | $s + {rows: [$r.rows[] | select(.engine == $s.engine)]}]};

def h: tostring | @html;
def two($e): if $e == null then "<span class=\"muted\">-</span>" else "\($e | fu | h)<br><span class=\"muted\">\($e | fl | h)</span>" end;
def card($label; $n; $cls): "<div class=\"card \($cls)\"><div class=\"n\">\($n)</div><div class=\"l\">\($label | h)</div></div>";
def minitable($title; $o): "<div class=\"mini\"><h3>\($title | h)</h3><table>"
  + ($o | to_entries | map("<tr><td>\(.key | h)</td><td class=\"num\">\(.value)</td></tr>") | join("")) + "</table></div>";
def cmdbox($c): "<div class=\"cmd\"><code>\($c | h)</code><button class=\"cp\" type=\"button\" title=\"Copy to clipboard\">Copy</button></div>";
def html_head($r):
  (["Urgency", "Days", "Apply (UTC / \($r.meta.tz_abbr))", "Account", "Region", "Type", "Identifier", "Seq / role", "Cluster", "Engine", "Minor version", "Class"]
   + ($r.meta.tag_columns) + ["Action", "Description", "Opt-in", "Auto-applied after", "Forced apply", "Maint. window (UTC / \($r.meta.tz_abbr))", "Commands (printed only)"]
   | map("<th>\(h)</th>") | join(""));
def html_row:
        "<tr class=\"r-\(.urgency)\"><td data-s=\"\(.urgency | urg_rank)\"><span class=\"u u-\(.urgency)\">\(.urgency)</span></td>"
        + "<td data-s=\"\(.days_until // 99999)\" class=\"num\">\(.days_until // "-")</td>"
        + "<td data-s=\"\(.effective_apply // 9999999999)\">\(two(.effective_apply))<br><span class=\"muted\">\(.effective_basis | h)</span></td>"
        + "<td>\(.account | h)<br><span class=\"muted\">\(.profile | h)</span></td><td>\(.region | h)</td><td>\(.resource_type | h)</td>"
        + "<td><b>\(.identifier | h)</b>\(if .resolved then "" else "<br><span class=\"muted\">not found by describe-db-*</span>" end)</td>"
        + "<td data-s=\"\(.patch_sequence // 9)\"><span class=\"seq\">\(.patch_sequence // "-")</span> \(.role | h)<br><span class=\"muted\">\(.sequence_note | h)</span></td>"
        + "<td>\(.cluster | h)</td><td>\(.engine | h)<br><span class=\"muted\">\(.engine_version | h)</span></td>"
        + "<td class=\"ver\" data-s=\"\(if .minor_behind then 0 else 1 end)\">"
        + (if .minor_behind then "<span class=\"behind\">&#8593; \(.minor_targets | length) newer minor</span><br>next <b>\(.next_minor_version | h)</b><br>latest <b>\(.latest_minor_version | h)</b>"
             + "<br><span class=\"muted\">\(.minor_versions_available | h)</span>"
           elif .minor_version_status == "up to date" then "<span class=\"ok-v\">&#10003; up to date</span>"
           else "<span class=\"muted\">\(.next_minor_version | h)</span>" end)
        + (if .auto_minor_upgrade != "" then "<br><span class=\"pill\">auto minor upgrade: \(if .auto_minor_upgrade == "true" then "on" else "off" end)</span>" else "" end)
        + "</td><td>\(.instance_class | h)</td>"
        + ([.tag_columns[]] | map("<td>\(h)</td>") | join(""))
        + "<td><b>\(.action | h)</b></td><td>\(.description | h)</td><td>\(.opt_in_status | h)</td>"
        + "<td data-s=\"\(.auto_applied_after // 9999999999)\">\(two(.auto_applied_after))</td>"
        + "<td data-s=\"\(.forced_apply // 9999999999)\">\(two(.forced_apply))</td>"
        + "<td>\(.maint_window_utc | h)<br><span class=\"muted\">\(.maint_window_local | h)</span></td>"
        + "<td>"
        + "<div class=\"csec\">" + (if .backup_command == "" then "<div class=\"lbl\">1. backup first</div><span class=\"muted\">-</span>"
             else "<div class=\"lbl\">1. backup first (manual snapshot \(.backup_snapshot_name | h))</div>" + cmdbox(.backup_command)
                  + "<div class=\"lbl\">wait until the snapshot is available (same shell)</div>" + cmdbox(.backup_wait_command) end)
        + (if .backup_note != "" then "<div class=\"note\">\(.backup_note | h)</div>" else "" end) + "</div>"
        + "<div class=\"csec\">" + (if .apply_immediate_command == "" then "<div class=\"lbl\">2. apply immediately</div><span class=\"muted\">-</span>"
                    else "<div class=\"lbl\">2. apply immediately <span class=\"warn\">&#9888; may restart / fail over now</span></div>" + cmdbox(.apply_immediate_command) end)
        + (if .apply_note != "" then "<div class=\"note\">\(.apply_note | h)</div>" else "" end) + "</div>"
        + (if .minor_upgrade_command != "" then "<div class=\"csec\"><div class=\"lbl\">minor version upgrade &rarr; \(.latest_minor_version | h)</div>" + cmdbox(.minor_upgrade_command)
             + "<div class=\"note\">applies in the next maintenance window unless --apply-immediately is added</div></div>" else "" end)
        + (if .status_command != "" or .pending_actions_command != "" then "<div class=\"csec\">"
             + (if .status_command != "" then "<details><summary>check status (maintenance in progress?)</summary>" + cmdbox(.status_command) + "</details>" else "" end)
             + (if .pending_actions_command != "" then "<details><summary>pending actions (live)</summary>" + cmdbox(.pending_actions_command) + "</details>" else "" end)
             + "</div>" else "" end)
        + "</td></tr>";
def html:
  . as $r | ($r.summary.by_urgency) as $u
  | "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">"
  + "<title>RDS pending maintenance - \($r.meta.generated_local | h)</title><style>"
  + "body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1f2933}"
  + "header{background:#232f3e;color:#fff;padding:18px 28px}header h1{margin:0;font-size:22px}header p{margin:4px 0 0;color:#c9d1d9;font-size:13px}"
  + "main{padding:20px 28px}.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:18px}"
  + ".card{background:#fff;border-radius:8px;padding:12px 18px;min-width:120px;box-shadow:0 1px 3px rgba(0,0,0,.12);border-top:4px solid #8792a2}"
  + ".card .n{font-size:28px;font-weight:700}.card .l{font-size:12px;color:#52606d;text-transform:uppercase;letter-spacing:.04em}"
  + ".c-total{border-color:#232f3e}.c-overdue{border-color:#7b1fa2}.c-crit{border-color:#d32f2f}.c-warn{border-color:#f57c00}.c-info{border-color:#1976d2}.c-opt{border-color:#78909c}.c-err{border-color:#6d4c41}"
  + ".minis{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:18px}.mini{background:#fff;border-radius:8px;padding:8px 14px;box-shadow:0 1px 3px rgba(0,0,0,.12)}"
  + ".mini h3{margin:2px 0 6px;font-size:13px;color:#52606d}.mini table{border-collapse:collapse;font-size:13px}.mini td{padding:2px 10px 2px 0}.num{text-align:right;font-weight:600}"
  + "#q{padding:7px 10px;width:320px;border:1px solid #c5ccd6;border-radius:6px;margin-bottom:10px}"
  + "table.main{border-collapse:collapse;width:100%;background:#fff;font-size:12.5px;box-shadow:0 1px 3px rgba(0,0,0,.12)}"
  + "table.main th{background:#e9edf2;text-align:left;padding:7px 8px;cursor:pointer;white-space:nowrap;position:sticky;top:0}"
  + "table.main th:hover{background:#dde3ea}table.main td{padding:6px 8px;border-top:1px solid #e6e9ee;vertical-align:top}"
  + "table.main tr:hover td{background:#fafbfc}.muted{color:#7b8794;font-size:11.5px}"
  + ".u{font-weight:700;padding:2px 7px;border-radius:10px;color:#fff;font-size:11px;white-space:nowrap}"
  + ".u-OVERDUE{background:#7b1fa2}.u-CRIT{background:#d32f2f}.u-WARN{background:#f57c00}.u-INFO{background:#1976d2}.u-OPTIONAL{background:#78909c}"
  + "tr.r-OVERDUE td:first-child{border-left:4px solid #7b1fa2}tr.r-CRIT td:first-child{border-left:4px solid #d32f2f}tr.r-WARN td:first-child{border-left:4px solid #f57c00}"
  + ".errors{background:#fff3e0;border:1px solid #ffb74d;border-radius:8px;padding:10px 14px;margin-bottom:16px;font-size:13px}"
  + ".cmd{display:flex;gap:6px;align-items:flex-start;min-width:420px}.cmd code{font-family:SFMono-Regular,Consolas,Menlo,monospace;font-size:11.5px;background:#f1f3f6;border:1px solid #dde2e8;border-radius:4px;padding:4px 6px;white-space:pre-wrap;word-break:break-all;flex:1}"
  + ".ver b{font-family:SFMono-Regular,Consolas,Menlo,monospace}.ok-v{color:#2e7d32;font-weight:600}.behind{color:#e65100;font-weight:600}.pill{display:inline-block;font-size:10.5px;padding:1px 6px;border-radius:8px;background:#e9edf2;color:#334e68;margin-top:2px}"
  + ".toc{background:#fff;border-radius:8px;padding:8px 14px;margin-bottom:8px;box-shadow:0 1px 3px rgba(0,0,0,.12);font-size:13px}.toc a{margin-right:12px;color:#1565c0;text-decoration:none;white-space:nowrap}.cnt{font-size:11px;color:#52606d;font-weight:400;background:#e9edf2;border-radius:8px;padding:1px 7px}"
  + "section.eng{margin:22px 0}section.eng h2{font-size:17px;margin:0 0 6px;padding:6px 10px;background:#232f3e;color:#fff;border-radius:6px}section.eng h2 .cnt{background:#3d4b5c;color:#e3e8ee}"
  + ".ssum{font-size:12.5px;margin:0 0 8px;color:#334e68}.ssum a{color:#1565c0}.seq{display:inline-block;min-width:16px;text-align:center;font-weight:700;background:#334e68;color:#fff;border-radius:4px;padding:0 4px}"
  + ".csec{border-top:1px dashed #dde2e8;padding-top:5px;margin-top:5px}.csec:first-child{border-top:0;margin-top:0;padding-top:0}"
  + ".cp{font-size:11px;padding:3px 8px;border:1px solid #8792a2;border-radius:4px;background:#fff;cursor:pointer;white-space:nowrap}.cp:hover{background:#e9edf2}.cp.ok{background:#2e7d32;color:#fff;border-color:#2e7d32}"
  + "details{margin-top:4px}details summary{cursor:pointer;color:#52606d;font-size:11.5px}.lbl{font-size:11px;color:#52606d;margin-bottom:2px;font-weight:600}.warn{color:#c62828;font-weight:600}.note{color:#8d6e63;font-size:11.5px;margin-top:3px}"
  + "footer{padding:14px 28px;color:#7b8794;font-size:12px}</style></head><body>\n"
  + "<header id=\"top\"><h1>RDS pending maintenance report</h1><p>Generated \($r.meta.generated_utc | h) &middot; \($r.meta.generated_local | h) &middot; accounts: "
  + ($r.meta.accounts | map("\(.account) (\(.profile))") | join(", ") | h) + " &middot; regions: \($r.meta.regions | join(", ") | h)"
  + (if ($r.meta.filters_text // "") != "" then " &middot; filters: \($r.meta.filters_text | h)" else "" end) + "</p></header>\n<main>\n"
  + "<div class=\"cards\">" + card("pending actions"; $r.summary.total; "c-total") + card("resources"; $r.summary.resources; "c-total")
  + card("overdue"; ($u.OVERDUE // 0); "c-overdue") + card("critical (<= \($r.meta.crit_days)d)"; ($u.CRIT // 0); "c-crit")
  + card("warning (<= \($r.meta.warn_days)d)"; ($u.WARN // 0); "c-warn") + card("later"; ($u.INFO // 0); "c-info")
  + card("optional (no date)"; ($u.OPTIONAL // 0); "c-opt")
  + (if $r.meta.version_check != false then card("behind latest minor"; $r.summary.behind_latest_minor; "c-warn") else "" end) + (if $r.summary.errors > 0 then card("errors"; $r.summary.errors; "c-err") else "" end) + "</div>\n"
  + (if ($r.errors | length) > 0 then "<div class=\"errors\"><b>Report incomplete - AWS errors:</b><ul>"
       + ($r.errors | map("<li>\(.account | h) \(.profile | h) \(.region | h) <code>\(.call | h)</code>: \(.message | h)</li>") | join("")) + "</ul></div>\n" else "" end)
  + "<div class=\"minis\">" + minitable("By action"; $r.summary.by_action) + minitable("By engine"; $r.summary.by_engine)
  + minitable("By region"; $r.summary.by_region) + minitable("By account"; $r.summary.by_account) + "</div>\n"
  + "<input id=\"q\" type=\"search\" placeholder=\"Filter rows in every section (any text)...\">\n"
  + "<nav class=\"toc\"><b>Engines</b> " + ($r.summary.sections | map("<a href=\"#\(.anchor)\">\(.engine | h) <span class=\"cnt\">\(.total)</span></a>") | join(" ")) + "</nav>\n"
  + "<p class=\"muted\">Rows per engine are in patching order: by cluster / server, then <b>Seq</b> (1 = replicas / readers first, 2 = primary / writer last), then instance. Take the backup (1) before applying (2).</p>\n"
  + ( $r.summary.sections | map(. as $s
        | "<section id=\"\($s.anchor)\" class=\"eng\"><h2>\($s.engine | h) <span class=\"cnt\">\($s.total) action(s) &middot; \($s.resources) resource(s) &middot; \($s.groups) cluster/server group(s)</span></h2>"
          + "<div class=\"ssum\">" + ($s.by_urgency | to_entries | map("<span class=\"u u-\(.key)\">\(.key) \(.value)</span>") | join(" "))
          + " &middot; " + ($s.by_action | kv | h)
          + (if $r.meta.version_check != false then " &middot; <b>\($s.behind_latest_minor)</b> behind latest minor" else "" end)
          + " &middot; <a href=\"#top\">top</a></div>"
          + "<table class=\"main\"><thead><tr>" + html_head($r) + "</tr></thead><tbody>\n"
          + ([$r.rows[] | select(.engine == $s.engine) | html_row] | join("\n"))
          + "\n</tbody></table></section>") | join("\n") )
  + (if ($r.rows | length) == 0 then "<p style=\"padding:18px;text-align:center\">No pending maintenance actions found.</p>" else "" end)

  + "\n</main>\n<footer>\($r.meta.script | h) v\($r.meta.version | h) on \($r.meta.host | h) &middot; urgency: OVERDUE = apply date passed, CRIT &le; \($r.meta.crit_days)d, WARN &le; \($r.meta.warn_days)d, INFO later, OPTIONAL = no date &middot; read-only report, nothing was changed; commands are printed only - check the maintenance window and impact first (immediate may restart / fail over the DB; minor upgrades apply in the next window) &middot; exit \($r.summary.exit_code)</footer>\n"
  + "<script>(function(){var ts=document.querySelectorAll('table.main');Array.prototype.forEach.call(ts,function(t){var b=t.tBodies[0],dir={};"
  + "t.tHead.addEventListener('click',function(e){var th=e.target.closest('th');if(!th)return;var i=th.cellIndex;dir[i]=!dir[i];"
  + "var rows=Array.prototype.slice.call(b.rows);rows.sort(function(x,y){var a=x.cells[i],c=y.cells[i];if(!a||!c)return 0;"
  + "var va=a.getAttribute('data-s'),vb=c.getAttribute('data-s');var r;if(va!==null&&vb!==null){r=parseFloat(va)-parseFloat(vb);}"
  + "else{r=a.textContent.localeCompare(c.textContent);}return dir[i]?r:-r;});rows.forEach(function(r){b.appendChild(r);});});});"
  + "document.addEventListener('click',function(e){var bt=e.target.closest('.cp');if(!bt)return;var txt=bt.previousElementSibling.textContent;"
  + "var done=function(){bt.textContent='Copied';bt.classList.add('ok');setTimeout(function(){bt.textContent='Copy';bt.classList.remove('ok');},1500);};"
  + "var fb=function(){var ta=document.createElement('textarea');ta.value=txt;ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);ta.select();"
  + "try{document.execCommand('copy');done();}catch(x){}document.body.removeChild(ta);};"
  + "if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(txt).then(done,fb);}else{fb();}});"
  + "document.getElementById('q').addEventListener('input',function(){var q=this.value.toLowerCase();"
  + "Array.prototype.forEach.call(document.querySelectorAll('table.main tbody tr'),function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>=0?'':'none';});});})();</script>\n"
  + "</body></html>";

def alert:
  {status: .summary.overall, exit_code: .summary.exit_code, generated_utc: .meta.generated_utc, generated_local: .meta.generated_local,
   accounts: .meta.accounts, regions: .meta.regions, summary: .summary,
   urgent: [.rows[] | select(.severity == "CRIT") | {account, region, resource_type, identifier, cluster, engine, action, urgency,
            days_until, effective_apply_utc, effective_apply_local, opt_in_status, role, patch_sequence, backup_command, backup_wait_command, apply_immediate_command, status_command, pending_actions_command, apply_note,
            engine_version, next_minor_version, latest_minor_version, auto_minor_upgrade, minor_upgrade_command}],
   errors: .errors};

if $mode == "rows" then rows elif $mode == "finalize" then finalize elif $mode == "text" then text
elif $mode == "csv" then csv elif $mode == "html" then html elif $mode == "json" then json_out else alert end
