# lib/render.jq - report assembly and rendering for aurora_pg_check.sh
#   finalize : {meta, clusters, results}  -> adds .summary (per-cluster + overall + exit code)
#   text     : finalized report -> plain text   (--arg only_problems 0|1 --arg details 0|1)
#   html     : finalized report -> standalone HTML page
#   alert    : finalized report -> JSON payload for --alert-webhook-format json

def sev: {"OK":0, "INFO":0, "SKIP":0, "WARN":1, "ERROR":2, "CRIT":3}[.] // 0;
def overall: if any(.[]; . == "CRIT") then "CRIT" elif any(.[]; . == "ERROR") then "ERROR"
             elif any(.[]; . == "WARN") then "WARN" else "OK" end;
def rc: {"CRIT":11, "ERROR":3, "WARN":10, "OK":0}[.];
def pad($n): tostring | if length >= $n then .[0:$n] else . + (" " * ($n - length)) end;
def cut($n): tostring | if length > $n then .[0:($n - 3)] + "..." else . end;
def problem: .status == "WARN" or .status == "CRIT" or .status == "ERROR";
def counts: {ok: map(select(.status == "OK" or .status == "INFO" or .status == "SKIP")) | length,
             warn: map(select(.status == "WARN")) | length, crit: map(select(.status == "CRIT")) | length,
             error: map(select(.status == "ERROR")) | length, total: length};

def finalize:
  . as $r
  | ($r.results | group_by([.region, .cluster]) | map({region: .[0].region, cluster: .[0].cluster,
        status: (map(.status) | overall)} + (. | counts))) as $pc
  | ($r.results | map(.status) | overall) as $ov
  | $r + {summary: {overall: $ov, exit_code: ($ov | rc), clusters: $pc, counts: ($r.results | counts),
                    cluster_count: ($r.clusters | length)}};

def info_of($r; $c): ($r.clusters | map(select(.region == $c.region and .cluster == $c.cluster)) | .[0]);

def text:
  . as $r | ($only_problems == "1") as $op | ($details == "1") as $dt
  | [ "Aurora PostgreSQL checks - \($r.meta.script) v\($r.meta.version)",
      "Generated : \($r.meta.generated)   (host \($r.meta.host))",
      "Account   : \($r.meta.account)   profile: \($r.meta.profile)",
      "Regions   : \($r.meta.regions | join(", "))",
      "Window    : lookback \($r.meta.lookback) (metrics period \($r.meta.period)s)   checks: \($r.meta.checks | join(","))",
      "",
      ( $r.summary.clusters[] as $c | info_of($r; $c) as $i
        | ($r.results | map(select(.region == $c.region and .cluster == $c.cluster))) as $rows
        | ($rows | map(select(if $op then problem else true end))) as $show
        | "=== \($c.region) / \($c.cluster) : \($c.status)"
          + (if $i then "  (aurora-postgresql \($i.engine_version), \($i.instances) instance(s): \($i.writers) writer, \($i.readers) reader(s)\(if $i.serverless then ", serverless v2" else "" end))" else "" end),
        ( if ($show | length) == 0 then "    all \($rows | length) checks OK"
          else ("    " + ("STATUS" | pad(7)) + ("GROUP" | pad(9)) + ("CHECK" | pad(27)) + ("VALUE" | pad(42)) + "REASON"),
               ( $show[] | ("    " + (.status | pad(7)) + (.group | pad(9)) + (.check | cut(26) | pad(27)) + (.value | cut(41) | pad(42)) + .reason),
                           ( if ($dt or problem) then (.details[] | "        - " + .) else empty end ) ) end ),
        "" ),
      "SUMMARY",
      ("    " + ("REGION" | pad(16)) + ("CLUSTER" | pad(34)) + ("STATUS" | pad(8)) + ("OK" | pad(5)) + ("WARN" | pad(6)) + ("CRIT" | pad(6)) + "ERROR"),
      ( $r.summary.clusters[] | "    " + (.region | pad(16)) + (.cluster | cut(33) | pad(34)) + (.status | pad(8))
          + (.ok | pad(5)) + (.warn | pad(6)) + (.crit | pad(6)) + (.error | tostring) ),
      "",
      "Overall: \($r.summary.overall) (exit \($r.summary.exit_code)) - \($r.summary.cluster_count) cluster(s), \($r.summary.counts.total) checks: \($r.summary.counts.ok) ok, \($r.summary.counts.warn) warn, \($r.summary.counts.crit) crit, \($r.summary.counts.error) error"
    ] | join("\n");

def badge: "<span class=\"st st-\(. | ascii_downcase)\">\(. | @html)</span>";
def html:
  . as $r
  | "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>Aurora PostgreSQL checks - \($r.summary.overall)</title>\n"
  + "<style>body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:24px;color:#222}"
  + "table{border-collapse:collapse;width:100%;margin-bottom:18px;font-size:13px}th,td{border:1px solid #ddd;padding:4px 8px;text-align:left;vertical-align:top}"
  + "th{background:#f3f3f3}.st{font-weight:bold;padding:1px 6px;border-radius:3px;color:#fff}.st-ok{background:#2e7d32}.st-info{background:#607d8b}"
  + ".st-skip{background:#9e9e9e}.st-warn{background:#ef6c00}.st-crit{background:#c62828}.st-error{background:#6a1b9a}"
  + "ul{margin:2px 0 0 16px;padding:0;color:#555;font-size:12px}.meta td{border:none;padding:1px 8px}</style></head><body>\n"
  + "<h1>Aurora PostgreSQL checks: \($r.summary.overall | badge)</h1>\n<table class=\"meta\">"
  + ([["Generated", $r.meta.generated], ["Account", "\($r.meta.account) (profile \($r.meta.profile))"], ["Regions", ($r.meta.regions | join(", "))],
      ["Window", "lookback \($r.meta.lookback), period \($r.meta.period)s"], ["Checks", ($r.meta.checks | join(", "))],
      ["Exit code", ($r.summary.exit_code | tostring)], ["Tool", "\($r.meta.script) v\($r.meta.version) on \($r.meta.host)"]]
     | map("<tr><td><b>\(.[0])</b></td><td>\(.[1] | @html)</td></tr>") | join(""))
  + "</table>\n<h2>Summary</h2>\n<table><tr><th>Region</th><th>Cluster</th><th>Version</th><th>Instances</th><th>Status</th><th>OK</th><th>WARN</th><th>CRIT</th><th>ERROR</th></tr>"
  + ($r.summary.clusters | map(. as $c | info_of($r; $c) as $i
       | "<tr><td>\($c.region | @html)</td><td><a href=\"#\($c.region | @html)-\($c.cluster | @html)\">\($c.cluster | @html)</a></td><td>\($i.engine_version // "-" | @html)</td>"
       + "<td>\($i.instances // "-")</td><td>\($c.status | badge)</td><td>\($c.ok)</td><td>\($c.warn)</td><td>\($c.crit)</td><td>\($c.error)</td></tr>") | join(""))
  + "</table>\n"
  + ($r.summary.clusters | map(. as $c
       | "<h2 id=\"\($c.region | @html)-\($c.cluster | @html)\">\($c.region | @html) / \($c.cluster | @html) \($c.status | badge)</h2>\n"
       + "<table><tr><th>Status</th><th>Group</th><th>Check</th><th>Value</th><th>Reason</th></tr>"
       + ($r.results | map(select(.region == $c.region and .cluster == $c.cluster)
            | "<tr><td>\(.status | badge)</td><td>\(.group | @html)</td><td>\(.check | @html)</td><td>\(.value | @html)</td><td>\(.reason | @html)"
              + (if (.details | length) > 0 then "<ul>" + (.details | map("<li>\(@html)</li>") | join("")) + "</ul>" else "" end) + "</td></tr>") | join(""))
       + "</table>\n") | join(""))
  + "</body></html>";

def alert:
  {status: .summary.overall, exit_code: .summary.exit_code, generated: .meta.generated, host: .meta.host,
   account: .meta.account, regions: .meta.regions, clusters: .summary.clusters,
   problems: [.results[] | select(problem) | {region, cluster, group, check, status, value, reason}]};

if $mode == "finalize" then finalize elif $mode == "text" then text elif $mode == "html" then html else alert end
