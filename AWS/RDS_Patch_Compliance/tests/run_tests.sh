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

echo "== oracle patch lines + same-major safety net (MOCK_SCENARIO=oracle)"
O=19.0.0.0.ru-
t ora 0 oracle -P prod -r us-east-1 -F json -v
rowt ora ora-mrp ".latest_minor_version == \"${O}2026-07.mrp-2026-07.r2\" and .versions_behind == 1 and .compliance_status == \"COMPLIANT\""
rowt ora ora-mrp ".newer_versions == [\"${O}2026-07.mrp-2026-07.r2\"] and (.note | contains(\"excluded ${O}2026-07.spb-2026-07.r1 (different patch line spb; current is mrp)\"))"
rowt ora ora-rur ".newer_versions == [\"${O}2026-01.rur-2026-04.r1\", \"${O}2026-04.rur-2026-04.r1\"] and (.excluded_targets | length) == 2"
rowt ora ora-ru ".newer_versions == [\"${O}2026-07.r1\", \"${O}2026-10.r1\"] and (.note | test(\"patch line mrp; current is plain RU\"))"
rowt ora ora-r9 ".newer_versions == [\"${O}2026-07.mrp-2026-07.r10\", \"${O}2026-10.mrp-2026-10.r1\"] and .versions_behind == 2"
rowt ora ora-r9 '(.note | contains("excluded 26.0.0.0.ru-2026-07.spb-1.r1 (different major version 26; current is 19)")) and (.newer_versions | index("19.0.0.0.ru-2026-07.mrp-2026-07.r8")) == null'
rowt ora ora-odd '.newer_versions == ["19.0.0.0.custom-build2"] and .version_warnings[0] != null'
has ora err 'DEBUG.*ora-odd: oracle version format not recognised'
has ora err 'DEBUG.*ora-mrp: excluded .*spb-2026-07.r1'
rowt ora sql15 '.newer_versions == ["15.00.4440.1.v1"] and (.note | contains("excluded 16.00.4185.3.v1 (different major version 16; current is 15)"))'
rowt ora my80 '.newer_versions == ["8.0.44"] and (.note | contains("excluded 8.4.6 (different major version 8.4; current is 8.0)"))'
rowt ora amy2 '.newer_versions == ["5.7.mysql_aurora.2.12.4"] and (.note | test("different major version 3; current is 2"))'
jqt ora '.summary.engines[] | select(.engine == "oracle-ee") | .majors[0].latest_minor | contains("mrp: 19.0.0.0.ru-2026-10.mrp-2026-10.r1") and contains("plain RU: 19.0.0.0.ru-2026-10.r1")'
t ora_any 0 oracle -P prod -r us-east-1 -F json --oracle-any-patch-line
rowt ora_any ora-mrp ".latest_minor_version == \"${O}2026-07.mrp-2026-07.r2\" and .versions_behind == 2 and (.newer_versions | index(\"${O}2026-07.spb-2026-07.r1\")) != null and (.excluded_targets | length) == 0"
rowt ora_any ora-r9 '(.newer_versions | length) == 2'
jqt ora_any '.meta.oracle_any_patch_line == true'
printf 'oracle_any_patch_line = yes\n' >"$OUT/oal.conf"
t ora_conf 0 oracle --config "$OUT/oal.conf" -P prod -r us-east-1 -F json
rowt ora_conf ora-mrp '.versions_behind == 2'
vce() { local r; r="$(jq -n --arg mode vcmp_e --arg e "$1" --arg a "$2" --arg b "$4" --argjson now 0 --argjson max_behind 2 --argjson warn_days 180 --argjson top_n 10 \
            --argjson tagcols '[]' --argjson f '{}' --argjson nc_only false -f "$LIBJQ")"; if [[ "$r" == "$3" ]]; then ok "vcmp_e $2 vs $4 = $3"; else bad "vcmp_e $2 vs $4 = $r expected $3"; fi; }
vce oracle-ee "${O}2026-07.mrp-2026-07.r10" 1 "${O}2026-07.mrp-2026-07.r9"
vce oracle-ee "${O}2026-07.mrp-2026-07.r2" 1 "${O}2026-07.mrp-2026-07.r1"
vce oracle-ee "${O}2026-10.mrp-2026-10.r1" 1 "${O}2026-07.mrp-2026-07.r10"

echo "== usage / validation"
t help 0 fleet --help;               has help out 'Exit codes'; has help out 'read-only'; has help out '--max-behind'; has help out 'NEVER run'
t version 0 fleet --version;         has version out '1\.3\.0'
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
jqt fleet '.summary.total == 22 and .summary.compliant == 13 and .summary.non_compliant == 8 and .summary.unknown == 1'
jqt fleet '.summary.pct_compliant == 59.1'
jqt fleet '[.meta.accounts[].account] == ["111111111111","222222222222"]'
jqt fleet '[.rows[].identifier] | index("unrelated-redis-like") == null'
jqt fleet '[.rows[].identifier] | map(select(test("^orders-pg15-|^pay-aurora-pg16-|^ledger-maz-[0-9]"))) | length == 0'
chk "engine versions looked up once per engine+region (cache)" test "$(jq -c 'select(index("describe-db-engine-versions"))' "$MOCK_LOG" | sort | uniq -d | wc -l)" -eq 0
chk "one inventory call per profile+region" test "$(jq -c 'select(index("describe-db-instances"))' "$MOCK_LOG" | wc -l)" -eq 4
chk "only describe/get calls were made" test "$(jq -r '.[] | select(test("^(modify|create|delete|apply|reboot|start|stop|failover)-"))' "$MOCK_LOG" | wc -l)" -eq 0
echo "-- rule and boundaries"
rowt fleet crm-aurora-pg15 '.versions_behind == 2 and .compliance_status == "COMPLIANT" and .newer_versions == ["15.12","15.13"]'
rowt fleet orders-aurora-pg15 '.versions_behind == 2 and .compliance_status == "COMPLIANT" and .newer_versions == ["15.10","15.12"] and .latest_minor_version == "15.12"'
rowt fleet reports-aurora-pg14 '.versions_behind == 3 and .compliance_status == "NON-COMPLIANT" and .newer_versions == ["14.13","14.15","14.17"]'
echo "-- counts come ONLY from ValidUpgradeTarget of the current version (mock full list differs on purpose)"
rowt fleet orders-aurora-pg15 '(.newer_versions | index("15.13")) == null and .major_upgrade_targets == 2'
rowt fleet reports-aurora-pg14 '(.newer_versions | index("14.18")) == null and .latest_minor_version == "14.17"'
rowt fleet shop-aurora-mysql '.newer_versions == ["8.0.mysql_aurora.3.06.0","8.0.mysql_aurora.3.07.1","8.0.mysql_aurora.3.08.2","8.0.mysql_aurora.3.09.0","8.0.mysql_aurora.3.10.0"]'
rowt fleet inv-mysql '([.newer_versions[] | select(startswith("8.4"))] | length) == 0 and .major_upgrade_targets == 2'
rowt fleet graph-neptune '.newer_versions == ["1.3.3.0","1.3.4.0"] and .default_auto_upgrade_target == "1.3.4.0"'
rowt fleet analytics-pg '([.newer_versions[] | select(startswith("13.") | not)] | length) == 0'
echo "-- default auto-upgrade target"
rowt fleet orders-aurora-pg15 '.default_auto_upgrade_target == "15.12"'
rowt fleet inv-mysql '.default_auto_upgrade_target == "8.0.40"'
rowt fleet shop-aurora-mysql '.default_auto_upgrade_target == "8.0.mysql_aurora.3.08.2"'
rowt fleet pay-aurora-pg16 '.default_auto_upgrade_target == null'
chk "every engine-version call names --engine-version (no full-list call)" test "$(jq -c 'select(index("describe-db-engine-versions")) | select(index("--engine-version") | not)' "$MOCK_LOG" | wc -l)" -eq 0
chk "engine-version calls = distinct engine+version+region" test "$(jq -c 'select(index("describe-db-engine-versions"))' "$MOCK_LOG" | wc -l)" -eq "$(jq '[.rows[] | [.engine, .current_version, .region]] | unique | length' "$OUT/fleet.out")"
rowt fleet dev-aurora-pg15 '.versions_behind == 7 and .latest_minor_version == "15.13" and .account_id == "222222222222" and .region == "ap-south-1"'
rowt fleet pay-aurora-pg16 '.versions_behind == 0 and .compliance_status == "COMPLIANT" and .upgrade_command == ""'
rowt fleet shop-aurora-mysql '.versions_behind == 5 and .major_version == "8.0" and .latest_minor_version == "8.0.mysql_aurora.3.10.0"'
rowt fleet cms-aurora-mysql '.versions_behind == 1 and .compliance_status == "COMPLIANT"'
rowt fleet hr-sql '.versions_behind == 3 and .major_version == "15.00" and .latest_minor_version == "15.00.4430.1.v1" and .compliance_status == "NON-COMPLIANT"'
rowt fleet erp-sql '.versions_behind == 1 and .major_version == "16.00"'
rowt fleet fin-ora '.versions_behind == 2 and .major_version == "19" and .compliance_status == "COMPLIANT"'
rowt fleet inv-mysql '.versions_behind == 6 and .auto_minor_upgrade == "false" and .pending_actions_count == 2'
rowt fleet app-mysql84 '.versions_behind == 0 and .major_version == "8.4"'
rowt fleet analytics-pg '.versions_behind == 3 and .newer_versions == ["13.20","13.21","13.22"]'
rowt fleet billing-pg '.versions_behind == 2 and .resource_type == "instance" and .members == ""'
rowt fleet dev-mariadb '.versions_behind == 2 and .major_version == "10.11"'
rowt fleet qa-pg '.versions_behind == 2 and .latest_minor_version == "17.6"'
rowt fleet catalog-docdb '.resource_type == "docdb-cluster" and .versions_behind == 0 and .pending_actions_count == 1 and .major_version == "5.0"'
rowt fleet graph-neptune '.resource_type == "neptune-cluster" and .versions_behind == 2 and .major_version == "1.3" and (.support_flag | startswith("n/a"))'
rowt fleet ledger-maz '.resource_type == "multi-az-cluster" and .versions_behind == 3 and .member_count == 3 and .auto_minor_upgrade == "true"'
echo "-- support / flags"
rowt fleet legacy-aurora-pg12 '.support_flag == "past standard support (Extended Support charges)" and .past_standard_support and .extended_support_end != null'
rowt fleet old-aurora-pg11 '.deprecated_version and .compliance_status == "UNKNOWN" and .versions_behind == null and .newer_versions == [] and .latest_minor_version == null and .upgrade_command == "" and (.note | test("current version not returned by describe-db-engine-versions"))'
rowt fleet analytics-pg '.nearing_end_of_support and (.support_flag | test("^standard support ends in 1[0-9][0-9] days$"))'
rowt fleet inv-mysql '.nearing_end_of_support'
rowt fleet hr-sql '(.support_flag | startswith("unknown"))'
rowt fleet reports-aurora-pg14 '.auto_minor_upgrade == "false"'
rowt fleet shop-aurora-mysql '.auto_minor_upgrade == "mixed" and (.note | test("off on some members"))'
rowt fleet orders-aurora-pg15 '.pending_actions_count == 2 and .members == "orders-pg15-1 (writer), orders-pg15-2, orders-pg15-3" and .member_count == 3'
rowt fleet orders-aurora-pg15 '.maint_window_utc == "sat:21:00-sat:21:30" and .maint_window_ist == "sun:02:30-sun:03:00"'
rowt fleet hr-sql '.maint_window_ist == "sun:00:00-sun:00:30"'
rowt fleet orders-aurora-pg15 '.tags.Owner == "orders" and (.arn | test("^arn:aws:rds:us-east-1:111111111111:cluster:orders-aurora-pg15$"))'
jqt fleet '.summary.past_standard_support == 2 and .summary.nearing_end_of_support == 2 and .summary.auto_minor_off == 3 and .summary.with_pending == 3 and .summary.pending_total == 5 and .summary.deprecated == 1'
jqt fleet '.summary.pending_by_action == {"os-upgrade":2,"system-update":2,"db-upgrade":1}'
echo "-- pending maintenance text"
rowt fleet orders-aurora-pg15 '(.pending_actions | test("^system-update on cluster \\(auto-apply [0-9]{4}-[0-9]{2}-[0-9]{2}, forced [0-9]{4}-[0-9]{2}-[0-9]{2}\\) - Upgrade to Aurora PostgreSQL 15.8.1 patch; os-upgrade on member orders-pg15-2 \\(opt-in: next-maintenance\\) - New Operating System update is available$"))'
rowt fleet orders-aurora-pg15 '.pending_actions_detail[0].auto_applied_after_ist | test("^[0-9]{4}-[0-9]{2}-[0-9]{2} 01:30 IST$")'
rowt fleet inv-mysql '(.pending_actions | test("^db-upgrade \\(auto-apply [0-9-]{10}\\) - Automatic minor version upgrade to 8.0.40; os-upgrade \\(no date, optional\\) - New Operating System update is available; it includes sec\\.\\.\\.$"))'
rowt fleet catalog-docdb '(.pending_actions | startswith("system-update on member catalog-docdb-2 (auto-apply "))'
rowt fleet pay-aurora-pg16 '.pending_actions == "" and .pending_actions_count == 0'
echo "-- upgrade commands (printed only)"
rowt fleet orders-aurora-pg15 '.upgrade_command == "aws rds modify-db-cluster --db-cluster-identifier orders-aurora-pg15 --engine-version 15.12 --region us-east-1 --profile prod"'
rowt fleet inv-mysql '.upgrade_command == "aws rds modify-db-instance --db-instance-identifier inv-mysql --engine-version 8.0.43 --region us-east-1 --profile prod"'
rowt fleet graph-neptune '(.upgrade_command | startswith("aws neptune modify-db-cluster --db-cluster-identifier graph-neptune --engine-version 1.3.4.0"))'
rowt fleet fin-ora '(.upgrade_command | test("--engine-version 19.0.0.0.ru-2025-07.rur-2025-07.r1 "))'
jqt fleet '[.rows[].upgrade_command | select(test("apply-immediately"))] | length == 0'
t noprofile 0 fleet -r us-east-1 -F json -e postgres
jqt noprofile '[.rows[].upgrade_command | select(. != "" and test("--profile"))] | length == 0'
jqt noprofile '[.rows[].profile] | unique == ["default"]'
echo "-- sorting / summary"
jqt fleet '[.rows[] | select(.engine == "aurora-postgresql") | .identifier] == ["dev-aurora-pg15","legacy-aurora-pg12","reports-aurora-pg14","old-aurora-pg11","crm-aurora-pg15","orders-aurora-pg15","pay-aurora-pg16"]'
jqt fleet '.summary.top_behind[0].identifier == "dev-aurora-pg15" and (.summary.top_behind | length) == 10'
jqt fleet '(.summary.engines[] | select(.engine == "aurora-postgresql") | .majors | map(.major)) == ["16","15","14","12","11"]'
jqt fleet '(.summary.engines[] | select(.engine == "aurora-postgresql") | .majors[] | select(.major == "15")) | .total == 3 and .compliant == 2 and .non_compliant == 1 and .latest_minor == "15.13"'
jqt fleet '(.summary.engines[] | select(.engine == "aurora-postgresql") | .majors[] | select(.major == "14")) | .latest_minor == "14.17"'
t top3 0 fleet "${P2[@]}" -F json --top 3;   jqt top3 '(.summary.top_behind | length) == 3'
echo "-- options"
t max3 0 fleet -P prod -r us-east-1 -F json --max-behind 3
rowt max3 reports-aurora-pg14 '.compliance_status == "COMPLIANT"';  rowt max3 shop-aurora-mysql '.compliance_status == "NON-COMPLIANT"'
t max0 0 fleet -P prod -r us-east-1 -F json --max-behind 0
rowt max0 cms-aurora-mysql '.compliance_status == "NON-COMPLIANT"';  rowt max0 pay-aurora-pg16 '.compliance_status == "COMPLIANT"'
t warn100 0 fleet -P prod -r us-east-1 -F json --warn-days 100;  jqt warn100 '.summary.nearing_end_of_support == 0'
t nconly 0 fleet "${P2[@]}" -F json --non-compliant-only
jqt nconly '(.rows | length) == 8 and all(.rows[]; .compliance_status == "NON-COMPLIANT") and .summary.total == 22'
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
jqt lookupfail '.summary.unknown == 3 and .summary.errors == 0'
has lookupfail err 'WARN.*aurora-mysql .* failed'
t nolc 0 nolc -P prod -r us-east-1 -F json
jqt nolc '.meta.lifecycle_api == false and ([.rows[] | select(.engine == "postgres") | .support_flag] | unique) == ["unknown (lifecycle lookup unavailable)"]'
chk "nolc: lifecycle API tried only once" test "$(grep -c 'describe-db-major-engine-versions' "$MOCK_LOG")" -ge 1
t lcfail 0 lcfail -P prod -r us-east-1 -F json
jqt lcfail '.summary.non_compliant == 7 and .summary.past_standard_support == 0'
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
chk "5 files written (txt, html, json, csv, regions csv)" test "${#F[@]}" -eq 5
chk "files are 0640" test "$(stat -c %a "${F[@]}" | sort -u)" = 640
CSV="$(find "$OUT/rep" -name '*.csv' ! -name '*_regions.csv')"; HTML="$(find "$OUT/rep" -name '*.html')"; TXT="$(find "$OUT/rep" -name '*.txt')"
chk "csv header" test "$(head -1 "$CSV")" = '"account_id","profile","region","resource_type","identifier","members","engine","major_version","current_version","latest_minor_version","versions_behind","newer_versions","default_auto_upgrade_target","compliance_status","auto_minor_upgrade","standard_support_end","extended_support_end","support_flag","pending_actions_count","pending_actions","deprecated_version","maint_window_utc","maint_window_ist","tag:Environment","tag:Owner","arn","upgrade_command","note","next_maintenance","days_until_maintenance"'
chk "csv rows = 22" test "$(python3 -c 'import csv,sys; print(sum(1 for _ in csv.reader(open(sys.argv[1])))-1)' "$CSV")" -eq 22
chk "csv parses with 30 columns everywhere" test "$(python3 -c 'import csv,sys; print(set(len(r) for r in csv.reader(open(sys.argv[1]))))' "$CSV")" = "{30}"
for p in 'id="q"' 'class="cp"' 'class="badge">2<' 'details class="pend"' '01:30 IST' "haven't been applied yet" 'Valid minor targets' 'Auto-upgrade default' 'table class="main"' 'st bad' 'st ok' 'Extended Support' 'Top 10 most behind' 'Per engine and major version' 'localeCompare' 'href="#eng-aurora-postgresql"'; do
    if grep -qF -- "$p" "$HTML"; then ok "html has $p"; else bad "html lacks $p"; fi
done
chk "html is well-formed enough (python html.parser)" python3 -c 'import html.parser,sys; html.parser.HTMLParser().feed(open(sys.argv[1]).read())' "$HTML"
for p in '^SUMMARY' '^PER ENGINE / MAJOR VERSION' '^TOP 10 MOST BEHIND' '^=== aurora-postgresql: 7' '59.1% compliant' 'past standard support' 'Pending maint\.   : on 3 server\(s\): os-upgrade 2, system-update 2, db-upgrade 1' '^      pending: os-upgrade on member orders-pg15-2'; do
    if grep -qE -- "$p" "$TXT"; then ok "txt has /$p/"; else bad "txt lacks /$p/"; fi
done
chk "summary is at the top of the txt" test "$(grep -n '^SUMMARY' "$TXT" | cut -d: -f1)" -lt 10
t notags 0 fleet -P prod -r us-east-1 -F csv -T ''
chk "-T '' -> no tag columns" bash -c "! head -1 '$OUT/notags.out' | grep -q tag:"
t logf 0 fleet -P prod -r us-east-1 -l "$OUT/run.log"
chk "log file has timestamped lines" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} \[INFO\]' "$OUT/run.log"

echo "== region discovery (-A) and region-wise breakdown (MOCK_SCENARIO=discover: 14 regions)"
# prod: us-east-1 = fleet, us-west-2 = one headless Aurora cluster only, ca-central-1 = describe-db-instances AccessDenied (SCP)
api_calls() { jq -c 'select(.[0] == "--output")' "$MOCK_LOG" | wc -l; }   # AWS API calls (not `aws --version` / `aws configure get`)
probes() { jq -c 'select(index("--query"))' "$MOCK_LOG" | wc -l; }
full_regions() { jq -r 'select(index("describe-db-instances") and (index("--query") | not)) | .[index("--region") + 1]' "$MOCK_LOG" | sort -u | paste -sd, -; }
: >"$MOCK_LOG"
t disc 0 discover -P prod -A -F json
jqt disc '.summary.region_overview | .mode == "discover" and .probe_parallel == 8 and .checked == 14 and .with_databases == 2 and .empty == 11 and .error == 1'
jqt disc '[.summary.regions[] | select(.status == "empty") | .region] == ["ap-northeast-1","ap-south-1","ap-southeast-1","ap-southeast-2","eu-central-1","eu-north-1","eu-west-1","eu-west-2","sa-east-1","us-east-2","us-west-1"]'
jqt disc '[.summary.regions[] | select(.status == "empty") | .total + .compliant + .non_compliant + .unknown + .with_pending] | add == 0'
chk "disc: 28 probes (2 per enabled region)" test "$(probes)" -eq 28
chk "disc: full scan only where databases or a probe error ($(full_regions))" test "$(full_regions)" == "ca-central-1,us-east-1,us-west-2"
chk "disc: no pending-maintenance call in an empty region" test "$(jq -c 'select(index("describe-pending-maintenance-actions")) | select(index("eu-west-1") or index("us-east-2"))' "$MOCK_LOG" | wc -l)" -eq 0
jqt disc '.summary.regions[] | select(.region == "us-west-2") | .status == "databases" and .total == 1 and .compliant == 1 and .probe_instances == 0 and .probe_clusters == 1'
rowt disc dr-aurora-pg15 '.region == "us-west-2" and .resource_type == "aurora-cluster" and .member_count == 0'
jqt disc '.summary.regions[] | select(.region == "ca-central-1") | .status == "error" and .probe_instances == null and .probe_clusters == 0 and .errors >= 1'
jqt disc '[.errors[] | select(.region == "ca-central-1" and .call == "rds describe-db-instances (discovery probe)" and (.message | test("AccessDenied")) and (.message | test("scanned in full anyway")))] | length == 1'
jqt disc '.meta.aws_failures >= 1'
chk "disc: aws_calls (incl. probes) = calls made ($(jq .meta.aws_calls "$OUT/disc.out") vs $(api_calls))" test "$(jq .meta.aws_calls "$OUT/disc.out")" -eq "$(api_calls)"
jqt disc '.meta.regions | length == 14'
echo "-- breakdown totals = overall totals"
jqt disc '.summary as $s | [$s.regions[].total] | add == $s.total'
jqt disc '.summary as $s | ([$s.regions[].compliant] | add) == $s.compliant and ([$s.regions[].non_compliant] | add) == $s.non_compliant and ([$s.regions[].unknown] | add) == $s.unknown and ([$s.regions[].with_pending] | add) == $s.with_pending'
jqt disc '.summary as $s | $s.regions_total | .region == "All regions" and .total == $s.total and .compliant == $s.compliant and .non_compliant == $s.non_compliant and .unknown == $s.unknown and .pct_compliant == $s.pct_compliant and .with_pending == $s.with_pending'
jqt disc '.summary.regions[] | select(.region == "us-east-1") | .total == 19 and .compliant == 11 and .non_compliant == 7 and .unknown == 1 and .pct_compliant == 57.9 and .with_pending == 3'
jqt disc '.summary as $s | [.rows[] | select(.region == "us-east-1")] | length == ($s.regions[] | select(.region == "us-east-1") | .total)'
t disc_txt 0 discover -P prod -A
has disc_txt out '^Regions  : 14 checked, 2 with databases, 11 empty, 1 error \(discovery probe, 8 in parallel'
hasnt disc_txt out '^Empty'
has disc_txt out '^Accounts : 111111111111 \(prod\)   Regions: all enabled$'
chk "disc_txt: no region names above SUMMARY" test "$(sed '/^SUMMARY/q' "$OUT/disc_txt.out" | grep -cE '[a-z]{2}-[a-z]+-[0-9]')" -eq 0
has disc_txt out '^PER REGION'
has disc_txt out '^  111111111111  us-east-1       databases      19     11      7     1   57\.9%     3'
has disc_txt out '^  111111111111  ca-central-1    error           0 .* see ERRORS \(no data\)'
hasnt disc_txt out '^  [0-9]{12}  [a-z0-9-]+ +empty '
chk "disc_txt: PER REGION = 2 databases + 1 error + ALL rows" test "$(sed -n '/^PER REGION/,/^$/p' "$OUT/disc_txt.out" | grep -cE '^  (111111111111|ALL) ')" -eq 4
has disc_txt out '^  ALL           All regions                    20     12      7     1     60%     3'
has disc_txt out 'ca-central-1: rds describe-db-instances \(discovery probe\): .*AccessDenied'
has disc_txt err 'discovery: probing 14 region\(s\), 8 at a time'
t disc_files 0 discover -P prod -A -F csv,html -o "$OUT/disc"
RCSV="$(find "$OUT/disc" -name '*_regions.csv')"; RHTML="$(find "$OUT/disc" -name '*.html')"
chk "regions csv written" test -s "$RCSV"
chk "regions csv: header + 2 regions with databases + 1 error + All regions (no empty rows)" test "$(wc -l <"$RCSV")" -eq 5
chk "regions csv: no empty-region rows" test "$(grep -c '"empty"' "$RCSV")" -eq 0
chk "regions csv: All regions row" grep -q '^"ALL","","All regions","",20,12,7,1,60,3,5,2,2,"",""$' "$RCSV"
chk "regions csv parses with 15 columns everywhere" test "$(python3 -c 'import csv,sys; print(set(len(r) for r in csv.reader(open(sys.argv[1]))))' "$RCSV")" == "{15}"
chk "html: sortable region table" grep -q '<table class="sortable regions"><thead><tr><th>Account</th><th>Region</th><th>Status</th><th>Total</th>' "$RHTML"
chk "html: All regions total row in tfoot" grep -q '<tfoot><tr class="foot"><td><b>All regions</b></td>' "$RHTML"
chk "html: colour-coded % compliant" grep -q 'class="n bad" data-s="57.9">57.9%<div class="bar"><i class="bad"' "$RHTML"
chk "html: no empty-regions list" test "$(grep -c 'details class="empty"\|empty region(s)' "$RHTML")" -eq 0
chk "html: header region line is counts only" grep -q '&middot; Regions: 14 checked, 2 with databases, 11 empty, 1 error</p></header>' "$RHTML"
TOPH="$(cat "$RHTML")"; TOPH="${TOPH%%<table*}"   # everything above the first table
chk "html: no region names above the first table" test "$(grep -oE '[a-z]{2}-[a-z]+-[0-9]' <<<"$TOPH" | wc -l)" -eq 0
chk "html: no <details> in the header" test "$(grep -o '<header.*</header>' "$RHTML" | grep -c '<details')" -eq 0
chk "html: region table = 3 rows (databases + error), no empty rows" test "$(grep -oP '<table class="sortable regions">.*?</tbody>' "$RHTML" | grep -o '<tr[ >]' | wc -l)" -eq 4
chk "html: no empty status chip" test "$(grep -c 'class="st unk">empty<' "$RHTML")" -eq 0
chk "html: sort script covers the region table" grep -q "querySelectorAll('table.main,table.sortable')" "$RHTML"
echo "-- --no-discover / config / explicit -r"
: >"$MOCK_LOG"
t nodisc 0 discover -P prod -A --no-discover -F json
chk "nodisc: no probe" test "$(probes)" -eq 0
chk "nodisc: every enabled region scanned in full" test "$(jq -r 'select(index("describe-db-instances")) | .[index("--region") + 1]' "$MOCK_LOG" | sort -u | wc -l)" -eq 14
jqt nodisc '.summary.region_overview | .mode == "full" and .checked == 14 and .with_databases == 2 and .empty == 11 and .error == 1'
jqt nodisc '.meta.region_discovery.probe_parallel == null and ([.meta.region_status[].status] | unique) == ["scanned"]'
jqt nodisc '.summary.total == 20 and .summary.compliant == 12'
chk "nodisc: same rows as with discovery" test "$(jq -c '[.rows[] | [.account_id, .region, .identifier, .compliance_status]] | sort' "$OUT/nodisc.out")" == "$(jq -c '[.rows[] | [.account_id, .region, .identifier, .compliance_status]] | sort' "$OUT/disc.out")"
printf 'profiles = prod\nall_regions = yes\ndiscover = no\nformat = json\n' >"$OUT/nd.conf"
: >"$MOCK_LOG"
t nodisc_conf 0 discover --config "$OUT/nd.conf"
chk "discover = no in config: no probe" test "$(probes)" -eq 0
jqt nodisc_conf '.summary.region_overview.mode == "full"'
: >"$MOCK_LOG"
t disc_r 0 discover -P prod -r us-east-1,us-west-2,eu-west-1 -F json
chk "-r: no probe" test "$(probes)" -eq 0
chk "-r: only the named regions" test "$(full_regions)" == "eu-west-1,us-east-1,us-west-2"
jqt disc_r '.summary.region_overview | .mode == "explicit" and .checked == 3 and .with_databases == 2 and .empty == 1 and .error == 0'
t disc_r_txt 0 discover -P prod -r us-east-1,us-west-2
has disc_r_txt out '^Regions  : 2 checked, 2 with databases, 0 empty, 0 errors \(queried directly, no probe\)'
t badpp 1 discover -P prod -A --probe-parallel 0;   has badpp err 'probe-parallel'
t badpp2 1 discover -P prod -A --probe-parallel 33
echo "-- parallel probes"
: >"$MOCK_LOG"; rm -f "$OUT/timing.jsonl"
SECONDS=0
MOCK_PROBE_DELAY=0.6 MOCK_TIMING="$OUT/timing.jsonl" t par 0 discover -P prod -A --probe-parallel 4 -F json
PAR_S=$SECONDS
MAXC="$(python3 - "$OUT/timing.jsonl" <<'PY'
import json, sys
ev = sorted([(a, 1) for a, b, *_ in map(json.loads, open(sys.argv[1]))] + [(b, -1) for a, b, *_ in map(json.loads, open(sys.argv[1]))], key=lambda e: (e[0], e[1]))
c = m = 0
for _, d in ev: c += d; m = max(m, c)
print(m)
PY
)"
chk "par: 27 probe calls timed (the 28th, ca-central-1 instances, is denied before the delay)" test "$(wc -l <"$OUT/timing.jsonl")" -eq 27
chk "par: probes ran in parallel, at most 4 at a time (max concurrent = $MAXC)" test "$MAXC" -ge 2 -a "$MAXC" -le 4
chk "par: faster than serial (28 x 0.6s = 16.8s; took ${PAR_S}s)" test "$PAR_S" -lt 14
chk "par: same breakdown as default parallelism" test "$(jq -c '.summary.regions' "$OUT/par.out")" == "$(jq -c '.summary.regions' "$OUT/disc.out")"
chk "par: aws_calls (incl. probes) = calls made" test "$(jq .meta.aws_calls "$OUT/par.out")" -eq "$(api_calls)"
t ser 0 discover -P prod -A --probe-parallel 1 -F json
chk "ser: --probe-parallel 1 gives the same breakdown" test "$(jq -c '.summary.regions' "$OUT/ser.out")" == "$(jq -c '.summary.regions' "$OUT/disc.out")"
echo "-- multi-account + other scenarios"
t disc2 0 discover -P prod,nonprod -A -F json
jqt disc2 '.summary.region_overview | .checked == 28 and .with_databases + .empty + .error == 28'
jqt disc2 '.summary as $s | ([$s.regions[].total] | add) == $s.total and $s.regions_total.total == $s.total'
jqt disc2 '[.summary.regions[] | select(.status == "databases") | "\(.account_id)/\(.region)"] | sort == ["111111111111/us-east-1","111111111111/us-west-2","222222222222/ap-south-1"]'
t disc2_txt 0 discover -P prod,nonprod -A
hasnt disc2_txt out '^Empty'
has disc2_txt out '^Regions  : 28 checked, 3 with databases, 23 empty, 2 errors'
t ad_disc 0 accessdenied -P prod -A -F json
jqt ad_disc '.summary.regions[] | select(.region == "eu-west-1") | .status == "error"'
jqt ad_disc '[.errors[] | select(.region == "eu-west-1" and .call == "rds describe-db-clusters (discovery probe)")] | length == 1'
: >"$MOCK_LOG"
t disc_dry 0 discover -P prod -A --dry-run
has disc_dry out 'discovery probe, every enabled region, 8 at a time \(2 calls per region\)'
has disc_dry out 'rds describe-db-instances --max-records 20 --query length.?\(DBInstances.?\) --no-paginate'
has disc_dry out 'rds describe-db-clusters --max-records 20 --query length.?\(DBClusters.?\) --no-paginate'
has disc_dry out 'full scan, only regions where a probe found'
chk "disc_dry: no AWS calls" test ! -s "$MOCK_LOG"
t nodisc_dry 0 discover -P prod -A --no-discover --dry-run;  hasnt nodisc_dry out 'length\(DBInstances\)'
t r_dry 0 discover -P prod -r us-east-1 --dry-run;           hasnt r_dry out 'length\(DBInstances\)'

echo "== large fleet (ARG_MAX safety)"
SECONDS=0
MOCK_LARGE_N=3000 t large 0 large -P prod -r us-east-1 -F csv,json,html -o "$OUT/large"
chk "large: 3000 rows" test "$(jq '.rows | length' "$(find "$OUT/large" -name '*.json')")" -eq 3000
chk "large: under 120s ($SECONDS s)" test "$SECONDS" -lt 120
hasnt large err 'Argument list too long'

echo "== alerts (local stubs only)"
t al_mail 0 fleet "${P2[@]}" --alert-email dba@example.com
chk "mail sent (subject)" grep -qF 'NON-COMPLIANT:\ 8\ non-compliant\ of\ 22' "$MAIL_SINK"
chk "mail body is the text report" grep -q '^PER ENGINE / MAJOR VERSION' "$MAIL_SINK"
: >"$MAIL_SINK"
t al_none 0 fleet -P prod -r us-east-1 -e docdb --alert-email dba@example.com
chk "no alert when all compliant (alert-on noncompliant)" test ! -s "$MAIL_SINK"
t al_hook 0 fleet "${P2[@]}" --alert-webhook "$HOOK" --alert-webhook-format json
chk "json webhook payload" bash -c "grep . '$OUT/webhook.txt' | tail -1 | jq -e '.status == \"NON-COMPLIANT\" and (.non_compliant | length) == 8' >/dev/null"
t al_slack 0 fleet "${P2[@]}" --alert-webhook "$HOOK"
chk "slack webhook payload" bash -c "grep . '$OUT/webhook.txt' | tail -1 | jq -e '.text | startswith(\"*[rds_patch_compliance]\")' >/dev/null"
hasnt al_slack err 'SECRET'
t al_test 0 fleet --alert-test --alert-email dba@example.com;  chk "test alert" grep -q 'Test alert from' "$MAIL_SINK"

echo "== v1.3.0: account number in file names, --save-data, --merge (offline)"
MG="$OUT/mg in"; mkdir -p "$MG"
RDS_PCR_NOW=1790000000 t sd_prod 0 fleet -P prod -r us-east-1,ap-south-1 -F html,csv -o "$MG" --save-data
chk "single account: html name has the account number" test -f "$MG/rds_patch_compliance_111111111111_20260921_194320.html"
chk "single account: csv + regions csv names have the account number" test -f "$MG/rds_patch_compliance_111111111111_20260921_194320_regions.csv"
SD1="$MG/rds_patch_111111111111_20260921.json"
chk "save-data default name rds_patch_<acct>_<date>.json" test -f "$SD1"
chk "save-data: schema, account, profile, collected_at UTC" jq -e '.schema == "rds_patch_compliance_data" and .schema_version == 1 and .accounts == [{account: "111111111111", profile: "prod", collected_epoch: 1790000000, collected_at: "2026-09-21T14:13:20Z"}] and .collected_at == "2026-09-21T14:13:20Z"' "$SD1"
chk "save-data: regions with databases only" jq -e '.regions == ["us-east-1"]' "$SD1"
chk "save-data: per DB engine / versions / status / pending" jq -e '(.rows | length) == 19 and all(.rows[]; has("engine") and has("current_version") and has("latest_minor_version") and has("compliance_status") and has("pending_actions_detail") and .account_id == "111111111111")' "$SD1"
chk "save-data: region_status kept (empty ap-south-1 counted)" jq -e '[.region_status[] | select(.region == "ap-south-1")] | length == 1' "$SD1"
calls_before="$(wc -l <"$MOCK_LOG")"
RDS_PCR_NOW=1790000000 t sd_prod_calls 0 fleet -P prod -r us-east-1 --save-data "$OUT/sdcalls/x.json"
chk "save-data adds no AWS call (describe + sts only)" bash -c "tail -n +$(( calls_before + 1 )) '$MOCK_LOG' | grep -qE '\"(create|modify|delete|apply|reboot|start|stop|put|add|remove|restore|copy|failover|promote)-' && exit 1 || tail -n +$(( calls_before + 1 )) '$MOCK_LOG' | grep -q describe-db"
RDS_PCR_NOW=1790100000 t sd_np 0 fleet -P nonprod -r ap-south-1 --save-data "$MG/nonprod data.json"
chk "save-data FILE with a space" test -f "$MG/nonprod data.json"
RDS_PCR_NOW=1790200000 t sd_dev 0 fleet -P dev -r eu-west-1 -F json -o "$MG" --save-data
SD3="$MG/rds_patch_333333333333_20260923.json"; chk "dev data file" test -f "$SD3"
RDS_PCR_NOW=1790000000 t sd_multi 0 fleet -P prod,nonprod -r us-east-1,ap-south-1 -F html -o "$OUT/sdm" --save-data
chk "multi-account run: one data file per account" test "$(find "$OUT/sdm" -name 'rds_patch_[0-9]*_*.json' | wc -l)" -eq 2
chk "multi-account run: html name without an account number" test "$(find "$OUT/sdm" -name 'rds_patch_compliance_2026*.html' | wc -l)" -eq 1
t sd_badname 1 fleet -P prod -r us-east-1 --save-data "$OUT/x.txt"
t sd_badname2 1 fleet -P prod -r us-east-1 --save-data "$OUT/x.txt"; has sd_badname2 err 'must end in .json'

# older prod copy: the newer collection must win
jq '.collected_epoch = 1780000000 | .collected_at = "2026-05-28T20:26:40Z" | .accounts[0].collected_epoch = 1780000000 | .rows |= map(.compliance_status = "NON-COMPLIANT" | .versions_behind = 9)' "$SD1" >"$OUT/old_prod.json"
calls_before="$(wc -l <"$MOCK_LOG")"
NOAWS="$OUT/noaws"; mkdir -p "$NOAWS"; printf '#!/bin/sh\necho AWS-CALLED >>"%s/aws_called"; exit 99\n' "$OUT" >"$NOAWS/aws"; chmod +x "$NOAWS/aws"
mg() { local name="$1" exp="$2"; shift 2; PATH="$NOAWS:$PATH" RDS_PCR_NOW=1791000000 t "$name" "$exp" fleet "$@"; }
mg merge 0 --merge "$OUT/old_prod.json" "$MG" -o "$OUT/mg out/combined.html" -F html,json
MH="$OUT/mg out/combined.html"; MJ="$OUT/mg out/combined.json"
chk "merge: -o FILE.html written" test -s "$MH"
chk "merge: json next to it" test -s "$MJ"
chk "merge: zero AWS calls (no aws exec, mock log unchanged)" test ! -e "$OUT/aws_called" -a "$(wc -l <"$MOCK_LOG")" -eq "$calls_before"
has merge err 'Skipping .*rds_patch_compliance_333333333333_.*\.json \(not a --save-data file\)'
has merge err 'Account 111111111111: using newer rds_patch_111111111111_20260921\.json .* ignoring older old_prod\.json'
has merge err '0 AWS calls'
chk "merge: 3 accounts, 24 rows, newer prod data used" jq -e '(.meta.accounts | map(.account)) == ["111111111111","222222222222","333333333333"] and (.rows | length) == 24 and .summary.non_compliant == 9' "$MJ"
chk "merge: totals = sum of single runs" jq -e '.summary.total == 24 and .summary.compliant == 14 and .summary.unknown == 1' "$MJ"
chk "merge: per-account breakdown" jq -e '[.summary.accounts[] | [.account_id, .total, .non_compliant]] == [["111111111111",19,7],["222222222222",3,1],["333333333333",2,1]]' "$MJ"
chk "merge: per region by account, empty regions left out" jq -e '[.summary.regions[] | select(.status != "empty") | .account_id + "|" + .region] == ["111111111111|us-east-1","222222222222|ap-south-1","333333333333|eu-west-1"]' "$MJ"
chk "merge: support days recomputed at merge time" jq -e '[.rows[] | select(.standard_support_end != null and .standard_support_end != "")] | length > 5 and all(.[]; .support_days_left == (((.standard_support_end + "T00:00:00Z" | fromdateiso8601) - 1791000000) / 86400 | floor))' "$MJ"
chk "merge: days differ from the collection-time copy" test "$(jq '[.rows[] | select(.identifier == "shop-aurora-mysql") | .support_days_left][0]' "$SD1")" != "$(jq '[.rows[] | select(.identifier == "shop-aurora-mysql") | .support_days_left][0]' "$MJ")"
chk "merge: days until maintenance recomputed" jq -e '[.rows[] | select(.pending_actions_count > 0) | .days_until_maintenance | numbers] | length >= 1' "$MJ"
chk "merge: sources note data" jq -e '.meta.merge.files == 4 and ([.meta.merge.sources[] | select(.file == "old_prod.json") | .superseded] == [["111111111111"]])' "$MJ"
chk "merge html: header has counts, no region names" bash -c "grep -oP '<header id=\"top\">.*?</header>' '$MH' | grep -q 'Regions: 4 checked, 3 with databases, 1 empty, 0 errors' && ! grep -oP '<header id=\"top\">.*?</header>' '$MH' | grep -qE '[a-z]{2}-[a-z]+-[0-9]'"
chk "merge html: account dropdown, region / engine / status selects, name search, Export CSV" bash -c "grep -q 'id=\"f-acct\"' '$MH' && grep -q 'id=\"f-region\"' '$MH' && grep -q 'id=\"f-engine\"' '$MH' && grep -q 'id=\"f-status\"' '$MH' && grep -q 'id=\"q\"' '$MH' && grep -q 'id=\"f-csv\"' '$MH'"
chk "merge html: per account table + merged inputs note" bash -c "grep -q '<section id=\"accounts\">' '$MH' && grep -q '<section id=\"sources\">' '$MH' && grep -q 'old_prod.json' '$MH'"
chk "merge html: no empty region rows" test "$(grep -oP '<table class="sortable regions">.*?</tbody>' "$MH" | grep -o '<tr[ >]' | wc -l)" -eq 4
chk "merge html: embedded data cannot close the script tag" bash -c "grep -oP '<script type=\"application/json\" id=\"pc-data\">\K.*?(?=</script>)' '$MH' | grep -q . && ! grep -oP '<script type=\"application/json\" id=\"pc-data\">\K.*?(?=</script>)' '$MH' | grep -q '<'"
mg merge_txt 0 --merge "$SD1" "$MG/nonprod data.json" "$SD3" -F text; has merge_txt out '^PER ACCOUNT'; has merge_txt out '^Accounts : 111111111111 \(prod\), 222222222222 \(nonprod\), 333333333333 \(dev\)   Merged: 3 file\(s\)'
mg merge_dir_default 0 --merge "$MG" -o "$OUT/mgd"
chk "merge: default format html, -o DIR" test "$(find "$OUT/mgd" -name 'rds_patch_compliance_2026*.html' | wc -l)" -eq 1
mg merge_mb 0 --merge "$SD1" --max-behind 9 -F json; jqt merge_mb '.summary.non_compliant == 0'
mg merge_glob 0 --merge "$MG/rds_patch_1*.json" -F json; jqt merge_glob '(.meta.accounts | length) == 1'
# errors -> exit 3
mg mbad_missing 3 --merge "$OUT/nope.json";           has mbad_missing err 'File not found'
printf '{"rows": [' >"$OUT/trunc.json";  mg mbad_trunc 3 --merge "$OUT/trunc.json";   has mbad_trunc err 'not valid JSON'
mg mbad_html 3 --merge "$MH";                         has mbad_html err 'is an HTML report'
mg mbad_report 3 --merge "$MJ";                        has mbad_report err 'is a -F json report'
echo '{"schema":"rds_patch_compliance_data","schema_version":2,"accounts":[{"account":"1"}],"rows":[],"collected_epoch":1}' >"$OUT/v2.json"
mg mbad_v2 3 --merge "$OUT/v2.json";                  has mbad_v2 err 'newer data schema 2'
echo '{"schema":"x"}' >"$OUT/other.json"; mg mbad_other 3 --merge "$OUT/other.json"; has mbad_other err 'not a patch compliance data file'
mkdir -p "$OUT/emptydir"; mg mbad_dir 3 --merge "$OUT/emptydir";  has mbad_dir err 'No --save-data JSON file'
mg mbad_noargs 1 --merge
mg mbad_profile 1 --merge "$SD1" -P prod
mg mbad_region 1 --merge "$SD1" -r us-east-1
# Git Bash: jq.exe writes CRLF, Windows paths, spaces
CR="$OUT/crlfjq"; mkdir -p "$CR"; REALJQ="$(command -v jq)"
printf '#!/bin/bash\n"%s" "$@" | sed '"'"'s/$/\\r/'"'"'; exit "${PIPESTATUS[0]}"\n' "$REALJQ" >"$CR/jq"; chmod +x "$CR/jq"
mkdir -p "$OUT/drv/c/Users/DBA Team/patch data"; cp "$SD1" "$MG/nonprod data.json" "$SD3" "$OUT/drv/c/Users/DBA Team/patch data/"
PATH="$CR:$NOAWS:$PATH" RDS_PCR_DRIVE_ROOT="$OUT/drv" RDS_PCR_NOW=1791000000 t merge_win 0 fleet --merge 'C:\Users\DBA Team\patch data' -o "$OUT/win out/combined.html" -F html,json,csv
chk "git bash: CRLF jq output -> HTML has no CR" bash -c "test -s '$OUT/win out/combined.html' && ! grep -q $'\r' '$OUT/win out/combined.html'"
chk "git bash: same numbers as the LF merge" test "$(jq -c '[.summary.total, .summary.non_compliant, (.summary.accounts | length)]' "$OUT/win out/combined.json")" = '[24,9,3]'
chk "git bash: windows path with spaces resolved" grep -q 'Input 1: .*drv/c/Users/DBA Team/patch data/' "$OUT/merge_win.err"
chk "git bash: no aws executed" test ! -e "$OUT/aws_called"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    res="$(node "$HERE/browser_check.js" "$MH" ${SHOTS:+"$SHOTS"} 2>&1)"; rc=$?
    chk "browser: filters, totals, per region, CSV export ($(jq -r '.checks' <<<"$res" 2>/dev/null) checks) ${res:0:300}" test "$rc" -eq 0
    res="$(node "$HERE/browser_check.js" "$(find "$MG" -name 'rds_patch_compliance_111111111111_*.html' | head -1)" 2>&1)"; rc=$?
    chk "browser: single-account report ${res:0:300}" test "$rc" -eq 0
else echo "  skip browser check (node + puppeteer-core on NODE_PATH + Chrome not found)"; fi

echo "== hygiene"
chk "shellcheck script" shellcheck "$SCRIPT"
chk "shellcheck tests" shellcheck "$HERE/run_tests.sh" "$HERE/validate_cli.sh"
AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "no files written into the tool folder" test "$BEFORE" = "$AFTER"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
