#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2054  # cond && ok || bad is safe (ok returns 0); jq programs are single-quoted; comma lists are CLI args
# Test suite for rds_patch_compliance_report.sh against the mock AWS CLI (tests/mock/aws).
# Guard: the mock must be the `aws` on PATH, credentials are fake, the endpoint is a dead local port and
# all output goes to a temp dir - nothing can reach AWS and nothing is written into the repo.
# Usage: tests/run_tests.sh [-k]   (-k keeps the temp output dir)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../rds_patch_compliance_report.sh"
LIBJQ="$HERE/../lib/compliance.jq"
OUT="$(mktemp -d /tmp/rpc_tests.XXXXXX)"
KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0; LISTENER_PID=""
export MOCK_LOG="$OUT/aws_calls.jsonl"
STUB="$OUT/stubbin"; mkdir -p "$STUB"
export PATH="$HERE/mock:$STUB:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE MOCK_DEFAULT_REGION MOCK_SCENARIO
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_SESSION_TOKEN=fake \
       AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
       AWS_ENDPOINT_URL=http://127.0.0.1:9 TMPDIR="$OUT"
# --- guard: refuse to run unless `aws` is the mock
if [[ "$(command -v aws)" != "$HERE/mock/aws" || "$(aws --version 2>&1)" != *.mock* ]]; then
    echo "GUARD: 'aws' on PATH is not tests/mock/aws - refusing to run (would risk real AWS)"; exit 2
fi
BEFORE="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"

cleanup() {
    [[ -n "$LISTENER_PID" ]] && kill "$LISTENER_PID" 2>/dev/null
    if (( KEEP )); then echo "output kept in $OUT"; else rm -rf -- "$OUT"; fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
# t <name> <expected-rc> <scenario> [args...]  -> stdout in $OUT/<name>.out, stderr in .err
t() {
    local name="$1" exp="$2" scen="$3"; shift 3
    MOCK_SCENARIO="$scen" "$SCRIPT" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"
    local rc=$?
    if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; sed 's/^/       /' "$OUT/$name.err" | tail -5; fi
}
has()  { if grep -qE -- "$3" "$OUT/$1.$2"; then ok "$1 $2 has /$3/"; else bad "$1 $2 lacks /$3/"; fi; }
hasnt(){ if grep -qE -- "$3" "$OUT/$1.$2"; then bad "$1 $2 unexpectedly has /$3/"; else ok "$1 $2 lacks /$3/"; fi; }
chk()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
jqt()  { if jq -e "$2" "$OUT/$1.out" >/dev/null 2>&1; then ok "$1 json: $2"; else bad "$1 json: $2"; fi; }
row()  { jq -c --arg i "$2" '.rows[] | select(.identifier == $i)' "$OUT/$1.out"; }
rowt() { if row "$1" "$2" | jq -e "$3" >/dev/null 2>&1; then ok "$1 $2: $3"; else bad "$1 $2: $3 (got $(row "$1" "$2" | head -c 400))"; fi; }
vc()   { jq -n --arg mode vkey_cmp --arg a "$1" --arg b "$2" --argjson now 0 --argjson max_behind 2 --argjson warn_days 180 --argjson top_n 10 \
            --argjson tagcols '[]' --argjson f '{}' --argjson nc_only false -f "$LIBJQ"; }
vct()  { local r; r="$(vc "$1" "$3")"; if [[ "$r" == "$2" ]]; then ok "vcmp $1 vs $3 = $2"; else bad "vcmp $1 vs $3 = $r expected $2"; fi; }
mj()   { local r; r="$(jq -rn --arg mode major --arg a "$2" --arg e "$1" --argjson now 0 --argjson max_behind 2 --argjson warn_days 180 --argjson top_n 10 \
            --argjson tagcols '[]' --argjson f '{}' --argjson nc_only false -f "$LIBJQ")"
         if [[ "$r" == "$3" ]]; then ok "major($1 $2) = $3"; else bad "major($1 $2) = $r expected $3"; fi; }

cat >"$STUB/mail" <<'MAIL'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %q' "$@"; printf '\n'; cat; } >>"${MAIL_SINK:?}"
MAIL
chmod +x "$STUB/mail"
export MAIL_SINK="$OUT/mail.txt"
PORT_FILE="$OUT/port"
python3 - "$OUT/webhook.txt" "$PORT_FILE" <<'PY' &
import http.server, sys
sink, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(sink, "ab") as f: f.write(body + b"\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()
PY
LISTENER_PID=$!
for _ in $(seq 50); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
HOOK="http://127.0.0.1:$(cat "$PORT_FILE")/hooks/T000/SECRET"
P2=(-P prod,nonprod -r us-east-1,ap-south-1)

echo "== version compare (unit)"
vct 15.10 1 15.9;  vct 15.9 -1 15.10;  vct 15.10 0 15.10;  vct 15.4 -1 15.4.1;  vct 16.1 1 15.13
vct 8.0.mysql_aurora.3.10.0 1 8.0.mysql_aurora.3.9.0;  vct 8.0.mysql_aurora.3.05.2 -1 8.0.mysql_aurora.3.06.0
vct 8.0.mysql_aurora.3.05.2 0 8.0.mysql_aurora.3.5.2;  vct 8.0.mysql_aurora.3.08.10 1 8.0.mysql_aurora.3.08.9
vct 15.00.4430.1.v1 1 15.00.4415.2.v1;  vct 15.00.4410.1.v1 -1 15.00.4410.2.v1;  vct 16.00.4165.4.v1 1 15.00.4430.1.v1
vct 19.0.0.0.ru-2025-07.rur-2025-07.r1 1 19.0.0.0.ru-2025-04.rur-2025-04.r1;  vct 19.0.0.0.ru-2025-01.rur-2025-01.r2 1 19.0.0.0.ru-2025-01.rur-2025-01.r1
vct 10.11.10 1 10.11.9;  vct 1.3.10.0 1 1.3.4.0
mj postgres 16.4 16; mj postgres 9.6.24 9.6; mj aurora-postgresql 15.10 15; mj mysql 8.0.36 8.0; mj aurora-mysql 8.0.mysql_aurora.3.05.2 8.0
mj sqlserver-se 15.00.4410.1.v1 15.00; mj oracle-ee 19.0.0.0.ru-2025-01.rur-2025-01.r1 19; mj docdb 5.0.0 5.0; mj neptune 1.3.2.1 1.3

echo "== usage / validation"
t help 0 fleet --help;               has help out 'Exit codes'; has help out 'read-only'; has help out '--max-behind'; has help out 'NEVER run'
t version 0 fleet --version;         has version out '1\.0\.0'
t badopt 1 fleet --bogus
t badfmt 1 fleet -r us-east-1 -F xml
t multinoout 1 fleet -r us-east-1 -F csv,html
t bothregions 1 fleet -r us-east-1 --all-regions
t badregion 1 fleet -r useast1
t badprofile 1 fleet -P 'a;b' -r us-east-1
t badmax 1 fleet -r us-east-1 --max-behind two
t badwarn 1 fleet -r us-east-1 --warn-days -5
t badtop 1 fleet -r us-east-1 --top 0
t badtz 1 fleet -r us-east-1 --tz Mars/Base
t badprefix 1 fleet -r us-east-1 -o "$OUT/o" --prefix '../x'
t badhook 1 fleet -r us-east-1 --alert-webhook ftp://x
t bademail 1 fleet -r us-east-1 --alert-email 'a b@c'
t badalerton 1 fleet -r us-east-1 --alert-on sometimes
t missingarg 1 fleet -r
printf 'aws_secret_access_key = x\n' >"$OUT/cred.conf"
t confcred 1 fleet --config "$OUT/cred.conf";   has confcred err 'credentials are not accepted'
printf 'bogus = 1\n' >"$OUT/unk.conf"
t confunk 1 fleet --config "$OUT/unk.conf";     has confunk err "unknown key 'bogus'"
printf '# test\nprofiles = prod\nregions = us-east-1\nmax_behind = 5   # comment\nformat = json\n$(touch %s/pwned)\n' "$OUT" >"$OUT/inj.conf"
t confinj 1 fleet --config "$OUT/inj.conf";     chk "config is parsed, never sourced" test ! -e "$OUT/pwned"
printf 'profiles = prod\nregions = us-east-1\nmax_behind = 5   # comment\nformat = json\ntag_columns = Owner\n' >"$OUT/c.conf"
t conf 0 fleet --config "$OUT/c.conf";          jqt conf '.summary.max_behind == 5'; jqt conf '.meta.tag_columns == ["Owner"]'
t confover 0 fleet --config "$OUT/c.conf" --max-behind 1;  jqt confover '.summary.max_behind == 1'
: >"$MOCK_LOG"
t confex 0 fleet --config "$HERE/../rds_patch_compliance_report.conf.example" --dry-run
has confex out 'prod nonprod'; has confex out "-> $HOME/compliance-reports"
t dryrun 0 fleet "${P2[@]}" --dry-run;         has dryrun out 'describe-db-major-engine-versions'; has dryrun out 'no AWS calls'
chk "dry-run made no AWS calls" test ! -s "$MOCK_LOG"

echo "== fleet (2 profiles x 2 regions)"
: >"$MOCK_LOG"
t fleet 0 fleet "${P2[@]}" -F json
jqt fleet '.summary.total == 22 and .summary.compliant == 13 and .summary.non_compliant == 9 and .summary.unknown == 0'
jqt fleet '.summary.pct_compliant == 59.1'
jqt fleet '[.meta.accounts[].account] == ["111111111111","222222222222"]'
jqt fleet '[.rows[].identifier] | index("unrelated-redis-like") == null'
jqt fleet '[.rows[].identifier] | map(select(test("^orders-pg15-|^pay-aurora-pg16-|^ledger-maz-[0-9]"))) | length == 0'
chk "engine versions looked up once per engine+region (cache)" test "$(jq -c 'select(index("describe-db-engine-versions"))' "$MOCK_LOG" | sort | uniq -d | wc -l)" -eq 0
chk "one inventory call per profile+region" test "$(jq -c 'select(index("describe-db-instances"))' "$MOCK_LOG" | wc -l)" -eq 4
chk "only describe/get calls were made" test "$(jq -r '.[] | select(test("^(modify|create|delete|apply|reboot|start|stop|failover)-"))' "$MOCK_LOG" | wc -l)" -eq 0
echo "-- rule and boundaries"
rowt fleet crm-aurora-pg15 '.versions_behind == 2 and .compliance_status == "COMPLIANT" and .newer_versions == ["15.12","15.13"]'
rowt fleet orders-aurora-pg15 '.versions_behind == 3 and .compliance_status == "NON-COMPLIANT" and .newer_versions == ["15.10","15.12","15.13"]'
rowt fleet dev-aurora-pg15 '.versions_behind == 7 and .latest_minor_version == "15.13" and .account_id == "222222222222" and .region == "ap-south-1"'
rowt fleet pay-aurora-pg16 '.versions_behind == 0 and .compliance_status == "COMPLIANT" and .upgrade_command == ""'
rowt fleet shop-aurora-mysql '.versions_behind == 8 and .major_version == "8.0" and .latest_minor_version == "8.0.mysql_aurora.3.10.0"'
rowt fleet cms-aurora-mysql '.versions_behind == 1 and .compliance_status == "COMPLIANT"'
rowt fleet hr-sql '.versions_behind == 3 and .major_version == "15.00" and .latest_minor_version == "15.00.4430.1.v1" and .compliance_status == "NON-COMPLIANT"'
rowt fleet erp-sql '.versions_behind == 1 and .major_version == "16.00"'
rowt fleet fin-ora '.versions_behind == 2 and .major_version == "19" and .compliance_status == "COMPLIANT"'
rowt fleet inv-mysql '.versions_behind == 6 and .auto_minor_upgrade == "false" and .pending_actions == 2'
rowt fleet app-mysql84 '.versions_behind == 0 and .major_version == "8.4"'
rowt fleet analytics-pg '.versions_behind == 3 and .newer_versions == ["13.20","13.21","13.22"]'
rowt fleet billing-pg '.versions_behind == 2 and .resource_type == "instance" and .members == ""'
rowt fleet dev-mariadb '.versions_behind == 2 and .major_version == "10.11"'
rowt fleet qa-pg '.versions_behind == 2 and .latest_minor_version == "17.6"'
rowt fleet catalog-docdb '.resource_type == "docdb-cluster" and .versions_behind == 0 and .pending_actions == 1 and .major_version == "5.0"'
rowt fleet graph-neptune '.resource_type == "neptune-cluster" and .versions_behind == 2 and .major_version == "1.3" and (.support_flag | startswith("n/a"))'
rowt fleet ledger-maz '.resource_type == "multi-az-cluster" and .versions_behind == 3 and .member_count == 3 and .auto_minor_upgrade == "true"'
echo "-- support / flags"
rowt fleet legacy-aurora-pg12 '.support_flag == "past standard support (Extended Support charges)" and .past_standard_support and .extended_support_end != null'
rowt fleet old-aurora-pg11 '.deprecated_version and .versions_behind == 1 and .major_version == "11" and (.note | test("deprecated"))'
rowt fleet analytics-pg '.nearing_end_of_support and (.support_flag | test("^standard support ends in 1[0-9][0-9] days$"))'
rowt fleet inv-mysql '.nearing_end_of_support'
rowt fleet hr-sql '(.support_flag | startswith("unknown"))'
rowt fleet reports-aurora-pg14 '.auto_minor_upgrade == "false"'
rowt fleet shop-aurora-mysql '.auto_minor_upgrade == "mixed" and (.note | test("off on some members"))'
rowt fleet orders-aurora-pg15 '.pending_actions == 1 and .members == "orders-pg15-1 (writer), orders-pg15-2, orders-pg15-3" and .member_count == 3'
rowt fleet orders-aurora-pg15 '.maint_window_utc == "sat:21:00-sat:21:30" and .maint_window_ist == "sun:02:30-sun:03:00"'
rowt fleet hr-sql '.maint_window_ist == "sun:00:00-sun:00:30"'
rowt fleet orders-aurora-pg15 '.tags.Owner == "orders" and (.arn | test("^arn:aws:rds:us-east-1:111111111111:cluster:orders-aurora-pg15$"))'
jqt fleet '.summary.past_standard_support == 2 and .summary.nearing_end_of_support == 2 and .summary.auto_minor_off == 3 and .summary.with_pending == 3 and .summary.pending_total == 4 and .summary.deprecated == 1'
echo "-- upgrade commands (printed only)"
rowt fleet orders-aurora-pg15 '.upgrade_command == "aws rds modify-db-cluster --db-cluster-identifier orders-aurora-pg15 --engine-version 15.13 --region us-east-1 --profile prod"'
rowt fleet inv-mysql '.upgrade_command == "aws rds modify-db-instance --db-instance-identifier inv-mysql --engine-version 8.0.43 --region us-east-1 --profile prod"'
rowt fleet graph-neptune '(.upgrade_command | startswith("aws neptune modify-db-cluster --db-cluster-identifier graph-neptune --engine-version 1.3.4.0"))'
rowt fleet fin-ora '(.upgrade_command | test("--engine-version 19.0.0.0.ru-2025-07.rur-2025-07.r1 "))'
jqt fleet '[.rows[].upgrade_command | select(test("apply-immediately"))] | length == 0'
t noprofile 0 fleet -r us-east-1 -F json -e postgres
jqt noprofile '[.rows[].upgrade_command | select(. != "" and test("--profile"))] | length == 0'
jqt noprofile '[.rows[].profile] | unique == ["default"]'
echo "-- sorting / summary"
jqt fleet '[.rows[] | select(.engine == "aurora-postgresql") | .identifier] == ["dev-aurora-pg15","legacy-aurora-pg12","reports-aurora-pg14","orders-aurora-pg15","crm-aurora-pg15","old-aurora-pg11","pay-aurora-pg16"]'
jqt fleet '.summary.top_behind[0].identifier == "shop-aurora-mysql" and (.summary.top_behind | length) == 10'
jqt fleet '(.summary.engines[] | select(.engine == "aurora-postgresql") | .majors | map(.major)) == ["16","15","14","12","11"]'
jqt fleet '(.summary.engines[] | select(.engine == "aurora-postgresql") | .majors[] | select(.major == "15")) | .total == 3 and .compliant == 1 and .non_compliant == 2 and .latest_minor == "15.13"'
t top3 0 fleet "${P2[@]}" -F json --top 3;   jqt top3 '(.summary.top_behind | length) == 3'
echo "-- options"
t max3 0 fleet -P prod -r us-east-1 -F json --max-behind 3
rowt max3 orders-aurora-pg15 '.compliance_status == "COMPLIANT"';  rowt max3 reports-aurora-pg14 '.compliance_status == "NON-COMPLIANT"'
t max0 0 fleet -P prod -r us-east-1 -F json --max-behind 0
rowt max0 cms-aurora-mysql '.compliance_status == "NON-COMPLIANT"';  rowt max0 pay-aurora-pg16 '.compliance_status == "COMPLIANT"'
t warn100 0 fleet -P prod -r us-east-1 -F json --warn-days 100;  jqt warn100 '.summary.nearing_end_of_support == 0'
t nconly 0 fleet "${P2[@]}" -F json --non-compliant-only
jqt nconly '(.rows | length) == 9 and all(.rows[]; .compliance_status == "NON-COMPLIANT") and .summary.total == 22'
t failnc 5 fleet "${P2[@]}" --fail-on-noncompliant
t failnc_ok 0 fleet -P prod -r us-east-1 -e docdb,neptune --fail-on-noncompliant
t engglob 0 fleet -P prod -r us-east-1 -F json -e 'aurora-*' -e 'SQLSERVER-*'
jqt engglob '[.rows[].engine] | unique == ["aurora-mysql","aurora-postgresql","sqlserver-se"]'
t idmember 0 fleet -P prod -r us-east-1 -F json -i 'orders-pg15-2'
jqt idmember '[.rows[].identifier] == ["orders-aurora-pg15"]'
t idglob 0 fleet -P prod -r us-east-1 -F json -i 'billing-*'
jqt idglob '(.rows | length) == 2'
t empty 0 empty -P prod -r us-east-1;  has empty out 'No servers matched'
echo "-- failures"
t lookupfail 0 lookupfail -P prod -r us-east-1 -F json
rowt lookupfail shop-aurora-mysql '.compliance_status == "UNKNOWN" and .versions_behind == null and .upgrade_command == "" and (.note | test("Throttling"))'
jqt lookupfail '.summary.unknown == 2 and .summary.errors == 0'
has lookupfail err 'WARN.*aurora-mysql failed'
t nolc 0 nolc -P prod -r us-east-1 -F json
jqt nolc '.meta.lifecycle_api == false and ([.rows[] | select(.engine == "postgres") | .support_flag] | unique) == ["unknown (lifecycle lookup unavailable)"]'
chk "nolc: lifecycle API tried only once" test "$(grep -c 'describe-db-major-engine-versions' "$MOCK_LOG")" -ge 1
t lcfail 0 lcfail -P prod -r us-east-1 -F json
jqt lcfail '.summary.non_compliant == 8 and .summary.past_standard_support == 0'
t denied 0 accessdenied -P prod -r us-east-1,eu-west-1
has denied out 'ERRORS'; has denied out 'eu-west-1: rds describe-db-clusters: .*AccessDenied'
t badcreds 2 badcreds -P prod -r us-east-1;  has badcreds err 'No profile could be used'
t onebroken 0 fleet -P prod,broken -r us-east-1 -F json;  jqt onebroken '(.errors | length) == 1 and .summary.total == 19'
t allreg 0 fleet -P nonprod --all-regions -F json;  jqt allreg '.meta.regions == ["ap-south-1","eu-west-1","us-east-1"] and .summary.total == 3'
MOCK_DEFAULT_REGION=ap-south-1 t defregion 0 fleet -P nonprod -F json;  jqt defregion '.summary.total == 3'
t noregion 2 fleet -P prod

echo "== output files"
t files 0 fleet "${P2[@]}" -F csv,html,txt,json -o "$OUT/rep" -T Environment,Owner
mapfile -t F < <(find "$OUT/rep" -type f | sort)
chk "4 files written" test "${#F[@]}" -eq 4
chk "files are 0640" test "$(stat -c %a "${F[@]}" | sort -u)" = 640
CSV="$(find "$OUT/rep" -name '*.csv')"; HTML="$(find "$OUT/rep" -name '*.html')"; TXT="$(find "$OUT/rep" -name '*.txt')"
chk "csv header" test "$(head -1 "$CSV")" = '"account_id","profile","region","resource_type","identifier","members","engine","major_version","current_version","latest_minor_version","versions_behind","newer_versions","compliance_status","auto_minor_upgrade","standard_support_end","extended_support_end","support_flag","pending_actions","deprecated_version","maint_window_utc","maint_window_ist","tag:Environment","tag:Owner","arn","upgrade_command","note"'
chk "csv rows = 22" test "$(python3 -c 'import csv,sys; print(sum(1 for _ in csv.reader(open(sys.argv[1])))-1)' "$CSV")" -eq 22
chk "csv parses with 26 columns everywhere" test "$(python3 -c 'import csv,sys; print(set(len(r) for r in csv.reader(open(sys.argv[1]))))' "$CSV")" = "{26}"
for p in 'id="q"' 'class="cp"' 'table class="main"' 'st bad' 'st ok' 'Extended Support' 'Top 10 most behind' 'Per engine and major version' 'localeCompare' 'href="#eng-aurora-postgresql"'; do
    if grep -qF -- "$p" "$HTML"; then ok "html has $p"; else bad "html lacks $p"; fi
done
chk "html is well-formed enough (python html.parser)" python3 -c 'import html.parser,sys; html.parser.HTMLParser().feed(open(sys.argv[1]).read())' "$HTML"
for p in '^SUMMARY' '^PER ENGINE / MAJOR VERSION' '^TOP 10 MOST BEHIND' '^=== aurora-postgresql: 7' '59.1% compliant' 'past standard support'; do
    if grep -qE -- "$p" "$TXT"; then ok "txt has /$p/"; else bad "txt lacks /$p/"; fi
done
chk "summary is at the top of the txt" test "$(grep -n '^SUMMARY' "$TXT" | cut -d: -f1)" -lt 8
t notags 0 fleet -P prod -r us-east-1 -F csv -T ''
chk "-T '' -> no tag columns" bash -c "! head -1 '$OUT/notags.out' | grep -q tag:"
t logf 0 fleet -P prod -r us-east-1 -l "$OUT/run.log"
chk "log file has timestamped lines" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} \[INFO\]' "$OUT/run.log"

echo "== large fleet (ARG_MAX safety)"
SECONDS=0
MOCK_LARGE_N=3000 t large 0 large -P prod -r us-east-1 -F csv,json,html -o "$OUT/large"
chk "large: 3000 rows" test "$(jq '.rows | length' "$(find "$OUT/large" -name '*.json')")" -eq 3000
chk "large: under 120s ($SECONDS s)" test "$SECONDS" -lt 120
hasnt large err 'Argument list too long'

echo "== alerts (local stubs only)"
t al_mail 0 fleet "${P2[@]}" --alert-email dba@example.com
chk "mail sent (subject)" grep -qF 'NON-COMPLIANT:\ 9\ non-compliant\ of\ 22' "$MAIL_SINK"
chk "mail body is the text report" grep -q '^PER ENGINE / MAJOR VERSION' "$MAIL_SINK"
: >"$MAIL_SINK"
t al_none 0 fleet -P prod -r us-east-1 -e docdb --alert-email dba@example.com
chk "no alert when all compliant (alert-on noncompliant)" test ! -s "$MAIL_SINK"
t al_hook 0 fleet "${P2[@]}" --alert-webhook "$HOOK" --alert-webhook-format json
chk "json webhook payload" bash -c "grep . '$OUT/webhook.txt' | tail -1 | jq -e '.status == \"NON-COMPLIANT\" and (.non_compliant | length) == 9' >/dev/null"
t al_slack 0 fleet "${P2[@]}" --alert-webhook "$HOOK"
chk "slack webhook payload" bash -c "grep . '$OUT/webhook.txt' | tail -1 | jq -e '.text | startswith(\"*[rds_patch_compliance]\")' >/dev/null"
hasnt al_slack err 'SECRET'
t al_test 0 fleet --alert-test --alert-email dba@example.com;  chk "test alert" grep -q 'Test alert from' "$MAIL_SINK"

echo "== hygiene"
chk "shellcheck script" shellcheck "$SCRIPT"
chk "shellcheck tests" shellcheck "$HERE/run_tests.sh" "$HERE/validate_cli.sh"
AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "no files written into the tool folder" test "$BEFORE" = "$AFTER"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
