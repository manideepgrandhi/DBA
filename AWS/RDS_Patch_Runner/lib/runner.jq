# lib/runner.jq - plan building and rendering for rds_patch_runner.sh
# Modes ($mode): plan | plan_text | summary_text | summary_csv | summary_html | alert
# plan inputs (--slurpfile): cluster (describe-db-clusters), members (describe-db-instances), pma (array of
# {ResourceIdentifier, PendingMaintenanceActionDetails}); --argjson actions ["all"] | [..]; --arg minor "<version>|"

def vkey: [scan("[0-9]+|[A-Za-z]+") | (tonumber? // .)];
def selected($acts): . as $a | ($acts | index("all")) != null or ($acts | index($a)) != null;
def ts: if . == null or . == "" then "" else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") end;
def act_rows($arn; $pma; $acts):
  [ $pma[] | select(.ResourceIdentifier == $arn) | .PendingMaintenanceActionDetails[]
    | {action: .Action, description: (.Description // ""), opt_in_status: (.OptInStatus // ""),
       auto_applied_after: (.AutoAppliedAfterDate // "" | ts), forced_apply: (.ForcedApplyDate // "" | ts),
       current_apply: (.CurrentApplyDate // "" | ts), selected: (.Action | selected($acts))} ];

def plan:
  $ARGS.named as $A
  | ($A.cluster[0].DBClusters[0]) as $c
  | ($A.members[0].DBInstances // []) as $inst
  | ($A.pma[0] // []) as $pma
  | ($A.actions) as $acts
  | ([$c.DBClusterMembers[]? | select(.IsClusterWriter) | .DBInstanceIdentifier] | .[0] // "") as $writer
  | [ $inst[] | . as $i | {id: .DBInstanceIdentifier, arn: .DBInstanceArn, status: .DBInstanceStatus, class: .DBInstanceClass,
                 version: .EngineVersion, az: (.AvailabilityZone // ""), writer: (.DBInstanceIdentifier == $writer),
                 promotion_tier: ([$c.DBClusterMembers[]? | select(.DBInstanceIdentifier == $i.DBInstanceIdentifier) | .PromotionTier] | .[0] // null)} ] as $m0
  | ($m0 | map(. + {actions: act_rows(.arn; $pma; $acts)})
        | sort_by([(if .writer then 1 else 0 end), (.id | ascii_downcase)])) as $members
  | act_rows($c.DBClusterArn; $pma; $acts) as $cacts
  | ($members | map(select(.writer | not) | select(any(.actions[]; .selected)))) as $readers
  | ($members | map(select(.writer) | select(any(.actions[]; .selected)))) as $wr
  | ([$cacts[] | select(.selected)] | length > 0) as $has_cluster
  | ( [ {kind: "snapshot", target: $c.DBClusterIdentifier} ]
      + (if $A.minor != "" then [{kind: "minor-upgrade", target: $c.DBClusterIdentifier, to: $A.minor, from: $c.EngineVersion}] else [] end)
      + ($readers | map({kind: "instance", role: "reader", target: .id, arn: .arn, actions: [.actions[] | select(.selected) | .action]}))
      + (if $has_cluster then [{kind: "cluster", target: $c.DBClusterIdentifier, arn: $c.DBClusterArn, actions: [$cacts[] | select(.selected) | .action]}] else [] end)
      + ($wr | map({kind: "instance", role: "writer", target: .id, arn: .arn, actions: [.actions[] | select(.selected) | .action]}))
      + [ {kind: "verify", target: $c.DBClusterIdentifier} ] ) as $steps
  | { cluster: {id: $c.DBClusterIdentifier, arn: $c.DBClusterArn, engine: $c.Engine, version: $c.EngineVersion, status: $c.Status,
                global: ($c.GlobalClusterIdentifier // ""), multi_az: ($c.MultiAZ // false), window: ($c.PreferredMaintenanceWindow // ""),
                engine_mode: ($c.EngineMode // "provisioned")},
      writer: $writer, members: $members, cluster_actions: $cacts,
      not_selected: ([$cacts[], $members[].actions[] | select(.selected | not) | .action] | unique),
      minor_to: $A.minor,
      nothing_to_do: (($readers | length) == 0 and ($wr | length) == 0 and ($has_cluster | not) and $A.minor == ""),
      steps: ($steps | to_entries | map(.value + {n: (.key + 1)})) };

def pad($n): tostring | if length >= $n then .[0:$n] else . + (" " * ($n - length)) end;
def acts_txt: if length == 0 then "-" else map(.action + (if .selected then "" else " (not selected)" end)
                                                + (if .opt_in_status != "" then " [opt-in: " + .opt_in_status + "]" else "" end)) | join(", ") end;

def plan_text:
  . as $p
  | "Cluster   : \($p.cluster.id) (\($p.cluster.engine) \($p.cluster.version), status \($p.cluster.status), window \($p.cluster.window) UTC)",
    "Account   : \($ARGS.named.account // "-")   profile: \($ARGS.named.profile // "default")   region: \($ARGS.named.region // "-")",
    "Writer    : \($p.writer)",
    "",
    "MEMBERS   " + ("ROLE" | pad(8)) + ("INSTANCE" | pad(32)) + ("STATUS" | pad(12)) + ("CLASS" | pad(18)) + ("VERSION" | pad(26)) + "PENDING",
    ($p.members[] | "          " + ((if .writer then "writer" else "reader" end) | pad(8)) + (.id | pad(32)) + (.status | pad(12))
                    + (.class | pad(18)) + (.version | pad(26)) + (.actions | acts_txt)),
    "          " + ("cluster" | pad(8)) + ($p.cluster.id | pad(32)) + ($p.cluster.status | pad(12)) + ("-" | pad(18)) + ($p.cluster.version | pad(26)) + ($p.cluster_actions | acts_txt),
    "",
    (if $p.nothing_to_do then "PLAN      : nothing to do (no selected pending action and no --minor-upgrade)"
     else "PLAN (in this order; one step at a time, stop on the first failure):",
       ($p.steps[] | "  \(.n). " + (
          if .kind == "snapshot" then (if $ARGS.named.skip_snapshot == "1" then "snapshot   : SKIPPED (--skip-snapshot)"
                                       else "snapshot   : create-db-cluster-snapshot pre-maint-\(.target)-<UTC YYYYMMDD-HHMM>, wait until available" end)
          elif .kind == "minor-upgrade" then "minor upg  : modify-db-cluster --engine-version \(.to) --apply-immediately (from \(.from); whole cluster, all members restart)"
          elif .kind == "instance" then "\(.role | pad(10)) : \(.target) <- \(.actions | join(", ")) (--opt-in-type immediate), wait until available and nothing pending"
          elif .kind == "cluster" then "cluster    : \(.target) <- \(.actions | join(", ")) (cluster-level, --opt-in-type immediate), wait for cluster + members"
          else "verify     : no pending actions left, all available, versions" end)) end),
    (if ($p.not_selected | length) > 0 then "", "Not selected by --action (left pending): \($p.not_selected | join(", "))" else empty end);

def dur: if . == null then "-" else (. as $s | "\(($s / 60) | floor)m\($s % 60)s") end;
def summary_text:
  . as $s
  | "RDS patch runner summary - \($s.meta.script) v\($s.meta.version)",
    "Cluster  : \($s.meta.cluster) (\($s.meta.engine))  account \($s.meta.account)  region \($s.meta.region)  profile \($s.meta.profile)",
    "Started  : \($s.meta.started_utc)   Finished: \($s.meta.finished_utc)   Mode: \($s.meta.mode)",
    "Result   : \($s.meta.result) (exit \($s.meta.exit_code))\(if ($s.meta.message // "") != "" then " - " + $s.meta.message else "" end)",
    "Snapshot : \(if ($s.meta.snapshot // "") == "" then "-" else $s.meta.snapshot end)",
    "",
    ("STEP" | pad(5)) + ("KIND" | pad(14)) + ("TARGET" | pad(30)) + ("ACTIONS" | pad(30)) + ("START (UTC)" | pad(21)) + ("END (UTC)" | pad(21)) + ("DURATION" | pad(10)) + ("RESULT" | pad(10)) + ("BEFORE -> AFTER" | pad(40)) + "DETAIL",
    ($s.steps[] | (.n | tostring | pad(5)) + (.kind | pad(14)) + (.target | pad(30)) + ((.actions // "") | pad(30)) + ((.start_utc // "-") | pad(21))
                  + ((.end_utc // "-") | pad(21)) + (.duration_s | dur | pad(10)) + (.result | pad(10))
                  + ("\(.version_before // "") -> \(.version_after // "")" | pad(40)) + (.detail // "")),
    "",
    "VERSIONS (before -> after):",
    ($s.versions[] | "  \(.resource | pad(32)) \(.before // "-") -> \(.after // "-")"),
    "",
    (if $s.state_unknown then "PENDING ACTIONS LEFT: unknown (final state could not be read)" elif ($s.remaining | length) > 0 then "PENDING ACTIONS LEFT:", ($s.remaining[] | "  \(.resource): \(.action)\(if .opt_in_status != "" then " [opt-in: " + .opt_in_status + "]" else "" end)") else "PENDING ACTIONS LEFT: none" end),
    (if ($s.failovers | length) > 0 then "", "FAILOVERS SEEN:", ($s.failovers[] | "  \(.at_utc): writer \(.from) -> \(.to)") else empty end);

def summary_csv:
  (["step","kind","target","actions","start_utc","end_utc","duration_s","result","version_before","version_after","detail"] | @csv),
  (.steps[] | [.n, .kind, .target, (.actions // ""), (.start_utc // ""), (.end_utc // ""), .duration_s, .result, (.version_before // ""), (.version_after // ""), (.detail // "")] | @csv);

def h: tostring | @html;
def summary_html:
  . as $s
  | "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>RDS patch runner - \($s.meta.cluster | h)</title><style>"
  + "body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1f2933}header{background:#232f3e;color:#fff;padding:16px 26px}"
  + "header h1{margin:0;font-size:20px}header p{margin:4px 0 0;color:#c9d1d9;font-size:13px}main{padding:18px 26px}"
  + "table{border-collapse:collapse;background:#fff;font-size:13px;box-shadow:0 1px 3px rgba(0,0,0,.12);margin-bottom:16px}th{background:#e9edf2;text-align:left;padding:6px 9px}td{padding:6px 9px;border-top:1px solid #e6e9ee;vertical-align:top}"
  + ".ok{color:#2e7d32;font-weight:700}.fail{color:#c62828;font-weight:700}.other{color:#8d6e63;font-weight:700}h2{font-size:15px;margin:14px 0 6px}</style></head><body>"
  + "<header><h1>RDS patch runner: \($s.meta.cluster | h) - <span>\($s.meta.result | h)</span></h1><p>\($s.meta.engine | h) &middot; account \($s.meta.account | h) &middot; \($s.meta.region | h) &middot; \($s.meta.started_utc | h) - \($s.meta.finished_utc | h) &middot; exit \($s.meta.exit_code) &middot; snapshot \($s.meta.snapshot // "-" | h)</p></header><main>"
  + (if ($s.meta.message // "") != "" then "<p>\($s.meta.message | h)</p>" else "" end)
  + "<h2>Steps</h2><table><tr><th>#</th><th>Kind</th><th>Target</th><th>Actions</th><th>Start (UTC)</th><th>End (UTC)</th><th>Duration</th><th>Result</th><th>Before &rarr; after</th><th>Detail</th></tr>"
  + ($s.steps | map("<tr><td>\(.n)</td><td>\(.kind | h)</td><td>\(.target | h)</td><td>\(.actions // "" | h)</td><td>\(.start_utc // "-" | h)</td><td>\(.end_utc // "-" | h)</td><td>\(.duration_s | dur)</td>"
       + "<td class=\"\(if .result == "ok" then "ok" elif .result == "failed" or .result == "timeout" then "fail" else "other" end)\">\(.result | h)</td>"
       + "<td>\(.version_before // "" | h) &rarr; \(.version_after // "" | h)</td><td>\(.detail // "" | h)</td></tr>") | join(""))
  + "</table><h2>Versions</h2><table><tr><th>Resource</th><th>Before</th><th>After</th></tr>"
  + ($s.versions | map("<tr><td>\(.resource | h)</td><td>\(.before // "-" | h)</td><td>\(.after // "-" | h)</td></tr>") | join("")) + "</table>"
  + "<h2>Pending actions left</h2>" + (if ($s.remaining | length) == 0 then "<p>none</p>" else "<table><tr><th>Resource</th><th>Action</th><th>Opt-in</th></tr>"
       + ($s.remaining | map("<tr><td>\(.resource | h)</td><td>\(.action | h)</td><td>\(.opt_in_status | h)</td></tr>") | join("")) + "</table>" end)
  + (if ($s.failovers | length) > 0 then "<h2>Failovers seen</h2><ul>" + ($s.failovers | map("<li>\(.at_utc | h): writer \(.from | h) &rarr; \(.to | h)</li>") | join("")) + "</ul>" else "" end)
  + "</main></body></html>";

if $mode == "plan" then plan elif $mode == "plan_text" then plan_text elif $mode == "summary_text" then summary_text
elif $mode == "summary_csv" then summary_csv elif $mode == "summary_html" then summary_html else . end
