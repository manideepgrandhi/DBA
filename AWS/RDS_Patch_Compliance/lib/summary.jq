# lib/summary.jq - rendering for rds_patch_compliance_summary.sh (high-level summary + NON-COMPLIANT list)
# Input: the finalized JSON report of rds_patch_compliance_report.sh (all counting is done there, with
# lib/compliance.jq + lib/versions.jq, so the numbers are identical). Modes ($mode): text | html | csv_nc | csv_summary | csv_regions | csv_accounts | alert
# A --merge report (meta.merge) adds the merged input files; per-account rows come from summary.accounts.
include "versions" {search: "./"};
def h: tostring | @html;
def dash: if . == null or . == "" then "-" else tostring end;
def pad($n): tostring | if length >= $n then . else . + (" " * ($n - length)) end;
def rpad($n): tostring | if length >= $n then . else (" " * ($n - length)) + . end;
def nc_rows: [.rows[] | select(.compliance_status == "NON-COMPLIANT")]
             | sort_by([-(.versions_behind // 0), (.identifier | ascii_downcase), .account_id, .region]);
def unk_rows: [.rows[] | select(.compliance_status == "UNKNOWN")] | sort_by([(.identifier | ascii_downcase), .account_id, .region]);
def why: if .deprecated_version then "current version not returned by RDS (deprecated / not offered in region)"
         else (.note | split("; ")[0] | if . == "" then "lookup failed" else . end) end;
def rule($s): "NON-COMPLIANT when the current version is more than \($s.max_behind) valid minor versions behind the latest (\($s.max_behind + 1) or more); counted from RDS ValidUpgradeTarget (same major; Oracle: same patch line)";
def accts: .meta.accounts | map("\(.account) (\(.profile))") | join(", ");
# region-wise breakdown (summary.regions / regions_total / region_overview, built by compliance.jq finalize).
# Rows (txt / html / csv_regions) are only regions with databases or an AWS error; empty regions are only counted.
# Region NAMES are never listed in the header (only "Regions: N checked, ..."); JSON from the report keeps everything.
def ro: .summary.region_overview // {checked: (.meta.regions | length), with_databases: 0, empty: 0, error: 0, empty_regions: [], mode: "explicit"};
def multi: (.meta.accounts | length) > 1;
def region_line: "\(.checked) checked, \(.with_databases) with databases, \(.empty) empty, \(.error) error\(if .error == 1 then "" else "s" end)"
  + ({"discover": " (discovery probe)", "full": " (all scanned in full, --no-discover)", "explicit": "", "merge": " (merged from saved data)"}[.mode] // "");
def merged: .meta.merge != null;
def acct_rows: .summary.accounts // [];
def src_state: if (.used | length) > 0 and (.superseded | length) == 0 then "used"
               elif (.used | length) == 0 then "superseded (newer data used)" else "partly used" end;
def merge_line: "\(.meta.merge.files) file(s), offline (0 AWS calls); days counted from \(.meta.generated_utc)";
def shown_regions: [.summary.regions // [] | .[] | select(.status != "empty")];
def pct_txt: if . == null then "-" else "\(.)%" end;
def pctc: if . == null then "" elif . >= 100 then "ok" elif . >= 80 then "warn" else "bad" end;
def latest_txt: (.latest_minor // "-") | gsub("; "; " | ");

def text:
  . as $r | $r.summary as $s | nc_rows as $nc | unk_rows as $uk
  | ($s.engines | map(.engine | length) | max // 6 | [., 6] | max + 2) as $ew
  | [ "RDS PATCH COMPLIANCE - SUMMARY",
      "Run      : \($r.meta.generated_utc) / \($r.meta.generated_local)",
      (if $r | merged then "Merged   : \($r | merge_line); accounts \($r | accts)" else
      "Scanned  : accounts \($r | accts)" + (if ($r | ro).mode == "explicit" then "; regions \($r.meta.regions | join(", "))" else "; all enabled regions" end) + (if $r.meta.filters_text != "" then "; filters: \($r.meta.filters_text)" else "" end) end),
      "Rule     : " + rule($s),
      "",
      "Regions  : \($r | ro | region_line)",
      "",
      "OVERALL  : \($s.total) servers/clusters | COMPLIANT \($s.compliant) | NON-COMPLIANT \($s.non_compliant) | UNKNOWN \($s.unknown) | \($s.pct_compliant)% compliant",
      "",
      "PER ACCOUNT",
      "  " + ("ACCOUNT" | pad(14)) + ("NAME" | pad(14)) + ("COLLECTED" | pad(22)) + ("REGIONS" | rpad(8)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + ("%COMPL" | rpad(8)) + ("PEND" | rpad(6)),
      ( $r | acct_rows[] | "  " + (.account_id | pad(14)) + (.profile | dash | pad(14)) + (.collected_utc | dash | pad(22)) + (.regions_with_databases | rpad(8))
          + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6)) + (.pct_compliant | pct_txt | rpad(8)) + (.with_pending | rpad(6))
          + (if .errors > 0 then "  \(.errors) AWS error(s)" else "" end) ),
      "",
      "PER REGION",
      "  " + ("ACCOUNT" | pad(14)) + ("REGION" | pad(16)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + ("%COMPL" | rpad(8)) + ("PEND" | rpad(6)),
      ( ($r | shown_regions) + [$s.regions_total // empty] | .[]
        | "  " + (.account_id | pad(14)) + (.region | pad(16)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6))
          + (.pct_compliant | pct_txt | rpad(8)) + (.with_pending | rpad(6)) + (if .status == "error" then "  AWS error - see ERRORS" else "" end) ),
      "",
      "PER ENGINE",
      "  " + ("ENGINE" | pad($ew)) + ("MAJOR" | pad(8)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + ("  %COMPL" | rpad(9)) + "  LATEST MINOR",
      ( $s.engines[] | . as $e
        | ("  " + ($e.engine | pad($ew)) + ("all" | pad(8)) + ($e.total | rpad(6)) + ($e.compliant | rpad(7)) + ($e.non_compliant | rpad(7)) + ($e.unknown | rpad(6)) + ("\($e.pct_compliant)%" | rpad(9))),
          ($e.majors[] | "  " + ("" | pad($ew)) + (.major | pad(8)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6)) + ("" | rpad(9)) + "  " + latest_txt) ),
      "",
      "KEY FLAGS: past standard support (Extended Support charges) \($s.past_standard_support) | standard support ending within \($s.warn_days) days \($s.nearing_end_of_support) | auto minor upgrade off \($s.auto_minor_off) | pending maintenance \($s.with_pending)" + (if $s.errors > 0 then " | AWS errors \($s.errors)" else "" end),
      "",
      ( if ($nc | length) == 0 then "*** All servers compliant (no server is more than \($s.max_behind) minor versions behind) ***"
        else "!!! NON-COMPLIANT SERVERS (\($nc | length)) - most behind first",
             ( ($nc | map(.region | length) | max) as $rw | ($nc | map(.engine | length) | max) as $gw | ($nc | map(.identifier | length) | max) as $iw
               | ($nc | map("\(.current_version) -> \(.latest_minor_version | dash)" | length) | max) as $vw
               | ("   " + ("ACCOUNT" | pad(14)) + ("REGION" | pad($rw + 2)) + ("ENGINE" | pad($gw + 2)) + ("IDENTIFIER" | pad($iw + 2)) + ("CURRENT -> LATEST MINOR" | pad($vw + 2)) + "BEHIND  SUPPORT"),
                 ($nc[] | "!! " + (.account_id | pad(14)) + (.region | pad($rw + 2)) + (.engine | pad($gw + 2)) + (.identifier | pad($iw + 2))
                          + ("\(.current_version) -> \(.latest_minor_version | dash)" | pad($vw + 2)) + (.versions_behind | rpad(6)) + "  " + .support_flag) ) end ),
      ( if ($uk | length) > 0 then "", "UNKNOWN (\($uk | length))", ($uk[] | "?  \(.account_id)  \(.region)  \(.engine)  \(.identifier)  \(.current_version): \(why)") else empty end ),
      ( if $r | merged then "", "MERGED INPUTS (\($r.meta.merge.files))",
          ($r.meta.merge.sources[] | "   \(.file)  collected \(.collected_utc)  account(s) \((.used + .superseded) | join(", "))  \(src_state)") else empty end ),
      ( if ($r.errors | length) > 0 then "", "ERRORS", ($r.errors[] | "   \(.profile)/\(.region): \(.call): \(.message)") else empty end ),
      "",
      "Read-only summary; full per-server details: rds_patch_compliance_report.sh" ] | join("\n");

def card($l; $v; $cls; $sub): "<div class=\"card \($cls)\"><div class=\"v\">\($v | h)</div><div class=\"l\">\($l | h)</div><div class=\"s\">\($sub | h)</div></div>";
def html:
  . as $r | $r.summary as $s | nc_rows as $nc | unk_rows as $uk
  | "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>RDS patch compliance summary - \($r.meta.generated_utc | h)</title><style>"
  + "body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1f2933}header{background:#232f3e;color:#fff;padding:16px 26px}header h1{margin:0;font-size:21px}header p{margin:4px 0 0;color:#c9d1d9;font-size:13px}"
  + "main{padding:16px 26px;max-width:1300px}.rule{background:#fff;border-left:4px solid #232f3e;padding:8px 12px;font-size:13px;margin-bottom:14px}"
  + ".cards{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:16px}.card{background:#fff;border-radius:10px;padding:12px 16px;min-width:140px;box-shadow:0 1px 3px rgba(0,0,0,.12);border-top:4px solid #9aa5b1}.card .v{font-size:26px;font-weight:700}.card .l{font-size:13px;font-weight:600}.card .s{font-size:12px;color:#52606d}"
  + ".card.ok{border-color:#2e7d32}.card.bad{border-color:#c62828}.card.bad .v{color:#c62828}.card.warn{border-color:#e08a00}.card.unk{border-color:#7b8794}"
  + "table{border-collapse:collapse;background:#fff;font-size:13px;box-shadow:0 1px 3px rgba(0,0,0,.12);margin-bottom:18px}th{background:#e9edf2;text-align:left;padding:6px 9px}td{padding:6px 9px;border-top:1px solid #e6e9ee}"
  + "td.n{text-align:right}.mono{font-family:SFMono-Regular,Consolas,monospace;font-size:12px}tr.eng td{font-weight:700;background:#f8f9fb}td.bad{color:#c62828;font-weight:700}td.ok{color:#2e7d32}"
  + "table.nc{border:2px solid #c62828}table.nc th{background:#c62828;color:#fff}table.nc tr td{background:#fdecea}h2{font-size:16px;margin:16px 0 6px}h2.bad{color:#c62828}"
  + ".allok{background:#e6f4ea;color:#1b5e20;border:2px solid #2e7d32;border-radius:8px;padding:12px 16px;font-weight:700;margin-bottom:16px}footer{padding:8px 26px 22px;color:#7b8794;font-size:12px}"
  + "table.sortable th{cursor:pointer}td.warn{color:#b26a00;font-weight:600}tfoot td{border-top:2px solid #232f3e;background:#f0f3f7;font-weight:600}h2 .sub{font-size:12px;font-weight:400;color:#52606d}"
  + ".err{background:#fdecea;color:#c62828;border-radius:8px;padding:1px 6px;font-size:11px;font-weight:600}</style></head><body>"
  + "<header><h1>RDS patch compliance - summary</h1><p>\($r.meta.generated_utc | h) &middot; \($r.meta.generated_local | h) &middot; accounts \($r | accts | h) &middot; Regions: \($r | ro | region_line | h)\(if $r | merged then " &middot; merged from \($r.meta.merge.files) file(s)" else "" end)\(if $r.meta.filters_text != "" then " &middot; filters: " + ($r.meta.filters_text | h) else "" end)</p></header><main>"
  + "<div class=\"rule\"><b>Rule:</b> \(rule($s) | h)</div><div class=\"cards\">"
  + card("Servers / clusters"; $s.total; ""; "\($r.meta.accounts | length) account(s), \($r.meta.regions | length) region(s)")
  + card("% compliant"; "\($s.pct_compliant)%"; (if $s.non_compliant > 0 then "warn" else "ok" end); "of all servers")
  + card("Compliant"; $s.compliant; "ok"; "<= \($s.max_behind) behind")
  + card("Non-compliant"; $s.non_compliant; (if $s.non_compliant > 0 then "bad" else "ok" end); ">= \($s.max_behind + 1) behind")
  + card("Unknown"; $s.unknown; "unk"; "lookup failed / deprecated")
  + card("Past standard support"; $s.past_standard_support; (if $s.past_standard_support > 0 then "bad" else "ok" end); "Extended Support charges")
  + card("Support ending"; $s.nearing_end_of_support; (if $s.nearing_end_of_support > 0 then "warn" else "ok" end); "within \($s.warn_days) days")
  + card("Auto minor upgrade off"; $s.auto_minor_off; (if $s.auto_minor_off > 0 then "warn" else "ok" end); "incl. mixed clusters")
  + card("Pending maintenance"; $s.with_pending; (if $s.with_pending > 0 then "warn" else "ok" end); "servers with actions")
  + ($r | ro | card("Regions with databases"; "\(.with_databases) / \(.checked)"; (if .error > 0 then "bad" else "" end); "\(.empty) empty, \(.error) error(s)")) + "</div>"
  + (if ($nc | length) == 0 then "<div class=\"allok\">All servers compliant - no server is more than \($s.max_behind) minor versions behind.</div>"
     else "<h2 class=\"bad\">Non-compliant servers (\($nc | length)) - most behind first</h2><table class=\"nc\"><tr><th>Account</th><th>Region</th><th>Engine</th><th>Identifier</th><th>Current &rarr; latest minor</th><th>Behind</th><th>Support</th></tr>"
          + ($nc | map("<tr><td>\(.account_id | h)</td><td>\(.region | h)</td><td>\(.engine | h)</td><td><b>\(.identifier | h)</b></td><td class=\"mono\">\(.current_version | h) &rarr; \(.latest_minor_version | dash | h)</td><td class=\"n bad\">\(.versions_behind)</td><td>\(.support_flag | h)</td></tr>") | join("")) + "</table>" end)
  + "<h2>Per account <span class=\"sub\">\($r.meta.accounts | length) account(s) &middot; click a header to sort</span></h2><table class=\"sortable\" id=\"accounts\"><thead><tr><th>Account</th><th>Name</th><th>Collected</th><th>Regions with DBs</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th><th>Past standard support</th></tr></thead><tbody>"
  + ($r | acct_rows | map("<tr><td><b>\(.account_id | h)</b></td><td>\(.profile | dash | h)</td><td>\(.collected_utc | dash | h)\(if .source then "<br><span class=\"sub\">" + (.source | h) + "</span>" else "" end)</td><td class=\"n\">\(.regions_with_databases)</td><td class=\"n\">\(.total)</td><td class=\"n ok\">\(.compliant)</td><td class=\"n \(if .non_compliant > 0 then "bad" else "" end)\">\(.non_compliant)</td><td class=\"n\">\(.unknown)</td><td class=\"n \(.pct_compliant | pctc)\" data-s=\"\(.pct_compliant // -1)\">\(.pct_compliant | pct_txt)</td><td class=\"n \(if .with_pending > 0 then "warn" else "" end)\">\(.with_pending)</td><td class=\"n \(if .past_standard_support > 0 then "bad" else "" end)\">\(.past_standard_support)</td></tr>") | join("")) + "</tbody></table>"
  + "<h2>Per region <span class=\"sub\">\($r | ro | region_line | h) &middot; click a header to sort</span></h2><table class=\"sortable\"><thead><tr><th>Account</th><th>Region</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th></tr></thead><tbody>"
  + ($r | shown_regions | map("<tr><td>\(.account_id | h)</td><td><b>\(.region | h)</b>\(if .status == "error" then " <span class=\"err\">AWS error</span>" else "" end)</td><td class=\"n\">\(.total)</td><td class=\"n ok\">\(.compliant)</td><td class=\"n \(if .non_compliant > 0 then "bad" else "" end)\">\(.non_compliant)</td><td class=\"n\">\(.unknown)</td><td class=\"n \(.pct_compliant | pctc)\" data-s=\"\(.pct_compliant // -1)\">\(.pct_compliant | pct_txt)</td><td class=\"n \(if .with_pending > 0 then "warn" else "" end)\">\(.with_pending)</td></tr>") | join(""))
  + "</tbody>" + ($s.regions_total // null | if . == null then "" else "<tfoot><tr><td><b>All regions</b></td><td></td><td class=\"n\">\(.total)</td><td class=\"n ok\">\(.compliant)</td><td class=\"n \(if .non_compliant > 0 then "bad" else "" end)\">\(.non_compliant)</td><td class=\"n\">\(.unknown)</td><td class=\"n \(.pct_compliant | pctc)\">\(.pct_compliant | pct_txt)</td><td class=\"n\">\(.with_pending)</td></tr></tfoot>" end) + "</table>"
  + "<h2>Per engine and major version</h2><table><tr><th>Engine</th><th>Major</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Latest minor</th></tr>"
  + ([$s.engines[] | . as $e
      | "<tr class=\"eng\"><td>\($e.engine | h)</td><td>all</td><td class=\"n\">\($e.total)</td><td class=\"n ok\">\($e.compliant)</td><td class=\"n \(if $e.non_compliant > 0 then "bad" else "" end)\">\($e.non_compliant)</td><td class=\"n\">\($e.unknown)</td><td class=\"n\">\($e.pct_compliant)%</td><td></td></tr>"
        + ($e.majors | map("<tr><td></td><td>\(.major | h)</td><td class=\"n\">\(.total)</td><td class=\"n ok\">\(.compliant)</td><td class=\"n \(if .non_compliant > 0 then "bad" else "" end)\">\(.non_compliant)</td><td class=\"n\">\(.unknown)</td><td></td><td class=\"mono\">\(latest_txt | h)</td></tr>") | join(""))] | join("")) + "</table>"
  + (if ($uk | length) > 0 then "<h2>Unknown (\($uk | length))</h2><table><tr><th>Account</th><th>Region</th><th>Engine</th><th>Identifier</th><th>Current</th><th>Why</th></tr>"
       + ($uk | map("<tr><td>\(.account_id | h)</td><td>\(.region | h)</td><td>\(.engine | h)</td><td>\(.identifier | h)</td><td class=\"mono\">\(.current_version | h)</td><td>\(why | h)</td></tr>") | join("")) + "</table>" else "" end)
  + (if $r | merged then "<h2>Merged inputs <span class=\"sub\">\($r | merge_line | h)</span></h2><table id=\"sources\"><tr><th>File</th><th>Collected</th><th>Account(s)</th><th>Used</th><th>Script</th></tr>"
       + ($r.meta.merge.sources | map("<tr><td class=\"mono\">\(.file | h)</td><td>\(.collected_utc | h)<br><span class=\"sub\">\(.collected_local // "" | h)</span></td><td>\((.used + .superseded) | join(", ") | h)</td><td>\(src_state | h)</td><td>v\(.script_version // "?" | h)</td></tr>") | join("")) + "</table>" else "" end)
  + (if ($r.errors | length) > 0 then "<h2>Errors</h2><ul>" + ($r.errors | map("<li>\(.profile | h)/\(.region | h): \(.call | h): \(.message | h)</li>") | join("")) + "</ul>" else "" end)
  + "</main><script>(function(){Array.prototype.forEach.call(document.querySelectorAll('table.sortable'),function(t){var hs=t.tHead.rows[0].cells;"
  + "Array.prototype.forEach.call(hs,function(th,i){var asc=false;th.title='Sort';th.addEventListener('click',function(){asc=!asc;var b=t.tBodies[0];"
  + "var rs=Array.prototype.slice.call(b.rows);rs.sort(function(x,y){var a=x.cells[i],c=y.cells[i];var p=a.getAttribute('data-s')||a.textContent.trim(),q=c.getAttribute('data-s')||c.textContent.trim();"
  + "var m=parseFloat(p),n=parseFloat(q);var r=(!isNaN(m)&&!isNaN(n)&&/^-?[0-9.]+%?$/.test(p)&&/^-?[0-9.]+%?$/.test(q))?m-n:p.localeCompare(q);return asc?r:-r;});"
  + "rs.forEach(function(r){b.appendChild(r);});});});});})();</script><footer>rds_patch_compliance_summary.sh v\($ARGS.named.version // "" | h) &middot; read-only; numbers from rds_patch_compliance_report.sh v\($r.meta.version | h)</footer></body></html>";

def csv_nc:
  (["account_id","profile","region","engine","identifier","resource_type","major_version","current_version","latest_minor_version","versions_behind","support_flag","auto_minor_upgrade","pending_actions_count"] | @csv),
  (nc_rows[] | [.account_id, .profile, .region, .engine, .identifier, .resource_type, .major_version, .current_version, .latest_minor_version, .versions_behind, .support_flag, .auto_minor_upgrade, .pending_actions_count] | @csv);
def csv_summary:
  .summary as $s
  | (["scope","engine","major","total","compliant","non_compliant","unknown","pct_compliant","latest_minor"] | @csv),
    (["overall","","",$s.total,$s.compliant,$s.non_compliant,$s.unknown,$s.pct_compliant,""] | @csv),
    ($s.engines[] | . as $e | (["engine",$e.engine,"",$e.total,$e.compliant,$e.non_compliant,$e.unknown,$e.pct_compliant,""] | @csv),
       ($e.majors[] | ["major",$e.engine,.major,.total,.compliant,.non_compliant,.unknown,"",(.latest_minor // "")] | @csv)),
    (["flag","past_standard_support","",$s.past_standard_support,"","","","",""] | @csv),
    (["flag","nearing_end_of_support_\($s.warn_days)d","",$s.nearing_end_of_support,"","","","",""] | @csv),
    (["flag","auto_minor_upgrade_off","",$s.auto_minor_off,"","","","",""] | @csv),
    (["flag","pending_maintenance","",$s.with_pending,"","","","",""] | @csv);
def csv_regions:
  (["account_id","profile","region","status","total","compliant","non_compliant","unknown","pct_compliant","servers_with_pending_maintenance","pending_actions","aws_errors"] | @csv),
  (shown_regions + [.summary.regions_total // empty] | .[]
   | [.account_id, .profile, .region, .status, .total, .compliant, .non_compliant, .unknown, (.pct_compliant // ""), .with_pending, .pending_total, .errors] | @csv);
def csv_accounts:
  (["account_id","profile","collected_utc","source_file","regions_with_databases","total","compliant","non_compliant","unknown","pct_compliant","servers_with_pending_maintenance","past_standard_support","aws_errors"] | @csv),
  (acct_rows[] | [.account_id, .profile, .collected_utc, (.source // ""), .regions_with_databases, .total, .compliant, .non_compliant, .unknown, (.pct_compliant // ""), .with_pending, .past_standard_support, .errors] | @csv);
def alert: {summary: (.summary | {total, compliant, non_compliant, unknown, pct_compliant, max_behind, errors}),
            regions: (ro | {checked, with_databases, empty, error}),
            accounts: [acct_rows[] | {account_id, profile, total, compliant, non_compliant, unknown, pct_compliant}],
            merged_files: (.meta.merge.files // null),
            non_compliant: [nc_rows[] | {account_id, region, engine, identifier, current_version, latest_minor_version, versions_behind, support_flag}]};

if $mode == "text" then text elif $mode == "html" then html elif $mode == "csv_nc" then csv_nc
elif $mode == "csv_summary" then csv_summary elif $mode == "csv_accounts" then csv_accounts elif $mode == "csv_regions" then csv_regions elif $mode == "alert" then alert else . end
