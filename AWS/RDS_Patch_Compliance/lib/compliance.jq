# lib/compliance.jq - logic + rendering for rds_patch_compliance_report.sh
include "versions" {search: "./"};   # lib/versions.jq: version parsing + minor candidate selection (shared with the sibling tools)
# Modes ($mode): rows | finalize | text | csv | json | html | alert | vkey_cmp (tests)
# Every mode gets: $now (epoch), $max_behind, $warn_days, $top_n, $tagcols, $f (filters), $nc_only; optional --argjson oracle_any (default false)

# ------------------------------------------------------------------ helpers
def h: tostring | @html;
def dash: if . == null or . == "" then "-" else tostring end;
def glob2re: "^" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
def gmatch($globs): . as $v | ($globs | length) == 0 or any($globs[]; . as $g | ($v // "") | test($g | glob2re; "i"));
def sq: tostring | if test("^[A-Za-z0-9_./:=@,+%-]+$") then . else "'" + gsub("'"; "'\\''") + "'" end;
def day: if . == null or . == "" then null else (tostring | .[0:10]) end;
def epoch_of_day: if . == null then null else (. + "T00:00:00Z" | fromdateiso8601) end;

# ------------------------------------------------------------------ version compare
# A version string is split into runs of digits and runs of letters; digit runs compare as NUMBERS (15.10 > 15.9,
# 3.05.2 = 3.5.2), letter runs as strings, and a shorter prefix sorts first (15.4 < 15.4.1). jq orders numbers
# before strings, so "19.0.0.0.ru-2024-01.rur-2024-01.r1" and "15.00.4415.2.v1" compare field by field.
# Aurora MySQL "8.0.mysql_aurora.3.05.2" shares the "8.0.mysql_aurora." prefix inside one major line, so the
# Aurora release (3.05.2) decides.
# vkey lives in lib/versions.jq; Oracle patch lines are parsed there (ora_parse) and compared numerically.
def vcmp($a; $b): ($a | vkey) as $x | ($b | vkey) as $y | if $x < $y then -1 elif $x > $y then 1 else 0 end;
# major line when AWS no longer lists the version (deprecated): same rule AWS uses for MajorEngineVersion
def derive_major($engine):
  split(".") as $k
  | if ($engine | test("postgres")) then (if (($k[0] | tonumber? // 0)) >= 10 then $k[0] else $k[0] + "." + ($k[1] // "0") end)
    elif ($engine | test("^oracle")) then $k[0]
    else ($k[0] + "." + ($k[1] // "0")) end;

# ------------------------------------------------------------------ maintenance window UTC -> IST
def dayn: {"sun":0,"mon":1,"tue":2,"wed":3,"thu":4,"fri":5,"sat":6}[ascii_downcase];
def dname: ["sun","mon","tue","wed","thu","fri","sat"][.];
def two: tostring | if length < 2 then "0" + . else . end;
def shift_win($mins):
  if . == null or . == "" then "" else
  split("-") | map(split(":") | ((.[0] | dayn) * 1440 + (.[1] | tonumber) * 60 + (.[2] | tonumber) + $mins) % 10080
                   | "\((. / 1440 | floor) | dname):\(((. % 1440) / 60 | floor) | two):\((. % 60) | two)") | join("-") end;

# ------------------------------------------------------------------ rows (per profile / region)
def svc_of: if . == "docdb" then "docdb" elif . == "neptune" then "neptune" else "rds" end;
def in_scope: test("^(aurora-postgresql|aurora-mysql|postgres|mysql|mariadb|sqlserver-(ee|se|ex|web)|oracle-(ee|se2|ee-cdb|se2-cdb)|docdb|neptune)$");
def tags_obj: [(.TagList // [])[] | {key: .Key, value: .Value}] | from_entries;
def mk_cmd($words; $region; $profile):
  ($words + ["--region", $region] + (if $profile != "" and $profile != "default" then ["--profile", $profile] else [] end)) | map(sq) | join(" ");

# one pending maintenance action -> structured + readable ("on" = "cluster", "member <id>" or "" for an instance)
def utc_day: if . == null or . == "" then null else tostring | .[0:10] end;
def ist_of: if . == null or . == "" then null else (tostring | .[0:19] + "Z" | fromdateiso8601 + 19800 | strftime("%Y-%m-%d %H:%M IST")) end;
def utc_of: if . == null or . == "" then null else (tostring | .[0:16] | sub("T"; " ")) + " UTC" end;
def pend_item($on):
  { action: .Action, on: $on, description: (.Description // ""), opt_in_status: (.OptInStatus // ""),
    auto_applied_after: (.AutoAppliedAfterDate | utc_day), forced_apply: (.ForcedApplyDate | utc_day), current_apply: (.CurrentApplyDate | utc_day),
    auto_applied_after_ist: (.AutoAppliedAfterDate | ist_of), forced_apply_ist: (.ForcedApplyDate | ist_of),
    auto_applied_after_utc: (.AutoAppliedAfterDate | utc_of), forced_apply_utc: (.ForcedApplyDate | utc_of) }
  | . + {text: (.action + (if .on != "" then " on " + .on else "" end)
          + " (" + ([ (if .auto_applied_after then "auto-apply \(.auto_applied_after)" else empty end),
                      (if .forced_apply then "forced \(.forced_apply)" else empty end),
                      (if .opt_in_status != "" then "opt-in: \(.opt_in_status)" else empty end) ] | if length == 0 then "no date, optional" else join(", ") end) + ")"
          + (if .description != "" then " - " + (.description | if length > 60 then .[0:57] + "..." else . end) else "" end))};

def rows:
  $ARGS.named as $A | ($A.account // "") as $account | ($A.profile // "") as $profile | ($A.region // "") as $region
  | ($A.clusters[0] // []) as $cl | ($A.instances[0] // []) as $in | ($A.pma[0] // []) as $pma
  | ($A.ev[0] // {}) as $ev | ($A.lc[0] // {}) as $lc
  | ($in | map({key: .DBInstanceIdentifier, value: .}) | from_entries) as $ix
  | ([$pma[] | .ResourceIdentifier as $a | .PendingMaintenanceActionDetails[]? | {arn: $a, d: .}] | group_by(.arn) | map({key: .[0].arn, value: map(.d)}) | from_entries) as $pc
  | ( [ $cl[] | select(.Engine | in_scope) | . as $c
        | {kind: "cluster", id: .DBClusterIdentifier, arn: .DBClusterArn, engine: .Engine, version: .EngineVersion,
           rtype: (if .Engine == "docdb" then "docdb-cluster" elif .Engine == "neptune" then "neptune-cluster"
                   elif (.Engine | startswith("aurora")) then "aurora-cluster" else "multi-az-cluster" end),
           window: (.PreferredMaintenanceWindow // ""), tags: tags_obj,
           members: [ (.DBClusterMembers // [])[] | {id: .DBInstanceIdentifier, writer: (.IsClusterWriter // false)} ],
           auto: ( if (.AutoMinorVersionUpgrade // null) != null and (.Engine | startswith("aurora") | not) then [.AutoMinorVersionUpgrade]
                   else [ (.DBClusterMembers // [])[] | $ix[.DBInstanceIdentifier].AutoMinorVersionUpgrade | select(. != null) ] end ),
           member_arns: [ (.DBClusterMembers // [])[] | {id: .DBInstanceIdentifier, arn: $ix[.DBInstanceIdentifier].DBInstanceArn} | select(.arn != null) ] } ]
      + [ $in[] | select((.DBClusterIdentifier // "") == "") | select(.Engine | in_scope)
        | {kind: "instance", id: .DBInstanceIdentifier, arn: .DBInstanceArn, engine: .Engine, version: .EngineVersion,
           rtype: "instance", window: (.PreferredMaintenanceWindow // ""), tags: tags_obj, members: [],
           auto: [.AutoMinorVersionUpgrade | select(. != null)], member_arns: []} ] ) as $res
  | [ $res[]
      | select(.engine | gmatch($f.engines))
      | select(. as $r | ([$r.id] + [$r.members[].id]) | any(.[]; gmatch($f.identifiers)))
      | . as $r
      # ONLY RDS metadata for THIS version: ValidUpgradeTarget[] of describe-db-engine-versions --engine E --engine-version V,
      # minor targets only (IsMajorVersionUpgrade == false) of the same engine. Nothing is derived from the full version list.
      | ($ev[$r.engine + "|" + $r.version] // {ok: false, error: "no lookup"}) as $e
      | ($e.ok == true) as $ok
      | ($ok and ($e.returned != true)) as $deprecated
      | ($ok and ($e.returned == true)) as $known
      | ($e.major // ($r.version | derive_major($r.engine))) as $major
      # minor_select (lib/versions.jq): same engine, IsMajorVersionUpgrade false, SAME major line (all engines),
      # Oracle: SAME patch line (mrp/rur/plain RU/spb...) unless --oracle-any-patch-line; newer than current only
      | (($e.targets // []) | minor_select($r.engine; $r.version; ($e.major // null); ($ARGS.named.oracle_any // false))) as $sel
      | $sel.targets as $tg
      | ($tg | map(.EngineVersion)) as $newer
      | ([ $tg[] | select(.AutoUpgrade == true) | .EngineVersion ] | .[-1] // null) as $auto_target
      | ([ ($e.targets // [])[] | select(.IsMajorVersionUpgrade == true) ] | length) as $major_targets
      | (if $known then ($newer | length) else null end) as $behind
      | (if $known | not then "UNKNOWN" elif $behind <= $max_behind then "COMPLIANT" else "NON-COMPLIANT" end) as $status
      | ($lc[$r.engine] // null) as $l
      | ([ ($l.majors // [])[] | select(.MajorEngineVersion == $major) | .SupportedEngineLifecycles[]? ]) as $lcs
      | ([ $lcs[] | select(.LifecycleSupportName | test("standard"; "i")) | .LifecycleSupportEndDate | day ] | .[0]) as $std
      | ([ $lcs[] | select(.LifecycleSupportName | test("extended"; "i")) | .LifecycleSupportEndDate | day ] | .[0]) as $ext
      | (if $std == null then null else ((($std | epoch_of_day) - $now) / 86400 | floor) end) as $days
      | ( if $l == null then (if ($r.engine | svc_of) != "rds" then "n/a (no lifecycle API for \($r.engine))" else "unknown (lifecycle lookup unavailable)" end)
          elif $std == null then "unknown (AWS lists no lifecycle dates for \($r.engine) \($major))"
          elif $days < 0 then "past standard support (Extended Support charges)"
          elif $days <= $warn_days then "standard support ends in \($days) days"
          else "ok" end ) as $sflag
      | ( [ ($pc[$r.arn] // [])[] | pend_item(if $r.kind == "cluster" then "cluster" else "" end) ]
          + [ $r.member_arns[] as $m | ($pc[$m.arn] // [])[] | pend_item("member " + $m.id) ] ) as $pend
      | ( if ($r.auto | length) == 0 then "unknown" elif all($r.auto[]; . == true) then "true" elif all($r.auto[]; . == false) then "false" else "mixed" end ) as $auto
      | ($newer[-1] // $r.version) as $latest
      | {account_id: $account, profile: $profile, region: $region, resource_type: $r.rtype, identifier: $r.id,
         members: ($r.members | map(.id + (if .writer then " (writer)" else "" end)) | join(", ")),
         member_count: ($r.members | length),
         engine: $r.engine, major_version: $major, current_version: $r.version,
         latest_minor_version: (if $known then $latest else null end),
         versions_behind: $behind, newer_versions: $newer, default_auto_upgrade_target: $auto_target, major_upgrade_targets: $major_targets,
         excluded_targets: $sel.excluded, version_warnings: $sel.warnings,
         compliance_status: $status, auto_minor_upgrade: $auto,
         standard_support_end: $std, extended_support_end: $ext, support_days_left: $days, support_flag: $sflag,
         past_standard_support: ($sflag | startswith("past")), nearing_end_of_support: ($sflag | startswith("standard support ends")),
         deprecated_version: $deprecated,
         pending_actions_count: ($pend | length), pending_actions: ($pend | map(.text) | join("; ")), pending_actions_detail: $pend,
         maint_window_utc: $r.window, maint_window_ist: ($r.window | shift_win(330)),
         tags: $r.tags, arn: $r.arn,
         upgrade_command: (if $known and ($behind // 0) > 0 then
             mk_cmd(["aws", ($r.engine | svc_of)] + (if $r.kind == "cluster" then ["modify-db-cluster", "--db-cluster-identifier", $r.id] else ["modify-db-instance", "--db-instance-identifier", $r.id] end)
                    + ["--engine-version", $latest]; $region; $profile) else "" end),
         note: ([ (if $ok | not then "version lookup failed: \($e.error // "unknown")" else empty end),
                  (if $deprecated then "current version not returned by describe-db-engine-versions (deprecated or not offered in \($region)); no valid upgrade targets known" else empty end),
                  (if $known and ($behind // 0) > 0 then "upgrade applies in the next maintenance window (no --apply-immediately)" + (if $r.rtype == "aurora-cluster" then "; Aurora restarts all instances together" else "" end) else empty end),
                  ($sel.excluded[] | .reason),
                  (if $auto == "false" then "auto minor upgrade is off" elif $auto == "mixed" then "auto minor upgrade is off on some members" else empty end) ] | join("; "))} ];

# ------------------------------------------------------------------ finalize: filters, sort, summary
def st_rank: {"NON-COMPLIANT": 0, "UNKNOWN": 1, "COMPLIANT": 2}[.] // 3;
def pct($a; $b): if $b == 0 then 0 else ($a * 1000 / $b | round) / 10 end;
def counts: {total: length, compliant: (map(select(.compliance_status == "COMPLIANT")) | length),
             non_compliant: (map(select(.compliance_status == "NON-COMPLIANT")) | length),
             unknown: (map(select(.compliance_status == "UNKNOWN")) | length)};
# Region-wise breakdown: one entry per account + region that was checked (meta.region_status, written by the
# script: scanned | databases | empty | probe-error), counted from ALL rows (before --non-compliant-only).
# Final status: error (any AWS error there, incl. a failed discovery probe), empty (no DB instance / cluster),
# databases (has instances / clusters). checked = databases + empty + error.
def region_rank: {"databases": 0, "error": 1, "empty": 2}[.] // 3;
def region_counts: counts + {pct_compliant: (if length == 0 then null else pct(counts.compliant; length) end),
                             with_pending: (map(select(.pending_actions_count > 0)) | length), pending_total: (map(.pending_actions_count) | add // 0),
                             past_standard_support: (map(select(.past_standard_support)) | length)};
def region_breakdown:
  . as $r
  | ($r.rows | group_by([.account_id, .region]) | map({key: (.[0].account_id + "|" + .[0].region), value: .}) | from_entries) as $by
  | [ ([($r.meta.region_status // [])[]] + [$r.rows[] | {account: .account_id, profile, region, status: "scanned"}]) | unique_by([.account, .region])[]
      | . as $x | ($by[$x.account + "|" + $x.region] // []) as $g
      | ([$r.errors[] | select(.account == $x.account and .region == $x.region)] | length) as $ne
      | {account_id: $x.account, profile: $x.profile, region: $x.region,
         status: (if $ne > 0 or $x.status == "probe-error" then "error"
                  elif ($g | length) > 0 or $x.status == "databases" then "databases"
                  elif $x.status == "empty" then "empty"
                  else "empty" end),
         skipped: ($x.status == "empty"), probe_instances: $x.probe_instances, probe_clusters: $x.probe_clusters, errors: $ne}
        + ($g | region_counts) ]
  | sort_by([(.status | region_rank), .account_id, .region]);
# Dates relative to $now are recomputed here (collection run AND --merge), so a merged report counts days from merge time.
def days_from($d): if $d == null then null else ((($d | epoch_of_day) - $now) / 86400 | floor) end;
def refresh_row:
  (if .standard_support_end != null then days_from(.standard_support_end) as $days
     | .support_days_left = $days
     | .support_flag = (if $days < 0 then "past standard support (Extended Support charges)"
                        elif $days <= $warn_days then "standard support ends in \($days) days" else "ok" end)
   else . end)
  | .past_standard_support = (.support_flag | startswith("past")) | .nearing_end_of_support = (.support_flag | startswith("standard support ends"))
  | .pending_actions_detail |= map(([.current_apply, .auto_applied_after, .forced_apply] | map(select(. != null)) | min) as $m
                                   | . + {next_date: $m, days_until: days_from($m)})
  | ([.pending_actions_detail[].next_date | select(. != null)] | min) as $nx
  | .next_maintenance = $nx | .days_until_maintenance = days_from($nx);
def account_breakdown($regs):
  . as $r
  | [ ($r.meta.accounts // [])[] | . as $a | [$r.rows[] | select(.account_id == $a.account)] as $g
      | {account_id: $a.account, profile: $a.profile, collected_utc: ($a.collected_utc // $r.meta.generated_utc), source: ($a.source // null),
         regions_with_databases: ([$regs[] | select(.account_id == $a.account and .status == "databases")] | length),
         errors: ([$r.errors[] | select(.account == $a.account)] | length)} + ($g | region_counts) ]
  | sort_by(.account_id);
def finalize:
  (.rows |= map(refresh_row))
  | . as $r
  | ($r | region_breakdown) as $regs
  | ($r.rows | map(select(($nc_only | not) or .compliance_status == "NON-COMPLIANT"))
             | sort_by([.engine, (.compliance_status | st_rank), -(.versions_behind // -1), (.identifier | ascii_downcase), .account_id, .region])) as $rows
  | ($r.rows | counts) as $all
  | $r + {rows: $rows,
          summary: ($all + {
             pct_compliant: pct($all.compliant; $all.total), shown: ($rows | length),
             max_behind: $max_behind, warn_days: $warn_days,
             past_standard_support: ($r.rows | map(select(.past_standard_support)) | length),
             nearing_end_of_support: ($r.rows | map(select(.nearing_end_of_support)) | length),
             auto_minor_off: ($r.rows | map(select(.auto_minor_upgrade == "false" or .auto_minor_upgrade == "mixed")) | length),
             with_pending: ($r.rows | map(select(.pending_actions_count > 0)) | length),
             pending_total: ($r.rows | map(.pending_actions_count) | add // 0),
             pending_by_action: ([$r.rows[].pending_actions_detail[].action] | group_by(.) | map({key: .[0], value: length}) | sort_by(-.value, .key) | from_entries),
             deprecated: ($r.rows | map(select(.deprecated_version)) | length),
             errors: ($r.errors | length),
             regions: $regs,
             accounts: ($r | account_breakdown($regs)),
             regions_total: ({account_id: "ALL", profile: "", region: "All regions", status: "",
                              errors: ($r.errors | length)} + ($r.rows | region_counts)),
             region_overview: {mode: ($r.meta.region_discovery.mode // "explicit"), probe_parallel: ($r.meta.region_discovery.probe_parallel // null),
                               checked: ($regs | length), with_databases: ($regs | map(select(.status == "databases")) | length),
                               empty: ($regs | map(select(.status == "empty")) | length), error: ($regs | map(select(.status == "error")) | length),
                               empty_regions: ($regs | map(select(.status == "empty")) | group_by(.account_id) | map({account_id: .[0].account_id, regions: map(.region)}))},
             engines: ($r.rows | group_by(.engine) | map(. as $g | {engine: $g[0].engine, anchor: ("eng-" + ($g[0].engine | gsub("[^A-Za-z0-9]"; "-")))} + ($g | counts)
                         + {pct_compliant: pct(($g | counts).compliant; $g | length),
                            majors: ($g | group_by(.major_version) | map(. as $m | {major: $m[0].major_version} + ($m | counts)
                                       + {latest_minor: ([$m[].latest_minor_version] | latest_of($m[0].engine)),   # Oracle: per patch line
                                          standard_support_end: ([$m[].standard_support_end | select(. != null)] | .[0] // null),
                                          support_flag: ($m[0].support_flag)}) | sort_by(.major | vkey) | reverse)})),
             top_behind: ([$r.rows[] | select(.versions_behind != null and .versions_behind > 0)] | sort_by([-.versions_behind, .identifier]) | .[:$top_n]
                          | map({identifier, engine, region, account_id, current_version, latest_minor_version, versions_behind, compliance_status}))
          })};

# ------------------------------------------------------------------ text
def pad($n): tostring | if length >= $n then .[0:$n] else . + (" " * ($n - length)) end;
def rpad($n): tostring | if length >= $n then . else (" " * ($n - length)) + . end;
def short_list: if length == 0 then "-" elif length <= 4 then join(", ") else (.[:3] | join(", ")) + ", ... +\(length - 3) (latest \(.[-1]))" end;
def pend_summary: "on \(.with_pending) server(s): " + (.pending_by_action | to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "none" else . end);
def pend_tip: [ .pending_actions_detail[] | .text + (if .auto_applied_after_utc then " | auto-apply \(.auto_applied_after_utc) = \(.auto_applied_after_ist)" else "" end)
                + (if .forced_apply_utc then " | forced \(.forced_apply_utc) = \(.forced_apply_ist)" else "" end) ] | join("\n");
def region_mode_txt: {"discover": "discovery probe, \(.probe_parallel) in parallel; full scan only where databases or a probe error",
                       "full": "every enabled region scanned in full (--no-discover)", "explicit": "queried directly, no probe", "merge": "merged offline from saved data"}[.mode] // .mode;
def region_line: "\(.checked) checked, \(.with_databases) with databases, \(.empty) empty, \(.error) error\(if .error == 1 then "" else "s" end)";
# Region NAMES are never listed in the report header; empty regions (no DB instance / cluster) are only counted.
# Rows / CSV show regions with databases or an AWS error; JSON summary.regions keeps every region (incl. empty).
def shown_regions: [.summary.regions[] | select(.status != "empty")];
def text:
  . as $r | $r.summary as $s | $s.region_overview as $ro | (($r.meta.accounts | length) > 1) as $multi
  | ([12, ($r.rows[] | (.current_version, .latest_minor_version) | tostring | length)] | max + 2) as $vw
  | ([20, ($s.engines[].engine | length)] | max + 2) as $ew
  | "RDS PATCH COMPLIANCE REPORT - \($r.meta.generated_utc) (\($r.meta.generated_local))",
    "Accounts : \($r.meta.accounts | map("\(.account) (\(.profile))") | join(", "))" + (if $ro.mode == "explicit" then "   Regions: \($r.meta.regions | length) given" elif $ro.mode == "merge" then "   Merged: \($r.meta.merge.files) file(s)" else "   Regions: all enabled" end),
    "Rule     : COMPLIANT when RDS lists at most \($s.max_behind) valid minor upgrade target(s) for the current version (NON-COMPLIANT = \($s.max_behind + 1)+; UNKNOWN = lookup failed or current version not returned)",
    "Source   : ValidUpgradeTarget (IsMajorVersionUpgrade=false) of describe-db-engine-versions --engine-version <current>, per server. Latest minor per major = highest valid target seen (current version when up to date)",
    "Regions  : \($ro | region_line) (\($ro | region_mode_txt))" + (if $multi then " - per account x region" else "" end),
    (if ($r.meta.filters_text // "") != "" then "Filters  : \($r.meta.filters_text)" else empty end),
    "",
    "SUMMARY",
    "  Servers/clusters : \($s.total)   COMPLIANT \($s.compliant)   NON-COMPLIANT \($s.non_compliant)   UNKNOWN \($s.unknown)   -> \($s.pct_compliant)% compliant",
    "  Support          : \($s.past_standard_support) past standard support (Extended Support charges), \($s.nearing_end_of_support) ending within \($s.warn_days) days",
    "  Pending maint.   : " + (if $s.with_pending == 0 then "none" else ($s | pend_summary) + " (\($s.pending_total) action(s))" end),
    "  Other flags      : auto minor upgrade off \($s.auto_minor_off), current version not returned / deprecated \($s.deprecated)",
    (if $s.errors > 0 then "  AWS errors       : \($s.errors) (see ERRORS at the end; affected regions may be missing)" else empty end),
    "",
    "PER ENGINE / MAJOR VERSION",
    "  " + ("ENGINE" | pad($ew)) + ("MAJOR" | pad(10)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + "  " + ("LATEST MINOR" | pad($vw)) + "SUPPORT",
    ($s.engines[] | . as $e | .majors[] | "  " + ($e.engine | pad($ew)) + (.major | pad(10)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6)) + "  " + ((.latest_minor | dash) as $l | if ($l | contains("; ")) then ("per patch line, below" | pad($vw)) else ($l | pad($vw)) end) + (.support_flag | dash) + (if .standard_support_end != null then " (standard end \(.standard_support_end))" else "" end)
       + ((.latest_minor // "") | if contains("; ") then "\n" + (split("; ") | map("        latest minor, " + .) | join("\n")) else "" end)),
    ($s.engines[] | "  " + (.engine | pad($ew)) + ("all" | pad(10)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6)) + "  \(.pct_compliant)% compliant"),
    "",
    "PER REGION (account x region with databases or an AWS error; empty regions only counted above; pending = servers with pending maintenance)",
    "  " + ("ACCOUNT" | pad(14)) + ("REGION" | pad(16)) + ("STATUS" | pad(11)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + ("%COMPL" | rpad(8)) + ("PEND" | rpad(6)) + ("PAST-STD" | rpad(10)),
    (($r | shown_regions) + [$s.regions_total] | .[] | "  " + (.account_id | pad(14)) + (.region | pad(16)) + (.status | pad(11)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6))
       + ((if .pct_compliant == null then "-" else "\(.pct_compliant)%" end) | rpad(8)) + (.with_pending | rpad(6)) + (.past_standard_support | rpad(10))
       + (if .status == "error" then "  see ERRORS" + (if .total == 0 then " (no data)" else " (partial)" end) else "" end)),
    "",
    "PER ACCOUNT",
    "  " + ("ACCOUNT" | pad(14)) + ("PROFILE" | pad(16)) + ("COLLECTED" | pad(22)) + ("REG" | rpad(4)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + ("%COMPL" | rpad(8)) + ("PEND" | rpad(6)),
    ($s.accounts[] | "  " + (.account_id | pad(14)) + (.profile | pad(16)) + (.collected_utc | pad(22)) + (.regions_with_databases | rpad(4)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6))
       + ((if .pct_compliant == null then "-" else "\(.pct_compliant)%" end) | rpad(8)) + (.with_pending | rpad(6))),
    "",
    "TOP \($top_n) MOST BEHIND",
    (if ($s.top_behind | length) == 0 then "  none" else
      ($s.top_behind[] | "  " + (.versions_behind | tostring | rpad(3)) + " behind  " + (.identifier | pad(32)) + (.engine | pad($ew)) + (.current_version | pad($vw)) + "-> " + (.latest_minor_version | dash | pad($vw)) + .compliance_status + "  (" + .account_id + " " + .region + ")") end),
    "",
    ($s.engines[] | . as $e
      | "=== \($e.engine): \($e.total) (compliant \($e.compliant), non-compliant \($e.non_compliant), unknown \($e.unknown)) ===",
        "  " + ("STATUS" | pad(14)) + ("BEHIND" | rpad(6)) + "  " + ("IDENTIFIER" | pad(32)) + ("TYPE" | pad(17)) + ("CURRENT" | pad($vw)) + ("LATEST MINOR" | pad($vw)) + ("AUTO" | pad(7)) + ("PEND" | rpad(4)) + "  " + ("ACCOUNT" | pad(13)) + ("REGION" | pad(15)) + "FLAGS",
        ($r.rows[] | select(.engine == $e.engine)
          | ("  " + (.compliance_status | pad(14)) + (.versions_behind | dash | rpad(6)) + "  " + (.identifier | pad(32)) + (.resource_type | pad(17)) + (.current_version | pad($vw)) + (.latest_minor_version | dash | pad($vw))
            + (.auto_minor_upgrade | pad(7)) + (.pending_actions_count | rpad(4)) + "  " + (.account_id | pad(13)) + (.region | pad(15))
            + ([ (if .support_flag != "ok" and (.support_flag | startswith("n/a") | not) then .support_flag else empty end), (if .deprecated_version then "current version not returned (deprecated?)" else empty end)] | join("; ") | dash)),
          (.pending_actions_detail[] | "      pending: " + .text + (if .auto_applied_after_ist then " [auto-apply \(.auto_applied_after_ist)]" else "" end))),
        ""),
    (if ($r.rows | length) == 0 then "No servers matched.", "" else empty end),
    (if ($r.errors | length) > 0 then "ERRORS", ($r.errors[] | "  \(.account) \(.profile)/\(.region): \(.call): \(.message)"), "" else empty end),
    "Upgrade commands (printed only, never run) are in the CSV / HTML / JSON output.";

# ------------------------------------------------------------------ csv / json
def cols: ["account_id","profile","region","resource_type","identifier","members","engine","major_version","current_version","latest_minor_version",
           "versions_behind","newer_versions","default_auto_upgrade_target","compliance_status","auto_minor_upgrade","standard_support_end","extended_support_end","support_flag",
           "pending_actions_count","pending_actions","deprecated_version","maint_window_utc","maint_window_ist"];
def csv:
  . as $r
  | (cols + ($tagcols | map("tag:" + .)) + ["arn","upgrade_command","note","next_maintenance","days_until_maintenance"] | @csv),
    ($r.rows[] | . as $x | ([cols[] | $x[.]] | map(if type == "array" then join(" ") elif . == null then "" else . end))
       + ($tagcols | map($x.tags[.] // "")) + [$x.arn, $x.upgrade_command, $x.note, ($x.next_maintenance // ""), ($x.days_until_maintenance // "")] | @csv);
def csv_regions:
  [["account_id","account_id"],["profile","profile"],["region","region"],["status","status"],["total","total"],["compliant","compliant"],
   ["non_compliant","non_compliant"],["unknown","unknown"],["pct_compliant","pct_compliant"],["servers_with_pending_maintenance","with_pending"],
   ["pending_actions","pending_total"],["past_standard_support","past_standard_support"],["aws_errors","errors"],
   ["probe_instances_max20","probe_instances"],["probe_clusters_max20","probe_clusters"]] as $c
  | ($c | map(.[0]) | @csv), ((shown_regions + [.summary.regions_total])[] | . as $x | [$c[] | $x[.[1]] | if . == null then "" else . end] | @csv);
def json_out: .;
def alert: {summary: .summary, non_compliant: [.rows[] | select(.compliance_status == "NON-COMPLIANT") | {account_id, region, identifier, engine, current_version, latest_minor_version, versions_behind}], errors: .errors};

# ------------------------------------------------------------------ html
def stc: {"COMPLIANT": "ok", "NON-COMPLIANT": "bad", "UNKNOWN": "unk"}[.] // "unk";
def sfc: if startswith("past") then "bad" elif startswith("standard support ends") then "warn" elif . == "ok" then "ok" else "muted" end;
def card($label; $val; $cls; $sub): "<div class=\"card \($cls)\" data-k=\"\($label | ascii_downcase | gsub("[^a-z]+"; "-"))\"><div class=\"v\">\($val | h)</div><div class=\"l\">\($label | h)</div><div class=\"s\">\($sub | h)</div></div>";
def dleft: if . == null then "" elif . < 0 then "\(-.) day(s) overdue" elif . == 0 then "today" else "in \(.) day(s)" end;
def html_row:
  . as $x
  | "<tr data-i=\"\(._i)\"><td><span class=\"st \(.compliance_status | stc)\">\(.compliance_status)</span></td><td data-s=\"\(.versions_behind // -1)\">\(.versions_behind | dash)</td>"
  + "<td><b>\(.identifier | h)</b>" + (if .members != "" then "<div class=\"sub\">\(.members | h)</div>" else "" end) + "</td>"
  + "<td>\(.resource_type | h)</td><td>\(.major_version | h)</td><td class=\"mono\">\(.current_version | h)</td><td class=\"mono\">\(.latest_minor_version | dash | h)</td>"
  + "<td class=\"mono small\">\(.newer_versions | short_list | h)</td><td class=\"mono small\">\(.default_auto_upgrade_target | dash | h)</td>"
  + "<td class=\"\(if .auto_minor_upgrade == "true" then "ok" elif .auto_minor_upgrade == "unknown" then "muted" else "warn" end)\">\(.auto_minor_upgrade | h)</td>"
  + "<td>\(.standard_support_end | dash | h)</td><td>\(.extended_support_end | dash | h)</td><td class=\"\(.support_flag | sfc)\">\(.support_flag | h)</td>"
  + "<td data-s=\"\(.pending_actions_count)\">" + (if .pending_actions_count == 0 then "<span class=\"muted\">0</span>"
       else "<details class=\"pend\" title=\"\(pend_tip | h)\"><summary><span class=\"badge\">\(.pending_actions_count)</span></summary><ul>"
            + (.pending_actions_detail | map("<li>\(.text | h)" + (if .auto_applied_after_ist then "<div class=\"sub\">auto-apply \(.auto_applied_after_utc | h) = \(.auto_applied_after_ist | h)</div>" else "" end)
                + (if .forced_apply_ist then "<div class=\"sub\">forced \(.forced_apply_utc | h) = \(.forced_apply_ist | h)</div>" else "" end) + "</li>") | join("")) + "</ul></details>"
            + (if .days_until_maintenance != null then "<div class=\"sub \(if .days_until_maintenance < 0 then "bad" elif .days_until_maintenance <= 14 then "warn" else "" end)\">next \(.next_maintenance) &middot; \(.days_until_maintenance | dleft)</div>" else "" end) end) + "</td><td class=\"small\">\(.maint_window_utc | dash | h) UTC<br>\(.maint_window_ist | dash | h) IST</td>"
  + "<td>\(.account_id | h)<div class=\"sub\">\(.profile | h) &middot; \(.region | h)</div></td>"
  + ($tagcols | map("<td>\($x.tags[.] // "" | h)</td>") | join(""))
  + "<td class=\"cmd\">" + (if .upgrade_command != "" then "<code>\(.upgrade_command | h)</code><button class=\"cp\">Copy</button>" else "-" end) + "</td>"
  + "<td class=\"small\">\(.note | h)" + (if .deprecated_version then " <span class=\"st bad\">DEPRECATED</span>" else "" end) + "<div class=\"sub mono\">\(.arn | h)</div></td></tr>";
def rgc: {"databases": "db", "error": "bad", "empty": "unk"}[.] // "unk";
def pctc: if . == null then "muted" elif . >= 100 then "ok" elif . >= 80 then "warn" else "bad" end;
def region_tr($foot):
  "<tr\(if $foot then " class=\"foot\"" else " data-k=\"\(.account_id | h)|\(.region | h)\"" end)><td>\(if $foot then "<b>All regions</b>" else (.account_id | h) + "<div class=\"sub\">\(.profile | h)</div>" end)</td>"
  + "<td>\(if $foot then "" else "<b>\(.region | h)</b>" end)</td>"
  + "<td data-s=\"\(if $foot then 9 else (.status | region_rank) end)\">\(if $foot then "" else "<span class=\"st \(.status | rgc)\">\(.status | h)</span>" + (if .status == "error" then "<div class=\"sub\">see Errors\(if .total == 0 then ", no data" else ", partial" end)</div>" else "" end) end)</td>"
  + "<td class=\"n\" data-s=\"\(.total)\"><b>\(.total)</b></td><td class=\"n \(if .compliant > 0 then "ok" else "" end)\" data-s=\"\(.compliant)\">\(.compliant)</td>"
  + "<td class=\"n \(if .non_compliant > 0 then "bad" else "" end)\" data-s=\"\(.non_compliant)\">\(.non_compliant)</td><td class=\"n\" data-s=\"\(.unknown)\">\(.unknown)</td>"
  + "<td class=\"n \(.pct_compliant | pctc)\" data-s=\"\(.pct_compliant // -1)\">" + (if .pct_compliant == null then "-" else "\(.pct_compliant)%<div class=\"bar\"><i class=\"\(.pct_compliant | pctc)\" style=\"width:\(.pct_compliant)%\"></i></div>" end) + "</td>"
  + "<td class=\"n \(if .with_pending > 0 then "warn" else "" end)\" data-s=\"\(.with_pending)\">\(.with_pending)\(if .pending_total > 0 then "<div class=\"sub\">\(.pending_total) action(s)</div>" else "" end)</td>"
  + "<td class=\"n \(if .past_standard_support > 0 then "bad" else "" end)\" data-s=\"\(.past_standard_support)\">\(.past_standard_support)</td></tr>";
def html_regions($r; $s; $ro; $multi):
  "<section id=\"regions\"><h2>Per region <span class=\"muted\">\($ro | region_line) &middot; \($ro | region_mode_txt | h)\(if $multi then " &middot; per account x region" else "" end) &middot; click a header to sort</span></h2>"
  + "<table class=\"sortable regions\"><thead><tr><th>Account</th><th>Region</th><th>Status</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th><th>Past standard support</th></tr></thead><tbody>"
  + ($r | shown_regions | map(region_tr(false)) | join("")) + "</tbody><tfoot>" + ($s.regions_total | region_tr(true)) + "</tfoot></table>"
  + "</section>";
def account_tr:
  "<tr data-a=\"\(.account_id | h)\"><td><b>\(.account_id | h)</b><div class=\"sub\">\(.profile | h)</div></td><td class=\"small\">\(.collected_utc | dash | h)\(if .source then "<div class=\"sub\">\(.source | h)</div>" else "" end)</td>"
  + "<td class=\"n\" data-s=\"\(.regions_with_databases)\">\(.regions_with_databases)\(if .errors > 0 then "<div class=\"sub bad\">\(.errors) error(s)</div>" else "" end)</td>"
  + "<td class=\"n\" data-s=\"\(.total)\"><b>\(.total)</b></td><td class=\"n \(if .compliant > 0 then "ok" else "" end)\" data-s=\"\(.compliant)\">\(.compliant)</td>"
  + "<td class=\"n \(if .non_compliant > 0 then "bad" else "" end)\" data-s=\"\(.non_compliant)\">\(.non_compliant)</td><td class=\"n\" data-s=\"\(.unknown)\">\(.unknown)</td>"
  + "<td class=\"n \(.pct_compliant | pctc)\" data-s=\"\(.pct_compliant // -1)\">" + (if .pct_compliant == null then "-" else "\(.pct_compliant)%<div class=\"bar\"><i class=\"\(.pct_compliant | pctc)\" style=\"width:\(.pct_compliant)%\"></i></div>" end) + "</td>"
  + "<td class=\"n \(if .with_pending > 0 then "warn" else "" end)\" data-s=\"\(.with_pending)\">\(.with_pending)\(if .pending_total > 0 then "<div class=\"sub\">\(.pending_total) action(s)</div>" else "" end)</td>"
  + "<td class=\"n \(if .past_standard_support > 0 then "bad" else "" end)\" data-s=\"\(.past_standard_support)\">\(.past_standard_support)</td></tr>";
def html_accounts($s):
  "<section id=\"accounts\"><h2>Per account <span class=\"muted\">\($s.accounts | length) account(s) &middot; click a header to sort</span></h2>"
  + "<table class=\"sortable accounts\"><thead><tr><th>Account</th><th>Collected</th><th>Regions with DBs</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th><th>Past standard support</th></tr></thead><tbody>"
  + ($s.accounts | map(account_tr) | join("")) + "</tbody></table></section>";
def html_sources($r):
  if ($r.meta.merge // null) == null then "" else
  "<section id=\"sources\"><h2>Merged inputs <span class=\"muted\">\($r.meta.merge.files) file(s) &middot; per account the newest collection wins &middot; days to maintenance / support counted from merge time (\($r.meta.generated_utc | h))</span></h2>"
  + "<table class=\"sources\"><thead><tr><th>File</th><th>Collected</th><th>Accounts used</th><th>Accounts ignored (newer file exists)</th><th>Script</th></tr></thead><tbody>"
  + ($r.meta.merge.sources | map("<tr><td class=\"mono small\">\(.file | h)</td><td class=\"small\">\(.collected_utc | h)<div class=\"sub\">\(.collected_local // "" | h)</div></td><td>\(.used | join(", ") | dash | h)</td><td class=\"muted\">\(.superseded | join(", ") | dash | h)</td><td class=\"small\">v\(.script_version | h)</td></tr>") | join(""))
  + "</tbody></table></section>" end;
def page_data($r):
  {cols: (cols + ($tagcols | map("tag:" + .)) + ["arn","upgrade_command","note","next_maintenance","days_until_maintenance"]), tagcols: $tagcols,
   csv_acct: (if ($r.meta.accounts | length) == 1 then $r.meta.accounts[0].account else "" end), csv_stamp: ($r.meta.generated_utc | gsub("[^0-9]"; "") | .[0:12]),
   nc_only: $nc_only,
   accounts: [$r.meta.accounts[] | {account, profile}],
   rows: [$r.rows[] | del(.pending_actions_detail, .excluded_targets, .version_warnings)]}
  | tojson | gsub("<"; "\\u003c") | gsub("\u2028"; "\\u2028") | gsub("\u2029"; "\\u2029");
def html:
  . as $r | $r.summary as $s | $s.region_overview as $ro | (($r.meta.accounts | length) > 1) as $multi
  | ($r.rows | to_entries | map(.value + {_i: .key})) as $irows
  | "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>RDS patch compliance - \($r.meta.generated_utc | h)</title><style>"
  + "body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1f2933}header{background:#232f3e;color:#fff;padding:16px 26px}"
  + "header h1{margin:0;font-size:21px}header p{margin:4px 0 0;color:#c9d1d9;font-size:13px}main{padding:16px 26px}"
  + ".cards{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:14px}.card{background:#fff;border-radius:10px;padding:12px 16px;min-width:150px;box-shadow:0 1px 3px rgba(0,0,0,.12);border-top:4px solid #9aa5b1}"
  + ".card .v{font-size:26px;font-weight:700}.card .l{font-size:13px;font-weight:600}.card .s{font-size:12px;color:#52606d}.card.ok{border-color:#2e7d32}.card.bad{border-color:#c62828}.card.warn{border-color:#e08a00}.card.unk{border-color:#7b8794}"
  + "table{border-collapse:collapse;background:#fff;font-size:12.5px;box-shadow:0 1px 3px rgba(0,0,0,.12);margin-bottom:16px}th{background:#e9edf2;text-align:left;padding:6px 8px;position:sticky;top:0}td{padding:6px 8px;border-top:1px solid #e6e9ee;vertical-align:top}"
  + "table.main th{cursor:pointer}table.main th:hover{background:#dde3ea}.st{display:inline-block;padding:2px 7px;border-radius:10px;font-weight:700;font-size:11.5px;white-space:nowrap}"
  + ".st.ok{background:#e6f4ea;color:#1b5e20}.st.bad{background:#fdecea;color:#b71c1c}.st.unk{background:#eceff1;color:#455a64}td.ok{color:#2e7d32}td.bad{color:#c62828;font-weight:600}td.warn{color:#b26a00;font-weight:600}td.muted,.muted{color:#7b8794}"
  + ".sub{color:#7b8794;font-size:11px}.mono,code{font-family:SFMono-Regular,Consolas,monospace;font-size:11.5px}.small{font-size:11.5px}td.cmd code{display:block;max-width:380px;white-space:pre-wrap;word-break:break-all}"
  + ".badge{display:inline-block;min-width:18px;padding:1px 7px;border-radius:10px;background:#e08a00;color:#fff;font-weight:700;text-align:center}details.pend summary{cursor:pointer;list-style:none}details.pend ul{margin:4px 0 0;padding-left:16px;min-width:260px}"
  + ".cp{margin-top:4px;font-size:11px;padding:2px 8px;border:1px solid #9aa5b1;background:#fff;border-radius:5px;cursor:pointer}.cp.ok{background:#e6f4ea}"
  + "h2{font-size:16px;margin:18px 0 6px}h3{font-size:14px;margin:12px 0 6px}#q{width:420px;padding:7px 10px;border:1px solid #9aa5b1;border-radius:6px;margin:8px 0 12px;font-size:13px}"
  + ".grid{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}table.sortable th{cursor:pointer}table.sortable th:hover{background:#dde3ea}td.n{text-align:right}"
  + ".st.db{background:#e3f0fb;color:#0d47a1}tfoot td{border-top:2px solid #232f3e;background:#f0f3f7;font-weight:600}"
  + ".bar{height:4px;background:#e6e9ee;border-radius:2px;margin-top:3px;min-width:70px}.bar i{display:block;height:4px;border-radius:2px;background:#2e7d32}.bar i.warn{background:#e08a00}.bar i.bad{background:#c62828}"
  + ".toolbar{position:sticky;top:0;z-index:5;background:#f5f6f8;display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 0;margin-bottom:6px;border-bottom:1px solid #dde3ea}"
  + ".toolbar select,.toolbar input,.toolbar button{padding:6px 8px;border:1px solid #9aa5b1;border-radius:6px;font-size:13px;background:#fff}.toolbar input#q{width:240px;margin:0}.toolbar button{cursor:pointer}.toolbar button.pri{background:#232f3e;color:#fff;border-color:#232f3e}"
  + ".toolbar .cnt{color:#52606d;font-size:12.5px}.filtered .card{border-style:dashed}.flt-note{display:none;color:#b26a00;font-size:12px;margin:0 0 8px}.filtered .flt-note{display:block}"
  + "footer{padding:10px 26px 24px;color:#7b8794;font-size:12px}</style></head><body>"
  + "<header id=\"top\"><h1>RDS patch compliance report</h1><p>\($r.meta.generated_utc | h) &middot; \($r.meta.generated_local | h) &middot; accounts \($r.meta.accounts | map("\(.account) (\(.profile))") | join(", ") | h) &middot; Regions: \($ro | region_line)\(if $r.meta.merge then " &middot; merged from \($r.meta.merge.files) file(s)" else "" end)</p></header><main>"
  + "<div class=\"toolbar\" id=\"filters\"><select id=\"f-acct\" aria-label=\"Account\"><option value=\"\">All accounts</option></select><select id=\"f-region\" aria-label=\"Region\"><option value=\"\">All regions</option></select>"
  + "<select id=\"f-engine\" aria-label=\"Engine\"><option value=\"\">All engines</option></select><select id=\"f-status\" aria-label=\"Compliance status\"><option value=\"\">All statuses</option></select>"
  + "<input id=\"q\" type=\"search\" placeholder=\"Search DB name (cluster / instance / member)\"><button id=\"f-reset\" type=\"button\">Reset</button><button id=\"f-csv\" class=\"pri\" type=\"button\">Export CSV</button><span class=\"cnt\" id=\"f-count\"></span></div>"
  + "<p class=\"flt-note\">Filtered view: cards, Per account and Per region show only the servers matching the filters. Per engine / major and Top most behind always show all servers.</p>"
  + "<p class=\"muted\">Rule: <b>COMPLIANT</b> = at most \($s.max_behind) valid minor upgrade target(s) for the current version; <b>NON-COMPLIANT</b> = \($s.max_behind + 1) or more; <b>UNKNOWN</b> = lookup failed or current version not returned (deprecated). Counted are only the <b>valid minor upgrade targets</b> RDS returns for the server's current version (describe-db-engine-versions --engine-version &lt;current&gt;, ValidUpgradeTarget with IsMajorVersionUpgrade=false). Latest minor per major = highest valid target seen (or the current version when up to date).<br><b>Pending maint.</b> = maintenance actions AWS has scheduled or offered for this server that haven't been applied yet (cluster rows include their member instances' actions); click the badge to expand, hover for IST dates.</p>"
  + "<div class=\"cards\">" + card("Servers / clusters"; $s.total; ""; "\($r.meta.accounts | length) account(s), \($r.meta.regions | length) region(s)")
  + card("Compliant"; $s.compliant; "ok"; "\($s.pct_compliant)% of all") + card("Non-compliant"; $s.non_compliant; (if $s.non_compliant > 0 then "bad" else "ok" end); "> \($s.max_behind) behind")
  + card("Unknown"; $s.unknown; "unk"; "lookup failed / version not returned")
  + card("Extended Support"; $s.past_standard_support; (if $s.past_standard_support > 0 then "bad" else "ok" end); "past standard support")
  + card("Support ending"; $s.nearing_end_of_support; (if $s.nearing_end_of_support > 0 then "warn" else "ok" end); "within \($s.warn_days) days")
  + card("Auto minor upgrade off"; $s.auto_minor_off; (if $s.auto_minor_off > 0 then "warn" else "ok" end); "incl. mixed clusters")
  + card("Pending maintenance"; $s.with_pending; (if $s.with_pending > 0 then "warn" else "ok" end); ($s.pending_by_action | to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "none" else . end))
  + card("Version not returned"; $s.deprecated; (if $s.deprecated > 0 then "bad" else "ok" end); "deprecated / not offered")
  + card("Regions"; "\($ro.with_databases) / \($ro.checked)"; (if $ro.error > 0 then "bad" else "" end); "with databases; \($ro.empty) empty, \($ro.error) error(s)") + "</div>"
  + html_accounts($s) + html_regions($r; $s; $ro; $multi)
  + "<div class=\"grid\"><div><h3>Per engine and major version</h3><table><tr><th>Engine</th><th>Major</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>Latest minor</th><th>Support</th></tr>"
  + ([$s.engines[] | . as $e | .majors[] | "<tr><td><a href=\"#\($e.anchor)\">\($e.engine | h)</a></td><td>\(.major | h)</td><td>\(.total)</td><td class=\"ok\">\(.compliant)</td><td class=\"\(if .non_compliant > 0 then "bad" else "" end)\">\(.non_compliant)</td><td>\(.unknown)</td><td class=\"mono\">\(.latest_minor | dash | h)</td><td class=\"\(.support_flag | sfc)\">\(.support_flag | dash | h)\(if .standard_support_end != null then "<div class=\"sub\">standard end \(.standard_support_end)</div>" else "" end)</td></tr>"] | join(""))
  + "</table></div><div><h3>Top \($top_n) most behind</h3><table><tr><th>Behind</th><th>Server / cluster</th><th>Engine</th><th>Current &rarr; latest minor</th><th>Status</th></tr>"
  + (if ($s.top_behind | length) == 0 then "<tr><td colspan=\"5\">none</td></tr>" else ($s.top_behind | map("<tr><td><b>\(.versions_behind)</b></td><td>\(.identifier | h)<div class=\"sub\">\(.account_id | h) &middot; \(.region | h)</div></td><td>\(.engine | h)</td><td class=\"mono\">\(.current_version | h) &rarr; \(.latest_minor_version | dash | h)</td><td><span class=\"st \(.compliance_status | stc)\">\(.compliance_status)</span></td></tr>") | join("")) end)
  + "</table></div></div>"
  + ([$s.engines[] | . as $e
      | "<section id=\"\($e.anchor)\"><h2>\($e.engine | h) <span class=\"muted\">\($e.total) &middot; compliant \($e.compliant) &middot; non-compliant \($e.non_compliant) &middot; unknown \($e.unknown) &middot; \($e.pct_compliant)% &middot; <a href=\"#top\">top</a></span></h2>"
        + "<table class=\"main\"><thead><tr><th>Status</th><th>Behind</th><th>Identifier / members</th><th>Type</th><th>Major</th><th>Current</th><th>Latest minor</th><th>Valid minor targets</th><th>Auto-upgrade default</th><th>Auto minor</th><th>Standard end</th><th>Extended end</th><th>Support</th><th>Pending maint.</th><th>Maint. window</th><th>Account</th>"
        + ($tagcols | map("<th>\(. | h)</th>") | join("")) + "<th>Upgrade command (printed only)</th><th>Note / ARN</th></tr></thead><tbody>"
        + ([$irows[] | select(.engine == $e.engine) | html_row] | join("")) + "</tbody></table></section>"] | join(""))
  + (if ($r.rows | length) == 0 then "<p>No servers matched.</p>" else "" end)
  + (if ($r.errors | length) > 0 then "<h2>Errors</h2><ul>" + ($r.errors | map("<li>\(.profile | h)/\(.region | h): \(.call | h): \(.message | h)</li>") | join("")) + "</ul>" else "" end)
  + html_sources($r)
  + "<script type=\"application/json\" id=\"pc-data\">" + page_data($r) + "</script>"
  + "</main><footer>\($r.meta.script | h) v\($r.meta.version | h) &middot; read-only report: nothing was changed; upgrade commands are printed only (no --apply-immediately: they apply in the next maintenance window)</footer>"
  + "<script>(function(){Array.prototype.forEach.call(document.querySelectorAll('table.main,table.sortable'),function(t){var b=t.tBodies[0],dir={};"
  + "t.tHead.addEventListener('click',function(e){var th=e.target.closest('th');if(!th)return;var i=th.cellIndex;dir[i]=!dir[i];"
  + "var rows=Array.prototype.slice.call(b.rows);rows.sort(function(x,y){var a=x.cells[i],c=y.cells[i];if(!a||!c)return 0;var va=a.getAttribute('data-s'),vb=c.getAttribute('data-s');"
  + "var r=(va!==null&&vb!==null)?parseFloat(va)-parseFloat(vb):a.textContent.localeCompare(c.textContent,undefined,{numeric:true});return dir[i]?r:-r;});rows.forEach(function(r){b.appendChild(r);});});});"
  + "document.addEventListener('click',function(e){var bt=e.target.closest('.cp');if(!bt)return;var txt=bt.previousElementSibling.textContent;"
  + "var done=function(){bt.textContent='Copied';bt.classList.add('ok');setTimeout(function(){bt.textContent='Copy';bt.classList.remove('ok');},1500);};"
  + "var fb=function(){var ta=document.createElement('textarea');ta.value=txt;document.body.appendChild(ta);ta.select();try{document.execCommand('copy');done();}catch(x){}document.body.removeChild(ta);};"
  + "if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(txt).then(done,fb);}else{fb();}});"
  + "})();</script><script>" + ($ARGS.named.pagejs // "") + "</script></body></html>";

if $mode == "rows" then rows elif $mode == "finalize" then finalize elif $mode == "text" then text elif $mode == "csv" then csv
elif $mode == "html" then html elif $mode == "json" then json_out elif $mode == "csv_regions" then csv_regions elif $mode == "alert" then alert
elif $mode == "vkey_cmp" then vcmp($ARGS.named.a; $ARGS.named.b)
elif $mode == "vcmp_e" then vcmp_e($ARGS.named.e; $ARGS.named.a; $ARGS.named.b) elif $mode == "major" then ($ARGS.named.a | derive_major($ARGS.named.e)) else . end
