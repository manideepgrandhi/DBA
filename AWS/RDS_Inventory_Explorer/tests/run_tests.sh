#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2034  # cond && ok || bad is safe; jq programs are single-quoted on purpose
# Test suite for rds_inventory_explorer.sh against the mock AWS CLI (tests/mock/aws).
# Guard: the mock must be the `aws` on PATH, credentials are fake, the endpoint is a dead local port and all output
# goes to a temp dir - nothing can reach AWS and nothing is written into the repo.
# Usage: tests/run_tests.sh [-k]   (-k keeps the temp dir).  NODE_PATH with puppeteer-core (+ Chrome) enables the browser check.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../rds_inventory_explorer.sh"
LIBJQ="$HERE/../lib/explorer.jq"
TPL="$HERE/../lib/explorer_template.html"
OUT="$(mktemp -d /tmp/rexp_tests.XXXXXX)"
KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0
export MOCK_LOG="$OUT/aws_calls.jsonl"
export PATH="$HERE/mock:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE MOCK_DEFAULT_REGION MOCK_SCENARIO
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_SESSION_TOKEN=fake \
       AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
       AWS_ENDPOINT_URL=http://127.0.0.1:9 TMPDIR="$OUT" TZ=UTC
export MOCK_NOW=1792218600 RDS_EXPLORER_NOW=1792218600     # 2026-10-17 06:30 UTC (12:00 IST)
if [[ "$(command -v aws)" != "$HERE/mock/aws" || "$(aws --version 2>&1)" != *.mock* ]]; then
    echo "GUARD: 'aws' on PATH is not tests/mock/aws - refusing to run (would risk real AWS)"; exit 2
fi
BEFORE="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
trap '(( KEEP )) && echo "output kept in $OUT" || rm -rf -- "$OUT"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
chk()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
t() {   # t <name> <expected-rc> <scenario> [args...]   (output dir: $OUT/<name>)
    local name="$1" exp="$2" scen="$3"; shift 3
    MOCK_SCENARIO="$scen" "$SCRIPT" -o "$OUT/$name" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"
    local rc=$?
    if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; sed 's/^/       /' "$OUT/$name.err" | tail -5; fi
    html="$(find "$OUT/$name" -name '*.html' 2>/dev/null | head -1)"
    if [[ -n "$html" ]]; then   # the page's embedded data model -> $OUT/<name>.json
        sed -n 's|.*<script type="application/json" id="explorer-data">\(.*\)</script>.*|\1|p' "$html" >"$OUT/$name.json"
    fi
}
has()  { if grep -qE -- "$3" "$OUT/$1.$2"; then ok "$1 $2 has /$3/"; else bad "$1 $2 lacks /$3/"; fi; }
hasnt(){ if ! grep -qE -- "$3" "$OUT/$1.$2"; then ok "$1 $2 has no /$3/"; else bad "$1 $2 has /$3/: $(grep -oE -- "$3" "$OUT/$1.$2" | head -3 | tr '\n' ' ')"; fi; }
jqt()  { if jq -e "$2" "$OUT/$1.json" >/dev/null 2>&1; then ok "$1: $2"; else bad "$1: $2 (got $(jq -c "$2" "$OUT/$1.json" 2>&1 | head -c 300))"; fi; }
res()  { jq -c --arg n "$2" '[.resources[] | select(.name == $n)][0]' "$OUT/$1.json"; }
rt()   { if res "$1" "$2" | jq -e "$3" >/dev/null 2>&1; then ok "$1 $2: $3"; else bad "$1 $2: $3 (got $(res "$1" "$2" | jq -c "$3" 2>&1 | head -c 400))"; fi; }
calls(){ jq -r 'select(.[0] != "--version" and .[0] != "configure") | join(" ")' "$MOCK_LOG"; }
FLEET=(-P "prod,nonprod,broken" -A)

echo "== static"
chk "shellcheck script + tests" shellcheck "$SCRIPT" "$HERE/run_tests.sh" "$HERE/validate_cli.sh"
chk "jq library compiles on an empty fleet" bash -c "jq -n '{meta: {tz_offset: 19800, tz_abbr: \"IST\", now: 0, include_docdb: false, accounts: []}, regions: [], errors: []}' | jq -e -f '$LIBJQ' >/dev/null"
chk "template has exactly one data placeholder" test "$(grep -o '/\*__EXPLORER_DATA__\*/' "$TPL" | wc -l)" -eq 1
chk "template loads nothing from the network" bash -c "! grep -qE '(src|href)=\"?(https?:)?//' '$TPL'"
chk "script never calls CloudWatch / Secrets Manager / KMS" bash -c "! grep -nE 'aws_call [^#]* (cloudwatch|secretsmanager|kms|logs) |get-metric-|get-secret-value' '$SCRIPT'"

echo "== usage / validation"
t help 0 fleet --help; has help out "--probe-parallel"; has help out "no CloudWatch"; has help out "-P prod,dev -A"
t version 0 fleet -V; has version out "rds_inventory_explorer.sh 1\.2\.0"; has help out "--csv"; has help out "--save-data"; has help out "--merge FILE"
t badopt 1 fleet --bogus
t noarg 1 fleet -P
t both_regions 1 fleet -r us-east-1 -A
t badregion 1 fleet -r useast1
t badprefix 1 fleet --prefix 'a/b'
t badtz 1 fleet --tz Mars/Olympus
t pp0 1 fleet -A --probe-parallel 0
t pp33 1 fleet -A --probe-parallel 33
t nodisc_noA 1 fleet --no-discover
t badtimeout 1 fleet --aws-timeout 0
touch "$OUT/afile"; MOCK_SCENARIO=fleet "$SCRIPT" -o "$OUT/afile/x" -P prod -r us-east-1 >/dev/null 2>&1; chk "unwritable output dir -> rc 1" test $? -eq 1

echo "== fleet: 2 accounts + 1 broken profile, all regions with discovery"
: >"$MOCK_LOG"
t fleet 0 fleet "${FLEET[@]}"
F="$(find "$OUT/fleet" -name '*.html')"
chk "file name <prefix>_YYYYmmdd_HHMMSS.html" test "${F##*/}" == "rds_inventory_explorer_20261017_063000.html"
chk "file mode 0640" test "$(stat -c %a "$F")" == 640
jqt fleet '.meta.counts == {accounts: 2, regions_with_databases: 3, global_clusters: 1, clusters: 4, instances: 14, standalone_instances: 5, cluster_members: 9, pending_maintenance: 5, pending_actions: 5, pending_past_due: 1, pending_due_7d: 1, pending_due_30d: 2, errors: 7}'
jqt fleet '.meta.generated_utc == "2026-10-17 06:30 UTC" and .meta.generated_local == "2026-10-17 12:00 IST" and .meta.tz_offset == 19800'
jqt fleet '.meta.cloudwatch_calls == 0 and .meta.region_mode == "discover"'
jqt fleet '[.resources[] | select(.engine | test("docdb|neptune"))] == []'
jqt fleet '[.resources[] | .region] | unique == ["ap-south-1", "us-east-1"]'
jqt fleet '[.errors[] | select(.profile == "broken")][0].message | test("InvalidClientTokenId")'
jqt fleet '[.errors[] | select(.region == "me-central-1")] | length == 6'
jqt fleet '[.resources[] | .raw | type] | unique == ["object"]'
echo "-- global cluster"
rt fleet pay-global '.type == "global" and .id == "arn:aws:rds::111111111111:global-cluster:pay-global" and .region == "us-east-1" and .regions == ["ap-south-1","us-east-1"]'
rt fleet pay-global '.d.primary_region == "us-east-1" and .d.secondary_regions == ["ap-south-1"] and .d.write_forwarding == ["pay-aurora-aps1"]'
rt fleet pay-global '[.d.members[] | .id != null] == [true, true] and .d.members[0].role == "primary" and .d.deletion_protection == true and .d.storage_encrypted == true'
rt fleet pay-global '.d.endpoint == "pay-global.global-abc123xyz.global.rds.amazonaws.com"'
jqt fleet '[.resources[] | select(.type == "global")] | length == 1'
echo "-- Aurora clusters"
rt fleet pay-aurora-use1 '.d.global.id == "arn:aws:rds::111111111111:global-cluster:pay-global" and .d.writer == "pay-use1-1"'
rt fleet pay-aurora-use1 '.d.master.managed and (.d.master.secret_arn | test("secret:rds!pay-aurora-use1")) and (.d.master.secret_kms | test("key/5ec7"))'
rt fleet pay-aurora-use1 '(.d.kms_key | test("^arn:aws:kms:")) and (.d.pi_kms | length) == 1 and (.d.pi_kms[0] | test("key/9e1f"))'
rt fleet pay-aurora-use1 '.d.backup.retention_days == 14 and .d.backup.window == {utc: "19:00-19:30 UTC", local: "00:30-01:00 IST"} and .d.backup.copy_tags_to_snapshot == true'
rt fleet pay-aurora-use1 '.d.backup.earliest_restorable.utc != null and .d.backup.earliest_restorable.days < 0'
rt fleet pay-aurora-use1 '.d.maintenance_window == {utc: "sat:21:00-sat:21:30 UTC", local: "sun:02:30-sun:03:00 IST"}'
rt fleet pay-aurora-use1 '.d.auto_minor_members == {on: 1, off: 1} and .d.auto_minor_cluster == null'
rt fleet pay-aurora-use1 '[.d.members[] | [.name, .role, .port, (.endpoint | test("\\.rds\\.amazonaws\\.com$")), .auto_minor]] == [["pay-use1-1","writer",5432,true,true],["pay-use1-2","reader",5432,true,false]]'
rt fleet pay-aurora-aps1 '.d.global_write_forwarding == "enabled" and .d.global.name == "pay-global" and .d.master.username == null'
rt fleet orders-aurora '.d.custom_endpoints == [{name: "orders-reporting", endpoint: "orders-reporting.cluster-custom-cxyzabc123.us-east-1.rds.amazonaws.com", type: "READER", status: "available", static: ["orders-3"], excluded: []}]'
rt fleet orders-aurora '.d.reader_endpoint == "orders-aurora.cluster-ro-cxyzabc123.us-east-1.rds.amazonaws.com" and .d.port == 3306 and .d.master.username == "admin" and .d.master.managed == false'
rt fleet orders-aurora '(.d.members | map(.name)) == ["orders-1","orders-2","orders-3"] and .d.storage_type == "aurora-iopt1"'
rt fleet orders-aurora '.d.pending == [{action: "db-upgrade", description: "Upgrade to 8.0.mysql_aurora.3.10.0", opt_in: null, auto_applied_after: null, forced_apply: {utc: "2027-01-15 06:30 UTC", local: "2027-01-15 12:00 IST", days: 90}, current_apply: null}]'
rt fleet orders-aurora '.d.member_pending[0].name == "orders-2" and .d.member_pending[0].pending[0].opt_in == "next-maintenance"'
rt fleet ledger-maz '.type_label == "Multi-AZ DB cluster" and .d.auto_minor_cluster == true and .class != null and .d.ca.id != null and (.d.pi_kms | length) == 1'
echo "-- instances"
rt fleet pay-use1-2 '.type == "member" and .d.cluster == {name: "pay-aurora-use1", id: "arn:aws:rds:us-east-1:111111111111:cluster:pay-aurora-use1", role: "reader"} and .d.auto_minor == false and .d.global.name == "pay-global"'
rt fleet crm-pg '.type == "instance" and .d.storage == {type: "gp3", allocated_gb: 500, max_allocated_gb: 1000, iops: 12000, throughput: 500} and .d.multi_az == true'
rt fleet crm-pg '[.d.replicas[] | [.name, .region, (.id != null)]] == [["crm-pg-rr1","us-east-1",true],["crm-pg-replica-aps1","ap-south-1",true]]'
rt fleet crm-pg '.d.master.managed and .d.iam_auth == true and .d.pi.enabled and .d.pi.kms != null and .d.backup.retention_days == 7'
rt fleet crm-pg '.d.maintenance_window.local == "mon:03:30-mon:04:00 IST" and (.d.pending | map(.action)) == ["system-update"] and .d.pending[0].auto_applied_after.days == 20'
rt fleet crm-pg-rr1 '.d.source == {name: "crm-pg", region: "us-east-1", id: "arn:aws:rds:us-east-1:111111111111:db:crm-pg"}'
rt fleet crm-pg-replica-aps1 '.region == "ap-south-1" and .d.source.id == "arn:aws:rds:us-east-1:111111111111:db:crm-pg"'
rt fleet hr-sqlserver '.d.ca.id == "rds-ca-2019" and .d.ca.valid_till.days == 40 and .d.auto_minor == false and .d.pi.enabled == false and .d.master.username == "sa_admin"'
rt fleet hr-sqlserver '.d.maintenance_window == {utc: "wed:23:30-thu:00:00 UTC", local: "thu:05:00-thu:05:30 IST"}'
rt fleet qa-mysql '.account == "222222222222" and .d.public == true and .d.deletion_protection == false and (.tags | map(.v) | index("orders</script><b>x")) != null'
rt fleet qa-mysql '.search | test("orders</script>") and test("222222222222") and test("ap-south-1")'
echo "-- HTML"
chk "html: one data block, AWS '</script' escaped (3 closing script tags = template only)" test "$(grep -o '</script' "$F" | wc -l)" -eq 3
chk "html: escaped value present as \\u003c" grep -q 'orders\\u003c/script>\\u003cb>x' "$F"
jqt fleet '.resources | length == 19'
chk "html: no external src / href" bash -c "! grep -qE '(src|href)=\"?(https?:)?//' '$F'"
chk "html: CSP default-src none" grep -q "default-src 'none'" "$F"
chk "html: mg-theme key" grep -q "localStorage.getItem('mg-theme')" "$F"
chk "html: empty region eu-west-1 never appears" bash -c "! grep -q 'eu-west-1' '$F'"
chk "html: no secret value / password field" bash -c "! grep -qiE 'SecretString|\"MasterUserPassword\"' '$F'"
echo "-- AWS calls (mock log)"
calls >"$OUT/fleet.calls"
hasnt fleet calls 'cloudwatch|secretsmanager|kms |logs '
hasnt fleet calls ' (create|delete|modify|start|stop|reboot|failover|apply|add|remove)-'
chk "every call: --output json --no-cli-pager" bash -c "! jq -e 'select(.[0] != \"--version\" and .[0] != \"configure\") | select((index(\"--no-cli-pager\") == null) or (index(\"json\") == null))' '$MOCK_LOG' | grep -q ."
chk "probes are the only --no-paginate calls" bash -c "grep -- '--no-paginate' '$OUT/fleet.calls' | grep -vq -- '--max-records 20 --query length(' && exit 1 || exit 0"
chk "eu-west-1 (empty) only probed: 2 calls per account" test "$(grep -c 'region eu-west-1' "$OUT/fleet.calls")" -eq 4
chk "me-central-1 (probe denied) still read in full" grep -q 'region me-central-1 rds describe-db-clusters$' "$OUT/fleet.calls"
chk "broken profile: only sts" test "$(grep -c 'profile broken' "$OUT/fleet.calls")" -eq 1
chk "describe-global-clusters once per scanned region" test "$(grep -c 'describe-global-clusters' "$OUT/fleet.calls")" -eq 3

echo "== options"
t docdb 0 fleet -P prod -r us-east-1 --include-docdb
jqt docdb '.meta.counts.clusters == 4 and .meta.counts.instances == 12 and ([.resources[] | select(.engine == "docdb")] | length) == 2 and .meta.include_docdb'
rt docdb catalog-docdb '.type_label == "DocumentDB cluster"'
t tzutc 0 fleet -P prod -r us-east-1 --tz UTC --prefix myrds
jqt tzutc '.meta.generated_local == "2026-10-17 06:30 UTC" and ([.resources[] | .d.maintenance_window.local // empty] | all(endswith("UTC")))'
chk "--prefix used" test -f "$OUT/tzutc/myrds_20261017_063000.html"
: >"$MOCK_LOG"
t explicit 0 fleet -P prod -r us-east-1
chk "explicit region: no probe, no describe-regions" bash -c "! calls() { jq -r 'join(\" \")' '$MOCK_LOG'; }; ! calls | grep -qE -- '--no-paginate|describe-regions'"
jqt explicit '.meta.counts.global_clusters == 1 and ([.resources[] | select(.name == "pay-global")][0].d.members | map(.id != null)) == [true, false]'
rt explicit crm-pg '.d.replicas[1] == {name: "crm-pg-replica-aps1", region: "ap-south-1", id: null}'
: >"$MOCK_LOG"
t nodisc 0 fleet -P prod -A --no-discover
chk "--no-discover: every region read in full (eu-west-1 included)" bash -c "jq -r 'join(\" \")' '$MOCK_LOG' | grep -q 'region eu-west-1 rds describe-db-clusters$'"
chk "--no-discover: no probe calls" bash -c "! jq -r 'join(\" \")' '$MOCK_LOG' | grep -q -- '--no-paginate'"
jqt nodisc '.meta.counts.instances == 13 and .meta.region_mode == "full"'
t pp1 0 fleet "${FLEET[@]}" --probe-parallel 1
chk "--probe-parallel 1: same model as default" bash -c "diff <(jq -S .resources '$OUT/fleet.json') <(jq -S .resources '$OUT/pp1.json') >/dev/null"
MOCK_DEFAULT_REGION=ap-south-1 t defregion 0 fleet -P nonprod
jqt defregion '.meta.counts.instances == 1 and .resources[0].name == "qa-mysql"'
t noregion 2 fleet -P prod; has noregion err "no region given"
t onlybroken 2 fleet -P broken -r us-east-1; has onlybroken err "InvalidClientTokenId"
t unknownprof 2 fleet -P nosuch -r us-east-1

echo "== failure scenarios"
t globalfail 0 globalfail -P prod -r us-east-1
jqt globalfail '.meta.counts.global_clusters == 0 and .meta.counts.clusters == 3 and ([.errors[] | select(.call == "rds describe-global-clusters")][0].message | test("Throttling"))'
t empty 0 empty -P prod -A --csv
jqt empty '.pending == [] and .meta.counts.pending_actions == 0'
EP="$(find "$OUT/empty" -name '*_pending_*.csv' | head -1)"
chk "empty fleet --csv: pending CSV is BOM + header only" bash -c "[[ -n '$EP' ]] && test \"\$(wc -l <'$EP')\" -eq 1 && head -c3 '$EP' | od -An -tx1 | grep -q 'ef bb bf'"
jqt empty '.resources == [] and .meta.counts.regions_with_databases == 0'
chk "empty fleet: no region listed in page" bash -c "! grep -qE 'us-east-1|ap-south-1|eu-west-1' '$(find "$OUT/empty" -name '*.html' 2>/dev/null | head -1)'"

echo "== pending maintenance model"
jqt fleet '[.pending[] | .res_name] == ["hr-sqlserver", "orders-2", "crm-pg", "orders-aurora", "qa-mysql"]'
jqt fleet '[.pending[] | .urgency] == ["past_due", "lt7", "lt30", "later", "no_date"]'
jqt fleet '[.pending[] | .earliest.days] == [-3, 6, 20, 90, null]'
jqt fleet '(.pending[] | select(.res_name == "orders-2")) | .res_kind == "instance" and .cluster_id != null and .res_type == "member"'
jqt fleet '(.pending[] | select(.res_name == "orders-aurora")).next_window | .utc == "2026-10-17 21:00 UTC" and .local == "2026-10-18 02:30 IST"'
jqt fleet '(.resources[] | select(.name == "orders-aurora")) | .pending_count == 1 and .pending_total == 2'
jqt fleet '[.resources[] | select(.pending_count > 0)] | length == 5'
jqt fleet '([.pending[] | .csv | length] | unique) == [19] and (.meta.csv_columns.pending | length) == 19'
jqt fleet '[.resources[] | .csv | length] | unique == [21]'

echo "== --csv"
t csv 0 fleet "${FLEET[@]}" --csv
CI="$OUT/csv/rds_inventory_explorer_inventory_20261017_063000.csv" CP="$OUT/csv/rds_inventory_explorer_pending_20261017_063000.csv"
chk "--csv wrote inventory + pending files" test -s "$CI" -a -s "$CP"
chk "no CSV without --csv" test -z "$(find "$OUT/fleet" -name '*.csv')"
chk "CSV files are mode 640" test "$(stat -c %a "$CI") $(stat -c %a "$CP")" == "640 640"
has csv err "Wrote .*_pending_20261017_063000\.csv"; has csv err "5 pending maintenance action\(s\) \(1 past due\)"
for f in "$CI" "$CP"; do
    chk "$(basename "$f"): UTF-8 BOM" bash -c "head -c3 '$f' | od -An -tx1 | grep -q 'ef bb bf'"
    chk "$(basename "$f"): every line ends CRLF" bash -c "test \"\$(grep -c \$'\\r\$' '$f')\" -eq \"\$(wc -l <'$f')\""
done
chk "pending CSV: header + 5 rows" test "$(wc -l <"$CP")" -eq 6
chk "inventory CSV: header + 19 resources" test "$(wc -l <"$CI")" -eq 20
chk "pending CSV: embedded quotes doubled" grep -qF ',"Rotate CA to ""rds-ca-rsa2048-g1"", restart required",' "$CP"
chk "inventory CSV: formula guard + quoting" grep -qF ',"'"'"'=HYPERLINK(""http://x"")"' "$CI"
chk "pending CSV: negative number not guarded" grep -qF ',-3,past due,' "$CP"
csvcheck() {   # header == meta.csv_columns, rectangular, values == model .csv (python csv module as oracle)
    python3 - "$1" "$2" "$OUT/csv.json" <<'PY'
import csv, json, sys
kind, path, model = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))
rows = list(csv.reader(open(path, encoding='utf-8-sig', newline='')))
cols = model['meta']['csv_columns'][kind]
if kind == 'inventory':
    tags = sorted({t['k'] for r in model['resources'] for t in r['tags']})
    cols = cols + ['tag:' + t for t in tags]
    want = [r['csv'] + [next((t['v'] for t in r['tags'] if t['k'] == k), '') for k in tags] for r in model['resources']]
else:
    want = [r['csv'] for r in model['pending']]
g = lambda v: "'" + v if v[:1] in ('=', '+', '-', '@', '\t', '\r') and not v.lstrip('-+').replace('.', '', 1).isdigit() else v
assert rows[0] == cols, (rows[0], cols)
assert all(len(r) == len(cols) for r in rows)
assert len(rows) == len(want) + 1 and rows[1:] == [[g(x) for x in w] for w in want]
PY
}
chk "inventory CSV: header, shape and values match the model" csvcheck inventory "$CI"
chk "pending CSV: header, shape and values match the model" csvcheck pending "$CP"

echo "== --save-data / --merge"
: >"$MOCK_LOG"
t sd 0 fleet "${FLEET[@]}" --save-data --csv
SD="$OUT/sd/rds_inventory_explorer_data_20261017_063000.json"
chk "data file written next to the HTML" test -s "$SD"
chk "data file mode 640" test "$(stat -c %a "$SD")" == 640
chk "no data file without --save-data" test -z "$(find "$OUT/fleet" -name '*_data_*' 2>/dev/null)"
dj() { if jq -e --slurpfile m "$OUT/sd.json" "$1" "$SD" >/dev/null 2>&1; then ok "data: $1"; else bad "data: $1 (got $(jq -c "$1" --slurpfile m "$OUT/sd.json" "$SD" 2>&1 | head -c 300))"; fi; }
dj '.schema == "rds-inventory-explorer/data" and .schema_version == 1 and .script_version == "1.2.0" and .merged == false'
dj '.generated_epoch == 1792218600 and .generated_utc == "2026-10-17 06:30 UTC"'
dj '[.accounts[] | [.account, .profile, .alias, .collected_epoch]] == [["111111111111","prod",null,1792218600],["222222222222","nonprod",null,1792218600]]'
dj '.regions_scanned | any(.region == "eu-west-1" and .status == "probed: no databases") and any(.status == "read")'
dj '.resources == $m[0].resources and .pending == $m[0].pending and .errors == $m[0].errors and .counts == $m[0].meta.counts'
dj '(.source.regions | length) > 0 and .source.include_docdb == false'
chk "--save-data leaves the HTML model unchanged" test "$(jq -cS 'del(.meta.generated_local)' "$OUT/sd.json")" == "$(jq -cS 'del(.meta.generated_local)' "$OUT/fleet.json")"

# the CloudShell side: one run per account, collected at different times
MD="$OUT/dl dir/Mani Deep"; mkdir -p "$MD" "$OUT/root/c/Users/Mani Deep/Downloads"
t sdA 0 fleet -P prod -A --save-data
RDS_EXPLORER_NOW=1792222200 t sdB 0 fleet -P nonprod,broken -A --save-data
cp "$OUT"/sdA/*_data_*.json "$OUT/root/c/Users/Mani Deep/Downloads/"
cp "$OUT"/sdB/*_data_*.json "$MD/"
# an older prod download with stale contents: must lose to the newer prod file whatever the order
jq '.generated_epoch -= 86400 | .accounts[].collected_epoch -= 86400 | .generated_utc = "2026-10-16 06:30 UTC"
    | .source.regions |= (map(tostring | gsub("hr-sqlserver"; "hr-sqlserver-OLD") | fromjson))' "$OUT"/sdA/*_data_*.json >"$MD/old prod_data_20261016.json"
dfiles=("$MD"/*.json "$OUT/root/c/Users/Mani Deep/Downloads"/*.json); chk "prepared 3 data files (2 prod, 1 nonprod)" test "${#dfiles[@]}" == 3
mcalls_before="$(wc -l <"$MOCK_LOG")"

# Git Bash simulation: no aws on PATH, jq.exe-style CRLF output, date without -d/-r, Windows + spaced paths, no AWS env
GB="$OUT/gbbin"; mkdir -p "$GB"
for x in bash env tr wc head grep sort mkdir mktemp cp mv chmod rm dirname cat sed basename ls; do ln -sf "$(command -v "$x")" "$GB/$x"; done
printf '#!%s\nset -o pipefail\n%s "$@" | %s '"'"'s/$/\\r/'"'"'\n' "$(command -v bash)" "$(command -v jq)" "$(command -v sed)" >"$GB/jq"
printf '#!%s\nfor a in "$@"; do case "$a" in -d|-d*|--date*|-r) echo "date: no $a" >&2; exit 1;; esac; done\nexec %s "$@"\n' "$(command -v bash)" "$(command -v date)" >"$GB/date"
chmod +x "$GB/jq" "$GB/date"
chk "sim: no aws on PATH" bash -c "PATH='$GB'; ! command -v aws"
chk "sim: jq prints CRLF" test "$(PATH="$GB" jq -n 1 | od -An -c | tr -d ' \n')" == '1\r\n'
chk "sim: date -d is unavailable" bash -c "! PATH='$GB' date -d @0 >/dev/null 2>&1"
gbm() {  # gbm <name> <expected-rc> [args...]   merge under the Git Bash simulation
    local name="$1" exp="$2"; shift 2
    env -i PATH="$GB" HOME="$OUT" TZ=UTC RDS_EXPLORER_NOW="${MNOW:-1792218600}" RDS_EXPLORER_DRIVE_ROOT="$OUT/root" \
        "$SCRIPT" -o "$OUT/$name out" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"
    local rc=$?
    if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; sed 's/^/       /' "$OUT/$name.err" | tail -5; fi
    local h; h="$(find "$OUT/$name out" -name '*.html' 2>/dev/null | head -1)"
    [[ -n "$h" ]] && sed -n 's|.*<script type="application/json" id="explorer-data">\(.*\)</script>.*|\1|p' "$h" >"$OUT/$name.json"
    return 0
}
gbm mg 0 --merge 'C:\Users\Mani Deep\Downloads\rds_inventory_explorer_data_*.json' "$MD/"*.json --csv --save-data
chk "merge made 0 AWS calls" test "$(wc -l <"$MOCK_LOG")" == "$mcalls_before"
has mg err "Input [0-9]: .*old prod_data_20261016\.json"
has mg err "Account 111111111111: using newer rds_inventory_explorer_data_20261017_063000\.json .*ignoring older old prod_data_20261016\.json"
has mg err "Merged 2 account\(s\) from 3 file\(s\).*relative to merge time.*0 AWS calls"
jqt mg '.meta.merge.files == 3 and .meta.aws_calls == 0 and .meta.region_mode == "merge" and .meta.counts.accounts == 2'
jqt mg '[.resources[].name] | index("hr-sqlserver-OLD") == null and index("hr-sqlserver") != null'
jqt mg '[.meta.merge.sources[] | select(.superseded == ["111111111111"])] | length == 1 and .[0].file == "old prod_data_20261016.json"'
chk "merged model == single fleet run (resources, pending, errors, counts)" test \
    "$(jq -cS '[.resources, .pending, (.errors | sort), .meta.counts]' "$OUT/mg.json")" == "$(jq -cS '[.resources, .pending, (.errors | sort), .meta.counts]' "$OUT/sd.json")"
for k in inventory pending; do
    chk "merged $k CSV (CRLF jq) is byte-identical to the scan's" cmp -s "$OUT/mg out/rds_inventory_explorer_${k}_20261017_063000.csv" "$OUT/sd/rds_inventory_explorer_${k}_20261017_063000.csv"
done
chk "merged CSVs have no doubled CR" bash -c "! grep -q \$'\\r\\r' '$OUT/mg out/'*.csv"
chk "merged HTML: empty region eu-west-1 never appears" bash -c "! grep -q eu-west-1 '$OUT/mg out/'*.html"
chk "merged HTML: no CR characters" bash -c "! grep -q \$'\\r' '$OUT/mg out/'*.html"
MGD="$OUT/mg out/rds_inventory_explorer_data_20261017_063000.json"
chk "merged --save-data: valid merged data file" jq -e >/dev/null '.merged == true and (.accounts|length) == 2 and (.sources|length) == 3 and any(.regions_scanned[]; .region == "eu-west-1")' "$MGD"
gbm mg2 0 --merge "$MGD"
chk "re-merging the merged data file gives the same model" test \
    "$(jq -cS '[.resources, .pending, .errors]' "$OUT/mg2.json")" == "$(jq -cS '[.resources, .pending, .errors]' "$OUT/mg.json")"
gbm mgdir 0 --merge "$MD" "/c/Users/Mani Deep/Downloads"
jqt mgdir '.meta.merge.files == 3 and .meta.counts.accounts == 2'
# urgency is relative to merge time: 7 days later orders-2 (due in 6 d at scan time) is past due
MNOW=1792823400 gbm mglate 0 --merge "$MD/"*.json "$OUT/root/c/Users/Mani Deep/Downloads/"*.json
jqt mglate '.meta.now == 1792823400 and .meta.merge.urgency_basis == "merge time"'
jqt mg '.meta.counts.pending_past_due == 1 and ([.pending[] | select(.res_name == "orders-2")][0].urgency == "lt7")'
jqt mglate '.meta.counts.pending_past_due == 2 and ([.pending[] | select(.res_name == "orders-2")][0].urgency == "past_due")'
# bad input -> exit 3 with a clear message
printf '{"schema":' >"$OUT/bad.json"
cp "$(find "$OUT/fleet" -name '*.html' | head -1)" "$OUT/report.html"
jq '.schema_version = 0' "$SD" >"$OUT/old0.json"; jq 'del(.schema_version)' "$SD" >"$OUT/old_nov.json"
jq '.schema_version = 2' "$SD" >"$OUT/newer.json"; jq 'del(.schema)' "$SD" >"$OUT/noschema.json"; jq 'del(.source)' "$SD" >"$OUT/partial.json"
gbm mbad 3 --merge "$OUT/bad.json";        has mbad err "not valid JSON"
gbm mhtml 3 --merge "$OUT/report.html";    has mhtml err "HTML report"
gbm mold 3 --merge "$OUT/old0.json";       has mold err "old data schema 0"
gbm moldv 3 --merge "$OUT/old_nov.json";   has moldv err "no schema_version"
gbm mnew 3 --merge "$OUT/newer.json";      has mnew err "newer"
gbm mnos 3 --merge "$OUT/noschema.json";   has mnos err "not an RDS Inventory Explorer data file"
gbm mpart 3 --merge "$OUT/partial.json";   has mpart err "missing accounts / source data"
gbm mmiss 3 --merge "$OUT/nope_*.json";    has mmiss err "No file matches"
gbm mmix 3 --merge "$SD" "$OUT/bad.json"
chk "bad merge input writes no report" test -z "$(find "$OUT/mbad out" "$OUT/mmix out" -name '*.html' 2>/dev/null)"
t mP 1 fleet --merge "$SD" -P prod;  has mP err "--merge"
t mnone 1 fleet --merge;              has mnone err "--merge"

echo "== browser (headless Chrome)"
if command -v node >/dev/null 2>&1 && node -e "require('puppeteer-core')" 2>/dev/null && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]]; then
    res="$(CSV_DIR="$OUT/csv" EMPTY_HTML="$(find "$OUT/empty" -name '*.html' | head -1)" node "$HERE/browser_check.js" "$F" ${SHOTS:+"$SHOTS"} 2>&1)"; rc=$?
    if (( rc == 0 )); then ok "browser: $(jq -r '"\(.passed)/\(.total)"' <<<"$res") checks - search, filters, card, links, hash, copy JSON, dark mode, pending tab, CSV export, mobile, no JS errors, no network"
    else bad "browser check: ${res:0:800}"; fi
    res="$(MERGED=3 CSV_DIR="$OUT/mg out" SHOTS_V120="${SHOTS_V120:-}" node "$HERE/browser_check.js" "$(find "$OUT/mg out" -name '*.html' | head -1)" 2>&1)"; rc=$?
    if (( rc == 0 )); then ok "browser on the merged HTML: $(jq -r '"\(.passed)/\(.total)"' <<<"$res") checks (same fleet checks + merged header)"
    else bad "browser check (merged): ${res:0:800}"; fi
else echo "  skip browser check (needs node + puppeteer-core on NODE_PATH + Chrome)"; fi

echo "== dry run / safety"
: >"$MOCK_LOG"
t dry 0 fleet "${FLEET[@]}" --dry-run; has dry out "describe-pending-maintenance-actions"; has dry out "no AWS calls"; has dry out "--max-records 20"
chk "dry run made no AWS calls" test ! -s "$MOCK_LOG"
chk "dry run wrote no file" test ! -e "$OUT/dry"
AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "repo tree unchanged by tests" test "$BEFORE" == "$AFTER"

echo "== scale"
s=$SECONDS
MOCK_LARGE_N=1500 t large 0 large -P prod -r us-east-1
jqt large '.meta.counts.instances == 1800 and .meta.counts.clusters == 150'
chk "1950 resources in < 90s ($((SECONDS - s))s)" test $((SECONDS - s)) -lt 90

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
