#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2034,SC2054  # cond && ok || bad is safe; jq single-quoted; KEEP used in trap; comma lists are CLI args
# Test suite for rds_inventory_report.sh against the mock AWS CLI (tests/mock/aws).
# Guard: the mock must be the `aws` on PATH, credentials are fake, the endpoint is a dead local port and
# all output goes to a temp dir - nothing can reach AWS and nothing is written into the repo.
# Usage: tests/run_tests.sh [-k]   (-k keeps the temp output dir).  NODE_PATH with puppeteer-core enables the HTML check.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../rds_inventory_report.sh"
LIBJQ="$HERE/../lib/inventory.jq"
OUT="$(mktemp -d /tmp/rinv_tests.XXXXXX)"
KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0
export MOCK_LOG="$OUT/aws_calls.jsonl"
export PATH="$HERE/mock:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE MOCK_DEFAULT_REGION MOCK_SCENARIO
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_SESSION_TOKEN=fake \
       AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
       AWS_ENDPOINT_URL=http://127.0.0.1:9 TMPDIR="$OUT"
export MOCK_NOW=1792218600 RDS_INV_NOW=1792218600     # 2026-10-17 06:30 UTC (12:00 IST)
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
chk()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
jqt()  { if jq -e "$2" "$OUT/$1.out" >/dev/null 2>&1; then ok "$1 json: $2"; else bad "$1 json: $2 (got $(jq -c "$2" "$OUT/$1.out" 2>&1 | head -c 300))"; fi; }
row()  { jq -c --arg i "$2" '[.groups[].rows[] | select(.name == $i)][0]' "$OUT/$1.out"; }
rowt() { if row "$1" "$2" | jq -e "$3" >/dev/null 2>&1; then ok "$1 $2: $3"; else bad "$1 $2: $3 (got $(row "$1" "$2" | head -c 500))"; fi; }
uj()   { local r; r="$(jq -cn --arg mode "$1" --arg e "${2:-}" --arg v "${3:-}" --arg c "${2:-}" --argjson now 0 --argjson cfg '{}' -f "$LIBJQ")"
         if [[ "$r" == "$4" ]]; then ok "$1($2 $3) = $4"; else bad "$1($2 $3) = $r expected $4"; fi; }
P2=(-P prod,nonprod -r us-east-1,ap-south-1)

echo "== static"
chk "shellcheck script + tests" shellcheck "$SCRIPT" "$HERE/run_tests.sh" "$HERE/validate_cli.sh"
chk "jq library compiles" bash -c "jq -n --arg mode json --argjson now 0 --argjson cfg '{}' -f '$LIBJQ' >/dev/null"
chk "script never issues a cloudwatch call" bash -c "! grep -nE 'aws_call .* cloudwatch |get-metric-' '$SCRIPT'"

echo "== unit: major version, static class table"
uj major aurora-mysql 8.0.mysql_aurora.3.08.2 '"8.0"'; uj major aurora-postgresql 16.9 '"16"'; uj major postgres 9.6.24 '"9.6"'
uj major mysql 8.0.40 '"8.0"'; uj major sqlserver-se 15.00.4430.1.v1 '"15.00"'; uj major oracle-ee 19.0.0.0.ru-2025-01.rur-2025-01.r1 '"19"'
uj major mariadb 10.11.9 '"10.11"'
uj classinfo db.r6g.xlarge "" '{"vcpu":4,"mem":32}'; uj classinfo db.m6i.2xlarge "" '{"vcpu":8,"mem":32}'; uj classinfo db.t4g.medium "" '{"vcpu":2,"mem":4}'
uj classinfo db.x2g.large "" '{"vcpu":2,"mem":32}'; uj classinfo db.serverless "" '{"vcpu":null,"mem":null}'; uj classinfo db.weird.huge "" '{"vcpu":null,"mem":null}'

echo "== usage / validation"
t help 0 fleet --help; has help out "--include-docdb"; has help out "no CloudWatch"
t version 0 fleet -V; has version out "1\.0\.0"
t badopt 1 fleet --bogus
t badfmt 1 fleet -F xml
t multifmt_noout 1 fleet -F csv,html
t badregex 1 fleet --prod-regex '('
t badca 1 fleet --ca-days x
t badregion 1 fleet -r useast1
t both_regions 1 fleet -r us-east-1 -A

echo "== config file (parsed, never sourced)"
cat >"$OUT/good.conf" <<CONF
# comment
profiles = prod,nonprod
regions  = "us-east-1, ap-south-1"
tags = Environment,Owner   # inline comment
format = json
evil = \$(touch $OUT/PWNED)
CONF
t conf_unknown 1 fleet --config "$OUT/good.conf"
chk "config value never executed" test ! -e "$OUT/PWNED"
sed -i '/^evil/d' "$OUT/good.conf"
t conf_ok 0 fleet --config "$OUT/good.conf"
jqt conf_ok '(.groups | length) == 9 and .meta.options.tagcols == ["Environment","Owner"]'
printf 'aws_secret_access_key = x\n' >"$OUT/cred.conf"
t conf_cred 1 fleet --config "$OUT/cred.conf"; has conf_cred err "credentials are not accepted"

echo "== fleet: grouping"
: >"$MOCK_LOG"
t fleet 0 fleet "${P2[@]}" -F json
jqt fleet '[.groups[].type] == ["global","cluster","cluster","cluster","standalone","standalone","standalone","standalone","standalone"]'
jqt fleet '[.groups[0].rows[] | "\(.level):\(.role):\(.name)"] == ["0:global:pay-global","1:primary:pay-aurora-use1","2:writer:pay-use1-1","2:reader:pay-use1-2","2:reader:pay-use1-3","1:secondary:pay-aurora-aps1","2:reader:pay-aps1-1","1:secondary:pay-aurora-euw1"]'
jqt fleet '.groups[0].rows[0] | .primary_region == "us-east-1" and .secondary_regions == ["ap-south-1","eu-west-1"] and (.member_clusters | length) == 3'
rowt fleet pay-aurora-euw1 '.not_scanned == true and (.status | test("not scanned"))'
jqt fleet '[.groups[] | select(.title == "billing-pg") | .rows[] | "\(.role):\(.name):\(.region)"] == ["primary:billing-pg:us-east-1","read replica:billing-pg-replica:us-east-1","cross-region replica:billing-pg-dr:ap-south-1"]'
jqt fleet '[.groups[].rows[].name] | (index("billing-pg-dr") != null and (map(select(. == "billing-pg-dr")) | length) == 1)'
jqt fleet '[.groups[].rows[].name] | (index("catalog-docdb") == null and index("graph-neptune") == null and index("pay-aurora-aps1") != null)'
jqt fleet '[.groups[].rows[] | .group] as $g | ($g | . as $a | [range(1; length) | select($a[.] != $a[. - 1]) | $a[.]] | length + 1) == (.groups | length)'
jqt fleet '[.groups[].rows | (map(.seq) == [range(1; length + 1)])] | all'

echo "== fleet: fields"
rowt fleet crm-sv2 '.mode == "provisioned + serverless v2" and .acu_min == 0.5 and .acu_max == 16 and .reader_count == 0 and (.custom_endpoints[0].excluded == ["crm-sv2-1"])'
rowt fleet crm-sv2-1 '.class == "db.serverless" and .vcpu == null'
rowt fleet pay-aurora-use1 '.reader_count == 2 and .reader_endpoint != "" and .custom_endpoints[0].type == "READER" and .ssl.value == "rds.force_ssl=1" and .ssl.enforced == true and .vpc == "vpc-0a1b2c3d4e5f60718" and (.member_azs | length) == 3'
rowt fleet pay-use1-2 '.pending_maintenance[0].action == "system-update" and .pending_maintenance[0].current_apply == "2026-10-29" and .promotion_tier == 2 and .allocated_gb == null and .parameter_group_status == "in-sync"'
rowt fleet ledger-maz '.cluster_type == "Multi-AZ DB cluster" and .allocated_gb == 400 and .iops == 3000 and .storage_type == "io1" and .ca_cert == "rds-ca-rsa2048-g1"'
rowt fleet billing-pg '.class == "db.m6i.2xlarge" and .vcpu == 8 and .memory_gib == 32 and .allocated_gb == 500 and .iops == 12000 and .throughput == 500 and .max_allocated_gb == 1000 and .multi_az and .secondary_az == "us-east-1b" and ([.pending_maintenance[].action] == ["db-upgrade","os-upgrade"]) and .iam_auth and .ssl.enforced == true'
rowt fleet billing-pg-dr '.replica_source == "arn:aws:rds:us-east-1:111111111111:db:billing-pg" and .region == "ap-south-1"'
rowt fleet hr-sql '.ssl.value == "rds.force_ssl=0" and .ssl.enforced == false and .ca_cert == "rds-ca-ecc384-g1" and .ca_valid_till == "2026-12-16" and .parameter_group_status == "pending-reboot" and .option_group == "hr-sql15-og" and .log_exports == ["error","agent"]'
rowt fleet legacy-mysql '.ssl.value == "require_secure_transport=engine-default" and .standard_support_end == "2025-09-12" and (.support_status | test("extended support")) and .major == "5.7"'
rowt fleet report-pg '.status == "stopped" and .automatic_restart == "2026-10-22"'
rowt fleet dev-pg '.account == "222222222222" and .tags.Environment == "dev" and .performance_insights == false and .database_insights == "standard"'
rowt fleet pay-use1-1 '.tags == {"Environment":"prod","Owner":"payments","Application":"pay"} and .age_days == 400 and .created == "2025-09-12"'

echo "== fleet: risk flags + summary"
rowt fleet legacy-mysql '.flags == ["CA_EXPIRING","EXTENDED_SUPPORT","NO_DELETION_PROTECTION","PI_OFF","PUBLIC","RETENTION_LT_7","SINGLE_AZ_PROD","UNENCRYPTED"]'
rowt fleet crm-sv2 '.flags == ["SINGLE_AZ_PROD"]'
rowt fleet pay-aurora-use1 '.flags == []'
rowt fleet report-pg '.flags == ["STOPPED_AUTO_RESTART"]'
rowt fleet dev-aurora '(.flags | index("SUPPORT_ENDING")) != null'
rowt fleet dev-aurora-1 '(.flags | index("SUPPORT_ENDING")) == null'
rowt fleet billing-pg-replica '(.flags | index("RETENTION_LT_7")) == null'
jqt fleet '.summary | .groups == 9 and .global_clusters == 1 and .clusters == 5 and .instances == 16 and .allocated_gb == 2500 and .vcpu_total == 68'
jqt fleet '.summary.by_type | map({(.key): .count}) | add | .["Read replica"] == 2 and .["Multi-AZ DB cluster"] == 1 and .["Global cluster"] == 1'
jqt fleet '(.summary.by_major | map(.key) | index("mysql 5.7")) != null and (.summary.by_class | map(.key) | index("db.serverless")) != null'
jqt fleet '[.summary.flags[] | {(.flag): .count}] | add | .PUBLIC == 1 and .UNENCRYPTED == 1 and .NO_DELETION_PROTECTION == 3 and .SINGLE_AZ_PROD == 3 and .CA_EXPIRING == 2 and .EXTENDED_SUPPORT == 1 and .PI_OFF == 2 and .RETENTION_LT_7 == 1 and .STOPPED_AUTO_RESTART == 1'
jqt fleet '.meta.cloudwatch_calls == 0 and .errors == []'
chk "no CloudWatch / only read operations reached the mock" python3 -c "
import json,sys
ops=set(); svcs=set()
for l in open('$MOCK_LOG'):
    a=json.loads(l); k=[i for i,x in enumerate(a) if x in ('rds','sts','ec2','cloudwatch')]
    if k: svcs.add(a[k[0]]); ops.add(a[k[0]+1])
sys.exit(1 if 'cloudwatch' in svcs or any(not o.startswith(('describe-','get-','list-')) for o in ops) or 'describe-db-parameters' not in ops else 0)"

echo "== options"
t docdb 0 fleet "${P2[@]}" -F json --include-docdb
jqt docdb '([.groups[].title] | index("catalog-docdb") != null and index("graph-neptune") != null) and (.groups | length) == 11'
rowt docdb catalog-docdb '.cluster_type == "DocumentDB cluster" and .member_count == 2'
: >"$MOCK_LOG"
t fast 0 fleet "${P2[@]}" -F json --fast
rowt fast billing-pg '.ssl.value == "skipped (--fast)"'
chk "--fast makes no parameter-group calls" bash -c "! grep -qE 'describe-db-(cluster-)?parameters' '$MOCK_LOG'"
t tags 0 fleet "${P2[@]}" -F csv -T Owner,CostCenter
has tags out '^"group","group_type","seq".*"tag:Owner","tag:CostCenter"$'
t eng 0 fleet "${P2[@]}" -F json -e 'aurora-*'
jqt eng '[.groups[].engine] | unique == ["aurora-mysql","aurora-postgresql"]'
t ident 0 fleet "${P2[@]}" -F json -i billing-pg-dr
jqt ident '[.groups[].title] == ["billing-pg"] and (.groups[0].rows | length) == 3'
t ident2 0 fleet "${P2[@]}" -F json -i pay-aps1-1
jqt ident2 '[.groups[].title] == ["pay-global"]'
t prodre 0 fleet "${P2[@]}" -F json --prod-regex '^(prod|production|dev)$'
rowt prodre dev-pg '(.flags | index("SINGLE_AZ_PROD")) != null'
t cadays 0 fleet "${P2[@]}" -F json --ca-days 45
jqt cadays '[.summary.flags[] | select(.flag == "CA_EXPIRING")][0].count == 1'
t allreg 0 fleet -P prod -A -F json
jqt allreg '.meta.regions == ["ap-south-1","eu-west-1","us-east-1"] and ([.groups[] | select(.type == "global")] | length) == 1'
MOCK_DEFAULT_REGION=us-east-1 t defregion 0 fleet -P prod -F json
jqt defregion '.meta.regions == ["us-east-1"]'
rowt defregion pay-aurora-aps1 '.not_scanned == true'

echo "== failures"
t nolc 0 nolc "${P2[@]}" -F json
rowt nolc legacy-mysql '.support_status == "unknown" and (.flags | index("EXTENDED_SUPPORT")) == null'
jqt nolc '.errors == [] and .meta.lifecycle_api == false'
t paramdenied 0 paramdenied "${P2[@]}" -F json
rowt paramdenied billing-pg '.ssl.value == "lookup failed"'
jqt paramdenied '(.errors | length) > 0 and (.groups | length) == 9'
t globalfail 0 globalfail "${P2[@]}" -F json
jqt globalfail '([.groups[] | select(.type == "global")] | length) == 0 and ([.groups[].title] | index("pay-aurora-use1") != null) and (.errors | length) == 4'
t badcreds 2 badcreds -P prod -r us-east-1
t onebroken 0 fleet -P prod,broken -r us-east-1 -F json
jqt onebroken '(.errors | map(select(.profile == "broken")) | length) == 1 and (.groups | length) > 0'
t empty 0 empty "${P2[@]}" -F json
jqt empty '.summary.groups == 0 and .summary.allocated_gb == 0'
t empty_html 0 empty "${P2[@]}" -F html; has empty_html out "No match"

echo "== outputs"
t files 0 fleet "${P2[@]}" -F txt,csv,json,html -o "$OUT/rep" --prefix inv
chk "5 files written" test "$(find "$OUT/rep" -name 'inv_*' | wc -l)" -eq 5
f="$(find "$OUT/rep" -name 'inv_*[0-9].csv')"
chk "rows csv: header + 23 resource rows" test "$(wc -l <"$f")" -eq 24
chk "rows csv: rectangular, groups contiguous, writer before readers, sorted by group order" python3 -c "
import csv
r=list(csv.DictReader(open('$f')))
assert all(len(x)==len(r[0]) for x in r)
seen=[]; prev=None
for x in r:
    if x['group']!=prev:
        assert x['group'] not in seen, 'group split: '+x['group']; seen.append(x['group']); prev=x['group']
roles=[x['role'] for x in r if x['group'].startswith('cluster/111111111111/us-east-1/ledger-maz')]
assert roles==['cluster','writer','reader','reader'], roles
assert [x['group_type'] for x in r].index('standalone') > max(i for i,x in enumerate(r) if x['group_type']=='global')
"
has_f() { if grep -qE -- "$2" "$1"; then ok "${1##*/} has /$2/"; else bad "${1##*/} lacks /$2/"; fi; }
s="$(find "$OUT/rep" -name 'inv_*_summary.csv')"
has_f "$s" '^"total","allocated_gb_excl_aurora",2500'
has_f "$s" '^"flag","NO_DELETION_PROTECTION",3'
x="$(find "$OUT/rep" -name 'inv_*.txt')"
has_f "$x" 'Generated: 2026-10-17 12:00 IST \| 2026-10-17 06:30 UTC'
has_f "$x" '^#### \[GLOBAL\] pay-global'
chk "text: summary before groups" bash -c "[[ \$(grep -n '^== SUMMARY' '$x' | cut -d: -f1) -lt \$(grep -n '^== GROUPS' '$x' | cut -d: -f1) ]]"
chk "text: member lines follow their cluster" bash -c "grep -nE '(Aurora cluster \\[primary\\]: pay-aurora-use1|instance \\[writer\\]: pay-use1-1|Aurora cluster \\[secondary\\]: pay-aurora-aps1)' '$x' | cut -d: -f1 | paste -sd' ' | awk '{exit !(\$1<\$2 && \$2<\$3)}'"
h="$(find "$OUT/rep" -name 'inv_*.html')"
has_f "$h" '<details class=card data-type="global"'
chk "html: self-contained (no external src/href)" bash -c "! grep -qE '(src|href)=\"?https?:' '$h'"
if command -v node >/dev/null 2>&1 && node -e "require('puppeteer-core')" 2>/dev/null && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]]; then
    res="$(node "$HERE/html_check.js" "$h" 2>&1)"; rc=$?
    if (( rc == 0 )); then ok "html: search / highlight / count / '/' / clear / filters / expand-collapse (headless Chrome)"; else bad "html check: ${res:0:600}"; fi
else echo "  skip html interaction check (needs node + puppeteer-core on NODE_PATH + Chrome)"; fi

echo "== dry run / safety"
: >"$MOCK_LOG"
t dry 0 fleet "${P2[@]}" --dry-run; has dry out "describe-global-clusters"
chk "dry run made no AWS calls" test ! -s "$MOCK_LOG"
AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "repo tree unchanged by tests" test "$BEFORE" == "$AFTER"

echo "== scale"
s=$SECONDS
MOCK_LARGE_N=1500 t large 0 large -P prod -r us-east-1 -F json
jqt large '.summary.instances == 1800 and .summary.clusters == 150 and (.groups | length) == 1650'
chk "1800 instances in < 90s ($((SECONDS - s))s)" test $((SECONDS - s)) -lt 90

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
