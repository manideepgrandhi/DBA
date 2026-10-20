#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2034,SC2054  # cond && ok || bad is safe; jq single-quoted; KEEP used in trap; comma lists are CLI args
# Test suite for rds_backup_compliance_report.sh against the mock AWS CLI (tests/mock/aws).
# Guard: the mock must be the `aws` on PATH, credentials are fake, the endpoint is a dead local port and
# all output goes to a temp dir - nothing can reach AWS and nothing is written into the repo.
# Usage: tests/run_tests.sh [-k]   (-k keeps the temp output dir)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../rds_backup_compliance_report.sh"
LIBJQ="$HERE/../lib/backup_compliance.jq"
OUT="$(mktemp -d /tmp/rbc_tests.XXXXXX)"
KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0
export MOCK_LOG="$OUT/aws_calls.jsonl"
export PATH="$HERE/mock:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE MOCK_DEFAULT_REGION MOCK_SCENARIO
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_SESSION_TOKEN=fake \
       AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
       AWS_ENDPOINT_URL=http://127.0.0.1:9 TMPDIR="$OUT"
# fixed clock: 2026-10-17 06:30 UTC (12:00 IST), shared by the mock and the script
export MOCK_NOW=1792218600 RDS_BCR_NOW=1792218600
if [[ "$(command -v aws)" != "$HERE/mock/aws" || "$(aws --version 2>&1)" != *.mock* ]]; then
    echo "GUARD: 'aws' on PATH is not tests/mock/aws - refusing to run (would risk real AWS)"; exit 2
fi
BEFORE="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
trap '(( KEEP )) && echo "output kept in $OUT" || rm -rf -- "$OUT"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
t() {   # t <name> <expected-rc> <scenario> [args...]
    local name="$1" exp="$2" scen="$3"; shift 3
    MOCK_SCENARIO="$scen" "$SCRIPT" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"
    local rc=$?
    if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; sed 's/^/       /' "$OUT/$name.err" | tail -5; fi
}
has()  { if grep -qE -- "$3" "$OUT/$1.$2"; then ok "$1 $2 has /$3/"; else bad "$1 $2 lacks /$3/"; fi; }
hasnt(){ if grep -qE -- "$3" "$OUT/$1.$2"; then bad "$1 $2 unexpectedly has /$3/"; else ok "$1 $2 lacks /$3/"; fi; }
chk()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
jqt()  { if jq -e "$2" "$OUT/$1.out" >/dev/null 2>&1; then ok "$1 json: $2"; else bad "$1 json: $2"; fi; }
row()  { jq -c --arg i "$2" '.servers[] | select(.identifier == $i)' "$OUT/$1.out"; }
rowt() { if row "$1" "$2" | jq -e "$3" >/dev/null 2>&1; then ok "$1 $2: $3"; else bad "$1 $2: $3 (got $(row "$1" "$2" | head -c 600))"; fi; }
tsu()  { local r; r="$(jq -n --arg mode ts --arg s "$1" --argjson now 0 --argjson cfg '{}' -f "$LIBJQ")"
         if [[ "$r" == "$2" ]]; then ok "ts($1) = $2"; else bad "ts($1) = $r expected $2"; fi; }
P2=(-P prod,nonprod -r us-east-1,ap-south-1)

echo "== static"
chk "shellcheck script" shellcheck "$SCRIPT"
chk "shellcheck tests" shellcheck "$HERE/run_tests.sh" "$HERE/validate_cli.sh"
chk "jq library compiles" bash -c "jq -n --arg mode json --argjson now 0 --argjson cfg '{}' -f '$LIBJQ' >/dev/null"
chk "no write verbs in AWS calls of the script" bash -c "! grep -nE 'aws_call [^|]*(rds|backup) (delete|modify|create|start|stop|restore|copy|put|update|tag)-' '$SCRIPT'"

echo "== timestamp parsing (unit)"
tsu "2026-10-16T03:05:12.345000+00:00" 1792119912
tsu "2026-10-16T08:35:12.345000+05:30" 1792119912
tsu "2026-10-15T22:05:12-05:00" 1792119912
tsu "2026-10-16T03:05:12Z" 1792119912
tsu "garbage" null

echo "== usage / validation"
t help 0 fleet --help; has help out "--weekly-retention"
t version 0 fleet -V; has version out "1\.0\.0"
t badopt 1 fleet --bogus
t badfmt 1 fleet -F xml
t multifmt_noout 1 fleet -F csv,html
t badrange 1 fleet --weekly-retention 35-28
t badwindow 1 fleet --weekly-required 6 --weekly-window 30
t badprice 1 fleet --price-per-gb abc
t badregex 1 fleet --rule-name-fallback --weekly-rule-regex '('
t badregion 1 fleet -r useast1
t both_regions 1 fleet -r us-east-1 -A

echo "== config file (parsed, never sourced)"
cat >"$OUT/good.conf" <<CONF
# comment
profiles = prod,nonprod
regions  = "us-east-1, ap-south-1"
weekly_retention = 28-35   # inline comment
max_manual_age = 90
format = json
evil = \$(touch $OUT/PWNED)
CONF
t conf_unknown 1 fleet --config "$OUT/good.conf"
chk "config value never executed" test ! -e "$OUT/PWNED"
sed -i '/^evil/d' "$OUT/good.conf"
t conf_ok 0 fleet --config "$OUT/good.conf"
jqt conf_ok '.summary.total == 8 and (.meta.accounts | length) == 2'
printf 'aws_secret_access_key = x\n' >"$OUT/cred.conf"
t conf_cred 1 fleet --config "$OUT/cred.conf"; has conf_cred err "credentials are not accepted"
t conf_cli_override 0 fleet --config "$OUT/good.conf" -P prod -r us-east-1
jqt conf_cli_override '.summary.total == 7'

echo "== fleet: rules"
t fleet 0 fleet "${P2[@]}" -F json
jqt fleet '.summary | .total == 8 and .compliant == 2 and .non_compliant == 6 and .unknown == 0'
rowt fleet pay-aurora-pg '.compliance_status == "COMPLIANT" and .type == "Aurora cluster" and .members == ["pay-aurora-pg-1","pay-aurora-pg-2"] and .daily.days_ok == 7 and .weekly.count == 5 and .monthly.count == 12'
rowt fleet hr-sql '.compliance_status == "COMPLIANT" and .weekly.status == "PASS" and .monthly.status == "PASS"'
rowt fleet shop-aurora-mysql '.daily.status == "FAIL" and (.daily.missing_dates | length) == 2 and .weekly.status == "PASS" and .weekly.borderline == true and .monthly.status == "FAIL" and (.monthly.gaps | length) == 1'
rowt fleet billing-pg '.daily.retention == 3 and ([.failures[].code] | index("DAILY_RETENTION")) != null and .weekly.status == "PASS" and .monthly.count == 0'
rowt fleet inv-mysql '.daily.status == "PASS" and .no_aws_backup == true and ([.failures[].code] | index("NO_AWS_BACKUP")) != null'
rowt fleet crm-pg '.weekly.status == "FAIL" and .weekly.count == 3 and (.weekly.gaps | length) == 1 and .monthly.status == "PASS" and .daily.status == "PASS"'
rowt fleet ledger-maz '.type == "Multi-AZ DB cluster" and .daily.retention == 0 and .daily.status == "FAIL" and .weekly.status == "PASS"'
rowt fleet dev-pg '.account == "222222222222" and .region == "ap-south-1" and .no_aws_backup'
jqt fleet '[.servers[].identifier] | (index("billing-pg-replica") == null and index("catalog-docdb") == null and index("pay-aurora-pg-1") == null)'
jqt fleet '.summary.skipped_replicas == 1'
jqt fleet '.summary.weekly_borderline == 1 and .summary.no_aws_backup == 2'
jqt fleet '.summary.by_account | length == 2'
jqt fleet '.summary.top_failures[0].servers >= .summary.top_failures[-1].servers'
jqt fleet '.servers[0].compliance_status == "NON-COMPLIANT" and .servers[-1].compliance_status == "COMPLIANT"'

echo "== manual snapshots"
jqt fleet '.summary.manual | .count == 5 and .total_gb == 950 and .est_monthly_usd == 90.25 and .orphans == 2 and .oldest_days == 400'
jqt fleet '[.manual[].snapshot] | (index("awsbackup:job-0a1b2c3d") == null and index("crm-pg-adhoc") == null)'
jqt fleet '[.manual[] | select(.orphan) | .snapshot] | sort == ["old-app-final","retired-aurora-final"]'
jqt fleet '.manual | all(.delete_command | test("^aws rds delete-db-(cluster-)?snapshot --db-(cluster-)?snapshot-identifier .+ --region [a-z0-9-]+( --profile .+)?$"))'
t manual_age 0 fleet "${P2[@]}" -F json --max-manual-age 250 --price-per-gb 0.021
jqt manual_age '.summary.manual | .count == 2 and .total_gb == 520 and .est_monthly_usd == 10.92'
chk "delete commands never executed (no write op reached the mock)" bash -c "! jq -r '.[]' '$MOCK_LOG' | grep -qE '^(delete|modify|create|restore|copy|start|stop)-'"
chk "only describe/list/get operations were called" python3 -c "
import json,sys
ops=set()
for l in open('$MOCK_LOG'):
    a=json.loads(l); svc=[k for k,x in enumerate(a) if x in ('rds','backup','sts','ec2')]
    if svc: ops.add(a[svc[0]+1])
bad=[o for o in ops if not o.startswith(('describe-','list-','get-'))]
sys.exit(1 if bad or not ops else 0)"

echo "== options"
t fallback 0 fleet "${P2[@]}" -F json --rule-name-fallback
rowt fallback billing-pg '.monthly.status == "PASS" and .monthly.by_rule_name == 12'
rowt fallback crm-pg '.weekly.count == 3'
t wide 0 fleet "${P2[@]}" -F json --monthly-retention 360-400
rowt wide billing-pg '.monthly.status == "PASS" and .monthly.by_rule_name == 0'
t minret 0 fleet "${P2[@]}" -F json --min-retention 3 --daily-days 3
rowt minret billing-pg '.daily.status == "PASS"'
t ncfail 5 fleet "${P2[@]}" -F json --fail-on-noncompliant
t nconly 0 fleet "${P2[@]}" -F json --non-compliant-only
jqt nconly '(.servers | length) == 6 and .summary.total == 8'
t eng 0 fleet -P prod -r us-east-1 -F json -e 'aurora-*'
jqt eng '[.servers[].engine] | unique == ["aurora-mysql","aurora-postgresql"]'
t ident 0 fleet -P prod -r us-east-1 -F json -i 'pay-aurora-pg-2'
jqt ident '[.servers[].identifier] == ["pay-aurora-pg"]'
t replicas 0 fleet -P prod -r us-east-1 -F json --include-replicas
rowt replicas billing-pg-replica '.read_replica == true and .daily.status == "FAIL"'
t allreg 0 fleet -P nonprod -A -F json
jqt allreg '.meta.regions == ["ap-south-1","eu-west-1","us-east-1"] and .summary.total == 1'
t defregion 2 fleet -P prod -F json; has defregion err "no region given"
MOCK_DEFAULT_REGION=us-east-1 t defregion2 0 fleet -P prod -F json
jqt defregion2 '.meta.regions == ["us-east-1"] and .summary.total == 7'

echo "== monthly grace (clock 2026-11-01 10:00 UTC: November's point is not taken yet)"
MOCK_NOW=1793527200 RDS_BCR_NOW=1793527200 t grace 0 fleet -P prod -r us-east-1 -F json
rowt grace pay-aurora-pg '.monthly.status == "PASS" and .monthly.current_month_pending == true and .monthly.count == 11'
MOCK_NOW=1793527200 RDS_BCR_NOW=1793527200 t nograce 0 fleet -P prod -r us-east-1 -F json --monthly-grace-days 0
rowt nograce pay-aurora-pg '.monthly.status == "FAIL" and .monthly.gaps == ["2026-11"]'

echo "== failures"
t backupdenied 0 backupdenied -P prod -r us-east-1 -F json
rowt backupdenied pay-aurora-pg '.compliance_status == "UNKNOWN" and .weekly.status == "UNKNOWN" and .no_aws_backup == false'
rowt backupdenied billing-pg '.compliance_status == "NON-COMPLIANT"'
jqt backupdenied '.summary.errors >= 1 and .summary.no_aws_backup == 0'
t snapfail 0 snapfail -P prod -r us-east-1 -F json
rowt snapfail hr-sql '.daily.status == "UNKNOWN" and .compliance_status == "UNKNOWN"'
rowt snapfail billing-pg '.daily.status == "UNKNOWN" and .compliance_status == "NON-COMPLIANT"'
rowt snapfail shop-aurora-mysql '.daily.status == "FAIL"'
t badcreds 2 badcreds -P prod -r us-east-1
t onebroken 0 fleet -P prod,broken -r us-east-1 -F json
jqt onebroken '.summary.total == 7 and (.errors | map(select(.profile == "broken")) | length) == 1'
t empty 0 empty "${P2[@]}" -F json
jqt empty '.summary.total == 0 and .summary.pct_compliant == 0 and .summary.manual.count == 0'
t empty_text 0 empty "${P2[@]}"; has empty_text out "OVERALL  : 0 servers"

echo "== outputs"
t files 0 fleet "${P2[@]}" -F txt,csv,json,html -o "$OUT/rep" --prefix bc
chk "6 files written" test "$(find "$OUT/rep" -name 'bc_*' | wc -l)" -eq 6
f="$(find "$OUT/rep" -name 'bc_*[0-9].csv')"
chk "servers csv: header + 8 rows" test "$(wc -l <"$f")" -eq 9
chk "servers csv parses (python csv)" python3 -c "import csv,sys; r=list(csv.reader(open('$f'))); assert all(len(x)==len(r[0]) for x in r), 'width'"
chk "manual csv: header + 5 rows" test "$(wc -l <"$(find "$OUT/rep" -name 'bc_*_manual_snapshots.csv')")" -eq 6
has_f() { if grep -qE -- "$2" "$1"; then ok "${1##*/} has /$2/"; else bad "${1##*/} lacks /$2/"; fi; }
has_f "$(find "$OUT/rep" -name 'bc_*_summary.csv')" '^"overall","all",8,2,6,0,25'
h="$(find "$OUT/rep" -name 'bc_*.html')"
has_f "$h" 'BORDERLINE|borderline'
has_f "$h" 'IST &middot; 2026-10-17 06:30 UTC'
has_f "$h" 'delete-db-cluster-snapshot'
chk "html: no unescaped <script>" bash -c "! grep -q '<script' '$h'"
x="$(find "$OUT/rep" -name 'bc_*.txt')"
chk "text: summary comes before the server list" bash -c "[[ \$(grep -n '^== SUMMARY' '$x' | cut -d: -f1) -lt \$(grep -n '^== SERVERS' '$x' | cut -d: -f1) ]]"
has_f "$x" 'Generated: 2026-10-17 12:00 IST \| 2026-10-17 06:30 UTC'
has_f "$x" 'exactly 4 in the window is BORDERLINE'
has_f "$x" 'approximate'
t stdout_csv 0 fleet "${P2[@]}" -F csv; has stdout_csv out '^"account","profile"'
t tz 0 fleet -P prod -r us-east-1 --tz UTC; has tz out 'Generated: 2026-10-17 06:30 UTC'

echo "== dry run / safety"
: >"$MOCK_LOG"
t dry 0 fleet "${P2[@]}" --dry-run; has dry out "list-recovery-points-by-backup-vault"
chk "dry run made no AWS calls" test ! -s "$MOCK_LOG"
AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "repo tree unchanged by tests" test "$BEFORE" == "$AFTER"

echo "== scale"
s=$SECONDS
MOCK_LARGE_N=1500 t large 0 large -P prod -r us-east-1 -F json
jqt large '.summary.total == 1500 and .summary.compliant == 1500'
chk "1500 servers in < 60s ($((SECONDS - s))s)" test $((SECONDS - s)) -lt 60

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
