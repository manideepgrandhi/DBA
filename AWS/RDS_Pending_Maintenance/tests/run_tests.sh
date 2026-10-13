#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2054  # cond && ok || bad is safe (ok returns 0); jq programs are single-quoted; comma lists are CLI args
# Test suite for rds_pending_maintenance_report.sh against the mock AWS CLI (tests/mock/aws).
# No AWS account, no real e-mail, no external URLs: alerts go to a local stub `mail`
# and a webhook listener on 127.0.0.1. Usage: tests/run_tests.sh [-k] (keep output dir)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../rds_pending_maintenance_report.sh"
OUT="$(mktemp -d /tmp/rpm_tests.XXXXXX)"
KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0; LISTENER_PID=""
export MOCK_LOG="$OUT/aws_calls.jsonl"
STUB="$OUT/stubbin"; mkdir -p "$STUB"
export PATH="$HERE/mock:$STUB:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE MOCK_DEFAULT_REGION
ALL3=(-P prod,nonprod -r us-east-1,ap-south-1,eu-west-1)

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
t help 0 fleet --help;                 has help out 'Exit codes'; has help out 'read-only'; has help out '--no-version-check'; hasnt help out 'apply-opt-in'
t version 0 fleet --version;           has version out '1\.3\.0'
t badopt 1 fleet --bogus
t badfmt 1 fleet -r us-east-1 -F xml
t multinoout 1 fleet -r us-east-1 -F csv,html
t bothregions 1 fleet -r us-east-1 --all-regions
t badregion 1 fleet -r useast1
t badprofile 1 fleet -P 'a;b' -r us-east-1
t badtag 1 fleet -r us-east-1 -t Environment
t badurg 1 fleet -r us-east-1 -u SOON
t baddays 1 fleet -r us-east-1 --crit-days 40 --warn-days 30
t badtz 1 fleet -r us-east-1 --tz Mars/Base
t badprefix 1 fleet -r us-east-1 -o "$OUT/o" --prefix '../x'
t badhook 1 fleet -r us-east-1 --alert-webhook ftp://x
t bademail 1 fleet -r us-east-1 --alert-email 'a b@c'
t badalerton 1 fleet -r us-east-1 --alert-on sometimes
t missingarg 1 fleet -r
printf 'region = us-east-1\naws_secret_access_key = abc\n' >"$OUT/cred.conf"
t confcred 1 fleet --config "$OUT/cred.conf";     has confcred err 'credentials are not accepted'; hasnt confcred err 'abc'
printf 'bogus_key = 1\n' >"$OUT/unk.conf"
t confunknown 1 fleet --config "$OUT/unk.conf"
t confmissing 1 fleet --config "$OUT/nope.conf"

echo "== dry run makes no AWS calls"
: >"$MOCK_LOG"
t dry 0 fleet "${ALL3[@]}" --include-docdb --dry-run
has dry out 'describe-pending-maintenance-actions'; has dry out 'docdb describe-pending-maintenance-actions'
chk "dry run: no mock calls" test ! -s "$MOCK_LOG"

echo "== scenario: nothing pending"
t none 0 none "${ALL3[@]}";            has none out 'No pending maintenance actions found'; has none out 'Overall: OK \(exit 0\)'
t none_json 0 none -P prod -r us-east-1 -F json;  jqt none_json '.summary.total == 0 and .rows == [] and .summary.exit_code == 0'

echo "== scenario: fleet (2 profiles x 3 regions, mixed engines)"
t fleet 11 fleet "${ALL3[@]}"
for x in crm-sql-prod qa-sql payments-ams orders-prod-2 erp-oracle-prod reporting-pg orders-prod cms-mariadb dev-pg-01 dev-apg graph-neptune web-mysql-prod old-replica-2023; do
    has fleet out " $x"
done
has fleet out 'Accounts  : 111111111111 \(prod\), 222222222222 \(nonprod\)'
hasnt fleet out 'catalog-docdb '   # docdb cluster only appears with --include-docdb
t fleet_json 11 fleet "${ALL3[@]}" -F json
jqt fleet_json '.summary.total == 15 and .summary.unfiltered_total == 15'
jqt fleet_json '[.rows[].action] | unique == ["ca-certificate-rotation","db-upgrade","hardware-maintenance","os-upgrade","system-update"]'
jqt fleet_json '[.rows[].opt_in_status] | unique == ["","immediate","next-maintenance","pending"]'
jqt fleet_json '[.rows[].engine] | unique | length == 11'
jqt fleet_json '.summary.by_urgency == {"OVERDUE":1,"CRIT":4,"WARN":5,"INFO":3,"OPTIONAL":2}'
jqt fleet_json '.summary.by_region == {"us-east-1":9,"ap-south-1":5,"eu-west-1":1}'
jqt fleet_json '.summary.by_account == {"111111111111":11,"222222222222":4}'
jqt fleet_json '.rows[0].identifier == "crm-sql-prod" and .rows[0].urgency == "OVERDUE" and .rows[0].action == "system-update"'
jqt fleet_json '[.rows[] | .effective_apply // 1e18] as $e | $e == ($e | sort)'
jqt fleet_json '.rows | map(select(.urgency == "OPTIONAL")) | all(.effective_apply == null and .days_until == null)'
jqt fleet_json '.rows[] | select(.identifier == "orders-prod-2") | .cluster == "orders-prod" and .instance_class == "db.r6g.xlarge" and .effective_basis == "current-apply-date" and .tags.Owner == "payments-team"'
jqt fleet_json '.rows[] | select(.identifier == "payments-ams") | .instance_class == "serverless v2 2.0-32.0 ACU" and .effective_basis == "next-window (opted in)" and .maint_window_local == "Tue 02:00-Tue 02:30 IST" and (.effective_apply_utc | endswith("20:30 UTC"))'
jqt fleet_json '.rows[] | select(.identifier == "erp-oracle-prod") | .urgency == "CRIT" and .days_until == 6'
jqt fleet_json '.rows[] | select(.identifier == "qa-sql") | .opt_in_status == "immediate" and .urgency == "CRIT"'
jqt fleet_json '.rows[] | select(.identifier == "reporting-pg") | .urgency == "WARN" and .action == "hardware-maintenance"'
jqt fleet_json '.rows[] | select(.identifier == "dev-apg") | .urgency == "INFO" and .resource_type == "cluster" and .engine == "aurora-postgresql"'
jqt fleet_json '.rows[] | select(.identifier == "old-replica-2023") | .resolved == false and .engine == "unknown"'
jqt fleet_json '[.rows[] | select(.identifier == "crm-sql-prod")] | length == 2'
jqt fleet_json '.rows[] | select(.identifier == "crm-sql-prod" and .action == "os-upgrade") | .urgency == "INFO"'
jqt fleet_json '.rows[] | select(.identifier == "cms-mariadb") | .tag_columns == {"Environment":"staging","Owner":"web-team","Application":"cms"}'

echo "== printed commands (never run): immediate / status / pending / minor upgrade"
jqt fleet_json '.meta.version_check == true and (.meta | has("apply_opt_in") | not)'
jqt fleet_json 'all(.rows[]; (has("apply_command") or has("undo_command")) | not)'
jqt fleet_json 'all(.rows[] | select(.apply_immediate_command != ""); .apply_immediate_command | test("^aws (rds|docdb|neptune) apply-pending-maintenance-action --resource-identifier arn:aws:rds:[a-z0-9-]+:[0-9]{12}:(db|cluster):[a-z0-9-]+ --apply-action [a-z-]+ --opt-in-type immediate --region [a-z0-9-]+ --profile (prod|nonprod)$"))'
jqt fleet_json '.rows[] | select(.identifier == "crm-sql-prod" and .action == "system-update") | .apply_immediate_command == "aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:crm-sql-prod --apply-action system-update --opt-in-type immediate --region us-east-1 --profile prod" and (.apply_note | test("restart/fail over"))'
jqt fleet_json '.rows[] | select(.identifier == "crm-sql-prod" and .action == "system-update") | .status_command | startswith("aws rds describe-db-instances --db-instance-identifier crm-sql-prod --query '"'"'DBInstances[0].{Status:DBInstanceStatus,") and endswith("--output table --region us-east-1 --profile prod")'
jqt fleet_json '.rows[] | select(.identifier == "orders-prod") | (.status_command | startswith("aws rds describe-db-clusters --db-cluster-identifier orders-prod --query '"'"'DBClusters[0].{Status:Status,")) and (.status_command | contains("Members:DBClusterMembers[]"))'
jqt fleet_json '.rows[] | select(.identifier == "orders-prod") | .pending_actions_command == "aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:us-east-1:111111111111:cluster:orders-prod --output table --region us-east-1 --profile prod"'
jqt fleet_json '.rows[] | select(.identifier == "graph-neptune") | (.status_command | startswith("aws neptune describe-db-clusters ")) and (.pending_actions_command | startswith("aws neptune describe-pending-maintenance-actions ")) and (.apply_immediate_command | startswith("aws neptune "))'
jqt fleet_json '.rows[] | select(.identifier == "old-replica-2023") | .apply_immediate_command == "" and (.status_command | startswith("aws rds describe-db-instances --db-instance-identifier old-replica-2023 ")) and (.pending_actions_command | length > 0) and (.apply_note | test("not found"))'
jqt fleet_json '.rows[] | select(.identifier == "qa-sql") | .apply_immediate_command == "" and (.status_command | length > 0) and (.apply_note | test("already opted in \\(immediate\\)"))'
jqt fleet_json '.rows[] | select(.identifier == "payments-ams") | (.apply_immediate_command | length > 0) and (.apply_note | test("already scheduled"))'
jqt fleet_json '[.rows[] | select(.apply_immediate_command != "")] | length == 13'
jqt fleet_json 'all(.rows[]; (.status_command | length > 0) and (.pending_actions_command | length > 0))'
t imm 11 fleet -P prod -r us-east-1 --include-docdb -F json
jqt imm '.rows[] | select(.identifier == "catalog-docdb") | (.apply_immediate_command | startswith("aws docdb ")) and (.apply_note | test("restart"))'
jqt imm '.rows[] | select(.identifier == "catalog-docdb-1") | (.status_command | startswith("aws docdb describe-db-instances --db-instance-identifier catalog-docdb-1 ")) and (.pending_actions_command | startswith("aws docdb describe-pending-maintenance-actions "))'
jqt imm '.rows[] | select(.identifier == "catalog-docdb") | .status_command | startswith("aws docdb describe-db-clusters --db-cluster-identifier catalog-docdb ")'
t depapply 11 fleet -P prod -r us-east-1 --apply-opt-in immediate -F json
has depapply err 'WARN.*--apply-opt-in is no longer used'; jqt depapply 'all(.rows[]; has("apply_command") | not)'
MOCK_DEFAULT_REGION=us-east-1 t defprofile 11 fleet -F json
jqt defprofile 'all(.rows[] | select(.apply_immediate_command != ""); (.apply_immediate_command | test("--profile") | not) and (.apply_immediate_command | endswith("--region us-east-1")))'
jqt defprofile 'all(.rows[] | select(.minor_upgrade_command != ""); (.minor_upgrade_command | test("--profile") | not) and (.minor_upgrade_command | endswith("--region us-east-1")))'
t textcmd 11 fleet -P prod -r us-east-1
has textcmd out 'printed only \(never run\)'
hasnt textcmd out 'apply    :|undo|next-maintenance --region'
has textcmd out '^         immediate: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:orders-prod-2 .* --opt-in-type immediate .*# may restart/fail over NOW$'
has textcmd out '^         status   : aws rds describe-db-instances --db-instance-identifier orders-prod-2 '
has textcmd out '^         pending  : aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:us-east-1:111111111111:db:orders-prod-2 '
has textcmd out '^         version  : 16.8 -> next 16.9, latest 16.10 \(available: 16.9, 16.10\) \| auto minor upgrade: true$'
has textcmd out '^         minor upg: aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 --region us-east-1 --profile prod   # next maintenance window$'
has textcmd out '^         version  : 16.00.4135.4.v1|^         version  : 15.00.4415.2.v1 -> next 15.00.4420.2.v1'
has textcmd out '^  minor ver. : 3 server\(s\) behind the latest minor version: crm-sql-prod'
printf 'region = us-east-1\nprofiles = prod\napply_opt_in = immediate\n' >"$OUT/ao.conf"
t confapply 11 fleet --config "$OUT/ao.conf" -F csv;  has confapply err 'apply_opt_in is no longer used'; has confapply out 'opt-in-type immediate --region us-east-1 --profile prod"'

echo "== minor version patch details"
jqt fleet_json '.summary.behind_latest_minor == 10'
jqt fleet_json '.rows[] | select(.identifier == "orders-prod") | .auto_minor_upgrade == "true" and .next_minor_version == "16.9" and .latest_minor_version == "16.10" and .minor_versions_available == "16.9, 16.10" and .minor_upgrade_command == "aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 --region us-east-1 --profile prod" and (.minor_upgrade_note | test("next maintenance window unless --apply-immediately"))'
jqt fleet_json '.rows[] | select(.identifier == "orders-prod-2") | .minor_upgrade_command == "aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 --region us-east-1 --profile prod"'
jqt fleet_json '[.rows[] | select(.identifier == "crm-sql-prod")][0] | .auto_minor_upgrade == "false" and .latest_minor_version == "15.00.4430.1.v1" and (.minor_upgrade_command | startswith("aws rds modify-db-instance --db-instance-identifier crm-sql-prod --engine-version 15.00.4430.1.v1 "))'
jqt fleet_json '.rows[] | select(.identifier == "web-mysql-prod") | .latest_minor_version == "8.0.42" and (.minor_targets | index("8.4.5") | not)'
jqt fleet_json '.rows[] | select(.identifier == "payments-ams") | .next_minor_version == "8.0.mysql_aurora.3.06.1" and .latest_minor_version == "8.0.mysql_aurora.3.08.0"'
jqt fleet_json '.rows[] | select(.identifier == "reporting-pg") | .latest_minor_version == "15.16" and .minor_versions_available == "15.8, 15.10, 15.12, ..., 15.15, 15.16 (7 versions)"'
jqt fleet_json '.rows[] | select(.identifier == "dev-apg") | .auto_minor_upgrade == "false" and .next_minor_version == "15.10" and .latest_minor_version == "15.13" and (.minor_upgrade_command | startswith("aws rds modify-db-cluster --db-cluster-identifier dev-apg "))'
jqt fleet_json '.rows[] | select(.identifier == "graph-neptune") | .minor_upgrade_command == "aws neptune modify-db-cluster --db-cluster-identifier graph-neptune --engine-version 1.3.4.0 --region ap-south-1 --profile prod"'
jqt fleet_json '.rows[] | select(.identifier == "qa-sql") | .next_minor_version == "up to date" and .latest_minor_version == "" and .minor_upgrade_command == "" and .minor_behind == false'
jqt fleet_json '.rows[] | select(.identifier == "old-replica-2023") | .next_minor_version == "resource not found" and .minor_upgrade_command == "" and .auto_minor_upgrade == ""'
jqt fleet_json 'all(.rows[] | select(.minor_upgrade_command != ""); .minor_upgrade_command | test("--apply-immediately") | not)'
: >"$MOCK_LOG"
t evcache 11 fleet "${ALL3[@]}" --include-docdb -F json
grep '"describe-db-engine-versions"' "$MOCK_LOG" >"$OUT/ev_calls.txt"
chk "engine-version lookups cached per engine+version+region ($(wc -l <"$OUT/ev_calls.txt") calls, no repeats across profiles)" python3 - "$OUT/ev_calls.txt" <<'PY2'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
keys = [(r[r.index("--region") + 1], r[r.index("--engine") + 1], r[r.index("--engine-version") + 1]) for r in rows]
sys.exit(not (len(keys) == 12 and len(set(keys)) == len(keys)))
PY2
t docv 11 fleet -P prod -r us-east-1 --include-docdb -F json
jqt docv '.rows[] | select(.identifier == "catalog-docdb") | .next_minor_version == "up to date" and .minor_upgrade_command == ""'
grep -q '"docdb", "describe-db-engine-versions", "--engine", "docdb"' "$MOCK_LOG" && ok "docdb engine versions via aws docdb" || bad "docdb engine versions not via aws docdb"
grep -q '"neptune", "describe-db-engine-versions", "--engine", "neptune"' "$MOCK_LOG" && ok "neptune engine versions via aws neptune" || bad "neptune engine versions not via aws neptune"
: >"$MOCK_LOG"
t novc 11 fleet "${ALL3[@]}" --no-version-check -F json
jqt novc '.meta.version_check == false and all(.rows[] | select(.resolved); .next_minor_version == "not checked" and .minor_upgrade_command == "" and .latest_minor_version == "") and .summary.behind_latest_minor == 0'
jqt novc '.rows[] | select(.identifier == "dev-apg") | .auto_minor_upgrade == "false"'
chk "--no-version-check: no describe-db-engine-versions calls" bash -c "! grep -q describe-db-engine-versions '$MOCK_LOG'"
t novctext 11 fleet -P prod -r us-east-1 --no-version-check;  has novctext out 'minor ver. : not checked'
printf 'region = us-east-1\nprofiles = prod\nversion_check = no\n' >"$OUT/vc.conf"
t confvc 11 fleet --config "$OUT/vc.conf" -F json;  jqt confvc '.meta.version_check == false'
t evfail 11 evfail -P prod -r us-east-1 -F json
has evfail err 'WARN.*engine-version lookup for mysql 8.0.39 failed'
jqt evfail '.summary.errors == 0 and .meta.aws_failures == 0 and (.rows[] | select(.identifier == "web-mysql-prod") | .next_minor_version == "lookup failed" and (.minor_lookup_error | test("AccessDenied")))'
jqt evfail '.rows[] | select(.identifier == "orders-prod") | .latest_minor_version == "16.10"'
chk "sq quoting round-trips through the shell" bash -c '
  for x in "plain" "it'"'"'s" "a b\$c\`d" "x;rm -rf /tmp/zz" "*"; do
    q="$(jq -rn --arg x "$x" -f <(sed -n "/^def sq:/p" "'"$HERE"'/../lib/report.jq"; echo "\$x | sq"))"
    eval "set -- $q"; [[ $# -eq 1 && "$1" == "$x" ]] || exit 1
  done'

echo "== thresholds / time zone"
t thr 10 fleet -P prod -r ap-south-1 -F json --crit-days 0 --warn-days 7   # crit 0: independent of time of day
jqt thr '[.rows[] | select(.identifier == "erp-oracle-prod")][0].urgency == "WARN"'
jqt thr '[.rows[] | select(.identifier == "reporting-pg")][0].urgency == "INFO"'
t tzutc 11 fleet -P prod -r ap-south-1 --tz UTC;   has tzutc out 'APPLY \(UTC\)'; hasnt tzutc out 'IST'

echo "== filters"
t f_engine 11 fleet "${ALL3[@]}" -e 'aurora*' -F json
jqt f_engine '.summary.total == 4 and ([.rows[].engine] | all(startswith("aurora")))'
jqt f_engine '.summary.unfiltered_total == 15 and .meta.filters_text == "engine=aurora*"'
t f_action 11 fleet "${ALL3[@]}" -a system-update,os-upgrade -F json
jqt f_action '.summary.total == 7 and ([.rows[].action] | unique == ["os-upgrade","system-update"])'
t f_ident 11 fleet "${ALL3[@]}" -i orders-prod -F json
jqt f_ident '.summary.total == 2 and ([.rows[].identifier] | sort == ["orders-prod","orders-prod-2"])'
t f_tag 10 fleet "${ALL3[@]}" -t Environment=dev -F json
jqt f_tag '.summary.total == 2 and ([.rows[].identifier] | sort == ["dev-apg","dev-pg-01"])'
t f_tag2 11 fleet "${ALL3[@]}" -t Environment=prod -t 'Owner=payments*' -F json
jqt f_tag2 '.summary.total == 3 and all(.rows[]; .tags.Environment == "prod" and (.tags.Owner | startswith("payments")))'
t f_tagcase 0 fleet "${ALL3[@]}" -t environment=DEV -F json   # keys are exact, values case-insensitive
jqt f_tagcase '.summary.total == 0'
t f_urg 11 fleet "${ALL3[@]}" -u overdue,crit -F json
jqt f_urg '.summary.total == 5 and all(.rows[]; .urgency == "OVERDUE" or .urgency == "CRIT")'
t f_info 10 fleet "${ALL3[@]}" -u INFO,optional -F json
jqt f_info '.summary.total == 5 and .summary.overall == "WARN"'
t f_nomatch 0 fleet "${ALL3[@]}" -e oracle-se2;  has f_nomatch out 'No pending'
t tagcols 11 fleet -P prod -r eu-west-1,us-east-1 -T Environment,CostCenter -F csv
has tagcols out '"tag:Environment","tag:CostCenter","action"'; hasnt tagcols out 'tag:Owner'

echo "== DocumentDB"
t docdb 11 fleet -P prod -r us-east-1 --include-docdb -F json
jqt docdb '[.rows[] | select(.identifier == "catalog-docdb")][0] | .source == "docdb" and .engine == "docdb" and .urgency == "CRIT"'
jqt docdb '[.rows[] | select(.identifier == "catalog-docdb-1")] | length == 1 and .[0].source == "rds"'
jqt docdb '.summary.total == 7'
grep -q '"docdb", "describe-pending-maintenance-actions"' "$MOCK_LOG" && ok "docdb API called" || bad "docdb API not called"

echo "== access denied in one region"
t denied 11 accessdenied "${ALL3[@]}"
has denied out 'ERRORS \(report incomplete\)'; has denied out 'eu-west-1 rds describe-pending-maintenance-actions: .*AccessDenied'
hasnt denied out 'cms-mariadb'
t denied_ok 3 accessdenied -P prod -r eu-west-1,us-east-1 -u INFO -F json
jqt denied_ok '.summary.overall == "ERROR" and .summary.errors == 1 and .errors[0].region == "eu-west-1"'

echo "== invalid credentials"
t badcreds 2 badcreds "${ALL3[@]}";    has badcreds err 'credentials invalid'; has badcreds err 'No profile could be used'
t onebroken 11 fleet -P prod,broken -r us-east-1 -F json
jqt onebroken '.summary.errors == 1 and .errors[0].profile == "broken" and .summary.total == 6'
t onebroken_info 3 fleet -P broken,nonprod -r ap-south-1 -F json
jqt onebroken_info '.summary.overall == "ERROR" and .summary.total == 1'
t noprofile 2 fleet -P doesnotexist -r us-east-1
t noregion 2 fleet -P prod;            has noregion err 'no region'
MOCK_DEFAULT_REGION=ap-south-1 t profregion 11 fleet -P prod;  has profregion out 'payments-ams'
t allregions 11 fleet -P nonprod -A -F json
jqt allregions '.meta.regions == ["ap-south-1","eu-west-1","us-east-1","us-west-2"] and .summary.total == 4'

echo "== output files"
t files 11 fleet "${ALL3[@]}" -F csv,html,json,text -o "$OUT/rep" --prefix pm
n="$(find "$OUT/rep" -name 'pm_[0-9]*_[0-9]*.*' | wc -l)"; chk "4 timestamped files ($n)" test "$n" -eq 4
f="$(find "$OUT/rep" -name 'pm_*.csv')"
chk "file mode 0640" test "$(stat -c %a "$f")" = 640
chk "csv parses: 16 lines, 37 columns" python3 -c "
import csv,sys; r=list(csv.reader(open('$f'))); sys.exit(not (len(r)==16 and all(len(x)==37 for x in r)))"
chk "csv header" grep -q '^"account_id","profile","region","resource_type","identifier","cluster","engine","engine_version","instance_class","tag:Environment","tag:Owner","tag:Application","action","description","opt_in_status","auto_applied_after_utc","forced_apply_utc","current_apply_utc","effective_apply_utc","effective_apply_ist","days_until","urgency","maint_window_utc","maint_window_ist","next_window_ist","source","arn","apply_immediate_command","apply_note","status_command","pending_actions_command","auto_minor_upgrade","next_minor_version","latest_minor_version","minor_versions_available","minor_upgrade_command","minor_upgrade_note"$' "$f"
h="$(find "$OUT/rep" -name 'pm_*.html')"
chk "html: cards + sortable table + IST + UTC" bash -c "grep -q 'OVERDUE' '$h' && grep -q 'data-s=' '$h' && grep -q 'IST' '$h' && grep -q 'UTC' '$h' && grep -q '<script>' '$h'"
chk "html: no external resources" bash -c "! grep -Eq '(src|href)=\"https?://' '$h'"
chk "html: apply command cell with copy button" bash -c "grep -q '<button class=\"cp\"' '$h' && grep -q 'navigator.clipboard' '$h' && ! grep -q 'undo opt-in' '$h' && ! grep -q 'next-maintenance --region' '$h' && grep -q 'apply immediately' '$h' && grep -q 'may restart / fail over now' '$h' && grep -q 'check status' '$h' && grep -q '<code>aws rds describe-pending-maintenance-actions' '$h' && grep -q '<code>aws rds apply-pending-maintenance-action' '$h'"
chk "html: minor version cell + minor upgrade command with copy button" bash -c "grep -q '<th>Minor version</th>' '$h' && grep -q 'up to date' '$h' && grep -q 'auto minor upgrade: off' '$h' && grep -q 'behind latest minor' '$h' && grep -q 'minor version upgrade &rarr; 16.10</div><div class=\"cmd\"><code>aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 ' '$h' && grep -q 'unless --apply-immediately is added' '$h'"
chk "html parses" python3 -c "import html.parser,sys; html.parser.HTMLParser().feed(open('$h').read())"
chk "json file valid" jq -e '.summary.total == 15' "$(find "$OUT/rep" -name 'pm_*.json')"
t stdout_csv 11 fleet -P prod -r us-east-1 -F csv;  has stdout_csv out '^"account_id"'
t badoutdir 1 fleet -r us-east-1 -o /proc/nope

echo "== config file"
cat >"$OUT/ok.conf" <<CONF
# test config
profiles = prod, nonprod
regions  = ap-south-1   # trailing comment
engines  = "aurora-*"
tag_columns = Environment
crit_days = 7
warn_days = 30
CONF
t conf 11 fleet --config "$OUT/ok.conf" -F json
jqt conf '.summary.total == 2 and .meta.tag_columns == ["Environment"]'
t confoverride 0 fleet --config "$OUT/ok.conf" -e oracle-se2

echo "== alerts (local stubs only)"
: >"$MAIL_SINK"; : >"$OUT/webhook.txt"
t alert_crit 11 fleet "${ALL3[@]}" --alert-email dba@example.invalid --alert-webhook "$HOOK" --alert-webhook-format json
head -1 "$MAIL_SINK" | grep -q 'rds_pending_maintenance.*CRIT:.*15.*pending.*1.*overdue.*4.*due.*7d.*exit.*11.*dba@example.invalid' && ok "mail subject/recipient" || bad "mail subject: $(head -1 "$MAIL_SINK")"
grep -q 'crm-sql-prod' "$MAIL_SINK" && ok "mail body has rows" || bad "mail body"
jq -e 'select(.status == "CRIT") | (.urgent | length) == 5 and .exit_code == 11' "$OUT/webhook.txt" >/dev/null && ok "webhook json payload" || bad "webhook payload"
hasnt alert_crit err 'SECRET'
: >"$MAIL_SINK"
t alert_skip 10 fleet "${ALL3[@]}" -u WARN --alert-email dba@example.invalid
chk "alert-on crit: no mail for WARN" test ! -s "$MAIL_SINK"
t alert_pending 10 fleet "${ALL3[@]}" -u WARN --alert-email dba@example.invalid --alert-on pending
chk "alert-on pending: mail sent" test -s "$MAIL_SINK"
: >"$MAIL_SINK"
t alert_always 0 none -P prod -r us-east-1 --alert-email dba@example.invalid --alert-on always
grep -q 'OK:.*0.*pending' "$MAIL_SINK" && ok "alert-on always: OK mail" || bad "always mail"
: >"$OUT/webhook.txt"
t alert_slack 11 fleet -P prod -r us-east-1 --alert-webhook "$HOOK"
jq -e '.text | startswith("*[rds_pending_maintenance] CRIT")' "$OUT/webhook.txt" >/dev/null && ok "slack payload" || bad "slack payload"
t alert_test 0 fleet --alert-test --alert-webhook "$HOOK" --alert-email dba@example.invalid
t alert_deadhook 11 fleet -P prod -r us-east-1 --alert-webhook "http://127.0.0.1:9/x"
has alert_deadhook err 'webhook .* failed'

echo "== large fleet (argv-size regression: v1.1.0 failed with 'Argument list too long')"
: >"$MAIL_SINK"; : >"$OUT/webhook.txt"
t0=$SECONDS
t large 11 large "${ALL3[@]}" --include-docdb -F csv,html,json,text -o "$OUT/large" --keep-workdir \
    --alert-email dba@example.invalid --alert-webhook "$HOOK" --alert-webhook-format json --alert-on always
el=$(( SECONDS - t0 ))
chk "large fleet finished in ${el}s (< 180s)" test "$el" -lt 180
hasnt large err 'Argument list too long'
has large err 'Result: CRIT - 5322 pending action\(s\) on 3240 resource\(s\)'
lw="$(sed -n 's/.*Raw AWS responses kept in //p' "$OUT/large.err" | tail -1)"
chk "large: rows payload > 128 KiB MAX_ARG_STRLEN ($(stat -c %s "$lw/all_rows.json" 2>/dev/null) bytes)" test "$(stat -c %s "$lw/all_rows.json" 2>/dev/null || echo 0)" -gt 131072
chk "large: rows payload > ARG_MAX ($(getconf ARG_MAX))" test "$(stat -c %s "$lw/all_rows.json" 2>/dev/null || echo 0)" -gt "$(getconf ARG_MAX)"
chk "large: alert body > 128 KiB" test "$(stat -c %s "$lw/alert_body.txt" 2>/dev/null || echo 0)" -gt 131072
rm -rf -- "$lw"
lj="$(find "$OUT/large" -name '*.json')"
chk "large json: 5322 rows, 3120 instances resolved, unique ARNs 3240" jq -e '(.rows | length) == 5322 and ([.rows[] | select(.resource_type == "instance" and .resolved)] | map(.arn) | unique | length) == 3120 and .summary.resources == 3240 and ([.rows[] | select(.resolved | not)] | length) == 0' "$lj"
chk "large json: 15 tags kept, long descriptions intact" jq -e '[.rows[] | select(.resource_type == "instance")][0] | (.tags | length) == 15 and (.description | length) > 250' "$lj"
chk "large json: sorted by effective date" jq -e '[.rows[] | .effective_apply // 1e18] as $e | $e == ($e | sort)' "$lj"
chk "large csv: 5323 lines" test "$(python3 -c "import csv,sys; print(len(list(csv.reader(open(sys.argv[1])))))" "$(find "$OUT/large" -name '*.csv')")" -eq 5323
chk "large html parses, 5322 rows" python3 -c "
import html.parser,sys
class P(html.parser.HTMLParser):
    n=0
    def handle_starttag(self,t,a):
        if t=='tr' and any(k=='class' and v.startswith('r-') for k,v in a): P.n+=1
p=P(); p.feed(open(sys.argv[1]).read()); sys.exit(P.n!=5322)" "$(find "$OUT/large" -name '*.html')"
chk "large: mail body streamed (> 1 MB, has rows)" bash -c "test \$(stat -c %s '$MAIL_SINK') -gt 1000000 && grep -q 'fleet-11-0-db-0000' '$MAIL_SINK'"
chk "large: json webhook payload delivered (5322-row report text)" jq -e -s 'length == 1 and .[0].summary.total == 5322 and (.[0].text | length) > 1000000' "$OUT/webhook.txt"
: >"$OUT/webhook.txt"
t large_slack 11 large -P prod -r us-east-1 --alert-webhook "$HOOK"
chk "large: slack payload truncated under 40k chars" jq -e -s 'length == 1 and (.[0].text | length) < 40000 and (.[0].text | test("truncated"))' "$OUT/webhook.txt"

if [[ -n "${OLD_SCRIPT:-}" ]]; then   # e.g. OLD_SCRIPT=/path/to/v1.1.0/rds_pending_maintenance_report.sh
    MOCK_SCENARIO=large "$OLD_SCRIPT" "${ALL3[@]}" --include-docdb -F json >/dev/null 2>"$OUT/old.err"; orc=$?
    chk "old script ($OLD_SCRIPT) fails on large fleet (rc=$orc) with 'Argument list too long'" grep -q 'Argument list too long' "$OUT/old.err"
fi

echo "== safety"
bad_ops="$(python3 - "$MOCK_LOG" <<'PY'
import json, sys
ro = ("describe-", "get-", "list-")
seen = set()
for line in open(sys.argv[1]):
    a = json.loads(line); skip = False; pos = []
    for i, x in enumerate(a):
        if skip: skip = False; continue
        if x in ("--output","--profile","--region","--cli-connect-timeout","--cli-read-timeout","--filters"): skip = True; continue
        if x.startswith("--"): continue
        pos.append(x)
    if len(pos) >= 2: seen.add(pos[1] if pos[0] != "configure" else "get-config-" + pos[2])
print(" ".join(sorted(o for o in seen if not o.startswith(ro))))
print(" ".join(sorted(seen)), file=sys.stderr)
PY
)"
chk "no mutating operation in mock log (${bad_ops:-none})" test -z "$bad_ops"
chk "script has no mutating aws subcommand" bash -c "! grep -Eq 'apply-pending|modify-|delete-|create-|reboot-|start-db|stop-db' <(grep -v '^ *#' '$SCRIPT' | grep -vi 'help\|README\|echo\|cat <<')"
chk "printed commands live only in lib/report.jq (string data, never executed)" bash -c "! grep -Eq 'eval|bash -c|sh -c' <(grep -v '^ *#' '$SCRIPT')"
chk "no leftover temp dirs" bash -c "! ls -d /tmp/rds_pending_maintenance.* 2>/dev/null | grep -q ."
chk "shellcheck clean" shellcheck "$SCRIPT"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
