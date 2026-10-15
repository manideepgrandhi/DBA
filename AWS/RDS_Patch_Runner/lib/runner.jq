# lib/runner.jq - plan building and rendering for rds_patch_runner.sh
# Modes ($mode): plan | plan_text | plan_html | minor_targets | summary_text | summary_csv | summary_html
# plan inputs (--slurpfile): cluster (describe-db-clusters), members (describe-db-instances), pma (array of
# {ResourceIdentifier, PendingMaintenanceActionDetails}), ev (describe-db-engine-versions or {});
# --argjson actions ["all"] | [..]; --arg ev_ok 1|0; --arg minor_mode latest|<version>|none; --arg minor_target
# "<version>|"; --arg minor_note "<why there is no target>"
def vkey: [scan("[0-9]+|[A-Za-z]+") | (tonumber? // .)];
def selected($acts): . as $a | ($acts | index("all")) != null or ($acts | index($a)) != null;
def ts: if . == null or . == "" then "" else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") end;
def act_rows($arn; $pma; $acts):
  [ $pma[] | select(.ResourceIdentifier == $arn) | .PendingMaintenanceActionDetails[]
    | {action: .Action, description: (.Description // ""), opt_in_status: (.OptInStatus // ""),
       auto_applied_after: (.AutoAppliedAfterDate // "" | ts), forced_apply: (.ForcedApplyDate // "" | ts),
       current_apply: (.CurrentApplyDate // "" | ts), selected: (.Action | selected($acts))} ];

# ---- action order inside the ONE rolling pass ----------------------------------------------------------------
# 0 system-update (system patches) -> 1 os-upgrade (OS updates) -> 2 db-upgrade (DB updates) -> 3 every other or
# unknown action type (ca-certificate-rotation, hardware-maintenance, future types: treated as DB updates, applied
# last, alphabetically)
def act_rank: if . == "system-update" then 0 elif . == "os-upgrade" then 1 elif . == "db-upgrade" then 2 else 3 end;
def act_phase: ["system patch", "OS update", "DB update", "DB update (other type)"][act_rank];
def order_acts: sort_by([(.action | act_rank), .action]);
# non-major upgrade targets newer than $cur, oldest first
def minor_targets($cur):
  [ .DBEngineVersions[]?.ValidUpgradeTarget[]? | select((.IsMajorVersionUpgrade // false) == false) | .EngineVersion
    | select(vkey > ($cur | vkey)) ] | unique_by(vkey);
def auto_minor($c; $inst):
  ([$inst[] | .AutoMinorVersionUpgrade | select(. != null)] | unique) as $u
  | if ($u | length) == 1 then ($u[0] | tostring) elif ($u | length) > 1 then "mixed (" + ([$inst[] | "\(.DBInstanceIdentifier)=\(.AutoMinorVersionUpgrade)"] | join(", ")) + ")"
    elif ($c.AutoMinorVersionUpgrade // null) != null then ($c.AutoMinorVersionUpgrade | tostring) else "unknown" end;
def act_steps($kind; $role; $id; $arn; $acts):
  [$acts[] | select(.selected)] | order_acts
  | map({kind: $kind, role: $role, target: $id, arn: $arn, action: .action, phase: (.action | act_phase)});

def plan:
  $ARGS.named as $A
  | ($A.cluster[0].DBClusters[0]) as $c
  | ($A.members[0].DBInstances // []) as $inst
  | ($A.pma[0] // []) as $pma
  | ($A.actions) as $acts
  | ([$c.DBClusterMembers[]? | select(.IsClusterWriter) | .DBInstanceIdentifier] | .[0] // "") as $writer
  | [ $inst[] | . as $i | {id: .DBInstanceIdentifier, arn: .DBInstanceArn, status: .DBInstanceStatus, class: .DBInstanceClass,
                 version: .EngineVersion, az: (.AvailabilityZone // ""), writer: (.DBInstanceIdentifier == $writer),
                 auto_minor_upgrade: (.AutoMinorVersionUpgrade // null),
                 promotion_tier: ([$c.DBClusterMembers[]? | select(.DBInstanceIdentifier == $i.DBInstanceIdentifier) | .PromotionTier] | .[0] // null)} ] as $m0
  | ($m0 | map(. + {actions: (act_rows(.arn; $pma; $acts) | order_acts)})
        | sort_by([(if .writer then 1 else 0 end), (.id | ascii_downcase)])) as $members
  | (act_rows($c.DBClusterArn; $pma; $acts) | order_acts) as $cacts
  | (if $A.ev_ok == "1" then ($A.ev[0] // {} | minor_targets($c.EngineVersion)) else null end) as $mt
  | ( [ {kind: "snapshot", target: $c.DBClusterIdentifier} ]
      + ([$members[] | select(.writer | not) | act_steps("instance"; "reader"; .id; .arn; .actions)] | add // [])
      + act_steps("cluster"; "cluster"; $c.DBClusterIdentifier; $c.DBClusterArn; $cacts)
      + ([$members[] | select(.writer) | act_steps("instance"; "writer"; .id; .arn; .actions)] | add // []) ) as $pass
  | ([$pass[] | select(.kind != "snapshot")] | length) as $n_apply
  | ( $pass
      + (if $n_apply > 0 or $A.minor_target != "" then [ {kind: "verify", target: $c.DBClusterIdentifier} ] else [] end)
      + (if $A.minor_target != "" then [{kind: "minor-upgrade", target: $c.DBClusterIdentifier, to: $A.minor_target, from: $c.EngineVersion, mode: $A.minor_mode}] else [] end)
    ) as $steps
  | { cluster: {id: $c.DBClusterIdentifier, arn: $c.DBClusterArn, engine: $c.Engine, version: $c.EngineVersion, status: $c.Status,
                global: ($c.GlobalClusterIdentifier // ""), multi_az: ($c.MultiAZ // false), window: ($c.PreferredMaintenanceWindow // ""),
                engine_mode: ($c.EngineMode // "provisioned")},
      writer: $writer, members: $members, cluster_actions: $cacts,
      minor: {current: $c.EngineVersion, auto_minor_upgrade: auto_minor($c; $inst),
              lookup_ok: ($A.ev_ok == "1"), available: ($mt // []), next: (($mt // [])[0] // null), latest: (($mt // [])[-1] // null),
              up_to_date: ($A.ev_ok == "1" and (($mt // []) | length) == 0),
              mode: $A.minor_mode, target: (if $A.minor_target == "" then null else $A.minor_target end), note: ($A.minor_note // "")},
      not_selected: ([$cacts[], $members[].actions[] | select(.selected | not) | .action] | unique),
      minor_to: $A.minor_target,
      nothing_to_do: ($n_apply == 0 and $A.minor_target == ""),
      steps: ($steps | to_entries | map(.value + {n: (.key + 1)})) };

def pad($n): tostring | if length >= $n then .[0:$n] else . + (" " * ($n - length)) end;
def acts_txt: if length == 0 then "-" else map(.action + (if .selected then "" else " (not selected)" end)
                                                + (if .opt_in_status != "" then " [opt-in: " + .opt_in_status + "]" else "" end)) | join(", ") end;
def dash: if . == null or . == "" then "-" else tostring end;
def minor_lines($m):
  "MINOR VERSION AVAILABILITY (describe-db-engine-versions, non-major targets only)",
  "  current engine version : \($m.current)",
  "  auto minor upgrade     : \($m.auto_minor_upgrade)",
  (if $m.lookup_ok | not then "  available minors       : unknown (lookup failed)"
   else "  next minor             : \(if $m.up_to_date then "- (up to date)" else $m.next end)",
        "  latest minor           : \(if $m.up_to_date then "- (already on the latest minor)" else $m.latest end)",
        "  available minors       : \(if $m.up_to_date then "none" else ($m.available | join(", ")) end)" end),
  "  --minor-upgrade        : \($m.mode) -> \(if $m.target != null then $m.target + " (runs LAST, after the rolling pass is verified)" else "no upgrade step (" + ($m.note | if . == "" then "none" else . end) + ")" end)";
def pending_lines($p):
  ([ ($p.members[] | . as $m | .actions[] | {role: (if $m.writer then "writer" else "reader" end), res: $m.id} + .),
     ($p.cluster_actions[] | {role: "cluster", res: $p.cluster.id} + .) ]) as $rows
  | "PENDING MAINTENANCE (per resource, in apply order)",
    (if ($rows | length) == 0 then "  none"
     else ("  " + ("ROLE" | pad(8)) + ("RESOURCE" | pad(30)) + ("ACTION" | pad(26)) + ("TYPE" | pad(24)) + ("AUTO-APPLIED AFTER" | pad(22)) + ("FORCED APPLY" | pad(22)) + "DESCRIPTION"),
          ($rows[] | "  " + (.role | pad(8)) + (.res | pad(30)) + ((.action + (if .selected then "" else " (not sel.)" end)) | pad(26))
                     + (.action | act_phase | pad(24)) + (.auto_applied_after | dash | pad(22)) + (.forced_apply | dash | pad(22)) + (.description | dash)) end);

def plan_text:
  . as $p
  | "Cluster   : \($p.cluster.id) (\($p.cluster.engine) \($p.cluster.version), status \($p.cluster.status), window \($p.cluster.window) UTC)",
    "Account   : \($ARGS.named.account // "-")   profile: \($ARGS.named.profile // "default")   region: \($ARGS.named.region // "-")",
    "Writer    : \($p.writer)",
    "",
    minor_lines($p.minor),
    "",
    "MEMBERS   " + ("ROLE" | pad(8)) + ("INSTANCE" | pad(32)) + ("STATUS" | pad(12)) + ("CLASS" | pad(18)) + ("VERSION" | pad(14)) + "PENDING",
    ($p.members[] | "          " + ((if .writer then "writer" else "reader" end) | pad(8)) + (.id | pad(32)) + (.status | pad(12))
                    + (.class | pad(18)) + (.version | pad(14)) + (.actions | acts_txt)),
    "          " + ("cluster" | pad(8)) + ($p.cluster.id | pad(32)) + ($p.cluster.status | pad(12)) + ("-" | pad(18)) + ($p.cluster.version | pad(14)) + ($p.cluster_actions | acts_txt),
    "",
    pending_lines($p),
    "",
    (if $p.nothing_to_do then "PLAN      : nothing to do (no selected pending action, and no minor upgrade: \($p.minor.note | if . == "" then "none" else . end))"
     else "PLAN (exact execution order; ONE rolling pass, then the minor upgrade; stop on the first failure):",
       ($p.steps[] | "  " + ("\(.n)." | pad(4)) + (
          if .kind == "snapshot" then (if $ARGS.named.skip_snapshot == "1" then "snapshot   : SKIPPED (--skip-snapshot)"
                                       else "snapshot   : create-db-cluster-snapshot pre-maint-\(.target)-<UTC YYYYMMDD-HHMM>, wait until available" end)
          elif .kind == "instance" then "\(.role | pad(10)) : \(.target) <- \(.action) [\(.phase)] (--opt-in-type immediate), wait until available and \(.action) gone"
          elif .kind == "cluster" then "cluster    : \(.target) <- \(.action) [\(.phase), cluster-level] (--opt-in-type immediate), wait for cluster + members"
          elif .kind == "verify" then "verify     : rolling pass done? cluster + all members available, selected actions gone (else STOP, no minor upgrade)"
          else "minor upg  : re-check the \(if .mode == "latest" then "latest minor" else "target" end) (skip if a DB update already got there), then modify-db-cluster --engine-version \(.to) --apply-immediately (from \(.from); ALL instances restart together), wait until cluster + members available on \(.to)" end)) end),
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
    "BEFORE:",
    (minor_lines($s.plan.minor) | "  " + .),
    "",
    (pending_lines($s.plan) | "  " + .),
    "",
    "MINOR UPGRADE (last step): \($s.minor_result.result // "not run") - \($s.minor_result.detail // "")\(if ($s.minor_result.to // "") != "" then " (target " + $s.minor_result.to + ")" else "" end)",
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
def css: ""
  + "body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1f2933}header{background:#232f3e;color:#fff;padding:16px 26px}"
  + "header h1{margin:0;font-size:20px}header p{margin:4px 0 0;color:#c9d1d9;font-size:13px}main{padding:18px 26px}"
  + "table{border-collapse:collapse;background:#fff;font-size:13px;box-shadow:0 1px 3px rgba(0,0,0,.12);margin-bottom:16px}th{background:#e9edf2;text-align:left;padding:6px 9px}td{padding:6px 9px;border-top:1px solid #e6e9ee;vertical-align:top}"
  + ".ok{color:#2e7d32;font-weight:700}.fail{color:#c62828;font-weight:700}.other{color:#8d6e63;font-weight:700}h2{font-size:15px;margin:14px 0 6px}" + ".mono{font-family:SFMono-Regular,Consolas,monospace;font-size:12px}.note{color:#52606d;font-size:13px}.warn{color:#b26a00;font-weight:700}";

def plan_html:
  . as $d | $d.plan as $p | $d.meta as $m
  | ([$p | plan_text] | map(select(test("^  [0-9]+\\. +")) | sub("^  [0-9]+\\. +"; ""))) as $lines
  | "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>RDS patch runner plan - \($p.cluster.id | h)</title><style>" + css + "</style></head><body>"
  + "<header><h1>RDS patch runner: \($p.cluster.id | h) - DRY RUN plan (\($m.result | h))</h1><p>\($p.cluster.engine | h) \($p.cluster.version | h) &middot; account \($m.account | h) &middot; profile \($m.profile | h) &middot; \($m.region | h) &middot; created \($m.created_utc | h) UTC &middot; writer \($p.writer | h) &middot; window \($p.cluster.window | h) UTC</p></header><main>"
  + "<p class=\"note\">Read-only dry run: nothing was changed. Re-run with <span class=\"mono\">--execute</span> to apply this plan.</p>"
  + "<h2>Minor version availability</h2><table><tr><th>Current</th><th>Auto minor upgrade</th><th>Next minor</th><th>Latest minor</th><th>Available minors</th><th>--minor-upgrade</th></tr>"
  + ($p.minor | "<tr><td>\(.current | h)</td><td>\(.auto_minor_upgrade | h)</td><td>\(if .up_to_date then "- (up to date)" else (.next | dash) end | h)</td><td>\(if .up_to_date then "- (already latest)" else (.latest | dash) end | h)</td><td>\(if .lookup_ok then (.available | join(", ") | if . == "" then "none" else . end) else "unknown (lookup failed)" end | h)</td><td>\(.mode | h) &rarr; \(if .target != null then (.target + " (runs LAST)") else ("no upgrade step: " + (.note | if . == "" then "none" else . end)) end | h)</td></tr></table>")
  + "<h2>Members</h2><table><tr><th>Role</th><th>Instance</th><th>Status</th><th>Class</th><th>Version</th><th>Pending</th></tr>"
  + ($p.members | map("<tr><td>\(if .writer then "writer" else "reader" end)</td><td>\(.id | h)</td><td>\(.status | h)</td><td>\(.class | h)</td><td>\(.version | h)</td><td>\(.actions | acts_txt | h)</td></tr>") | join(""))
  + "<tr><td>cluster</td><td>\($p.cluster.id | h)</td><td>\($p.cluster.status | h)</td><td>-</td><td>\($p.cluster.version | h)</td><td>\($p.cluster_actions | acts_txt | h)</td></tr></table>"
  + "<h2>Pending maintenance (per resource, in apply order)</h2>"
  + ([($p.members[] | . as $mm | .actions[] | {role: (if $mm.writer then "writer" else "reader" end), r: $mm.id} + .), ($p.cluster_actions[] | {role: "cluster", r: $p.cluster.id} + .)]
     | if length == 0 then "<p>none</p>" else "<table><tr><th>Role</th><th>Resource</th><th>Action</th><th>Type</th><th>Selected</th><th>Auto-applied after</th><th>Forced apply</th><th>Description</th></tr>"
       + (map("<tr><td>\(.role)</td><td>\(.r | h)</td><td>\(.action | h)</td><td>\(.action | act_phase | h)</td><td>\(if .selected then "yes" else "<span class=\"warn\">no</span>" end)</td><td>\(.auto_applied_after | dash | h)</td><td>\(.forced_apply | dash | h)</td><td>\(.description | dash | h)</td></tr>") | join("")) + "</table>" end)
  + "<h2>Plan (exact execution order)</h2>"
  + (if $p.nothing_to_do then "<p>Nothing to do: no selected pending action and no minor upgrade.</p>"
     else "<table><tr><th>#</th><th>Step</th></tr>" + ($lines | to_entries | map("<tr><td>\(.key + 1)</td><td class=\"mono\">\(.value | h)</td></tr>") | join("")) + "</table>" end)
  + (if ($p.not_selected | length) > 0 then "<p class=\"note\">Not selected by --action (left pending): \($p.not_selected | join(", ") | h)</p>" else "" end)
  + "<p class=\"note\">Generated by \($m.script | h) v\($m.version | h). Stops at the first failure: after a reader fails the writer is never touched and there is no minor upgrade.</p></main></body></html>";

def summary_html:
  . as $s
  | "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>RDS patch runner - \($s.meta.cluster | h)</title><style>"
  + css + "</style></head><body>"
  + "<header><h1>RDS patch runner: \($s.meta.cluster | h) - <span>\($s.meta.result | h)</span></h1><p>\($s.meta.engine | h) &middot; account \($s.meta.account | h) &middot; \($s.meta.region | h) &middot; \($s.meta.started_utc | h) - \($s.meta.finished_utc | h) &middot; exit \($s.meta.exit_code) &middot; snapshot \($s.meta.snapshot // "-" | h)</p></header><main>"
  + (if ($s.meta.message // "") != "" then "<p>\($s.meta.message | h)</p>" else "" end)
  + "<h2>Steps</h2><table><tr><th>#</th><th>Kind</th><th>Target</th><th>Actions</th><th>Start (UTC)</th><th>End (UTC)</th><th>Duration</th><th>Result</th><th>Before &rarr; after</th><th>Detail</th></tr>"
  + ($s.steps | map("<tr><td>\(.n)</td><td>\(.kind | h)</td><td>\(.target | h)</td><td>\(.actions // "" | h)</td><td>\(.start_utc // "-" | h)</td><td>\(.end_utc // "-" | h)</td><td>\(.duration_s | dur)</td>"
       + "<td class=\"\(if .result == "ok" then "ok" elif .result == "failed" or .result == "timeout" then "fail" else "other" end)\">\(.result | h)</td>"
       + "<td>\(.version_before // "" | h) &rarr; \(.version_after // "" | h)</td><td>\(.detail // "" | h)</td></tr>") | join(""))
  + "</table><h2>Minor version (before)</h2><table><tr><th>Current</th><th>Auto minor upgrade</th><th>Next minor</th><th>Latest minor</th><th>Available minors</th><th>--minor-upgrade</th><th>Minor upgrade result</th></tr>"
  + ($s.plan.minor | "<tr><td>\(.current | h)</td><td>\(.auto_minor_upgrade | h)</td><td>\(.next | dash | h)</td><td>\(.latest | dash | h)</td><td>\(if .lookup_ok then (.available | join(", ") | if . == "" then "none (up to date)" else . end) else "unknown" end | h)</td><td>\(.mode | h) &rarr; \(.target | dash | h)</td>")
  + "<td>\($s.minor_result.result // "not run" | h): \($s.minor_result.detail // "" | h)</td></tr></table>"
  + "<h2>Pending maintenance (before)</h2><table><tr><th>Resource</th><th>Action</th><th>Type</th><th>Description</th><th>Auto-applied after</th><th>Forced apply</th></tr>"
  + ([($s.plan.members[] | .id as $r | .actions[] | {r: $r} + .), ($s.plan.cluster_actions[] | {r: $s.plan.cluster.id} + .)]
     | map("<tr><td>\(.r | h)</td><td>\(.action | h)</td><td>\(.action | act_phase | h)</td><td>\(.description | dash | h)</td><td>\(.auto_applied_after | dash | h)</td><td>\(.forced_apply | dash | h)</td></tr>") | join(""))
  + "</table><h2>Versions</h2><table><tr><th>Resource</th><th>Before</th><th>After</th></tr>"
  + ($s.versions | map("<tr><td>\(.resource | h)</td><td>\(.before // "-" | h)</td><td>\(.after // "-" | h)</td></tr>") | join("")) + "</table>"
  + "<h2>Pending actions left</h2>" + (if ($s.remaining | length) == 0 then "<p>none</p>" else "<table><tr><th>Resource</th><th>Action</th><th>Opt-in</th></tr>"
       + ($s.remaining | map("<tr><td>\(.resource | h)</td><td>\(.action | h)</td><td>\(.opt_in_status | h)</td></tr>") | join("")) + "</table>" end)
  + (if ($s.failovers | length) > 0 then "<h2>Failovers seen</h2><ul>" + ($s.failovers | map("<li>\(.at_utc | h): writer \(.from | h) &rarr; \(.to | h)</li>") | join("")) + "</ul>" else "" end)
  + "</main></body></html>";

if $mode == "plan" then plan elif $mode == "minor_targets" then minor_targets($ARGS.named.cur)[] elif $mode == "plan_text" then plan_text elif $mode == "summary_text" then summary_text
elif $mode == "summary_csv" then summary_csv elif $mode == "summary_html" then summary_html elif $mode == "plan_html" then plan_html else . end
