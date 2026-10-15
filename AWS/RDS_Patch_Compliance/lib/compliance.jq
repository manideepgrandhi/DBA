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
def finalize:
  . as $r
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
def text:
  . as $r | $r.summary as $s
  | ([12, ($r.rows[] | (.current_version, .latest_minor_version) | tostring | length)] | max + 2) as $vw
  | ([20, ($s.engines[].engine | length)] | max + 2) as $ew
  | "RDS PATCH COMPLIANCE REPORT - \($r.meta.generated_utc) (\($r.meta.generated_local))",
    "Accounts : \($r.meta.accounts | map("\(.account) (\(.profile))") | join(", "))   Regions: \($r.meta.regions | join(", "))",
    "Rule     : COMPLIANT when RDS lists at most \($s.max_behind) valid minor upgrade target(s) for the current version (NON-COMPLIANT = \($s.max_behind + 1)+; UNKNOWN = lookup failed or current version not returned)",
    "Source   : ValidUpgradeTarget (IsMajorVersionUpgrade=false) of describe-db-engine-versions --engine-version <current>, per server. Latest minor per major = highest valid target seen (current version when up to date)",
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
    "TOP \($top_n) MOST BEHIND",
    (if ($s.top_behind | length) == 0 then "  none" else
      ($s.top_behind[] | "  " + (.versions_behind | tostring | rpad(3)) + " behind  " + (.identifier | pad(32)) + (.engine | pad($ew)) + (.current_version | pad($vw)) + "-> " + (.latest_minor_version | dash | pad($vw)) + .compliance_status + "  (" + .region + ")") end),
    "",
    ($s.engines[] | . as $e
      | "=== \($e.engine): \($e.total) (compliant \($e.compliant), non-compliant \($e.non_compliant), unknown \($e.unknown)) ===",
        "  " + ("STATUS" | pad(14)) + ("BEHIND" | rpad(6)) + "  " + ("IDENTIFIER" | pad(32)) + ("TYPE" | pad(17)) + ("CURRENT" | pad($vw)) + ("LATEST MINOR" | pad($vw)) + ("AUTO" | pad(7)) + ("PEND" | rpad(4)) + "  " + ("REGION" | pad(15)) + "FLAGS",
        ($r.rows[] | select(.engine == $e.engine)
          | ("  " + (.compliance_status | pad(14)) + (.versions_behind | dash | rpad(6)) + "  " + (.identifier | pad(32)) + (.resource_type | pad(17)) + (.current_version | pad($vw)) + (.latest_minor_version | dash | pad($vw))
            + (.auto_minor_upgrade | pad(7)) + (.pending_actions_count | rpad(4)) + "  " + (.region | pad(15))
            + ([ (if .support_flag != "ok" and (.support_flag | startswith("n/a") | not) then .support_flag else empty end), (if .deprecated_version then "current version not returned (deprecated?)" else empty end)] | join("; ") | dash)),
          (.pending_actions_detail[] | "      pending: " + .text + (if .auto_applied_after_ist then " [auto-apply \(.auto_applied_after_ist)]" else "" end))),
        ""),
    (if ($r.rows | length) == 0 then "No servers matched.", "" else empty end),
    (if ($r.errors | length) > 0 then "ERRORS", ($r.errors[] | "  \(.profile)/\(.region): \(.call): \(.message)"), "" else empty end),
    "Upgrade commands (printed only, never run) are in the CSV / HTML / JSON output.";

# ------------------------------------------------------------------ csv / json
def cols: ["account_id","profile","region","resource_type","identifier","members","engine","major_version","current_version","latest_minor_version",
           "versions_behind","newer_versions","default_auto_upgrade_target","compliance_status","auto_minor_upgrade","standard_support_end","extended_support_end","support_flag",
           "pending_actions_count","pending_actions","deprecated_version","maint_window_utc","maint_window_ist"];
def csv:
  . as $r
  | (cols + ($tagcols | map("tag:" + .)) + ["arn","upgrade_command","note"] | @csv),
    ($r.rows[] | . as $x | ([cols[] | $x[.]] | map(if type == "array" then join(" ") elif . == null then "" else . end))
       + ($tagcols | map($x.tags[.] // "")) + [$x.arn, $x.upgrade_command, $x.note] | @csv);
def json_out: .;
def alert: {summary: .summary, non_compliant: [.rows[] | select(.compliance_status == "NON-COMPLIANT") | {account_id, region, identifier, engine, current_version, latest_minor_version, versions_behind}], errors: .errors};

# ------------------------------------------------------------------ html
def stc: {"COMPLIANT": "ok", "NON-COMPLIANT": "bad", "UNKNOWN": "unk"}[.] // "unk";
def sfc: if startswith("past") then "bad" elif startswith("standard support ends") then "warn" elif . == "ok" then "ok" else "muted" end;
def card($label; $val; $cls; $sub): "<div class=\"card \($cls)\"><div class=\"v\">\($val | h)</div><div class=\"l\">\($label | h)</div><div class=\"s\">\($sub | h)</div></div>";
def html_row:
  . as $x
  | "<tr><td><span class=\"st \(.compliance_status | stc)\">\(.compliance_status)</span></td><td data-s=\"\(.versions_behind // -1)\">\(.versions_behind | dash)</td>"
  + "<td><b>\(.identifier | h)</b>" + (if .members != "" then "<div class=\"sub\">\(.members | h)</div>" else "" end) + "</td>"
  + "<td>\(.resource_type | h)</td><td>\(.major_version | h)</td><td class=\"mono\">\(.current_version | h)</td><td class=\"mono\">\(.latest_minor_version | dash | h)</td>"
  + "<td class=\"mono small\">\(.newer_versions | short_list | h)</td><td class=\"mono small\">\(.default_auto_upgrade_target | dash | h)</td>"
  + "<td class=\"\(if .auto_minor_upgrade == "true" then "ok" elif .auto_minor_upgrade == "unknown" then "muted" else "warn" end)\">\(.auto_minor_upgrade | h)</td>"
  + "<td>\(.standard_support_end | dash | h)</td><td>\(.extended_support_end | dash | h)</td><td class=\"\(.support_flag | sfc)\">\(.support_flag | h)</td>"
  + "<td data-s=\"\(.pending_actions_count)\">" + (if .pending_actions_count == 0 then "<span class=\"muted\">0</span>"
       else "<details class=\"pend\" title=\"\(pend_tip | h)\"><summary><span class=\"badge\">\(.pending_actions_count)</span></summary><ul>"
            + (.pending_actions_detail | map("<li>\(.text | h)" + (if .auto_applied_after_ist then "<div class=\"sub\">auto-apply \(.auto_applied_after_utc | h) = \(.auto_applied_after_ist | h)</div>" else "" end)
                + (if .forced_apply_ist then "<div class=\"sub\">forced \(.forced_apply_utc | h) = \(.forced_apply_ist | h)</div>" else "" end) + "</li>") | join("")) + "</ul></details>" end) + "</td><td class=\"small\">\(.maint_window_utc | dash | h) UTC<br>\(.maint_window_ist | dash | h) IST</td>"
  + "<td>\(.account_id | h)<div class=\"sub\">\(.profile | h) &middot; \(.region | h)</div></td>"
  + ($tagcols | map("<td>\($x.tags[.] // "" | h)</td>") | join(""))
  + "<td class=\"cmd\">" + (if .upgrade_command != "" then "<code>\(.upgrade_command | h)</code><button class=\"cp\">Copy</button>" else "-" end) + "</td>"
  + "<td class=\"small\">\(.note | h)" + (if .deprecated_version then " <span class=\"st bad\">DEPRECATED</span>" else "" end) + "<div class=\"sub mono\">\(.arn | h)</div></td></tr>";
def html:
  . as $r | $r.summary as $s
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
  + ".grid{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}footer{padding:10px 26px 24px;color:#7b8794;font-size:12px}</style></head><body>"
  + "<header id=\"top\"><h1>RDS patch compliance report</h1><p>\($r.meta.generated_utc | h) &middot; \($r.meta.generated_local | h) &middot; accounts \($r.meta.accounts | map("\(.account) (\(.profile))") | join(", ") | h) &middot; regions \($r.meta.regions | join(", ") | h)</p></header><main>"
  + "<p class=\"muted\">Rule: <b>COMPLIANT</b> = at most \($s.max_behind) valid minor upgrade target(s) for the current version; <b>NON-COMPLIANT</b> = \($s.max_behind + 1) or more; <b>UNKNOWN</b> = lookup failed or current version not returned (deprecated). Counted are only the <b>valid minor upgrade targets</b> RDS returns for the server's current version (describe-db-engine-versions --engine-version &lt;current&gt;, ValidUpgradeTarget with IsMajorVersionUpgrade=false). Latest minor per major = highest valid target seen (or the current version when up to date).<br><b>Pending maint.</b> = maintenance actions AWS has scheduled or offered for this server that haven't been applied yet (cluster rows include their member instances' actions); click the badge to expand, hover for IST dates.</p>"
  + "<div class=\"cards\">" + card("Servers / clusters"; $s.total; ""; "\($r.meta.accounts | length) account(s), \($r.meta.regions | length) region(s)")
  + card("Compliant"; $s.compliant; "ok"; "\($s.pct_compliant)% of all") + card("Non-compliant"; $s.non_compliant; (if $s.non_compliant > 0 then "bad" else "ok" end); "> \($s.max_behind) behind")
  + card("Unknown"; $s.unknown; "unk"; "lookup failed / version not returned")
  + card("Extended Support"; $s.past_standard_support; (if $s.past_standard_support > 0 then "bad" else "ok" end); "past standard support")
  + card("Support ending"; $s.nearing_end_of_support; (if $s.nearing_end_of_support > 0 then "warn" else "ok" end); "within \($s.warn_days) days")
  + card("Auto minor upgrade off"; $s.auto_minor_off; (if $s.auto_minor_off > 0 then "warn" else "ok" end); "incl. mixed clusters")
  + card("Pending maintenance"; $s.with_pending; (if $s.with_pending > 0 then "warn" else "ok" end); ($s.pending_by_action | to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "none" else . end))
  + card("Version not returned"; $s.deprecated; (if $s.deprecated > 0 then "bad" else "ok" end); "deprecated / not offered") + "</div>"
  + "<div class=\"grid\"><div><h3>Per engine and major version</h3><table><tr><th>Engine</th><th>Major</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>Latest minor</th><th>Support</th></tr>"
  + ([$s.engines[] | . as $e | .majors[] | "<tr><td><a href=\"#\($e.anchor)\">\($e.engine | h)</a></td><td>\(.major | h)</td><td>\(.total)</td><td class=\"ok\">\(.compliant)</td><td class=\"\(if .non_compliant > 0 then "bad" else "" end)\">\(.non_compliant)</td><td>\(.unknown)</td><td class=\"mono\">\(.latest_minor | dash | h)</td><td class=\"\(.support_flag | sfc)\">\(.support_flag | dash | h)\(if .standard_support_end != null then "<div class=\"sub\">standard end \(.standard_support_end)</div>" else "" end)</td></tr>"] | join(""))
  + "</table></div><div><h3>Top \($top_n) most behind</h3><table><tr><th>Behind</th><th>Server / cluster</th><th>Engine</th><th>Current &rarr; latest minor</th><th>Status</th></tr>"
  + (if ($s.top_behind | length) == 0 then "<tr><td colspan=\"5\">none</td></tr>" else ($s.top_behind | map("<tr><td><b>\(.versions_behind)</b></td><td>\(.identifier | h)<div class=\"sub\">\(.region | h)</div></td><td>\(.engine | h)</td><td class=\"mono\">\(.current_version | h) &rarr; \(.latest_minor_version | dash | h)</td><td><span class=\"st \(.compliance_status | stc)\">\(.compliance_status)</span></td></tr>") | join("")) end)
  + "</table></div></div>"
  + "<input id=\"q\" type=\"search\" placeholder=\"Filter rows (any text: name, version, status, tag...)\">"
  + ([$s.engines[] | . as $e
      | "<section id=\"\($e.anchor)\"><h2>\($e.engine | h) <span class=\"muted\">\($e.total) &middot; compliant \($e.compliant) &middot; non-compliant \($e.non_compliant) &middot; unknown \($e.unknown) &middot; \($e.pct_compliant)% &middot; <a href=\"#top\">top</a></span></h2>"
        + "<table class=\"main\"><thead><tr><th>Status</th><th>Behind</th><th>Identifier / members</th><th>Type</th><th>Major</th><th>Current</th><th>Latest minor</th><th>Valid minor targets</th><th>Auto-upgrade default</th><th>Auto minor</th><th>Standard end</th><th>Extended end</th><th>Support</th><th>Pending maint.</th><th>Maint. window</th><th>Account</th>"
        + ($tagcols | map("<th>\(. | h)</th>") | join("")) + "<th>Upgrade command (printed only)</th><th>Note / ARN</th></tr></thead><tbody>"
        + ([$r.rows[] | select(.engine == $e.engine) | html_row] | join("")) + "</tbody></table></section>"] | join(""))
  + (if ($r.rows | length) == 0 then "<p>No servers matched.</p>" else "" end)
  + (if ($r.errors | length) > 0 then "<h2>Errors</h2><ul>" + ($r.errors | map("<li>\(.profile | h)/\(.region | h): \(.call | h): \(.message | h)</li>") | join("")) + "</ul>" else "" end)
  + "</main><footer>\($r.meta.script | h) v\($r.meta.version | h) &middot; read-only report: nothing was changed; upgrade commands are printed only (no --apply-immediately: they apply in the next maintenance window)</footer>"
  + "<script>(function(){Array.prototype.forEach.call(document.querySelectorAll('table.main'),function(t){var b=t.tBodies[0],dir={};"
  + "t.tHead.addEventListener('click',function(e){var th=e.target.closest('th');if(!th)return;var i=th.cellIndex;dir[i]=!dir[i];"
  + "var rows=Array.prototype.slice.call(b.rows);rows.sort(function(x,y){var a=x.cells[i],c=y.cells[i];if(!a||!c)return 0;var va=a.getAttribute('data-s'),vb=c.getAttribute('data-s');"
  + "var r=(va!==null&&vb!==null)?parseFloat(va)-parseFloat(vb):a.textContent.localeCompare(c.textContent,undefined,{numeric:true});return dir[i]?r:-r;});rows.forEach(function(r){b.appendChild(r);});});});"
  + "document.addEventListener('click',function(e){var bt=e.target.closest('.cp');if(!bt)return;var txt=bt.previousElementSibling.textContent;"
  + "var done=function(){bt.textContent='Copied';bt.classList.add('ok');setTimeout(function(){bt.textContent='Copy';bt.classList.remove('ok');},1500);};"
  + "var fb=function(){var ta=document.createElement('textarea');ta.value=txt;document.body.appendChild(ta);ta.select();try{document.execCommand('copy');done();}catch(x){}document.body.removeChild(ta);};"
  + "if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(txt).then(done,fb);}else{fb();}});"
  + "document.getElementById('q').addEventListener('input',function(){var q=this.value.toLowerCase();Array.prototype.forEach.call(document.querySelectorAll('table.main tbody tr'),function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>=0?'':'none';});});})();</script></body></html>";

if $mode == "rows" then rows elif $mode == "finalize" then finalize elif $mode == "text" then text elif $mode == "csv" then csv
elif $mode == "html" then html elif $mode == "json" then json_out elif $mode == "alert" then alert
elif $mode == "vkey_cmp" then vcmp($ARGS.named.a; $ARGS.named.b)
elif $mode == "vcmp_e" then vcmp_e($ARGS.named.e; $ARGS.named.a; $ARGS.named.b) elif $mode == "major" then ($ARGS.named.a | derive_major($ARGS.named.e)) else . end
