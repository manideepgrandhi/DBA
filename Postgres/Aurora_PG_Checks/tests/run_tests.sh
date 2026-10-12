#!/usr/bin/env bash
# shellcheck disable=SC2015  # "cond && ok || bad" is safe here: ok() always returns 0
# Test suite for aurora_pg_check.sh against the mock AWS CLI (tests/mock/aws).
# No AWS account, no real e-mail, no external URLs: alerts go to a local stub `mail`
# and a webhook listener on 127.0.0.1. Usage: tests/run_tests.sh [-k] (keep output dir)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../aurora_pg_check.sh"
OUT="$(mktemp -d /tmp/apc_tests.XXXXXX)"
KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0; LISTENER_PID=""
export MOCK_LOG="$OUT/aws_calls.jsonl" MOCK_CAPTURE="$OUT/capture"
STUB="$OUT/stubbin"; mkdir -p "$STUB"
export PATH="$HERE/mock:$STUB:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE

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

# stub mailer + local webhook listener
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

echo "== usage / validation"
t help 0 fleet --help;                          has help out 'Exit codes'
t version 0 fleet --version;                    has version out '1\.0\.1'
t thresholds 0 fleet --list-thresholds;         has thresholds out 'xid_crit +1000000000'
t badopt 1 fleet --bogus
t badfmt 1 fleet -r us-east-1 -f xml
t badlook 1 fleet -r us-east-1 -L 5x
t badperiod 1 fleet -r us-east-1 --period 90
t badset 1 fleet -r us-east-1 -s nope=1
t badsetval 1 fleet -r us-east-1 -s cpu_warn=abc
t badorder 1 fleet -r us-east-1 -s cpu_crit=50
t badgroup 1 fleet -r us-east-1 -C cluster,foo
t bothregions 1 fleet -r us-east-1 --all-regions
t noregion 1 fleet
t badregion 1 fleet -r useast1
t badcluster 1 fleet -r us-east-1 -c 'x;rm'
t badhook 1 fleet -r us-east-1 --alert-webhook ftp://x
t bademail 1 fleet -r us-east-1 --alert-email 'a b@c'
MOCK_DEFAULT_REGION=ap-south-1 t profregion 0 fleet -q;   has profregion out 'ap-south-1 / payments-prod'

echo "== dry run (no AWS calls)"
: >"$MOCK_LOG"
t dry 0 fleet -r us-east-1,ap-south-1 -c orders-prod --dry-run -P prod
has dry out 'describe-db-clusters --filters Name=db-cluster-id\\,Values=orders-prod'
has dry out 'get-metric-data'
if [[ ! -s "$MOCK_LOG" ]] || ! grep -qv -e '"configure"' -e '"--version"' "$MOCK_LOG"; then ok "dry run made no AWS API calls"; else bad "dry run called AWS"; fi

echo "== scenarios"
t healthy 0 fleet -r us-east-1
has healthy out 'orders-prod : OK'; has healthy out 'Overall: OK \(exit 0\)'
t healthy_q 0 fleet -r us-east-1 -q;            has healthy_q out 'all 43 checks OK'
t allregions 0 fleet --all-regions -q
has allregions out 'ap-south-1 / payments-prod : OK'; has allregions out 'us-east-1 / orders-prod : OK'
has allregions err 'All enabled regions: 4'; hasnt allregions out 'legacy-mysql'
has allregions err 'no aurora-postgresql clusters'
t issues 11 issues -r us-east-1 -q
for c in 'CRIT +versions pending_maintenance' 'WARN +config +cluster_param_apply' 'WARN +config +instance_param_apply' \
         'WARN +config +public_access' 'CRIT +backups +backup_retention' 'CRIT +versions ca_certificate +rds-ca-2019' \
         'WARN +config +deletion_protection' 'WARN +config +log_exports' 'WARN +cluster +az_spread' \
         'WARN +versions auto_minor_upgrade' 'CRIT +versions support_lifecycle' 'WARN +backups +backup_window'; do
    has issues out "$c"; done
hasnt issues out 'some-other-db'
t issues_pubcrit 11 issues -r us-east-1 -q -s public_access_crit=1;   has issues_pubcrit out 'CRIT +config +public_access'
t issues_relaxed 11 issues -r us-east-1 -q -s backup_retention_warn=1 -s backup_retention_crit=1
has issues_relaxed out 'CRIT'; hasnt issues_relaxed out 'backup_retention'
t metrics 11 metrics -r us-east-1 -q
for c in 'CRIT +metrics +CPUUtilization' 'CRIT +metrics +AuroraReplicaLag ' 'CRIT +metrics +MaximumUsedTransactionIDs +1\.21B' \
         'WARN +metrics +DatabaseConnections +1712/2000' 'WARN +metrics +Deadlocks' 'WARN +metrics +OldestReplicationSlotLag' \
         'WARN +metrics +FreeableMemory' 'CRIT +events +recent_events' 'failover'; do has metrics out "$c"; done
t metrics_conn 11 metrics -r us-east-1 -q -s max_connections=1800;  has metrics_conn out 'CRIT +metrics +DatabaseConnections +1712/1800'
t metrics_only_events 11 metrics -r us-east-1 -C events -q;          hasnt metrics_only_events out 'metrics +CPU'
t metrics_noevents 11 metrics -r us-east-1 -X events -q;             hasnt metrics_noevents out 'recent_events'
t serverless 10 serverless -r eu-west-1 -D
has serverless out 'serverless_v2 +0.5-16(\.0)? ACU'; has serverless out 'WARN +metrics +ACUUtilization +96% on events-sls-1'
has serverless out 'ServerlessDatabaseCapacity'; has serverless out 'DatabaseConnections .*/3604'
t apifail 3 apifail -r us-east-1,eu-west-1 -q
has apifail out 'ERROR +versions pending_maintenance'; has apifail out 'ERROR +metrics +metrics +.*Throttling'
has apifail out 'eu-west-1 / \(region\) : ERROR'
t instfail 3 instfail -r us-east-1 -q;          has instfail out 'ERROR +cluster +instance_status +.*AccessDenied'
t badcreds 2 badcreds -r us-east-1;             has badcreds err 'InvalidClientTokenId'
t notfound 11 fleet -r us-east-1,ap-south-1 -c orders-prod,ghost-db -q
has notfound out '=== - / ghost-db : CRIT'; has notfound out 'CRIT +cluster +cluster_found'; has notfound out 'orders-prod : OK'
t byarn 0 fleet -r us-east-1 -c arn:aws:rds:us-east-1:123456789012:cluster:orders-prod -q
t mysql 10 fleet -r us-west-2 -c legacy-mysql -q; has mysql out 'engine is aurora-mysql'
t none 10 fleet -r eu-west-1 -q;                has none out 'no aurora-postgresql clusters found'

echo "== formats / output files"
t json 11 issues -r us-east-1 -f json
jqt json '.summary.overall == "CRIT" and .summary.exit_code == 11'
jqt json '.meta.account == "123456789012" and (.meta.thresholds.xid_crit == 1000000000)'
jqt json '[.results[] | select(.status == "CRIT")] | length == 4'
jqt json '.clusters[0].cluster == "billing-prod"'
t jsonfile 0 fleet --all-regions -f json -o "$OUT/report.json"
if jq -e '.summary.cluster_count == 2' "$OUT/report.json" >/dev/null; then ok "json -o file written"; else bad "json -o file"; fi
[[ "$(stat -c %a "$OUT/report.json")" == 640 ]] && ok "report mode 0640" || bad "report mode $(stat -c %a "$OUT/report.json")"
t html 11 metrics -r us-east-1 -f html -o "$OUT/report.html"
grep -q '<h1>Aurora PostgreSQL checks: <span class="st st-crit">CRIT</span>' "$OUT/report.html" && ok "html headline" || bad "html headline"
python3 -c "import html.parser,sys; p=html.parser.HTMLParser(); p.feed(open(sys.argv[1]).read()); print('parsed')" "$OUT/report.html" >/dev/null \
    && ok "html parses" || bad "html parse"
grep -q '&lt;\|failover to DB instance' "$OUT/report.html" && ok "html has event details" || bad "html details"
t textfile 10 serverless -r eu-west-1 -o "$OUT/report.txt" -l "$OUT/run.log"
grep -q 'Overall: WARN (exit 10)' "$OUT/report.txt" && ok "text -o file" || bad "text -o file"
grep -q 'Result: WARN' "$OUT/run.log" && ok "log file written" || bad "log file"

echo "== config file"
cat >"$OUT/test.conf" <<CONF
# test config
region = us-east-1          # inline comment
checks = cluster,metrics
cpu_warn = 99
cpu_crit = 99.5
format = "json"
CONF
t conf 11 metrics --config "$OUT/test.conf"
jqt conf '.meta.checks == ["cluster","metrics"] and .meta.thresholds.cpu_warn == 99'
jqt conf '[.results[] | select(.check == "CPUUtilization")][0].status == "OK"'
t conf_override 11 metrics --config "$OUT/test.conf" -f text -s cpu_warn=50 -s cpu_crit=90 -q
has conf_override out 'CRIT +metrics +CPUUtilization'
printf 'aws_secret_access_key = x\n' >"$OUT/bad.conf";  t conf_secret 1 fleet --config "$OUT/bad.conf"
printf 'nonsense here\n' >"$OUT/bad2.conf";             t conf_syntax 1 fleet --config "$OUT/bad2.conf"
printf 'colour = red\n' >"$OUT/bad3.conf";              t conf_key 1 fleet --config "$OUT/bad3.conf"

echo "== alerts (local stubs only)"
: >"$MAIL_SINK"; : >"$OUT/webhook.txt"
t alert_warn 11 issues -r us-east-1 --alert-email dba@example.invalid --alert-webhook "$HOOK" -q
head -1 "$MAIL_SINK" | grep -q 'aurora_pg_check.*CRIT.*dba@example.invalid' && ok "mail subject/recipient" || bad "mail subject: $(head -1 "$MAIL_SINK")"
grep -q 'pending_maintenance' "$MAIL_SINK" && ok "mail body has problems" || bad "mail body"
jq -e '.text | test("CRIT")' "$OUT/webhook.txt" >/dev/null 2>&1 && ok "slack webhook payload" || bad "slack webhook payload"
hasnt alert_warn err 'SECRET'; has alert_warn err 'webhook http://127.0.0.1:[0-9]+/\.\.\. -> HTTP 200'
: >"$OUT/webhook.txt"
t alert_json 10 serverless -r eu-west-1 --alert-webhook "$HOOK" --alert-webhook-format json -q
jq -e '.status == "WARN" and .exit_code == 10 and (.problems | length) == 1 and .problems[0].check == "ACUUtilization"' "$OUT/webhook.txt" >/dev/null \
    && ok "json webhook payload" || bad "json webhook payload"
: >"$OUT/webhook.txt"
t alert_crit_only 10 serverless -r eu-west-1 --alert-webhook "$HOOK" --alert-on crit -q
[[ ! -s "$OUT/webhook.txt" ]] && ok "alert-on crit skips WARN" || bad "alert-on crit sent on WARN"
t alert_ok_quiet 0 fleet -r us-east-1 --alert-webhook "$HOOK" -q
[[ ! -s "$OUT/webhook.txt" ]] && ok "no alert on OK (alert-on warn)" || bad "alert sent on OK"
t alert_always 0 fleet -r us-east-1 --alert-webhook "$HOOK" --alert-on always -q
grep -q 'OK' "$OUT/webhook.txt" && ok "alert-on always sends on OK" || bad "alert-on always"
: >"$OUT/webhook.txt"; : >"$MAIL_SINK"
t alert_test 0 fleet --alert-test --alert-webhook "$HOOK" --alert-email dba@example.invalid
grep -q TEST "$OUT/webhook.txt" && grep -q TEST "$MAIL_SINK" && ok "alert-test delivered" || bad "alert-test"
t alert_dead 10 serverless -r eu-west-1 --alert-webhook "http://127.0.0.1:9/x" -q
has alert_dead err 'Alert: webhook http://127.0.0.1:9/... failed'

echo "== pre-check failures"
NOAWS="$OUT/noaws"; mkdir -p "$NOAWS"
for b in bash env date jq mktemp rm mv cp cat tr sed grep sort dirname hostname touch chmod mkdir basename head; do
    p="$(command -v "$b")" && ln -sf "$p" "$NOAWS/$b"; done
MOCK_SCENARIO=fleet PATH="$NOAWS" "$SCRIPT" -r us-east-1 >/dev/null 2>"$OUT/noaws.err"; rc=$?
[[ $rc == 2 ]] && grep -q 'AWS CLI not found' "$OUT/noaws.err" && ok "missing aws -> 2" || bad "missing aws rc=$rc"
NOJQ="$OUT/nojq"; mkdir -p "$NOJQ"; cp -a "$NOAWS/." "$NOJQ/"; rm -f "$NOJQ/jq"; ln -sf "$HERE/mock/aws" "$NOJQ/aws"
ln -sf "$(command -v python3)" "$NOJQ/python3"
MOCK_SCENARIO=fleet PATH="$NOJQ" "$SCRIPT" -r us-east-1 >/dev/null 2>"$OUT/nojq.err"; rc=$?
[[ $rc == 2 ]] && grep -q 'jq not found' "$OUT/nojq.err" && ok "missing jq -> 2" || bad "missing jq rc=$rc"
V1="$OUT/v1"; mkdir -p "$V1"; printf '#!/bin/sh\necho "aws-cli/1.29.0 Python/3.8 Linux botocore/1.31"\n' >"$V1/aws"; chmod +x "$V1/aws"
PATH="$V1:$PATH" "$SCRIPT" -r us-east-1 >/dev/null 2>"$OUT/v1.err"; rc=$?
[[ $rc == 2 ]] && grep -q 'AWS CLI v2 required' "$OUT/v1.err" && ok "aws v1 -> 2" || bad "aws v1 rc=$rc"

echo "== large data (argv-size regression: v1.0.0 failed with 'Argument list too long')"
names="orders-prod$(for i in $(seq 1 6999); do printf ',ghost-cluster-name-%05d' "$i"; done)"
printf 'region = us-east-1\nclusters = %s\n' "$names" >"$OUT/big.conf"     # ~175 KB > 128 KiB MAX_ARG_STRLEN
: >"$MAIL_SINK"; : >"$OUT/webhook.txt"
t0=$SECONDS
t bigclusters 11 fleet --config "$OUT/big.conf" -f json -q --alert-email dba@example.invalid --alert-webhook "$HOOK" --alert-webhook-format json
el=$(( SECONDS - t0 ))
[[ $el -lt 120 ]] && ok "7000-cluster list finished in ${el}s" || bad "7000-cluster list took ${el}s"
hasnt bigclusters err 'Argument list too long'
jq -e '([.results[] | select(.check == "cluster_found" and .status == "CRIT")] | length) == 6999 and .summary.overall == "CRIT"' "$OUT/bigclusters.out" >/dev/null \
    && ok "6999 missing clusters reported" || bad "missing-cluster results"
n="$(jq -r 'select(.[0] == "--output" or true) | select(index("describe-db-clusters")) | .[index("--filters") + 1] | length' "$MOCK_LOG" | sort -n | tail -1)"
[[ -n "$n" && "$n" -lt 2000 ]] && ok "describe-db-clusters --filters batched (largest value ${n} chars)" || bad "filters not batched (${n})"
[[ "$(stat -c %s "$MAIL_SINK")" -gt 131072 ]] && grep -q 'ghost-cluster-name-06999' "$MAIL_SINK" && ok "large mail body streamed" || bad "large mail body"
jq -e -s 'length == 1 and (.[0].text | length) > 131072' "$OUT/webhook.txt" >/dev/null && ok "large json webhook payload delivered" || bad "large webhook"
: >"$OUT/webhook.txt"
t bigslack 11 fleet --config "$OUT/big.conf" -q --alert-webhook "$HOOK"
jq -e -s 'length == 1 and (.[0].text | length) < 40000 and (.[0].text | test("truncated"))' "$OUT/webhook.txt" >/dev/null && ok "slack payload truncated < 40k" || bad "slack truncation"

echo "== read-only guarantee"
ops="$(jq -r '. as $a | ([range(length)] | map(select($a[.] | IN("rds","sts","ec2","cloudwatch"))) | .[0]) as $i
             | if $i == null then empty else "\($a[$i]) \($a[$i + 1])" end' "$MOCK_LOG" | sort -u)"
while read -r svc op; do printf '       %s %s\n' "$svc" "$op"; done <<<"$ops"
if printf '%s\n' "$ops" | grep -vqE '^[a-z0-9]+ (describe-|get-|list-)'; then bad "non-read-only operation used"; else ok "only describe-/get- operations used"; fi

echo
echo "passed: $PASS  failed: $FAIL   (AWS calls logged: $(wc -l <"$MOCK_LOG"), log: $MOCK_LOG)"
(( FAIL == 0 ))
