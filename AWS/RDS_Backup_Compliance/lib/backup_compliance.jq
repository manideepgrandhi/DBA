# backup_compliance.jq - rules and rendering for rds_backup_compliance_report.sh (read-only report).
# Called as: jq --arg mode M --argjson now EPOCH --argjson cfg {...} -f backup_compliance.jq
#   rows      : -n with --slurpfile inst clus sa_i sa_c sm_i sm_c rp + --arg account/profile/region
#               + --argjson ok {rds,snap_auto,snap_manual,backup}
#   finalize  : raw report  -> report with .summary
#   text|csv|csv_manual|csv_summary|html|json : report -> rendered
# Times: AWS timestamps are parsed with any offset; dates / months are UTC.

def ts:
  if . == null or . == "" then null
  else ([capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")?] | .[0]) as $c
    | if $c == null then null
      else (($c.d + "T" + $c.t + "Z") | fromdateiso8601)
           - (if ($c.z // "Z") == "Z" then 0
              else ($c.z | gsub("[^0-9]"; "")) as $n
                   | (($n[0:2] | tonumber) * 3600 + ($n[2:4] | tonumber) * 60) * (if ($c.z | startswith("-")) then -1 else 1 end)
              end)
      end
  end;
def day(e): (e | floor | strftime("%Y-%m-%d"));
def iso(e): if e == null then null else (e | floor | strftime("%Y-%m-%d %H:%M UTC")) end;
def mnum(e): (e | floor | gmtime) as $g | ($g[0] * 12 + $g[1]);
def mkey(n): "\(n / 12 | floor)-" + (((n % 12) + 1) | tostring | if length == 1 then "0" + . else . end);
def glob2re: "^" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
def globmatch($globs): . as $s | ($globs | length) == 0 or any($globs[]; . as $g | ($s | ascii_downcase) | test($g | ascii_downcase | glob2re));
def r1: (. * 10 | round) / 10;
def r2: (. * 100 | round) / 100;
def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;");
def tagsobj: (. // []) | map({key: .Key, value: .Value}) | from_entries;
def nz: if . == null then "" else . end;

# ------------------------------------------------------------------ rows (one region)
def classify:
  . as $p
  | ($p.CreationDate | ts) as $c
  | ($p.CalculatedLifecycle.DeleteAt | ts) as $del
  | (if ($p.Lifecycle.DeleteAfterDays // null) != null then $p.Lifecycle.DeleteAfterDays
     elif $del != null and $c != null then (($del - $c) / 86400 | round) else null end) as $ret
  | ($p.CreatedBy.BackupRuleName // "") as $rule
  | (if $ret != null and $ret >= $cfg.weekly_min_days and $ret <= $cfg.weekly_max_days then {cls: "weekly", by: "retention"}
     elif $ret != null and $ret >= $cfg.monthly_min_days and $ret <= $cfg.monthly_max_days then {cls: "monthly", by: "retention"}
     elif $cfg.rule_name_fallback and $rule != "" and ($rule | test($cfg.weekly_rule_regex)) then {cls: "weekly", by: "rule_name"}
     elif $cfg.rule_name_fallback and $rule != "" and ($rule | test($cfg.monthly_rule_regex)) then {cls: "monthly", by: "rule_name"}
     else {cls: "other", by: null} end) as $k
  | {arn: $p.ResourceArn, created: $c, delete_at: $del, retention_days: $ret, status: ($p.Status // ""),
     vault: ($p.BackupVaultName // ""), rule: $rule, cls: $k.cls, by: $k.by};

def daily_check($retention; $snaps; $bwin):
  ($bwin // "" | capture("^(?<h>[0-9]{2}):(?<m>[0-9]{2})")? // null) as $bw
  | [$snaps[] | select((.Status // "") == "available" or (.Status // "") == "creating") | (.SnapshotCreateTime | ts) | select(. != null)] as $times
  | [range(0; $cfg.daily_days) as $k
      | ($now - ($k + 1) * 86400) as $s | ($now - $k * 86400) as $e
      | (if $bw == null then $s
         else (((day($s) + "T" + $bw.h + ":" + $bw.m + ":00Z") | fromdateiso8601) as $x | if $x < $s then $x + 86400 else $x end) end) as $exp
      | {label: day($exp), start: $s, end: $e, found: ([$times[] | select(. >= $s and . < $e)] | length)}] as $win
  | ([$win[] | select(.found == 0) | .label] | reverse) as $missing
  | {retention: $retention, required_days: $cfg.daily_days, snapshots: ($times | length),
     days_ok: ([$win[] | select(.found > 0)] | length),
     missing_dates: $missing, newest: iso($times | max), oldest: iso($times | min),
     status: (if $retention >= $cfg.min_retention and ($missing | length) == 0 then "PASS" else "FAIL" end),
     failures: ([if $retention < $cfg.min_retention then {code: "DAILY_RETENTION", detail: ("BackupRetentionPeriod \($retention) < \($cfg.min_retention)" + (if $retention == 0 then " (automated backups OFF)" else "" end))} else empty end]
               + [if ($missing | length) > 0 then {code: "DAILY_MISSING", detail: "no automated snapshot for \($missing | join(", "))"} else empty end])};

def weekly_check($pts):
  [$pts[] | select(.cls == "weekly")] as $all
  | [$all[] | select(.status == "COMPLETED")] as $done
  | [$done[] | select(.created > $now - $cfg.weekly_window_days * 86400)] as $win
  | [range(0; $cfg.weekly_required) as $k | ($now - ($k + 1) * 604800) as $s | ($now - $k * 604800) as $e
      | {label: "\(day($s))..\(day($e))", n: ([$win[] | select(.created >= $s and .created < $e)] | length)}] as $weeks
  | ([$weeks[] | select(.n == 0) | .label] | reverse) as $gaps
  | ($win | length) as $n
  | {count: $n, required: $cfg.weekly_required, window_days: $cfg.weekly_window_days,
     newest: iso([$done[].created] | max), oldest: iso([$done[].created] | min),
     vaults: ([$all[].vault] | unique), gaps: $gaps, by_rule_name: ([$all[] | select(.by == "rule_name")] | length),
     not_completed: ([$all[] | select(.status != "COMPLETED" and .created > $now - $cfg.weekly_window_days * 86400)] | length),
     borderline: ($n == $cfg.weekly_required and ($gaps | length) == 0),
     next_expiry: iso([$win[].delete_at | select(. != null)] | min),
     status: (if $n >= $cfg.weekly_required and ($gaps | length) == 0 then "PASS" else "FAIL" end),
     failures: ([if $n < $cfg.weekly_required then {code: "WEEKLY_COUNT", detail: "\($n) weekly recovery point(s) in \($cfg.weekly_window_days)d < \($cfg.weekly_required)"} else empty end]
               + [if ($gaps | length) > 0 then {code: "WEEKLY_GAP", detail: "no weekly point in \($gaps | join(", "))"} else empty end])};

def monthly_check($pts):
  [$pts[] | select(.cls == "monthly")] as $all
  | [$all[] | select(.status == "COMPLETED")] as $done
  | mnum($now) as $cur
  | [range(0; $cfg.monthly_required) | $cur - .] as $months
  | [$done[] | select(mnum(.created) >= ($cur - $cfg.monthly_required + 1))] as $win
  | ([$win[] | mnum(.created)] | unique) as $have
  | (($now | gmtime)[2] <= $cfg.monthly_grace_days and ($have | index($cur)) == null) as $pending
  | [$months[] | select(. as $m | ($have | index($m)) == null) | select(. != $cur or ($pending | not)) | mkey(.)] as $gaps
  | ($win | length) as $n
  | ($cfg.monthly_required - (if $pending then 1 else 0 end)) as $need
  | {count: $n, required: $cfg.monthly_required, months_covered: ($have | length), current_month_pending: $pending,
     newest: iso([$done[].created] | max), oldest: iso([$done[].created] | min),
     vaults: ([$all[].vault] | unique), gaps: ($gaps | reverse), by_rule_name: ([$all[] | select(.by == "rule_name")] | length),
     status: (if $n >= $need and ($gaps | length) == 0 then "PASS" else "FAIL" end),
     failures: ([if $n < $need then {code: "MONTHLY_COUNT", detail: "\($n) monthly recovery point(s) in last \($cfg.monthly_required) months < \($need)"} else empty end]
               + [if ($gaps | length) > 0 then {code: "MONTHLY_GAP", detail: "no monthly point in \($gaps | reverse | join(", "))"} else empty end])};

def unknown_check($why): {status: "UNKNOWN", failures: [], note: $why};

def server_row($kind; $x; $snaps; $pts; $members):
  (if $kind == "cluster" then $x.DBClusterIdentifier else $x.DBInstanceIdentifier end) as $id
  | (if (if $kind == "cluster" then $ARGS.named.ok.snap_auto_c else $ARGS.named.ok.snap_auto_i end) then daily_check($x.BackupRetentionPeriod // 0; $snaps; $x.PreferredBackupWindow)
     else unknown_check("automated snapshot listing failed") + {retention: ($x.BackupRetentionPeriod // 0)} end) as $d
  | (if $ARGS.named.ok.backup then weekly_check($pts) else unknown_check("AWS Backup listing failed") end) as $w
  | (if $ARGS.named.ok.backup then monthly_check($pts) else unknown_check("AWS Backup listing failed") end) as $m
  | ($ARGS.named.ok.backup and ($pts | length) == 0) as $nobk
  | ([$d.failures[], $w.failures[], $m.failures[]] + (if $nobk then [{code: "NO_AWS_BACKUP", detail: "no AWS Backup recovery points in a same-region vault"}] else [] end)) as $f
  | {account: $ARGS.named.account, profile: $ARGS.named.profile, region: $ARGS.named.region, kind: $kind,
     type: (if $kind == "instance" then "RDS instance" elif ($x.Engine | startswith("aurora")) then "Aurora cluster" else "Multi-AZ DB cluster" end),
     engine: $x.Engine, engine_version: ($x.EngineVersion // ""), identifier: $id,
     arn: (if $kind == "cluster" then $x.DBClusterArn else $x.DBInstanceArn end), members: $members,
     db_status: (($x.Status // $x.DBInstanceStatus) // ""), backup_window: ($x.PreferredBackupWindow // ""),
     tags: (($x.TagList // []) | tagsobj),
     daily: $d, weekly: $w, monthly: $m, aws_backup_points: ($pts | length), no_aws_backup: $nobk,
     failures: $f,
     compliance_status: (if ([$d.status, $w.status, $m.status] | all(. == "PASS")) then "COMPLIANT"
                         elif ([$d.status, $w.status, $m.status] | any(. == "FAIL")) then "NON-COMPLIANT" else "UNKNOWN" end)};

def rows:
  ($ARGS.named.inst[0] // []) as $I | ($ARGS.named.clus[0] // []) as $C
  | ([$ARGS.named.rp[0][]? | classify] | group_by(.arn) | map({key: .[0].arn, value: .}) | from_entries) as $P
  | ($ARGS.named.sa_i[0] // [] | group_by(.DBInstanceIdentifier) | map({key: .[0].DBInstanceIdentifier, value: .}) | from_entries) as $SI
  | ($ARGS.named.sa_c[0] // [] | group_by(.DBClusterIdentifier) | map({key: .[0].DBClusterIdentifier, value: .}) | from_entries) as $SC
  | ([$C[] | select((.Engine // "") | test("^(docdb|neptune)$") | not)]) as $C2
  | ([$C2[] | select(.Engine | globmatch($cfg.engines))
       | . as $c | [($c.DBClusterMembers // [])[] | .DBInstanceIdentifier] as $mem
       | select(([$c.DBClusterIdentifier] + $mem) | any(globmatch($cfg.identifiers)))
       | server_row("cluster"; $c; ($SC[$c.DBClusterIdentifier] // []); ($P[$c.DBClusterArn] // []); $mem)]) as $crows
  | ([$I[] | select((.DBClusterIdentifier // "") == "")
       | select(.Engine | test("^(docdb|neptune)$") | not)
       | select(.Engine | globmatch($cfg.engines)) | select(.DBInstanceIdentifier | globmatch($cfg.identifiers))
       | . as $i
       | (((.ReadReplicaSourceDBInstanceIdentifier // "") != "") or ((.ReadReplicaSourceDBClusterIdentifier // "") != "")) as $rep
       | if $rep and ($cfg.include_replicas | not) then {skipped_replica: .DBInstanceIdentifier}
         else server_row("instance"; $i; ($SI[$i.DBInstanceIdentifier] // []); ($P[$i.DBInstanceArn] // []); []) + {read_replica: $rep} end]) as $irows
  | ([$I[].DBInstanceIdentifier]) as $iids | ([$C[].DBClusterIdentifier]) as $cids
  | def manual($kind; $s):
      ($s | if $kind == "cluster" then {id: .DBClusterSnapshotIdentifier, src: .DBClusterIdentifier} else {id: .DBSnapshotIdentifier, src: .DBInstanceIdentifier} end) as $n
      | ($s.SnapshotCreateTime | ts) as $c
      | select($c != null and ($n.id | startswith("awsbackup:") | not) and (($s.SnapshotType // "manual") == "manual"))
      | select(($s.Engine // "") | globmatch($cfg.engines)) | select($n.src | globmatch($cfg.identifiers))
      | (($now - $c) / 86400 | floor) as $age
      | select($age > $cfg.max_manual_age)
      | ($s.AllocatedStorage // 0) as $gb
      | {account: $ARGS.named.account, profile: $ARGS.named.profile, region: $ARGS.named.region, kind: $kind, snapshot: $n.id, source: $n.src,
         engine: ($s.Engine // ""), created: iso($c), age_days: $age, size_gb: $gb, status: ($s.Status // ""),
         est_monthly_usd: ($gb * $cfg.price_per_gb_month | r2),
         orphan: (if $kind == "cluster" then ($cids | index($n.src)) == null else ($iids | index($n.src)) == null end),
         delete_command: ("aws rds " + (if $kind == "cluster" then "delete-db-cluster-snapshot --db-cluster-snapshot-identifier " else "delete-db-snapshot --db-snapshot-identifier " end)
                          + ($n.id | @sh) + " --region " + $ARGS.named.region + (if $ARGS.named.profile != "default" then " --profile " + ($ARGS.named.profile | @sh) else "" end))};
    {servers: ([$crows[], $irows[]] | map(select(has("identifier"))) | sort_by(.identifier)),
     skipped_replicas: ([$irows[] | select(has("skipped_replica")) | .skipped_replica]),
     manual: (if $ARGS.named.ok.snap_manual then ([($ARGS.named.sm_c[0] // [])[] | manual("cluster"; .)] + [($ARGS.named.sm_i[0] // [])[] | manual("instance"; .)]) | sort_by(-.age_days, .snapshot) else [] end)};

# ------------------------------------------------------------------ finalize
def pct($a; $b): if $b == 0 then 0 else ($a * 1000 / $b | round) / 10 end;
def counts: {total: length, compliant: (map(select(.compliance_status == "COMPLIANT")) | length),
             non_compliant: (map(select(.compliance_status == "NON-COMPLIANT")) | length),
             unknown: (map(select(.compliance_status == "UNKNOWN")) | length)}
            | . + {pct_compliant: pct(.compliant; .total)};
def finalize:
  . as $r | ($r.servers) as $S | ($r.manual) as $M
  | $r + {summary: (($S | counts) + {
      daily_pass: ($S | map(select(.daily.status == "PASS")) | length),
      weekly_pass: ($S | map(select(.weekly.status == "PASS")) | length),
      monthly_pass: ($S | map(select(.monthly.status == "PASS")) | length),
      weekly_borderline: ($S | map(select(.weekly.borderline == true)) | length),
      no_aws_backup: ($S | map(select(.no_aws_backup)) | length),
      skipped_replicas: ($r.skipped_replicas | length),
      errors: ($r.errors | length),
      by_engine: ($S | group_by(.engine) | map({engine: .[0].engine} + counts)),
      by_account: ($S | group_by(.account) | map({account: .[0].account, profile: .[0].profile} + counts)),
      top_failures: ([$S[] | . as $s | [.failures[].code] | unique[] | {code: ., id: $s.identifier}] | group_by(.code)
                     | map({code: .[0].code, servers: length, examples: ([.[].id] | .[0:5])}) | sort_by(-.servers, .code) | .[0:$cfg.top_n]),
      manual: {count: ($M | length), total_gb: ([$M[].size_gb] | add // 0), est_monthly_usd: ([$M[].est_monthly_usd] | add // 0 | r2),
               orphans: ($M | map(select(.orphan)) | length), orphan_gb: ([$M[] | select(.orphan) | .size_gb] | add // 0),
               oldest_days: ([$M[].age_days] | max // 0)}})}
  | .servers |= (sort_by((if .compliance_status == "NON-COMPLIANT" then 0 elif .compliance_status == "UNKNOWN" then 1 else 2 end), .account, .region, .identifier)
                 | if $cfg.nc_only then map(select(.compliance_status != "COMPLIANT")) else . end);

# ------------------------------------------------------------------ rendering
def rule_text:
  "Daily  : RDS automated backups - BackupRetentionPeriod >= \($cfg.min_retention) AND an automated snapshot in each of the last \($cfg.daily_days) x 24h (labelled by UTC date)",
  "Weekly : AWS Backup points with \($cfg.weekly_min_days)-\($cfg.weekly_max_days)d retention - >= \($cfg.weekly_required) COMPLETED in last \($cfg.weekly_window_days)d, one per 7-day week",
  "Monthly: AWS Backup points with \($cfg.monthly_min_days)-\($cfg.monthly_max_days)d retention - >= \($cfg.monthly_required) COMPLETED, one per calendar month (UTC) over the last \($cfg.monthly_required) months" + (if $cfg.monthly_grace_days > 0 then " (current month may be pending until day \($cfg.monthly_grace_days))" else "" end),
  (if $cfg.rule_name_fallback then "Fallback: points whose retention matches neither class are classified by backup rule name (/\($cfg.weekly_rule_regex)/, /\($cfg.monthly_rule_regex)/)" else empty end),
  "COMPLIANT only if daily + weekly + monthly all PASS. Aurora / Multi-AZ clusters are judged per cluster (members not separate).";
def borderline_note: "Note: weekly points keep ~30 days, so a server with exactly \($cfg.weekly_required) in the window is BORDERLINE - the oldest expires soon and, depending on schedule timing, a 5th week's point may be needed to stay at \($cfg.weekly_required). Points are counted only inside the \($cfg.weekly_window_days)-day window.";
def chk(c): if c.status == "PASS" then "ok" elif c.status == "FAIL" then "FAIL" else "?" end;
def pad($n): tostring | if length >= $n then . else . + (" " * ($n - length)) end;

def text:
  .meta as $m | .summary as $s
  | "RDS BACKUP COMPLIANCE REPORT  (\($m.script) v\($m.version), read-only)",
    "Generated: \($m.generated_local) | \($m.generated_utc)",
    "Accounts : \([$m.accounts[] | "\(.account) (\(.profile))"] | join(", "))",
    "Regions  : \($m.regions | join(", "))" + (if $m.filters_text != "" then "   Filters: \($m.filters_text)" else "" end),
    "",
    "== SUMMARY",
    "OVERALL  : \($s.total) servers/clusters | COMPLIANT \($s.compliant) | NON-COMPLIANT \($s.non_compliant) | UNKNOWN \($s.unknown) | \($s.pct_compliant)% compliant",
    "Checks   : daily PASS \($s.daily_pass)/\($s.total) | weekly PASS \($s.weekly_pass)/\($s.total) (borderline \($s.weekly_borderline)) | monthly PASS \($s.monthly_pass)/\($s.total) | no AWS Backup coverage: \($s.no_aws_backup)",
    (if $s.skipped_replicas > 0 then "Skipped  : \($s.skipped_replicas) read replica(s) (use --include-replicas)" else empty end),
    "",
    "By engine:",
    ($s.by_engine[] | "  \(.engine | pad(20)) total \(.total | pad(4)) compliant \(.compliant | pad(4)) non-compliant \(.non_compliant | pad(4)) unknown \(.unknown | pad(3)) \(.pct_compliant)%"),
    "By account:",
    ($s.by_account[] | "  \("\(.account) (\(.profile))" | pad(28)) total \(.total | pad(4)) compliant \(.compliant | pad(4)) non-compliant \(.non_compliant | pad(4)) unknown \(.unknown | pad(3)) \(.pct_compliant)%"),
    "Top failures:",
    (if ($s.top_failures | length) == 0 then "  none" else ($s.top_failures[] | "  \(.code | pad(16)) \(.servers | pad(4)) server(s)  e.g. \(.examples | join(", "))") end),
    "Old manual snapshots (> \($cfg.max_manual_age)d): \($s.manual.count) | \($s.manual.total_gb) GB | ~$\($s.manual.est_monthly_usd)/month (approximate, $\($cfg.price_per_gb_month)/GB-month) | orphaned \($s.manual.orphans) (\($s.manual.orphan_gb) GB) | oldest \($s.manual.oldest_days)d",
    (if $s.errors > 0 then "ERRORS   : \($s.errors) AWS call(s) failed - affected checks are UNKNOWN (see end)" else empty end),
    "",
    "== RULES", (rule_text | "  " + .), "  " + borderline_note,
    "",
    "== SERVERS (\(.servers | length))  status | daily | weekly | monthly",
    (.servers[] |
      "\(if .compliance_status == "COMPLIANT" then "  " elif .compliance_status == "NON-COMPLIANT" then "!!" else "??" end) \(.compliance_status | pad(13)) \(.account)/\(.region) \(.type): \(.identifier) [\(.engine) \(.engine_version)]",
      "     daily   \(chk(.daily) | pad(4)) retention \(.daily.retention)d, \(.daily.days_ok // 0)/\(.daily.required_days // $cfg.daily_days) days, newest \(.daily.newest // "-"), oldest \(.daily.oldest // "-")" + (if (.daily.missing_dates // []) | length > 0 then ", MISSING \(.daily.missing_dates | join(","))" else "" end) + (if .daily.note then " (\(.daily.note))" else "" end),
      "     weekly  \(chk(.weekly) | pad(4)) " + (if .weekly.status == "UNKNOWN" then .weekly.note else "\(.weekly.count) in \(.weekly.window_days)d (need >= \(.weekly.required)), newest \(.weekly.newest // "-"), oldest \(.weekly.oldest // "-"), vault \(.weekly.vaults | join(",") | if . == "" then "-" else . end)" + (if (.weekly.gaps | length) > 0 then ", GAPS \(.weekly.gaps | join(","))" else "" end) + (if .weekly.borderline then ", BORDERLINE (next expiry \(.weekly.next_expiry // "-"))" else "" end) end),
      "     monthly \(chk(.monthly) | pad(4)) " + (if .monthly.status == "UNKNOWN" then .monthly.note else "\(.monthly.count) (need >= \(.monthly.required)), \(.monthly.months_covered)/\(.monthly.required) month(s), newest \(.monthly.newest // "-"), oldest \(.monthly.oldest // "-"), vault \(.monthly.vaults | join(",") | if . == "" then "-" else . end)" + (if (.monthly.gaps | length) > 0 then ", GAPS \(.monthly.gaps | join(","))" else "" end) + (if .monthly.current_month_pending then ", current month pending" else "" end) end),
      (if .no_aws_backup then "     !! NO AWS Backup coverage" else empty end)),
    "",
    "== OLD MANUAL SNAPSHOTS (> \($cfg.max_manual_age) days; delete commands are PRINTED ONLY, never run)",
    (if (.manual | length) == 0 then "  none"
     else (.manual[] | "  \(.account)/\(.region) \(.kind) \(.snapshot) <- \(.source)\(if .orphan then " [ORPHAN: source deleted]" else "" end) | \(.engine) | \(.age_days)d | \(.size_gb) GB | ~$\(.est_monthly_usd)/mo",
                       "      \(.delete_command)") end),
    (if (.errors | length) > 0 then "", "== ERRORS", (.errors[] | "  \(.profile)/\(.region) \(.call): \(.message)") else empty end);

def csvq: map(if . == null then "" elif type == "array" then join("; ") elif type == "number" then . else tostring end) | @csv;
def csv:
  (["account","profile","region","type","engine","engine_version","identifier","members","compliance_status","failures",
   "daily_status","backup_retention_days","daily_days_ok","daily_missing_dates","daily_newest","daily_oldest",
   "weekly_status","weekly_count","weekly_required","weekly_borderline","weekly_gaps","weekly_newest","weekly_oldest","weekly_vaults",
   "monthly_status","monthly_count","monthly_required","monthly_gaps","monthly_newest","monthly_oldest","monthly_vaults",
   "aws_backup_points","no_aws_backup"] + ($cfg.tagcols | map("tag:" + .)) | csvq),
  (.servers[] | . as $r | [.account, .profile, .region, .type, .engine, .engine_version, .identifier, .members, .compliance_status, [.failures[].detail],
    .daily.status, .daily.retention, .daily.days_ok, .daily.missing_dates, .daily.newest, .daily.oldest,
    .weekly.status, .weekly.count, .weekly.required, .weekly.borderline, .weekly.gaps, .weekly.newest, .weekly.oldest, .weekly.vaults,
    .monthly.status, .monthly.count, .monthly.required, .monthly.gaps, .monthly.newest, .monthly.oldest, .monthly.vaults,
    .aws_backup_points, .no_aws_backup] + ($cfg.tagcols | map($r.tags[.])) | csvq);
def csv_manual:
  (["account","profile","region","kind","snapshot","source","orphan","engine","created","age_days","size_gb","est_monthly_usd_approx","delete_command_print_only"] | csvq),
  (.manual[] | [.account, .profile, .region, .kind, .snapshot, .source, .orphan, .engine, .created, .age_days, .size_gb, .est_monthly_usd, .delete_command] | csvq);
def csv_summary:
  .summary as $s | .meta as $m
  | (["section","key","total","compliant","non_compliant","unknown","pct_compliant","extra"] | csvq),
  (["generated","\($m.generated_local) | \($m.generated_utc)","","","","","",""] | csvq),
  (["overall","all",$s.total,$s.compliant,$s.non_compliant,$s.unknown,$s.pct_compliant,"no_aws_backup=\($s.no_aws_backup); weekly_borderline=\($s.weekly_borderline)"] | csvq),
  ($s.by_engine[] | ["engine",.engine,.total,.compliant,.non_compliant,.unknown,.pct_compliant,""] | csvq),
  ($s.by_account[] | ["account","\(.account) (\(.profile))",.total,.compliant,.non_compliant,.unknown,.pct_compliant,""] | csvq),
  ($s.top_failures[] | ["failure",.code,.servers,"","","","",(.examples | join(" "))] | csvq),
  (["manual_snapshots","older_than_\($cfg.max_manual_age)d",$s.manual.count,"","","","","total_gb=\($s.manual.total_gb); est_monthly_usd_approx=\($s.manual.est_monthly_usd); orphans=\($s.manual.orphans)"] | csvq);

def badge(st): if st == "PASS" or st == "COMPLIANT" then "<span class=ok>\(st)</span>" elif st == "FAIL" or st == "NON-COMPLIANT" then "<span class=bad>\(st)</span>" else "<span class=unk>\(st)</span>" end;
def html:
  .meta as $m | .summary as $s
  | "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>RDS backup compliance</title><style>"
  + "body{font:14px/1.45 system-ui,sans-serif;margin:20px;color:#1d2433;background:#f6f7f9}h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:22px 0 8px}"
  + ".meta{color:#5b6475}.cards{display:flex;gap:10px;flex-wrap:wrap;margin:12px 0}.card{background:#fff;border:1px solid #dde1e7;border-radius:8px;padding:10px 14px;min-width:120px}"
  + ".card b{display:block;font-size:22px}.card.g b{color:#137333}.card.r b{color:#c5221f}.card.y b{color:#b06000}"
  + "table{border-collapse:collapse;background:#fff;width:100%;margin-bottom:8px}th,td{border:1px solid #dde1e7;padding:5px 7px;text-align:left;vertical-align:top}th{background:#eef1f5}"
  + ".ok{color:#137333;font-weight:600}.bad{color:#c5221f;font-weight:600}.unk{color:#b06000;font-weight:600}tr.nc{background:#fff4f4}small{color:#5b6475}code{font-size:12px;word-break:break-all}.note{background:#fff8e1;border:1px solid #f0d58a;padding:8px;border-radius:6px}"
  + "</style></head><body>"
  + "<h1>RDS backup compliance</h1><div class=meta>Generated \($m.generated_local | esc) &middot; \($m.generated_utc | esc) &middot; accounts \([$m.accounts[] | "\(.account) (\(.profile))"] | join(", ") | esc) &middot; regions \($m.regions | join(", ") | esc) &middot; read-only</div>"
  + "<div class=cards><div class=card>Servers/clusters<b>\($s.total)</b></div><div class=\"card g\">Compliant<b>\($s.compliant)</b></div><div class=\"card r\">Non-compliant<b>\($s.non_compliant)</b></div><div class=\"card y\">Unknown<b>\($s.unknown)</b></div><div class=card>% compliant<b>\($s.pct_compliant)%</b></div>"
  + "<div class=\"card r\">No AWS Backup<b>\($s.no_aws_backup)</b></div><div class=\"card y\">Weekly borderline<b>\($s.weekly_borderline)</b></div><div class=card>Old manual snapshots<b>\($s.manual.count)</b><small>\($s.manual.total_gb) GB &middot; ~$\($s.manual.est_monthly_usd)/mo (approx.)</small></div></div>"
  + "<h2>By engine</h2><table><tr><th>Engine<th>Total<th>Compliant<th>Non-compliant<th>Unknown<th>%</tr>"
  + ([$s.by_engine[] | "<tr><td>\(.engine | esc)<td>\(.total)<td>\(.compliant)<td>\(.non_compliant)<td>\(.unknown)<td>\(.pct_compliant)%</tr>"] | join(""))
  + "</table><h2>By account</h2><table><tr><th>Account<th>Total<th>Compliant<th>Non-compliant<th>Unknown<th>%</tr>"
  + ([$s.by_account[] | "<tr><td>\(.account | esc) (\(.profile | esc))<td>\(.total)<td>\(.compliant)<td>\(.non_compliant)<td>\(.unknown)<td>\(.pct_compliant)%</tr>"] | join(""))
  + "</table><h2>Top failures</h2><table><tr><th>Failure<th>Servers<th>Examples</tr>"
  + (if ($s.top_failures | length) == 0 then "<tr><td colspan=3>none</tr>" else ([$s.top_failures[] | "<tr><td>\(.code)<td>\(.servers)<td>\(.examples | join(", ") | esc)</tr>"] | join("")) end)
  + "</table><h2>Rules</h2><div class=note>" + ([rule_text | esc] | join("<br>")) + "<br><b>" + (borderline_note | esc) + "</b></div>"
  + "<h2>Servers</h2><table><tr><th>Status<th>Account / region<th>Server<th>Daily (automated)<th>Weekly (AWS Backup)<th>Monthly (AWS Backup)<th>Failures</tr>"
  + ([.servers[] | "<tr\(if .compliance_status == "NON-COMPLIANT" then " class=nc" else "" end)><td>\(badge(.compliance_status))\(if .no_aws_backup then "<br><span class=bad>no AWS Backup</span>" else "" end)"
      + "<td>\(.account | esc)<br><small>\(.region | esc)</small><td><b>\(.identifier | esc)</b><br><small>\(.type) &middot; \(.engine | esc) \(.engine_version | esc)\(if (.members | length) > 0 then "<br>members: " + (.members | join(", ") | esc) else "" end)</small>"
      + "<td>\(badge(.daily.status))<br><small>retention \(.daily.retention)d &middot; \(.daily.days_ok // 0)/\(.daily.required_days // "-") days<br>newest \(.daily.newest // "-" | esc)<br>oldest \(.daily.oldest // "-" | esc)\(if ((.daily.missing_dates // []) | length) > 0 then "<br><span class=bad>missing \(.daily.missing_dates | join(", "))</span>" else "" end)</small>"
      + "<td>\(badge(.weekly.status))<br><small>" + (if .weekly.status == "UNKNOWN" then (.weekly.note | esc) else "\(.weekly.count)/\(.weekly.required) in \(.weekly.window_days)d\(if .weekly.borderline then " <span class=unk>borderline</span>" else "" end)<br>newest \(.weekly.newest // "-" | esc)<br>oldest \(.weekly.oldest // "-" | esc)<br>vault \(.weekly.vaults | join(", ") | esc)\(if (.weekly.gaps | length) > 0 then "<br><span class=bad>gaps \(.weekly.gaps | join(", "))</span>" else "" end)" end) + "</small>"
      + "<td>\(badge(.monthly.status))<br><small>" + (if .monthly.status == "UNKNOWN" then (.monthly.note | esc) else "\(.monthly.count)/\(.monthly.required) &middot; \(.monthly.months_covered) months<br>newest \(.monthly.newest // "-" | esc)<br>oldest \(.monthly.oldest // "-" | esc)<br>vault \(.monthly.vaults | join(", ") | esc)\(if (.monthly.gaps | length) > 0 then "<br><span class=bad>gaps \(.monthly.gaps | join(", "))</span>" else "" end)\(if .monthly.current_month_pending then "<br>current month pending" else "" end)" end) + "</small>"
      + "<td><small>\([.failures[].detail | esc] | join("<br>"))</small></tr>"] | join(""))
  + "</table><h2>Manual snapshots older than \($cfg.max_manual_age) days</h2><p><small>Cost is approximate: size (allocated GB) &times; $\($cfg.price_per_gb_month)/GB-month. Delete commands are printed only; the report never runs them.</small></p>"
  + "<table><tr><th>Account / region<th>Snapshot<th>Source<th>Age<th>Size GB<th>~$/month<th>Delete command (print only)</tr>"
  + (if (.manual | length) == 0 then "<tr><td colspan=7>none</tr>" else ([.manual[] | "<tr><td>\(.account | esc)<br><small>\(.region | esc)</small><td>\(.snapshot | esc)<br><small>\(.kind) &middot; \(.engine | esc)</small><td>\(.source | esc)\(if .orphan then " <span class=bad>orphan</span>" else "" end)<td>\(.age_days)d<td>\(.size_gb)<td>\(.est_monthly_usd)<td><code>\(.delete_command | esc)</code></tr>"] | join("")) end)
  + "</table>"
  + (if (.errors | length) > 0 then "<h2>Errors</h2><table><tr><th>Profile / region<th>Call<th>Message</tr>" + ([.errors[] | "<tr><td>\(.profile | esc) / \(.region | esc)<td>\(.call | esc)<td>\(.message | esc)</tr>"] | join("")) + "</table>" else "" end)
  + "<p><small>\($m.script | esc) v\($m.version | esc) &middot; \($m.aws_calls) AWS call(s) &middot; read-only</small></p></body></html>";

if $mode == "rows" then rows
elif $mode == "finalize" then finalize
elif $mode == "text" then text
elif $mode == "csv" then csv
elif $mode == "csv_manual" then csv_manual
elif $mode == "csv_summary" then csv_summary
elif $mode == "html" then html
elif $mode == "json" then .
elif $mode == "ts" then ($ARGS.named.s | ts)
else error("unknown mode \($mode)") end
