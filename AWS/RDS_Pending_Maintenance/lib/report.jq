# lib/report.jq - row building, filtering, summary and rendering for rds_pending_maintenance_report.sh
# Modes ($mode):
#   rows     : one (profile, region) collection dir -> array of rows      (slurpfiles pma/instances/clusters)
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

# ------------------------------------------------------------------ mode: rows
def rows:
  $ARGS.named as $A
  | (($A.instances[0] // []) | map({key: .DBInstanceArn, value: .}) | from_entries) as $I
  | (($A.clusters[0] // []) | map({key: .DBClusterArn, value: .}) | from_entries) as $C
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
          arn: $r.ResourceIdentifier } ];

# ------------------------------------------------------------------ mode: finalize
def decorate:
  . + { auto_applied_after_utc: (.auto_applied_after | fu), forced_apply_utc: (.forced_apply | fu),
        current_apply_utc: (.current_apply | fu), effective_apply_utc: (.effective_apply | fu),
        effective_apply_local: (.effective_apply | fl),
        maint_window_local: (if .next_window_start then (.next_window_start | strflocaltime("%a %H:%M")) + "-"
                             + (.next_window_end | strflocaltime("%a %H:%M %Z")) else "" end),
        next_window_local: (.next_window_start | fl) };
def counts(f): group_by(f) | map({key: (.[0] | f), value: length}) | sort_by(-.value) | from_entries;
def finalize:
  . as $r
  | ($r.rows | map(select((.engine | gmatch($f.engines)) and (.action | gmatch($f.actions))
                          and ((.identifier | gmatch($f.identifiers)) or (.cluster != "" and (.cluster | gmatch($f.identifiers))))
                          and (.urgency as $u | ($f.urgency | length) == 0 or any($f.urgency[]; ascii_upcase == $u))
                          and (. as $row | all($f.tags[]; . as $t | ($row.tags[$t.k] // null) as $v | $v != null and ($v | gmatch([$t.v])))) ))
       | sort_by([(.effective_apply // 1e18), (.urgency | urg_rank), .region, .identifier, .action]) | map(decorate)) as $rows
  | ( if ($rows | map(.severity) | index("CRIT")) then "CRIT" elif ($r.errors | length) > 0 then "ERROR"
      elif ($rows | length) > 0 then "WARN" else "OK" end ) as $ov
  | $r + { rows: $rows,
           summary: { overall: $ov, exit_code: {"CRIT":11, "ERROR":3, "WARN":10, "OK":0}[$ov],
                      total: ($rows | length), resources: ($rows | map(.arn) | unique | length),
                      unfiltered_total: ($r.rows | length),
                      by_urgency: (($rows | counts(.urgency)) | to_entries | sort_by(.key | urg_rank) | from_entries), by_action: ($rows | counts(.action)),
                      by_engine: ($rows | counts(.engine)), by_region: ($rows | counts(.region)),
                      by_account: ($rows | counts(.account)), errors: ($r.errors | length) } };

# ------------------------------------------------------------------ renderers
def pad($n): tostring | if length >= $n then .[0:$n] else . + (" " * ($n - length)) end;
def cut($n): tostring | if length > $n then .[0:($n - 2)] + ".." else . end;
def kv: to_entries | map("\(.key)=\(.value)") | join(", ");
def text:
  . as $r
  | [ "RDS pending maintenance report - \($r.meta.script) v\($r.meta.version)",
      "Generated : \($r.meta.generated_utc) / \($r.meta.generated_local)",
      "Accounts  : \($r.meta.accounts | map("\(.account) (\(.profile))") | join(", "))",
      "Regions   : \($r.meta.regions | join(", "))",
      (if ($r.meta.filters_text // "") != "" then "Filters   : \($r.meta.filters_text)" else empty end),
      "",
      ( if ($r.rows | length) == 0 then "No pending maintenance actions found."
        else ( (("URGENCY" | pad(9)) + ("DAYS" | pad(7)) + ("APPLY (\($r.meta.tz_abbr))" | pad(22)) + ("ACCOUNT" | pad(13)) + ("REGION" | pad(15))
                + ("TYPE" | pad(9)) + ("IDENTIFIER" | pad(30)) + ("ENGINE" | pad(24)) + ("ACTION" | pad(24)) + ("OPT-IN" | pad(17))
                + ($r.meta.tag_columns | map(pad(13)) | join(""))),
               ( $r.rows[] | (.urgency | pad(9)) + ((.days_until // "-") | tostring | pad(7)) + ((.effective_apply_local | if . == "" then "-" else .[0:16] end) | pad(22))
                 + (.account | pad(13)) + (.region | pad(15)) + (.resource_type | pad(9))
                 + ((.identifier + (if .cluster != "" then " (\(.cluster))" else "" end)) | cut(29) | pad(30))
                 + ("\(.engine) \(.engine_version)" | cut(23) | pad(24)) + (.action | pad(24)) + ((.opt_in_status | if . == "" then "-" else . end) | pad(17))
                 + ([.tag_columns[]] | map(cut(12) | pad(13)) | join("")) ) ) end ),
      "",
      "SUMMARY: \($r.summary.total) pending action(s) on \($r.summary.resources) resource(s)"
        + (if $r.summary.unfiltered_total != $r.summary.total then " (\($r.summary.unfiltered_total) before filters)" else "" end),
      "  by urgency : \($r.summary.by_urgency | kv)",
      "  by action  : \($r.summary.by_action | kv)",
      "  by engine  : \($r.summary.by_engine | kv)",
      "  by region  : \($r.summary.by_region | kv)",
      "  by account : \($r.summary.by_account | kv)",
      ( if ($r.errors | length) > 0 then "", "ERRORS (report incomplete):",
          ($r.errors[] | "  \(.account) \(.profile) \(.region) \(.call): \(.message)") else empty end ),
      "",
      "Overall: \($r.summary.overall) (exit \($r.summary.exit_code))"
    ] | join("\n");

def csv:
  (["account_id","profile","region","resource_type","identifier","cluster","engine","engine_version","instance_class"]
   + (.meta.tag_columns | map("tag:" + .))
   + ["action","description","opt_in_status","auto_applied_after_utc","forced_apply_utc","current_apply_utc",
      "effective_apply_utc","effective_apply_\(.meta.tz_abbr | ascii_downcase)","days_until","urgency",
      "maint_window_utc","maint_window_\(.meta.tz_abbr | ascii_downcase)","next_window_\(.meta.tz_abbr | ascii_downcase)","source","arn"]) as $h
  | ($h | @csv),
    (.rows[] | ([.account, .profile, .region, .resource_type, .identifier, .cluster, .engine, .engine_version, .instance_class]
               + [.tag_columns[]]
               + [.action, .description, .opt_in_status, .auto_applied_after_utc, .forced_apply_utc, .current_apply_utc,
                  .effective_apply_utc, .effective_apply_local, .days_until, .urgency, .maint_window_utc, .maint_window_local,
                  .next_window_local, .source, .arn]) | @csv);

def h: tostring | @html;
def two($e): if $e == null then "<span class=\"muted\">-</span>" else "\($e | fu | h)<br><span class=\"muted\">\($e | fl | h)</span>" end;
def card($label; $n; $cls): "<div class=\"card \($cls)\"><div class=\"n\">\($n)</div><div class=\"l\">\($label | h)</div></div>";
def minitable($title; $o): "<div class=\"mini\"><h3>\($title | h)</h3><table>"
  + ($o | to_entries | map("<tr><td>\(.key | h)</td><td class=\"num\">\(.value)</td></tr>") | join("")) + "</table></div>";
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
  + "footer{padding:14px 28px;color:#7b8794;font-size:12px}</style></head><body>\n"
  + "<header><h1>RDS pending maintenance report</h1><p>Generated \($r.meta.generated_utc | h) &middot; \($r.meta.generated_local | h) &middot; accounts: "
  + ($r.meta.accounts | map("\(.account) (\(.profile))") | join(", ") | h) + " &middot; regions: \($r.meta.regions | join(", ") | h)"
  + (if ($r.meta.filters_text // "") != "" then " &middot; filters: \($r.meta.filters_text | h)" else "" end) + "</p></header>\n<main>\n"
  + "<div class=\"cards\">" + card("pending actions"; $r.summary.total; "c-total") + card("resources"; $r.summary.resources; "c-total")
  + card("overdue"; ($u.OVERDUE // 0); "c-overdue") + card("critical (<= \($r.meta.crit_days)d)"; ($u.CRIT // 0); "c-crit")
  + card("warning (<= \($r.meta.warn_days)d)"; ($u.WARN // 0); "c-warn") + card("later"; ($u.INFO // 0); "c-info")
  + card("optional (no date)"; ($u.OPTIONAL // 0); "c-opt") + (if $r.summary.errors > 0 then card("errors"; $r.summary.errors; "c-err") else "" end) + "</div>\n"
  + (if ($r.errors | length) > 0 then "<div class=\"errors\"><b>Report incomplete - AWS errors:</b><ul>"
       + ($r.errors | map("<li>\(.account | h) \(.profile | h) \(.region | h) <code>\(.call | h)</code>: \(.message | h)</li>") | join("")) + "</ul></div>\n" else "" end)
  + "<div class=\"minis\">" + minitable("By action"; $r.summary.by_action) + minitable("By engine"; $r.summary.by_engine)
  + minitable("By region"; $r.summary.by_region) + minitable("By account"; $r.summary.by_account) + "</div>\n"
  + "<input id=\"q\" type=\"search\" placeholder=\"Filter rows (any text)...\">\n<table class=\"main\" id=\"t\"><thead><tr>"
  + (["Urgency", "Days", "Apply (UTC / \($r.meta.tz_abbr))", "Account", "Region", "Type", "Identifier", "Cluster", "Engine", "Class"]
     + ($r.meta.tag_columns) + ["Action", "Description", "Opt-in", "Auto-applied after", "Forced apply", "Maint. window (UTC / \($r.meta.tz_abbr))"]
     | map("<th>\(h)</th>") | join(""))
  + "</tr></thead><tbody>\n"
  + ( $r.rows | map(
        "<tr class=\"r-\(.urgency)\"><td data-s=\"\(.urgency | urg_rank)\"><span class=\"u u-\(.urgency)\">\(.urgency)</span></td>"
        + "<td data-s=\"\(.days_until // 99999)\" class=\"num\">\(.days_until // "-")</td>"
        + "<td data-s=\"\(.effective_apply // 9999999999)\">\(two(.effective_apply))<br><span class=\"muted\">\(.effective_basis | h)</span></td>"
        + "<td>\(.account | h)<br><span class=\"muted\">\(.profile | h)</span></td><td>\(.region | h)</td><td>\(.resource_type | h)</td>"
        + "<td><b>\(.identifier | h)</b>\(if .resolved then "" else "<br><span class=\"muted\">not found by describe-db-*</span>" end)</td>"
        + "<td>\(.cluster | h)</td><td>\(.engine | h)<br><span class=\"muted\">\(.engine_version | h)</span></td><td>\(.instance_class | h)</td>"
        + ([.tag_columns[]] | map("<td>\(h)</td>") | join(""))
        + "<td><b>\(.action | h)</b></td><td>\(.description | h)</td><td>\(.opt_in_status | h)</td>"
        + "<td data-s=\"\(.auto_applied_after // 9999999999)\">\(two(.auto_applied_after))</td>"
        + "<td data-s=\"\(.forced_apply // 9999999999)\">\(two(.forced_apply))</td>"
        + "<td>\(.maint_window_utc | h)<br><span class=\"muted\">\(.maint_window_local | h)</span></td></tr>") | join("\n") )
  + (if ($r.rows | length) == 0 then "<tr><td colspan=\"30\" style=\"padding:18px;text-align:center\">No pending maintenance actions found.</td></tr>" else "" end)
  + "\n</tbody></table>\n</main>\n<footer>\($r.meta.script | h) v\($r.meta.version | h) on \($r.meta.host | h) &middot; urgency: OVERDUE = apply date passed, CRIT &le; \($r.meta.crit_days)d, WARN &le; \($r.meta.warn_days)d, INFO later, OPTIONAL = no date &middot; read-only report, nothing was changed &middot; exit \($r.summary.exit_code)</footer>\n"
  + "<script>(function(){var t=document.getElementById('t'),b=t.tBodies[0],dir={};"
  + "t.tHead.addEventListener('click',function(e){var th=e.target.closest('th');if(!th)return;var i=th.cellIndex;dir[i]=!dir[i];"
  + "var rows=Array.prototype.slice.call(b.rows);rows.sort(function(x,y){var a=x.cells[i],c=y.cells[i];if(!a||!c)return 0;"
  + "var va=a.getAttribute('data-s'),vb=c.getAttribute('data-s');var r;if(va!==null&&vb!==null){r=parseFloat(va)-parseFloat(vb);}"
  + "else{r=a.textContent.localeCompare(c.textContent);}return dir[i]?r:-r;});rows.forEach(function(r){b.appendChild(r);});});"
  + "document.getElementById('q').addEventListener('input',function(){var q=this.value.toLowerCase();"
  + "Array.prototype.forEach.call(b.rows,function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>=0?'':'none';});});})();</script>\n"
  + "</body></html>";

def alert:
  {status: .summary.overall, exit_code: .summary.exit_code, generated_utc: .meta.generated_utc, generated_local: .meta.generated_local,
   accounts: .meta.accounts, regions: .meta.regions, summary: .summary,
   urgent: [.rows[] | select(.severity == "CRIT") | {account, region, resource_type, identifier, cluster, engine, action, urgency,
            days_until, effective_apply_utc, effective_apply_local, opt_in_status}],
   errors: .errors};

if $mode == "rows" then rows elif $mode == "finalize" then finalize elif $mode == "text" then text
elif $mode == "csv" then csv elif $mode == "html" then html else alert end
