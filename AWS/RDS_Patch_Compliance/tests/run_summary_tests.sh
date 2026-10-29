#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2054  # jq programs are single-quoted; comma lists are CLI args
# Tests for rds_patch_compliance_summary.sh against the mock AWS CLI (tests/mock/aws).
# Guard: the mock must be `aws` on PATH, fake credentials, dead endpoint, temp output only - nothing reaches AWS.
# Usage: tests/run_summary_tests.sh [-k]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
S="$HERE/../rds_patch_compliance_summary.sh"
FULL="$HERE/../rds_patch_compliance_report.sh"
OUT="$(mktemp -d /tmp/rpcs_tests.XXXXXX)"
KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0; LISTENER_PID=""
export MOCK_LOG="$OUT/aws_calls.jsonl"
STUB="$OUT/stubbin"; mkdir -p "$STUB"
export PATH="$HERE/mock:$STUB:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE MOCK_DEFAULT_REGION MOCK_SCENARIO
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_SESSION_TOKEN=fake \
       AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
       AWS_ENDPOINT_URL=http://127.0.0.1:9 TMPDIR="$OUT"
if [[ "$(command -v aws)" != "$HERE/mock/aws" || "$(aws --version 2>&1)" != *.mock* ]]; then
    echo "GUARD: 'aws' on PATH is not tests/mock/aws - refusing to run (would risk real AWS)"; exit 2
fi
BEFORE="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
cleanup() { [[ -n "$LISTENER_PID" ]] && kill "$LISTENER_PID" 2>/dev/null; if (( KEEP )); then echo "output kept in $OUT"; else rm -rf -- "$OUT"; fi; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
t() {   # t <name> <rc> <scenario> [args...]
    local name="$1" exp="$2" scen="$3"; shift 3
    MOCK_SCENARIO="$scen" "$S" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"; local rc=$?
    if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; tail -5 "$OUT/$name.err" | sed 's/^/       /'; fi
}
has()   { if grep -qF -- "$3" "$OUT/$1.$2"; then ok "$1 $2 has '$3'"; else bad "$1 $2 lacks '$3'"; fi; }
hasnt() { if grep -qF -- "$3" "$OUT/$1.$2"; then bad "$1 $2 unexpectedly has '$3'"; else ok "$1 $2 lacks '$3'"; fi; }
chk()   { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
ncline() { grep -E "^!! .* $2 " "$OUT/$1.out"; }
P2=(-P prod,nonprod -r us-east-1,ap-south-1)

echo "== usage"
t help 0 fleet --help; has help out 'versions_behind > --max-behind'
t version 0 fleet --version; has version out '1.3.0'
t badopt 1 fleet --bogus
t badfmt 1 fleet -r us-east-1 -F xml
t htmlnoout 1 fleet -r us-east-1 -F html
t badmax 1 fleet -r us-east-1 --max-behind x
t badhook 1 fleet -r us-east-1 --alert-webhook ftp://x
t bothreg 1 fleet -r us-east-1 --all-regions

echo "== fleet summary (txt to screen)"
: >"$MOCK_LOG"
t fleet 0 fleet "${P2[@]}"
has fleet out 'Rule     : NON-COMPLIANT when the current version is more than 2 valid minor versions behind the latest (3 or more)'
has fleet out 'UTC / '; has fleet out ' IST'
has fleet out 'accounts 111111111111 (prod), 222222222222 (nonprod); regions ap-south-1, us-east-1'
has fleet out 'OVERALL  : 22 servers/clusters | COMPLIANT 13 | NON-COMPLIANT 8 | UNKNOWN 1 | 59.1% compliant'
has fleet out '!!! NON-COMPLIANT SERVERS (8) - most behind first'
has fleet out 'KEY FLAGS: past standard support (Extended Support charges) 2 | standard support ending within 180 days 2 | auto minor upgrade off 3 | pending maintenance 3'
chk "boundary: 3 behind (reports-aurora-pg14) listed" ncline fleet reports-aurora-pg14
chk "boundary: 2 behind (crm-aurora-pg15, orders-aurora-pg15) not listed" bash -c "! grep -qE 'crm-aurora-pg15|orders-aurora-pg15' '$OUT/fleet.out'"
chk "compliant servers not listed" bash -c "! grep -qE 'pay-aurora-pg16|cms-aurora-mysql|catalog-docdb' '$OUT/fleet.out'"
chk "sorted most behind first, then name" bash -c "[[ \"\$(grep '^!! ' '$OUT/fleet.out' | awk '{print \$5}' | paste -sd,)\" == dev-aurora-pg15,inv-mysql,legacy-aurora-pg12,shop-aurora-mysql,analytics-pg,hr-sql,ledger-maz,reports-aurora-pg14 ]]"
has fleet out '15.4 -> 15.13'
has fleet out 'UNKNOWN (1)'; has fleet out 'old-aurora-pg11  11.9: current version not returned by RDS'
chk "only read-only AWS calls" test "$(jq -r '.[] | select(test("^(modify|create|delete|apply|reboot|start|stop|failover)-"))' "$MOCK_LOG" | wc -l)" -eq 0

echo "== consistency with the full report (same mock data)"
MOCK_SCENARIO=fleet "$FULL" "${P2[@]}" -F json >"$OUT/full.json" 2>/dev/null
MOCK_SCENARIO=fleet "$S" "${P2[@]}" -F csv -o "$OUT/cmp" >/dev/null 2>&1
SC="$(ls "$OUT"/cmp/*_summary.csv)"
chk "overall row = full report summary" test "$(jq -r '.summary | "\"overall\",\"\",\"\",\(.total),\(.compliant),\(.non_compliant),\(.unknown),\(.pct_compliant),\"\""' "$OUT/full.json")" == "$(grep '^"overall"' "$SC")"
chk "per engine/major rows = full report" test "$(jq -r '.summary.engines[] | . as $e | ("engine|\($e.engine)|\($e.total)|\($e.compliant)|\($e.non_compliant)|\($e.unknown)"), (.majors[] | "major|\($e.engine)|\(.major)|\(.total)|\(.compliant)|\(.non_compliant)|\(.unknown)|\(.latest_minor // "")")' "$OUT/full.json")" \
    == "$(jq -Rr 'fromjson? // (split(",") | map(ltrimstr("\"") | rtrimstr("\""))) | select(.[0] == "engine" or .[0] == "major") | if .[0] == "engine" then "engine|\(.[1])|\(.[3])|\(.[4])|\(.[5])|\(.[6])" else "major|\(.[1])|\(.[2])|\(.[3])|\(.[4])|\(.[5])|\(.[6])|\(.[8])" end' "$SC")"
chk "non-compliant CSV = full report NON-COMPLIANT rows" test "$(jq -r '[.rows[] | select(.compliance_status == "NON-COMPLIANT") | .identifier] | sort | join(",")' "$OUT/full.json")" \
    == "$(tail -n +2 "$(ls "$OUT"/cmp/*_noncompliant.csv)" | cut -d, -f5 | tr -d '"' | sort | paste -sd,)"
chk "csv: only non-compliant rows (8 + header)" test "$(wc -l <"$(ls "$OUT"/cmp/*_noncompliant.csv)")" -eq 9

echo "== --max-behind / all compliant / unknown"
t max3 0 fleet "${P2[@]}" --max-behind 3
has max3 out 'more than 3 valid minor versions behind the latest (4 or more)'
chk "max3: 3-behind servers now compliant" bash -c "! grep -q reports-aurora-pg14 '$OUT/max3.out'"
has max3 out 'NON-COMPLIANT SERVERS (4)'
t allok 0 fleet -P prod -r us-east-1 -e docdb,neptune
has allok out '*** All servers compliant'; hasnt allok out 'NON-COMPLIANT SERVERS'; hasnt allok out 'UNKNOWN ('
t lookupfail 0 lookupfail -P prod -r us-east-1
has lookupfail out 'UNKNOWN (3)'; has lookupfail out 'version lookup failed'

echo "== Oracle same patch line"
t ora 0 oracle -P prod -r us-east-1 -e 'oracle-*' --max-behind 1
chk "ora: mrp r1 -> mrp r2 is 1 behind (compliant at max 1)" bash -c "! grep -q 'ora-mrp' '$OUT/ora.out'"
chk "ora: r9 listed 2 behind with mrp target" bash -c "grep -E '^!! .*ora-r9 .*mrp-2026-07.r9 -> 19.0.0.0.ru-2026-10.mrp-2026-10.r1 +2 ' '$OUT/ora.out' >/dev/null"
has ora out 'mrp: 19.0.0.0.ru-2026-10.mrp-2026-10.r1'
t ora_any 0 oracle -P prod -r us-east-1 -e 'oracle-*' --max-behind 1 --oracle-any-patch-line
has ora_any out 'ora-mrp'

echo "== region discovery + region-wise breakdown (MOCK_SCENARIO=discover)"
probes() { jq -c 'select(index("--query"))' "$MOCK_LOG" | wc -l; }
: >"$MOCK_LOG"
t disc 0 discover -P prod -A
has disc out 'Regions  : 14 checked, 2 with databases, 11 empty, 1 error (discovery probe)'
has disc out 'PER REGION'
has disc out '  111111111111  us-east-1           19     11      7     1   57.9%     3'
has disc out '  111111111111  us-west-2            1      1      0     0    100%     0'
has disc out '  111111111111  ca-central-1         0      0      0     0       -     0  AWS error - see ERRORS'
has disc out '  ALL           All regions         20     12      7     1     60%     3'
hasnt disc out 'Empty'
has disc out 'Scanned  : accounts 111111111111 (prod); all enabled regions'
chk "disc: no region names above OVERALL" test "$(sed '/^OVERALL/q' "$OUT/disc.out" | grep -cE '[a-z]{2}-[a-z]+-[0-9]')" -eq 0
hasnt disc out '  111111111111  eu-west-1 '
chk "disc: 28 probes passed through the full report" test "$(probes)" -eq 28
: >"$MOCK_LOG"
t nodisc 0 discover -P prod -A --no-discover --probe-parallel 3
chk "nodisc: --no-discover passed through (no probe)" test "$(probes)" -eq 0
has nodisc out 'Regions  : 14 checked, 2 with databases, 11 empty, 1 error (all scanned in full, --no-discover)'
t pp 0 discover -P prod -A --probe-parallel 3 -v;  chk "pp: --probe-parallel passed through" grep -q 'probing 14 region(s), 3 at a time' "$OUT/pp.err"
t badpp 1 discover -P prod -A --probe-parallel 99
t rdisc 0 discover -P prod -r us-east-1,eu-west-1
has rdisc out 'Regions  : 2 checked, 1 with databases, 1 empty, 0 errors'
t dfiles 0 discover -P prod -A -F html,csv -o "$OUT/dfiles"
SRC="$(find "$OUT/dfiles" -name '*_regions.csv')"; SH="$(find "$OUT/dfiles" -name '*.html')"
chk "summary regions csv: header + 2 databases + 1 error + All regions (no empty rows)" test "$(wc -l <"$SRC")" -eq 5
chk "summary regions csv: totals row" grep -q '^"ALL","","All regions","",20,12,7,1,60,3,5,2$' "$SRC"
chk "summary regions csv: no empty-region rows" test "$(grep -c '"empty"' "$SRC")" -eq 0
chk "summary html: sortable region table + All regions" grep -q '<table class="sortable"><thead><tr><th>Account</th><th>Region</th>.*<tfoot><tr><td><b>All regions</b>' "$SH"
chk "summary html: AWS error badge" grep -q 'ca-central-1</b> <span class="err">AWS error</span>' "$SH"
chk "summary html: no empty-regions list" test "$(grep -c 'details class="empty"\|empty region(s)' "$SH")" -eq 0
chk "summary html: header has counts only" grep -q '&middot; Regions: 14 checked, 2 with databases, 11 empty, 1 error (discovery probe)</p></header>' "$SH"
SHTOP="$(cat "$SH")"; SHTOP="${SHTOP%%<table*}"   # everything above the first table
chk "summary html: no region names above the first table" test "$(grep -oE '[a-z]{2}-[a-z]+-[0-9]' <<<"$SHTOP" | wc -l)" -eq 0
chk "summary html: region totals = overall" grep -q '<td><b>All regions</b></td><td></td><td class="n">20</td><td class="n ok">12</td><td class="n bad">7</td><td class="n">1</td><td class="n bad">60%</td>' "$SH"

echo "== outputs"
t files 0 fleet "${P2[@]}" -F txt,html,csv -o "$OUT/files"
chk "6 files written (txt, html, summary, noncompliant, regions and accounts csv)" test "$(find "$OUT/files" -type f | wc -l)" -eq 6
has files out 'OVERALL  :'
H="$(ls "$OUT"/files/*.html)"; cp "$H" "$OUT/h.out"
has h out 'table class="nc"'; has h out 'Non-compliant servers (8)'; has h out 'Rule:'; has h out '59.1%'
chk "html: compliant servers absent" bash -c "! grep -q 'pay-aurora-pg16' '$H'"
t allokh 0 fleet -P prod -r us-east-1 -e docdb,neptune -F html -o "$OUT/okh"; cp "$(ls "$OUT"/okh/*.html)" "$OUT/okh.out"; has okh out 'All servers compliant'
t failnc 5 fleet "${P2[@]}" --fail-on-noncompliant
t failok 0 fleet -P prod -r us-east-1 -e docdb,neptune --fail-on-noncompliant
t badcreds 2 badcreds -P prod -r us-east-1

echo "== alerts (local stubs only)"
cat >"$STUB/mail" <<'MAIL'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %q' "$@"; printf '\n'; cat; } >>"${MAIL_SINK:?}"
MAIL
chmod +x "$STUB/mail"; export MAIL_SINK="$OUT/mail.txt"
python3 - "$OUT/hook.txt" "$OUT/port" <<'PY' &
import http.server, sys
sink, pf = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(sink, "ab").write(b + b"\n"); self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); open(pf, "w").write(str(s.server_port)); s.serve_forever()
PY
LISTENER_PID=$!
for _ in $(seq 50); do [[ -s "$OUT/port" ]] && break; sleep 0.1; done
HOOK="http://127.0.0.1:$(cat "$OUT/port")/hooks/T000/SECRET"
t al_mail 0 fleet "${P2[@]}" --alert-email dba@example.com
chk "e-mail subject + summary body" bash -c "grep -q 'NON-COMPLIANT:' '$MAIL_SINK' && grep -q 'OVERALL  : 22 servers' '$MAIL_SINK' && grep -q 'NON-COMPLIANT SERVERS (8)' '$MAIL_SINK'"
: >"$MAIL_SINK"
t al_none 0 fleet -P prod -r us-east-1 -e docdb,neptune --alert-email dba@example.com
chk "no alert when all compliant (alert-on noncompliant)" test ! -s "$MAIL_SINK"
t al_json 0 fleet "${P2[@]}" --alert-webhook "$HOOK" --alert-webhook-format json
chk "json webhook payload" bash -c "grep . '$OUT/hook.txt' | tail -1 | jq -e '.status == \"NON-COMPLIANT\" and (.non_compliant | length) == 8 and .summary.total == 22' >/dev/null"
t al_slack 0 fleet -P prod -r us-east-1 -e docdb,neptune --alert-on always --alert-webhook "$HOOK"
chk "slack payload" bash -c "grep . '$OUT/hook.txt' | tail -1 | jq -e '.text | contains(\"All servers compliant\")' >/dev/null"
hasnt al_slack err '/SECRET'

echo "== --save-data and --merge (offline)"
NOAWS="$OUT/noaws"; mkdir -p "$NOAWS"; printf '#!/bin/sh\necho AWS-CALLED >>"%s/aws_called"; exit 99\n' "$OUT" >"$NOAWS/aws"; chmod +x "$NOAWS/aws"
MG="$OUT/mg data"; mkdir -p "$MG"
RDS_PCR_NOW=1790000000 t sd_sum 0 fleet -P prod -r us-east-1 --save-data -o "$MG" -F txt
chk "summary --save-data default name in -o dir" test -s "$MG/rds_patch_111111111111_$(TZ=UTC date -d @1790000000 +%Y%m%d 2>/dev/null || date -u +%Y%m%d).json"
RDS_PCR_NOW=1790100000 MOCK_SCENARIO=fleet "$FULL" -P nonprod -r ap-south-1 --save-data "$MG/nonprod full.json" -o "$OUT/fullnp" -F json >/dev/null 2>&1
RDS_PCR_NOW=1790200000 t sd_named 0 fleet -P dev -r eu-west-1 --save-data "$MG/dev.json"
chk "summary --save-data FILE" jq -e '.accounts[0].account == "333333333333"' "$MG/dev.json"
chk "summary file merges in the full report (interchange)" bash -c "PATH='$NOAWS:$PATH' '$FULL' --merge '$MG' -F json -o '$OUT/fm' >/dev/null 2>&1 && jq -e '.summary.total == 24' '$OUT'/fm/*.json >/dev/null"
sm() { local name="$1" exp="$2"; shift 2; PATH="$NOAWS:$PATH" RDS_PCR_NOW=1791000000 t "$name" "$exp" fleet "$@"; }
sm m_txt 0 --merge "$MG"
has m_txt out 'Merged   : 3 file(s), offline (0 AWS calls)'
has m_txt out 'OVERALL  : 24 servers/clusters | COMPLIANT 14 | NON-COMPLIANT 9 | UNKNOWN 1'
has m_txt out 'PER ACCOUNT'; has m_txt out '333333333333  dev'
has m_txt out 'MERGED INPUTS (3)'; has m_txt out 'PER ENGINE'
hasnt m_txt out 'regions us-east-1'
sm m_all 0 --merge "$MG/dev.json" "$MG/nonprod full.json" "$MG" -o "$OUT/mo" -F txt,html,csv
chk "merge writes txt/html/csv + accounts csv" bash -c "ls '$OUT/mo' | grep -q '_accounts.csv' && ls '$OUT/mo' | grep -q '.html' && ls '$OUT/mo' | grep -q '_noncompliant.csv'"
chk "accounts csv has 3 accounts" test "$(tail -n +2 "$OUT"/mo/*_accounts.csv | wc -l)" = 3
chk "html has per-account + merged inputs" bash -c "grep -q 'id=\"accounts\"' '$OUT'/mo/*.html && grep -q 'Merged inputs' '$OUT'/mo/*.html"
sm m_max 0 --merge "$MG" --max-behind 0
has m_max out 'more than 0 valid minor versions behind'
sm m_fail 5 --merge "$MG" --fail-on-noncompliant
sm m_warn 0 --merge "$MG" --warn-days 400; has m_warn out 'ending within 400 days'
sm m_rej1 1 --merge "$MG" -P prod
sm m_rej2 1 --merge "$MG" -r us-east-1
sm m_rej3 1 --merge "$MG" --save-data
sm m_rej4 1 --merge
echo '{"x":1}' >"$OUT/bad.json"; sm m_bad 3 --merge "$OUT/bad.json"
: >"$MAIL_SINK"
sm m_alert 0 --merge "$MG" --alert-email dba@example.com
chk "merge alert e-mail sent with summary body" bash -c "grep -q 'NON-COMPLIANT:' '$MAIL_SINK' && grep -q 'OVERALL  : 24 servers' '$MAIL_SINK'"
CR="$OUT/crlfjq"; mkdir -p "$CR"; REALJQ="$(command -v jq)"
printf '#!/bin/bash\n"%s" "$@" | sed '"'"'s/$/\\r/'"'"'; exit "${PIPESTATUS[0]}"\n' "$REALJQ" >"$CR/jq"; chmod +x "$CR/jq"
mkdir -p "$OUT/drv/c/Users/DBA Team/patch data"; cp "$MG"/*.json "$OUT/drv/c/Users/DBA Team/patch data/"
PATH="$CR:$NOAWS:$PATH" RDS_PCR_DRIVE_ROOT="$OUT/drv" RDS_PCR_NOW=1791000000 t m_win 0 fleet --merge 'C:\Users\DBA Team\patch data' -o "$OUT/win out" -F txt,html,csv
chk "git bash: no CR in outputs, same totals" bash -c "! grep -lq $'\r' '$OUT/win out'/* && grep -q 'OVERALL  : 24 servers' '$OUT/win out'/*.txt"
MOCK_SCENARIO=oracle RDS_PCR_NOW=1790000000 "$FULL" -P prod -r us-east-1 --save-data "$OUT/ora.json" -o "$OUT/ora" -F json >/dev/null 2>&1
sm m_ora 0 --merge "$OUT/ora.json" --oracle-any-patch-line
chk "oracle any-line recounted at merge = live any-line" bash -c "MOCK_SCENARIO=oracle RDS_PCR_NOW=1791000000 '$S' -P prod -r us-east-1 --oracle-any-patch-line 2>/dev/null | grep OVERALL | diff - <(grep OVERALL '$OUT/m_ora.out')"
chk "merge mode made 0 AWS calls" test ! -e "$OUT/aws_called"

echo "== hygiene"
chk "shellcheck summary script" shellcheck "$S"
chk "shellcheck this test" shellcheck "$HERE/run_summary_tests.sh"
AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "no files written into the tool folder" test "$BEFORE" == "$AFTER"

echo; echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
