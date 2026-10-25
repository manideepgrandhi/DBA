# report.jq - renders mongo_health_report.sh output.  Inputs: $mode, $cfg[0], $S[0] (array of servers).
# Modes: html | text | csv_summary | csv_flags | json | worst
def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;");
def r1: if . == null then null else (. * 10 | round) / 10 end;
def r2: if . == null then null else (. * 100 | round) / 100 end;
def hb: if . == null then "-" else . as $b
  | if $b >= 1099511627776 then "\($b / 1099511627776 | r2) TB" elif $b >= 1073741824 then "\($b / 1073741824 | r2) GB"
    elif $b >= 1048576 then "\($b / 1048576 | r1) MB" elif $b >= 1024 then "\($b / 1024 | r1) KB" else "\($b) B" end end;
def hkb: if . == null then "-" else . * 1024 | hb end;
def hn: if . == null then "-" else tostring | [explode | reverse | _nwise(3) | reverse | implode] | reverse | join(",") end;
def dur: if . == null then "-" else (. | floor) as $s
  | if $s >= 86400 then "\($s / 86400 | floor)d \(($s % 86400) / 3600 | floor)h" elif $s >= 3600 then "\($s / 3600 | floor)h \(($s % 3600) / 60 | floor)m"
    elif $s >= 60 then "\($s / 60 | floor)m \($s % 60)s" else "\($s)s" end end;
def utc: if . == null then "-" else floor | strftime("%Y-%m-%d %H:%M:%S UTC") end;
def ist: if . == null then "-" else floor + 19800 | strftime("%Y-%m-%d %H:%M:%S IST") end;
def both: if . == null then "-" else "\(utc) · \(ist)" end;
def p: if . == null then "-" else "\(r1)%" end;
def d: if . == null then "-" else tostring end;
def rank: if . == "CRIT" then 3 elif . == "WARN" then 2 elif . == "INFO" then 1 else 0 end;
def worst: (map(.sev | rank) | max // 0) as $m | if $m == 3 then "CRIT" elif $m == 2 then "WARN" else "OK" end;
def lvl($v; $w; $c): if $v == null then null elif $c != null and $v >= $c then "CRIT" elif $v >= $w then "WARN" else null end;
def okstate: . as $st | [1, 2, 7] | index($st) != null;
def host: sub(":[0-9]+$"; "");

$cfg[0] as $C | $C.t as $T
# ---------------------------------------------------------------- flags
| def flags_for($s):
    $s.data as $x | $s.name as $n
    | def f($sev; $code; $obj; $detail): {sev: $sev, code: $code, server: $n, object: ($obj | tostring), detail: $detail};
    if ($x.ok | not) then [f("CRIT"; "UNREACHABLE"; $s.target; $x.error // "no data")]
    else
      [ ($x.repl // null) as $r
      | ( if $x.connect_fallback then f("WARN"; "RS_DISCOVERY_FAILED"; $x.connect_fallback.host; "Replica-set connection failed (\($x.connect_fallback.reason)); collected through a direct connection to this seed instead") else empty end ),
        ( if $r == null and $x.server.msg != "isdbgrid" then f("INFO"; "STANDALONE"; $x.server.host; "Not a replica set member: no automatic failover, no oplog-based point-in-time recovery") else empty end ),
        ( if $x.server.msg == "isdbgrid" then f("WARN"; "MONGOS"; $x.server.host; "Target is a mongos router; list the config server and shard replica sets instead") else empty end ),
        ( if $x.cmdline.repl_set and $r == null then f("WARN"; "RS_STATUS_UNAVAILABLE"; $x.server.host; "Started with replSet \($x.cmdline.repl_set) but replSetGetStatus failed: \($x.errors.replSetGetStatus // "?")") else empty end ),
        ( if $r then
            ( if $r.primary == null then f("CRIT"; "NO_PRIMARY"; $r.set; "No member is PRIMARY - the set cannot take writes") else empty end ),
            ( $r.members[] as $m
              | ( if $m.health != 1 then f("CRIT"; "MEMBER_DOWN"; $m.name; "\($m.state_str) (health \($m.health)); \($m.info // "no heartbeat")")
                  elif ([1, 2, 7] | index($m.state)) == null then
                    f(if ([3, 5, 9] | index($m.state)) != null and $m.state != 9 then "WARN" else "CRIT" end; "MEMBER_STATE"; $m.name; "State \($m.state_str)\(if $m.info then ": " + $m.info else "" end)")
                  else empty end ),
                ( if $m.lag_s != null and $m.state == 2 then (($m.lag_s - ($m.delay_s // 0)) | if . < 0 then 0 else . end) as $eff
                    | lvl($eff; $T.lag_warn; $T.lag_crit) as $l
                    | if $l then f($l; "REPL_LAG"; $m.name; "\($eff | dur) behind \($r.lag_reference)\(if $m.delay_s > 0 then " beyond its configured \($m.delay_s)s delay (total \($m.lag_s | dur))" else "" end)") else empty end
                  else empty end ) ),
            ( ($r.members | map(select(.votes > 0)) ) as $v | ($v | map(select(.health == 1)) | length) as $up
              | if ($v | length) > 0 and $up <= (($v | length) / 2) then f("CRIT"; "NO_MAJORITY"; $r.set; "Only \($up) of \($v | length) voting members healthy")
                elif ($v | length) % 2 == 0 then f("INFO"; "EVEN_VOTERS"; $r.set; "\($v | length) voting members - an odd number (or an arbiter) avoids tied elections") else empty end ),
            ( if $x.oplog and $x.oplog.window_h != null then lvl(- $x.oplog.window_h; - $T.oplog_warn; - $T.oplog_crit) as $l
                | if $l then f($l; "OPLOG_WINDOW"; $r.set; "Oplog covers \($x.oplog.window_h) h (oplog \($x.oplog.size_bytes | hb) of \($x.oplog.max_bytes | hb)); a secondary down longer than this needs a full resync") else empty end
              elif $x.errors.oplog then f("INFO"; "OPLOG_UNREADABLE"; $r.set; "Oplog window not measured: \($x.errors.oplog) (grant read on the local database)")
              else empty end ),
            ( [$x.members_direct[]? | select(.ok) | .version] | unique | if length > 1 then f("WARN"; "VERSION_MISMATCH"; $r.set; "Members run different versions: \(join(", "))") else empty end )
          else empty end ),
        ( if $x.cmdline.auth == false and $x.server.msg != "isdbgrid" then f("WARN"; "AUTH_DISABLED"; $x.server.host; "Authorization is not enabled (no --auth / security.authorization / keyFile)") else empty end ),
        ( if $x.server.uptime_s != null and $x.server.uptime_s < 3600 then f("INFO"; "RECENT_RESTART"; $x.server.host; "Up for \($x.server.uptime_s | dur)") else empty end ),
        ( lvl($x.conns.pct; $T.conn_warn; $T.conn_crit) as $l | if $l then f($l; "CONNECTIONS"; $x.server.host; "\($x.conns.current) used of \($x.conns.current + $x.conns.available) (\($x.conns.pct | p))") else empty end ),
        ( lvl($x.cache.dirty_pct; $T.dirty_warn; $T.dirty_crit) as $l | if $l then f($l; "CACHE_DIRTY"; $x.server.host; "WiredTiger cache dirty \($x.cache.dirty_pct | p) of \($x.cache.max_bytes | hb)") else empty end ),
        ( lvl($x.cache.used_pct; $T.cache_warn; null) as $l | if $l then f($l; "CACHE_FULL"; $x.server.host; "WiredTiger cache used \($x.cache.used_pct | p) of \($x.cache.max_bytes | hb) (application threads evicting: \($x.cache.evicted_app | hn) pages)") else empty end ),
        ( lvl($x.fs.pct; $T.disk_warn; $T.disk_crit) as $l | if $l then f($l; "DISK_DATA_FS"; $x.server.host; "Data filesystem \($x.fs.pct | p) used (\($x.fs.used_bytes | hb) of \($x.fs.total_bytes | hb), free \(($x.fs.total_bytes - $x.fs.used_bytes) | hb))") else empty end ),
        ( if ($x.queues.total // 0) >= $T.queue_warn then f("WARN"; "QUEUED_OPS"; $x.server.host; "\($x.queues.readers) readers + \($x.queues.writers) writers waiting for the global lock") else empty end ),
        ( if $x.queues.tickets_read_avail == 0 or $x.queues.tickets_write_avail == 0 then f("WARN"; "TICKETS_EXHAUSTED"; $x.server.host; "Storage engine tickets available: read \($x.queues.tickets_read_avail), write \($x.queues.tickets_write_avail)") else empty end ),
        ( ($x.long_ops // []) as $o | if ($o | length) > 0 then f("WARN"; "LONG_RUNNING_OPS"; $x.server.host; "\($o | length) operation(s) running ≥ \($T.long_op)s; longest \($o[0].secs)s: \($o[0].op // "") \($o[0].ns // "") opid \($o[0].opid)") else empty end ),
        ( if ($x.asserts.regular // 0) > 0 then f("INFO"; "ASSERTS"; $x.server.host; "\($x.asserts.regular) regular assert(s) since startup - check the mongod log") else empty end ),
        ( $x.members_direct[]? as $m
          | if $m.ok == false then f("INFO"; "MEMBER_DIRECT_FAILED"; $m.name; "Could not connect directly from this host (DNS/firewall from the runner?): \($m.error)")
            elif $m.ok then
              ( lvl($m.fs_pct; $T.disk_warn; $T.disk_crit) as $l | if $l and ($m.name | host) != ($x.server.me // "" | host) or ($l and $x.fs == null) then f($l; "DISK_DATA_FS"; $m.name; "Data filesystem \($m.fs_pct | p) used (free \(($m.fs_total - $m.fs_used) | hb) of \($m.fs_total | hb))") else empty end ),
              ( lvl($m.conn_pct; $T.conn_warn; $T.conn_crit) as $l | if $l and $m.name != $x.server.me then f($l; "CONNECTIONS"; $m.name; "\($m.conn_pct | p) of connections used") else empty end ),
              ( lvl($m.cache_dirty_pct; $T.dirty_warn; $T.dirty_crit) as $l | if $l and $m.name != $x.server.me then f($l; "CACHE_DIRTY"; $m.name; "WiredTiger cache dirty \($m.cache_dirty_pct | p)") else empty end )
            else empty end ),
        ( $s.ssh[]? as $h
          | if $h.ok | not then f("WARN"; "SSH_DF_FAILED"; $h.dest; $h.error)
            else $h.mounts[] as $mt | lvl($mt.pct; $T.disk_warn; $T.disk_crit) as $l
              | if $l then ([$h.paths[]? | select(.mount == $mt.mount) | .kind] | unique | join("+")) as $k
                  | f($l; "DISK_MOUNT"; "\($h.member // $h.host) \($mt.mount)"; "\($mt.pct)% used, \($mt.avail_kb | hkb) free of \($mt.size_kb | hkb) (\($mt.fs))\(if $k != "" then " - holds " + $k else "" end)")
                else empty end end ),
        ( ($x.errors | to_entries | map(select(.key | test("^(oplog|replSetGetStatus|fcv)$") | not))) as $e
          | if ($e | length) > 0 then f("INFO"; "SECTION_ERRORS"; $x.server.host; "\($e | length) section(s) not collected: \($e[0:4] | map("\(.key): \(.value)") | join("; "))\(if ($e | length) > 4 then " …" else "" end)") else empty end )
      ]
    end;
  ($S[0] | map(. + {flags: flags_for(.)} | . + {status: (.flags | worst)})) as $SV
| ([$SV[].flags[]] | sort_by([-(.sev | rank), .server, .code])) as $FL
| def summ($s): $s.data as $x
    | {server: $s.name, target: $s.target, status: $s.status, reachable: ($x.ok == true),
       type: (if ($x.ok | not) then "-" elif $x.repl then "RS " + $x.repl.set elif $x.server.msg == "isdbgrid" then "mongos" else "standalone" end),
       version: ($x.server.version // "-"), host: ($x.server.host // "-"), uptime: ($x.server.uptime_s | dur),
       primary: (if $x.repl then ($x.repl.primary // "NONE") else "-" end),
       members: (if $x.repl then "\([$x.repl.members[] | select(.health == 1 and (.state | okstate))] | length)/\($x.repl.members | length)" else "-" end),
       max_lag_s: (if $x.repl then ([$x.repl.members[] | select(.state == 2 and .lag_s != null) | ((.lag_s - (.delay_s // 0)) | if . < 0 then 0 else . end)] | max) else null end),
       oplog_h: ($x.oplog.window_h // null), conn_pct: ($x.conns.pct // null), cache_used_pct: ($x.cache.used_pct // null), cache_dirty_pct: ($x.cache.dirty_pct // null),
       disk_pct: ([$x.fs.pct, ($x.members_direct[]? | .fs_pct), ($s.ssh[]? | .mounts[]? | .pct)] | map(select(. != null)) | max),
       long_ops: (($x.long_ops // []) | length), crit: ([$s.flags[] | select(.sev == "CRIT")] | length), warn: ([$s.flags[] | select(.sev == "WARN")] | length),
       collected_at: ($x.collected_at // null)};
  ($SV | map(summ(.))) as $SUM
| def csvrow: map(if . == null then "" else tostring end | if test("[\",\n]") then "\"" + gsub("\""; "\"\"") + "\"" else . end) | join(",");

if $mode == "worst" then $FL | worst
elif $mode == "json" then {generated: $C.now, version: $C.version, thresholds: $T, summary: $SUM, flags: $FL, servers: $SV} | tojson
elif $mode == "csv_summary" then
  (["server","target","status","type","version","host","uptime","primary","members_ok","max_lag_s","oplog_window_h","conn_pct","cache_used_pct","cache_dirty_pct","max_disk_pct","long_ops","crit","warn","collected_utc"] | csvrow),
  ($SUM[] | [.server, .target, .status, .type, .version, .host, .uptime, .primary, .members, .max_lag_s, .oplog_h, .conn_pct, .cache_used_pct, .cache_dirty_pct, .disk_pct, .long_ops, .crit, .warn, (.collected_at | utc)] | csvrow)
elif $mode == "csv_flags" then (["severity","flag","server","object","detail"] | csvrow), ($FL[] | [.sev, .code, .server, .object, .detail] | csvrow)
elif $mode == "text" then
  "MongoDB health report · \($C.now | both)",
  "",
  ($SUM[] | "  \(.status | . + (" " * (5 - length)))  \(.server)  \(.type)  v\(.version)  primary=\(.primary)  members=\(.members)  lag=\(.max_lag_s | if . == null then "-" else dur end)  oplog=\(.oplog_h | if . == null then "-" else "\(.)h" end)  conn=\(.conn_pct | p)  disk=\(.disk_pct | p)  CRIT=\(.crit) WARN=\(.warn)"),
  "",
  (if ($FL | length) == 0 then "No flags." else "Flags (\($FL | length)):", ($FL[] | "  [\(.sev)] \(.code)  \(.server)  \(.object)  - \(.detail)") end)
else
# ---------------------------------------------------------------- html
def badge: "<span class=\"sev \(.)\">\(.)</span>";
def cell($v; $l): "<td class=\"\($l // "")\">\($v)</td>";
def kv($k; $v): "<tr><th>\($k)</th><td>\($v)</td></tr>";
def sevcls($v; $w; $c): (lvl($v; $w; $c) // "") ;
"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>MongoDB health report</title><style>
body{font:13px/1.4 system-ui,Segoe UI,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1d2330}
header{background:#1f3b5b;color:#fff;padding:12px 20px}header h1{margin:0;font-size:18px}header .m{opacity:.85;font-size:12px}
.bar{position:sticky;top:0;z-index:5;background:#fff;border-bottom:1px solid #d8dce3;padding:8px 20px;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.bar select,.bar button,.bar label{padding:4px 8px;font-size:13px}
main{padding:12px 20px}h2{font-size:15px;margin:16px 0 6px}h3{font-size:13px;margin:12px 0 4px;color:#1f3b5b}
table{border-collapse:collapse;width:100%;background:#fff;margin:4px 0}th,td{border:1px solid #e1e4ea;padding:3px 6px;text-align:left;vertical-align:top}
th{background:#eef1f5;font-weight:600}td.n,th.n{text-align:right;white-space:nowrap}
table.kv{width:auto;min-width:320px}table.kv th{width:190px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:10px}
details.card{background:#fff;border:1px solid #d8dce3;border-radius:6px;margin:10px 0}
details.card>summary{cursor:pointer;padding:8px 12px;font-size:14px}details.card[open]>summary{border-bottom:1px solid #e1e4ea;background:#f0f4fa}
.cb{padding:4px 12px 12px}.k{color:#56607a;font-size:12px}.err{color:#b00020}
.sev{display:inline-block;padding:0 6px;border-radius:3px;font-size:11px;font-weight:700}
.sev.CRIT{background:#c0392b;color:#fff}.sev.WARN{background:#f0b429;color:#1d2330}.sev.INFO{background:#d9e2ec}.sev.OK{background:#2e8b57;color:#fff}
td.CRIT{background:#fbe3e1;color:#8a1c12;font-weight:600}td.WARN{background:#fff4d6;font-weight:600}td.OK{background:#e5f4ea}
tr.self td:first-child{font-weight:700}.tag{font-size:11px;border:1px solid #b9c0cc;border-radius:3px;padding:0 4px;margin-left:6px;color:#56607a}
code{font:12px ui-monospace,Consolas,monospace;word-break:break-all}.hidden{display:none!important}
footer{padding:10px 20px 20px;color:#56607a;font-size:12px}
@media (prefers-color-scheme:dark){body{background:#14181f;color:#dfe5ee}table,details.card,.bar{background:#1b212b;border-color:#2c3542}th{background:#232b37}th,td{border-color:#2c3542}
details.card[open]>summary{background:#212a36;border-color:#2c3542}.k,footer,.tag{color:#9aa6b8}h3{color:#8fb4e0}td.CRIT{background:#4a1d1a;color:#ffb4a9}td.WARN{background:#463a12;color:#ffe08a}td.OK{background:#1d3a28}.sev.INFO{background:#33404f;color:#dfe5ee}}
</style></head><body>
<header><h1>MongoDB health report</h1><div class=\"m\">Generated \($C.now | utc) · \($C.now | ist) · runner \($C.runner | esc) · v\($C.version) · read-only diagnostics · \($SUM | length) target(s): \([$SUM[] | select(.status == "CRIT")] | length) CRIT, \([$SUM[] | select(.status == "WARN")] | length) WARN, \([$SUM[] | select(.status == "OK")] | length) OK</div></header>
<div class=\"bar\"><select id=\"fs\"><option value=\"\">All servers</option>\($SUM | map("<option>\(.server | esc)</option>") | join(""))</select>
<select id=\"fsev\"><option value=\"\">Flags: all</option><option value=\"CRIT\">CRIT only</option><option value=\"WARN\">WARN and CRIT</option></select>
<button id=\"ex\">Expand all</button><button id=\"co\">Collapse all</button><span class=\"k\">Thresholds: lag \($T.lag_warn)/\($T.lag_crit)s · oplog &lt;\($T.oplog_warn)/\($T.oplog_crit)h · conns \($T.conn_warn)/\($T.conn_crit)% · cache dirty \($T.dirty_warn)/\($T.dirty_crit)% · cache used \($T.cache_warn)% · disk \($T.disk_warn)/\($T.disk_crit)% · long ops ≥\($T.long_op)s · queue ≥\($T.queue_warn)</span></div><main>
<h2>Summary</h2><table id=\"sum\"><tr><th>Server</th><th>Status</th><th>Type</th><th>Version</th><th>Connected to</th><th>Uptime</th><th>Primary</th><th>Members ok</th><th class=\"n\">Max lag</th><th class=\"n\">Oplog window</th><th class=\"n\">Conns</th><th class=\"n\">Cache used / dirty</th><th class=\"n\">Max disk used</th><th class=\"n\">Long ops</th><th class=\"n\">CRIT</th><th class=\"n\">WARN</th></tr>
\($SUM | map("<tr data-server=\"\(.server | esc)\"><td><a href=\"#srv-\(.server | esc)\">\(.server | esc)</a><div class=\"k\">\(.target | esc)</div></td><td class=\"\(.status)\">\(.status | badge)</td><td>\(.type | esc)</td><td>\(.version | esc)</td><td>\(.host | esc)</td><td>\(.uptime)</td>"
  + "<td class=\"\(if .primary == "NONE" then "CRIT" else "" end)\">\(.primary | esc)</td>"
  + "<td class=\"\(if .members != "-" and (.members | split("/") | .[0] != .[1]) then "CRIT" else "" end)\">\(.members)</td>"
  + "<td class=\"n \(sevcls(.max_lag_s; $T.lag_warn; $T.lag_crit))\">\(.max_lag_s | if . == null then "-" else dur end)</td>"
  + "<td class=\"n \(if .oplog_h == null then "" else sevcls(- .oplog_h; - $T.oplog_warn; - $T.oplog_crit) end)\">\(.oplog_h | if . == null then "-" else "\(.) h" end)</td>"
  + "<td class=\"n \(sevcls(.conn_pct; $T.conn_warn; $T.conn_crit))\">\(.conn_pct | p)</td>"
  + "<td class=\"n \(sevcls(.cache_dirty_pct; $T.dirty_warn; $T.dirty_crit))\">\(.cache_used_pct | p) / \(.cache_dirty_pct | p)</td>"
  + "<td class=\"n \(sevcls(.disk_pct; $T.disk_warn; $T.disk_crit))\">\(.disk_pct | p)</td>"
  + "<td class=\"n \(if .long_ops > 0 then "WARN" else "" end)\">\(.long_ops)</td><td class=\"n\">\(.crit)</td><td class=\"n\">\(.warn)</td></tr>") | join(""))</table>
<h2>Risk flags (\($FL | length))</h2>\(if ($FL | length) == 0 then "<p class=\"k\">No flags raised.</p>" else "<table id=\"flags\"><tr><th>Severity</th><th>Flag</th><th>Server</th><th>Object</th><th>Detail</th></tr>"
  + ($FL | map("<tr class=\"fl\" data-sev=\"\(.sev)\" data-server=\"\(.server | esc)\"><td>\(.sev | badge)</td><td><code>\(.code)</code></td><td>\(.server | esc)</td><td>\(.object | esc)</td><td>\(.detail | esc)</td></tr>") | join("")) + "</table>" end)
<h2>Details</h2>"
+ ([$SV[] | . as $s | .data as $x
  | "<details class=\"card\" open id=\"srv-\(.name | esc)\" data-server=\"\(.name | esc)\"><summary>\(.status | badge) <b>\(.name | esc)</b><span class=\"tag\">\(.target | esc)</span>"
    + (if $x.ok then "<span class=\"tag\">\(if $x.repl then "replica set " + ($x.repl.set | esc) else "standalone" end)</span><span class=\"tag\">v\($x.server.version // "?" | esc)</span><span class=\"tag\">collected \($x.collected_at | utc) · \($x.collected_at | ist)</span>" else "" end) + "</summary><div class=\"cb\">"
    + (if ($x.ok | not) then "<p class=\"err\"><b>Not reachable:</b> \($x.error | esc)</p>"
      else
        "<div class=\"grid\"><div><h3>Server</h3><table class=\"kv\">"
        + kv("Connected to"; ($x.server.host // "-" | esc) + (if $x.server.is_writable_primary then " <span class=\"tag\">PRIMARY</span>" elif $x.server.secondary then " <span class=\"tag\">SECONDARY</span>" else "" end))
        + kv("Version / FCV"; "\($x.server.version // "-" | esc) / \($x.server.fcv // "-" | esc)\(if ($x.server.modules | length) > 0 then " (" + ($x.server.modules | join(",") | esc) + ")" else "" end)")
        + kv("Storage engine"; $x.server.storage_engine // "-" | esc) + kv("Uptime"; $x.server.uptime_s | dur) + kv("Server time"; $x.server.local_time | both)
        + kv("OS / CPUs / RAM"; "\($x.server.os // "-" | esc) / \($x.server.cpus | d) / \(if $x.server.mem_mb then ($x.server.mem_mb * 1048576 | hb) else "-" end)")
        + kv("dbPath"; "<code>\($x.cmdline.dbpath // "-" | esc)</code>") + kv("Log"; "<code>\($x.cmdline.logpath // "-" | esc)</code>") + kv("Config file"; "<code>\($x.cmdline.config // "-" | esc)</code>")
        + kv("Port / bindIp"; "\($x.cmdline.port | d) / \($x.cmdline.bind_ip // "-" | esc)") + kv("Authorization"; if $x.cmdline.auth then "enabled" else "<span class=\"err\">not enabled</span>" end)
        + "</table></div><div><h3>Load</h3><table class=\"kv\">"
        + "<tr><th>Connections</th><td class=\"\(sevcls($x.conns.pct; $T.conn_warn; $T.conn_crit))\">\($x.conns.current | hn) current · \($x.conns.available | hn) available · \($x.conns.pct | p) used · \($x.conns.active | hn) active · \($x.conns.total_created | hn) created</td></tr>"
        + kv("Memory resident / virtual"; "\(if $x.mem.resident_mb then ($x.mem.resident_mb * 1048576 | hb) else "-" end) / \(if $x.mem.virtual_mb then ($x.mem.virtual_mb * 1048576 | hb) else "-" end)")
        + "<tr><th>WiredTiger cache</th><td class=\"\([sevcls($x.cache.dirty_pct; $T.dirty_warn; $T.dirty_crit), sevcls($x.cache.used_pct; $T.cache_warn; null)] | map(select(. != "")) | (if index("CRIT") then "CRIT" elif length > 0 then "WARN" else "" end))\">\($x.cache.used_bytes | hb) of \($x.cache.max_bytes | hb) (\($x.cache.used_pct | p)) · dirty \($x.cache.dirty_bytes | hb) (\($x.cache.dirty_pct | p))</td></tr>"
        + kv("Cache pages read in / app evictions"; "\($x.cache.read_into | hn) / \($x.cache.evicted_app | hn)")
        + "<tr><th>Global lock queue</th><td class=\"\(if ($x.queues.total // 0) >= $T.queue_warn then "WARN" else "" end)\">readers \($x.queues.readers | d) · writers \($x.queues.writers | d) · active R/W \($x.queues.active_readers | d)/\($x.queues.active_writers | d)</td></tr>"
        + kv("Tickets out / available"; "read \($x.queues.tickets_read_out | d)/\($x.queues.tickets_read_avail | d) · write \($x.queues.tickets_write_out | d)/\($x.queues.tickets_write_avail | d)")
        + kv("Page faults"; $x.page_faults | hn)
        + kv("Asserts"; if $x.asserts then "regular \($x.asserts.regular) · warning \($x.asserts.warning) · msg \($x.asserts.msg) · user \($x.asserts.user | hn) · rollovers \($x.asserts.rollovers)" else "-" end)
        + kv("Network in / out"; "\($x.network.bytes_in | hb) / \($x.network.bytes_out | hb) · \($x.network.requests | hn) requests")
        + "</table></div><div><h3>Opcounters (since startup)</h3><table><tr><th></th><th class=\"n\">insert</th><th class=\"n\">query</th><th class=\"n\">update</th><th class=\"n\">delete</th><th class=\"n\">getmore</th><th class=\"n\">command</th></tr>"
        + ([["client", $x.opcounters], ["replicated", $x.opcounters_repl]] | map(select(.[1] != null) | "<tr><th>\(.[0])</th>" + (.[1] as $o | ["insert","query","update","delete","getmore","command"] | map("<td class=\"n\">\($o[.] | hn)</td>") | join("")) + "</tr>") | join(""))
        + "</table></div></div>"
        # ---- replica set
        + (if $x.repl then $x.repl as $r
            | "<h3>Replica set \($r.set | esc) · term \($r.term | d) · config v\($r.config_version | d) · lag measured against \($r.lag_reference)</h3><table><tr><th>Member</th><th>State</th><th class=\"n\">Health</th><th class=\"n\">Uptime</th><th>Last applied (optime)</th><th class=\"n\">Lag</th><th>Last heartbeat</th><th class=\"n\">Ping</th><th>Sync source</th><th class=\"n\">Priority</th><th class=\"n\">Votes</th><th>Hidden</th><th>Arbiter</th><th class=\"n\">Delay</th><th>Tags / message</th></tr>"
            + ($r.members | map(. as $m | ((($m.lag_s // 0) - ($m.delay_s // 0)) | if . < 0 then 0 else . end) as $eff
                | "<tr class=\"\(if .self then "self" else "" end)\"><td>\(.name | esc)\(if .self then " <span class=\"tag\">connected</span>" else "" end)</td>"
                + "<td class=\"\(if .health != 1 then "CRIT" elif (.state | okstate | not) then "WARN" else "OK" end)\">\(.state_str | esc)</td><td class=\"n \(if .health != 1 then "CRIT" else "" end)\">\(.health | d)</td><td class=\"n\">\(.uptime_s | dur)</td><td>\(.optime | utc)</td>"
                + "<td class=\"n \(if .state == 2 then sevcls($eff; $T.lag_warn; $T.lag_crit) else "" end)\">\(if .lag_s == null then "-" else (.lag_s | dur) end)</td><td>\(if .self then "(self)" else (.last_heartbeat | utc) end)</td><td class=\"n\">\(if .ping_ms == null then "-" else "\(.ping_ms) ms" end)</td>"
                + "<td>\(.sync_source // "-" | esc)</td><td class=\"n\">\(.priority | d)</td><td class=\"n\">\(.votes | d)</td><td>\(if .hidden then "yes" else "" end)</td><td>\(if .arbiter then "yes" else "" end)</td><td class=\"n\">\(if .delay_s > 0 then "\(.delay_s)s" else "" end)</td>"
                + "<td>\(.tags | to_entries | map("\(.key)=\(.value)") | join(", ") | esc)\(if .info then " <span class=\"k\">" + (.info | esc) + "</span>" else "" end)</td></tr>") | join("")) + "</table>"
            + "<p class=\"k\">Voting members \($r.voting_members | d), majority \($r.majority_vote_count | d), election timeout \($r.election_timeout_ms | d) ms, heartbeat \($r.heartbeat_ms | d) ms, writeConcernMajorityJournalDefault \($r.write_concern_majority_journal | d). Lag for delayed members is flagged only beyond their delay.</p>"
            + (if $x.oplog then "<h3>Oplog</h3><table class=\"kv\">"
                + "<tr><th>Window</th><td class=\"\(if $x.oplog.window_h == null then "" else sevcls(- $x.oplog.window_h; - $T.oplog_warn; - $T.oplog_crit) end)\">\($x.oplog.window_h | if . == null then "-" else "\(.) hours (\(. * 3600 | dur))" end)</td></tr>"
                + kv("First entry"; $x.oplog.first | both) + kv("Last entry"; $x.oplog.last | both)
                + kv("Size used / configured"; "\($x.oplog.size_bytes | hb) / \($x.oplog.max_bytes | hb) (\($x.oplog.used_pct | p))\(if $x.oplog.stats_error then " <span class=\"err\">" + ($x.oplog.stats_error | esc) + "</span>" else "" end)")
                + kv("On disk (compressed)"; $x.oplog.storage_bytes | hb) + kv("oplogMinRetentionHours"; $x.cmdline.oplog_min_retention_h | d) + "</table>"
              elif $x.errors.oplog then "<h3>Oplog</h3><p class=\"err\">\($x.errors.oplog | esc) - grant <code>{ role: \"read\", db: \"local\" }</code> to measure the oplog window.</p>" else "" end)
            + (if ($x.members_direct // []) | length > 0 then "<h3>Each member (direct connection)</h3><table><tr><th>Member</th><th>Host</th><th>Version</th><th class=\"n\">Uptime</th><th class=\"n\">Conns</th><th class=\"n\">Resident</th><th class=\"n\">Cache used</th><th class=\"n\">Cache dirty</th><th class=\"n\">Queue R/W</th><th class=\"n\">Page faults</th><th class=\"n\">Data disk used</th><th class=\"n\">Data disk free</th><th>dbPath</th></tr>"
                + ($x.members_direct | map(if .skipped then "<tr><td>\(.name | esc)</td><td colspan=\"12\" class=\"k\">skipped: \(.skipped)</td></tr>"
                    elif .ok | not then "<tr><td>\(.name | esc)</td><td colspan=\"12\" class=\"err\">\(.error | esc)</td></tr>"
                    else "<tr><td>\(.name | esc)</td><td>\(.host | esc)</td><td>\(.version | esc)</td><td class=\"n\">\(.uptime_s | dur)</td><td class=\"n \(sevcls(.conn_pct; $T.conn_warn; $T.conn_crit))\">\(.conn_current | hn) (\(.conn_pct | p))</td><td class=\"n\">\(if .resident_mb then (.resident_mb * 1048576 | hb) else "-" end)</td>"
                      + "<td class=\"n \(sevcls(.cache_used_pct; $T.cache_warn; null))\">\(.cache_used_pct | p)</td><td class=\"n \(sevcls(.cache_dirty_pct; $T.dirty_warn; $T.dirty_crit))\">\(.cache_dirty_pct | p)</td><td class=\"n\">\(.queue_r | d)/\(.queue_w | d)</td><td class=\"n\">\(.page_faults | hn)</td>"
                      + "<td class=\"n \(sevcls(.fs_pct; $T.disk_warn; $T.disk_crit))\">\(.fs_pct | p)</td><td class=\"n\">\(if .fs_total then ((.fs_total - .fs_used) | hb) + " of " + (.fs_total | hb) else "-" end)</td><td><code>\(.dbpath // "-" | esc)</code></td></tr>" end) | join("")) + "</table>" else "" end)
          else "" end)
        # ---- disk
        + "<h3>Disk free</h3>"
        + (if $x.fs then "<table class=\"kv\"><tr><th>Data filesystem (dbStats, \($x.server.host // "" | esc))</th><td class=\"\(sevcls($x.fs.pct; $T.disk_warn; $T.disk_crit))\">\($x.fs.pct | p) used · \(($x.fs.total_bytes - $x.fs.used_bytes) | hb) free of \($x.fs.total_bytes | hb)</td></tr></table>" else "<p class=\"k\">dbStats did not report filesystem sizes.</p>" end)
        + (if $s.ssh then ($s.ssh | map(. as $h | if .ok | not then "<p class=\"err\">df on \(.dest | esc): \(.error | esc)</p>"
              else "<table><tr><th colspan=\"7\">df on \(.dest | esc)\(if .member then " (member " + (.member | esc) + ")" else "" end) over SSH</th></tr><tr><th>Mount</th><th>Filesystem</th><th>Type</th><th class=\"n\">Size</th><th class=\"n\">Used</th><th class=\"n\">Free</th><th class=\"n\">Used %</th></tr>"
                + (.mounts | map(. as $mt | ([$h.paths[]? | select(.mount == $mt.mount) | .kind] | unique) as $k
                    | "<tr><td><code>\(.mount | esc)</code>\($k | map(" <span class=\"tag\">" + . + "</span>") | join(""))</td><td>\(.fs | esc)</td><td>\(.type | esc)</td><td class=\"n\">\(.size_kb | hkb)</td><td class=\"n\">\(.used_kb | hkb)</td><td class=\"n\">\(.avail_kb | hkb)</td><td class=\"n \(sevcls(.pct; $T.disk_warn; $T.disk_crit))\">\(.pct | d)%</td></tr>") | join(""))
                + ([.paths[]? | select(.error) | "<tr><td colspan=\"7\" class=\"err\">\(.kind) <code>\(.path | esc)</code>: \(.error | esc)</td></tr>"] | join("")) + "</table>" end) | join(""))
          else "<p class=\"k\">No SSH df for this target (add <code>ssh=auto</code> or <code>ssh=user@host</code> in servers.conf to include every mount).</p>" end)
        # ---- long ops
        + "<h3>Operations running ≥ \($T.long_op)s (\(($x.long_ops // []) | length))</h3>"
        + (if (($x.long_ops // []) | length) == 0 then (if $x.errors.currentOp then "<p class=\"err\">\($x.errors.currentOp | esc)</p>" else "<p class=\"k\">None.</p>" end)
          else "<table><tr><th>opid</th><th class=\"n\">Seconds</th><th>Op</th><th>Namespace</th><th>Client / app / user</th><th>Plan</th><th>Waiting for lock</th><th>Command (truncated)</th></tr>"
            + ($x.long_ops | map("<tr><td><code>\(.opid | esc)</code></td><td class=\"n WARN\">\(.secs | d)</td><td>\(.op // "-" | esc)</td><td>\(.ns // "-" | esc)</td><td>\(.client // "-" | esc)<div class=\"k\">\(.app // "" | esc) \(.user // "" | esc) \(.desc // "" | esc)</div></td><td>\(.plan // "-" | esc)</td><td>\(if .waiting_lock then "yes" else "" end)</td><td><code>\(.command // "" | esc)</code></td></tr>") | join("")) + "</table>" end)
        # ---- databases
        + "<h3>Databases (\($x.dbs | length))</h3><table><tr><th>Database</th><th class=\"n\">Collections</th><th class=\"n\">Views</th><th class=\"n\">Documents</th><th class=\"n\">Data size</th><th class=\"n\">Storage size</th><th class=\"n\">Indexes</th><th class=\"n\">Index size</th><th class=\"n\">Storage + index</th></tr>"
        + ($x.dbs | sort_by(-((.storage_bytes // 0) + (.index_bytes // 0))) | map("<tr><td>\(.name | esc)</td><td class=\"n\">\(.collections | hn)</td><td class=\"n\">\(.views | hn)</td><td class=\"n\">\(.objects | hn)</td><td class=\"n\">\(.data_bytes | hb)</td><td class=\"n\">\(.storage_bytes | hb)</td><td class=\"n\">\(.indexes | hn)</td><td class=\"n\">\(.index_bytes | hb)</td><td class=\"n\">\(((.storage_bytes // 0) + (.index_bytes // 0)) | hb)</td></tr>") | join(""))
        + "<tr><th>Total</th><td class=\"n\">\([$x.dbs[].collections // 0] | add // 0 | hn)</td><td class=\"n\">\([$x.dbs[].views // 0] | add // 0 | hn)</td><td class=\"n\">\([$x.dbs[].objects // 0] | add // 0 | hn)</td><td class=\"n\">\([$x.dbs[].data_bytes // 0] | add // 0 | hb)</td><td class=\"n\">\([$x.dbs[].storage_bytes // 0] | add // 0 | hb)</td><td class=\"n\">\([$x.dbs[].indexes // 0] | add // 0 | hn)</td><td class=\"n\">\([$x.dbs[].index_bytes // 0] | add // 0 | hb)</td><td class=\"n\">\([$x.dbs[] | (.storage_bytes // 0) + (.index_bytes // 0)] | add // 0 | hb)</td></tr></table>"
        + "<h3>Top \($C.top) collections by storage + index size\(if $x.colls_truncated then " <span class=\"k\">(stopped after \($x.colls_scanned) collections - raise --max-collections)</span>" else "" end)</h3>"
        + (if ($x.top_colls | length) == 0 then "<p class=\"k\">No user collections.</p>" else "<table><tr><th>Namespace</th><th class=\"n\">Documents</th><th class=\"n\">Avg doc</th><th class=\"n\">Data size</th><th class=\"n\">Storage size</th><th class=\"n\">Indexes</th><th class=\"n\">Index size</th></tr>"
          + ($x.top_colls | map("<tr><td>\(.ns | esc)\(if .capped then " <span class=\"tag\">capped</span>" else "" end)</td><td class=\"n\">\(.count | hn)</td><td class=\"n\">\(.avg_obj | hb)</td><td class=\"n\">\(.data_bytes | hb)</td><td class=\"n\">\(.storage_bytes | hb)</td><td class=\"n\">\(.indexes | d)</td><td class=\"n\">\(.index_bytes | hb)</td></tr>") | join("")) + "</table>" end)
        + (if ($x.errors | length) > 0 then "<h3>Sections not collected</h3><table><tr><th>Section</th><th>Error</th></tr>" + ($x.errors | to_entries | map("<tr><td>\(.key | esc)</td><td class=\"err\">\(.value | esc)</td></tr>") | join("")) + "</table>" else "" end)
      end)
    + "</div></details>"] | join(""))
+ "</main><footer>Generated by mongo_health_report.sh v\($C.version) using read-only diagnostic commands (hello, serverStatus, replSetGetStatus, replSetGetConfig, currentOp, dbStats, $collStats, first/last oplog entry)\(if ([$SV[].ssh] | map(select(. != null)) | length) > 0 then " and df over SSH" else "" end). Counters such as opcounters, asserts and page faults are cumulative since each mongod started.</footer>
<script>
(function(){var fs=document.getElementById('fs'),fv=document.getElementById('fsev');
function rank(s){return s==='CRIT'?3:s==='WARN'?2:1}
function apply(){var s=fs.value,v=fv.value;
document.querySelectorAll('[data-server]').forEach(function(e){var hide=s&&e.getAttribute('data-server')!==s;
if(!hide&&v&&e.classList.contains('fl'))hide=rank(e.getAttribute('data-sev'))<rank(v);e.classList.toggle('hidden',!!hide)})}
fs.onchange=apply;fv.onchange=apply;
document.getElementById('ex').onclick=function(){document.querySelectorAll('details.card').forEach(function(d){d.open=true})};
document.getElementById('co').onclick=function(){document.querySelectorAll('details.card').forEach(function(d){d.open=false})};})();
</script></body></html>"
end
