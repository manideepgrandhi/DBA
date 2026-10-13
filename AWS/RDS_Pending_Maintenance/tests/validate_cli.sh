#!/usr/bin/env bash
# 1. Replays every distinct AWS CLI command line that rds_pending_maintenance_report.sh issued (as
#    logged by the mock) through the REAL AWS CLI v2 with fake credentials and a dead local endpoint.
#    The real CLI parses options/shorthand (--filters) and runs botocore parameter validation before
#    connecting, so "Could not connect" == command accepted; bad syntax fails earlier with rc 252.
# 2. Negative control: a few deliberately broken command lines must be rejected.
# 3. Shape check: every key the mock returns must exist in `--generate-cli-skeleton output`.
# Nothing reaches AWS.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_AWS="${REAL_AWS:-/usr/local/bin/aws}"
[[ -x "$REAL_AWS" ]] || { echo "real aws CLI not found at $REAL_AWS"; exit 2; }
OUT="$(mktemp -d /tmp/rpm_cli.XXXXXX)"
trap 'rm -rf -- "$OUT"' EXIT
export MOCK_LOG="$OUT/calls.jsonl"
S="$HERE/../rds_pending_maintenance_report.sh"

for s in "fleet -P prod,nonprod -r us-east-1,ap-south-1,eu-west-1 --include-docdb" "fleet -P nonprod --all-regions" \
         "accessdenied -P prod -r eu-west-1" "fleet -P prod,broken -r us-east-1" "fleet -P prod -r us-west-2"; do
    read -r scen args <<<"$s"
    # shellcheck disable=SC2086
    MOCK_SCENARIO="$scen" PATH="$HERE/mock:$PATH" "$S" $args -F json >/dev/null 2>&1
done
jq -c 'select(.[0] != "--version" and .[0] != "configure")' "$MOCK_LOG" | sort -u >"$OUT/uniq.jsonl"
echo "distinct command lines: $(wc -l <"$OUT/uniq.jsonl")"

export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_MAX_ATTEMPTS=1 AWS_CONFIG_FILE=/dev/null \
       AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
pass=0; fail=0
run_real() {   # run_real <argv...>  -> sets OUTP, RC
    local -a args=(); local a skip=0
    for a in "$@"; do
        if (( skip )); then skip=0; continue; fi
        case "$a" in
            --profile) skip=1; continue ;;                       # no profiles on this box
            --cli-connect-timeout|--cli-read-timeout) args+=("$a" 2); skip=1; continue ;;
        esac
        args+=("$a")
    done
    OUTP="$("$REAL_AWS" "${args[@]}" --endpoint-url http://127.0.0.1:9 2>&1)"; RC=$?
}
declare -A seen_ops=()
while IFS= read -r line; do
    mapfile -t argv < <(jq -r '.[]' <<<"$line")
    run_real "${argv[@]}"
    svcop="$(jq -r '. as $a | ([range(length)] | map(select($a[.] | IN("rds","sts","ec2","docdb","neptune"))) | .[0]) as $i | "\($a[$i]) \($a[$i+1])"' <<<"$line")"
    seen_ops["$svcop"]=1
    if [[ "$OUTP" == *"Could not connect to the endpoint URL"* ]]; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL ($RC) $svcop: ${OUTP:0:300}"; fi
done <"$OUT/uniq.jsonl"
echo "accepted by real CLI: $pass, rejected: $fail"
echo "operations covered: $(printf '%s\n' "${!seen_ops[@]}" | sort | paste -sd, -)"

# negative control: these must NOT reach the connect stage
neg=0
for bad in "rds describe-pending-maintenance-actions --bogus-opt x" \
           "rds describe-db-instances --filters Name=db-instance-id,Valuez=x" \
           "rds describe-db-clusters --filters Nme=db-cluster-id" \
           "docdb describe-pending-maintenance-actions --max-records abc" \
           "rds describe-db-engine-versions --engine-versoin 16.8" "neptune describe-db-engine-versions --engine"; do
    # shellcheck disable=SC2086
    run_real --output json --region us-east-1 $bad
    if [[ "$OUTP" != *"Could not connect"* && "$RC" -ne 0 ]]; then neg=$((neg + 1)); else echo "NEGATIVE CONTROL NOT REJECTED: $bad"; fail=$((fail + 1)); fi
done
echo "negative control rejected: $neg/6"

# shape check: mock output keys must be a subset of the real CLI output skeleton
shape_ok=0
for spec in "rds describe-pending-maintenance-actions" "docdb describe-pending-maintenance-actions" \
            "rds describe-db-instances|--filters Name=db-instance-id,Values=arn:aws:rds:us-east-1:111111111111:db:orders-prod-2,crm-sql-prod" \
            "rds describe-db-clusters|--filters Name=db-cluster-id,Values=orders-prod,catalog-docdb" \
            "rds describe-db-engine-versions|--engine aurora-postgresql --engine-version 16.8" \
            "docdb describe-db-engine-versions|--engine docdb --engine-version 5.0.0" \
            "neptune describe-db-engine-versions|--engine neptune --engine-version 1.3.2.1" \
            "sts get-caller-identity" "ec2 describe-regions"; do
    cmd="${spec%%|*}"; extra=""; [[ "$spec" == *"|"* ]] && extra="${spec#*|}"
    if [[ "$cmd" == "sts get-caller-identity" ]]; then
        # CLI 2.37 cannot build this skeleton (its placeholder Arn fails its own min-length check); use the documented shape
        echo '{"UserId": "", "Account": "", "Arn": ""}' >"$OUT/skel.json"
    else
        # shellcheck disable=SC2086
        "$REAL_AWS" $cmd --region us-east-1 --generate-cli-skeleton output >"$OUT/skel.json" 2>"$OUT/skel.err" || { echo "skeleton failed: $cmd"; fail=$((fail + 1)); continue; }
    fi
    # shellcheck disable=SC2086
    MOCK_SCENARIO=fleet PATH="$HERE/mock:$PATH" aws --output json --no-cli-pager --profile prod --region us-east-1 $cmd $extra >"$OUT/mock.json" 2>/dev/null
    missing="$(jq -n --slurpfile s "$OUT/skel.json" --slurpfile m "$OUT/mock.json" '
        [$m[0] | paths | map(if type == "number" then 0 else . end)] | unique
        | map(select(. as $p | ($s[0] | try getpath($p) catch null) == null))
        | map(map(tostring) | join("."))')"
    if [[ "$(jq length <<<"$missing")" == 0 && -s "$OUT/mock.json" ]]; then shape_ok=$((shape_ok + 1))
    else echo "SHAPE MISMATCH $cmd: $missing"; fail=$((fail + 1)); fi
done
echo "mock response shapes matching CLI skeleton: $shape_ok/9"
(( shape_ok == 9 )) || fail=$((fail + 1))

# 4. every printed command (apply_immediate_command, status_command, pending_actions_command,
#    minor_upgrade_command; never run by the report) must be accepted by the real CLI:
#    every action type, rds + docdb + neptune, instance + cluster
CMDS='.rows[] | .apply_immediate_command, .status_command, .pending_actions_command, .minor_upgrade_command | select(. != "")'
: >"$OUT/cmds.txt"
MOCK_SCENARIO=fleet PATH="$HERE/mock:$PATH" "$S" -P prod,nonprod -r us-east-1,ap-south-1,eu-west-1,us-west-2 --include-docdb -F json \
    2>/dev/null >"$OUT/fleet.json"
jq -r "$CMDS" "$OUT/fleet.json" >>"$OUT/cmds.txt"
# synthetic rows through the real finalize step: a neptune instance (not in the mock fleet) and awkward
# values that need shell quoting; eval must give back exactly the original words
# shellcheck disable=SC2016  # literal $ and backtick in test data are intentional
SYN='[{"account":"123456789012","profile":"default","region":"us-east-1","source":"rds","resource_type":"instance",
  "identifier":"nep-1","cluster":"nep-cl","engine":"neptune","engine_version":"1.3","instance_class":"db.r6g.large","resolved":true,
  "tags":{},"tag_columns":{},"action":"system-update","description":"x","opt_in_status":"","effective_apply":null,
  "urgency":"OPTIONAL","severity":"INFO","arn":"arn:aws:rds:us-east-1:123456789012:db:nep-1",
  "minor_behind":true,"latest_minor_version":"1.3.4.0","next_minor_version":"1.3.3.0"},
 {"account":"123456789012","profile":"default","region":"us-east-1","source":"rds","resource_type":"instance",
  "identifier":"docdb-standalone-check","cluster":"ddb-cl","engine":"docdb","engine_version":"5.0.0","instance_class":"db.r6g.large","resolved":true,
  "tags":{},"tag_columns":{},"action":"system-update","description":"x","opt_in_status":"","effective_apply":null,
  "urgency":"OPTIONAL","severity":"INFO","arn":"arn:aws:rds:us-east-1:123456789012:db:docdb-standalone-check",
  "minor_behind":true,"latest_minor_version":"5.0.1","next_minor_version":"5.0.1"},
 {"account":"123456789012","profile":"default","region":"us-east-1","source":"rds","resource_type":"instance",
  "identifier":"it'"'"'s a b$c`d;rm -rf x","cluster":"","engine":"postgres","engine_version":"16","instance_class":"db.t4g.micro","resolved":false,
  "tags":{},"tag_columns":{},"action":"system-update","description":"x","opt_in_status":"","effective_apply":null,
  "urgency":"OPTIONAL","severity":"INFO","arn":"arn:aws:rds:us-east-1:123456789012:db:it'"'"'s a b$c`d;rm -rf x",
  "minor_behind":true,"latest_minor_version":"16.8","next_minor_version":"16.8"},
 {"account":"123456789012","profile":"default","region":"us-east-1","source":"rds","resource_type":"instance",
  "identifier":"'"$(printf '9Weird__ID--x%.0s' {1..25})"'-","cluster":"","engine":"postgres","engine_version":"16","instance_class":"db.t4g.micro","resolved":true,
  "tags":{},"tag_columns":{},"action":"system-update","description":"x","opt_in_status":"","effective_apply":null,"source_instance":"",
  "urgency":"OPTIONAL","severity":"INFO","arn":"arn:aws:rds:us-east-1:123456789012:db:weird","role":"primary","patch_sequence":2,"patch_group":"w",
  "minor_behind":false,"latest_minor_version":"","next_minor_version":"up to date"}]'
jq -n --argjson rows "$SYN" '{meta: {tz_abbr: "IST", tag_columns: [], version_check: true}, rows: $rows, errors: []}' \
  | TZ=Asia/Kolkata jq --arg mode finalize --argjson now 0 --argjson crit_days 7 --argjson warn_days 30 --argjson tagcols '[]' \
      --argjson f '{"engines":[],"actions":[],"identifiers":[],"urgency":[],"tags":[]}' \
      -f "$HERE/../lib/report.jq" >"$OUT/syn.json"
jq -r "$CMDS" "$OUT/syn.json" >>"$OUT/cmds.txt"
# backup + wait: shell snippets (variable + $(date -u ...)); run them in bash exactly as pasted, with `aws`
# replaced by a recorder, then replay every recorded argv through the real CLI and check the snapshot name rules
: >"$OUT/bk_argv.jsonl"; bk_pairs=0; bk_bad=0
while IFS= read -r pair; do
    b="$(jq -r '.[0]' <<<"$pair")"; w="$(jq -r '.[1]' <<<"$pair")"
    : >"$OUT/bk_one.jsonl"
    REC="$OUT/bk_one.jsonl" bash -c 'aws() { python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "$@" >>"$REC"; }; eval "$1" && eval "$2"' _ "$b" "$w" \
        || { echo "BACKUP SNIPPET FAILED IN BASH: $b"; bk_bad=$((bk_bad + 1)); continue; }
    names="$(jq -r '. as $a | (index("--db-snapshot-identifier") // index("--db-cluster-snapshot-identifier")) as $i | $a[$i + 1]' "$OUT/bk_one.jsonl" | sort -u)"
    if [[ "$(wc -l <<<"$names")" -ne 1 || "$(wc -l <"$OUT/bk_one.jsonl")" -ne 2 ]]; then echo "BACKUP/WAIT NAME MISMATCH: $names"; bk_bad=$((bk_bad + 1)); fi
    # RDS snapshot identifier rules: 1-255 chars, letters/digits/hyphens, first a letter, no '--', no trailing '-'
    if [[ ! "$names" =~ ^[A-Za-z][A-Za-z0-9-]{0,254}$ || "$names" == *--* || "$names" == *- || ! "$names" =~ ^pre-maint-.+-[0-9]{8}-[0-9]{4}$ ]]; then
        echo "BAD SNAPSHOT NAME (${#names}): $names"; bk_bad=$((bk_bad + 1))
    fi
    cat "$OUT/bk_one.jsonl" >>"$OUT/bk_argv.jsonl"; bk_pairs=$((bk_pairs + 1))
done < <(jq -c '.rows[] | select(.backup_command != "") | [.backup_command, .backup_wait_command]' "$OUT/fleet.json" "$OUT/syn.json" | sort -u)
long="$(jq -r '.rows[] | select(.arn | endswith(":weird")) | .backup_snapshot_name' "$OUT/syn.json")"
[[ ${#long} -le 255 && "$long" == pre-maint-9Weird-ID-x9Weird-ID-x*-YYYYMMDD-HHMM && "$long" != *--* ]] || { echo "LONG/AWKWARD ID NOT SANITISED: $long"; bk_bad=$((bk_bad + 1)); }
echo "backup snippets run in bash: $bk_pairs, name-rule/consistency failures: $bk_bad (longest name ${#long} chars incl. YYYYMMDD-HHMM)"
fail=$((fail + bk_bad))
qok=0
awk_id="it's a b\$c\`d;rm -rf x"
for field in status_command pending_actions_command minor_upgrade_command; do
    c="$(jq -r --arg f "$field" '.rows[] | select(.identifier | test("^it.s a b")) | .[$f]' "$OUT/syn.json")"
    [[ "$c" != *$'\n'* ]] || { echo "QUOTING: more than one command selected"; fail=$((fail + 1)); continue; }
    eval "set -- $c"
    want="$awk_id"; [[ "$field" == pending_actions_command ]] && want="arn:aws:rds:us-east-1:123456789012:db:$awk_id"
    [[ "$5" == "$want" ]] && qok=$((qok + 1)) || echo "QUOTING FAIL $field: got [$5]"
done
[[ "$(jq -r '.rows[] | select(.identifier | test("^it.s a b")) | .apply_immediate_command' "$OUT/syn.json")" == "" ]] && qok=$((qok + 1)) || echo "unresolved row has an immediate command"
echo "quoting of awkward values round-trips through the shell: $qok/4"
(( qok == 4 )) || fail=$((fail + 1))
sort -u -o "$OUT/cmds.txt" "$OUT/cmds.txt"
jq -r '@sh' "$OUT/bk_argv.jsonl" | sort -u | sed 's/^/aws /' >>"$OUT/cmds.txt"   # recorded backup / wait argv, re-quoted
cpass=0; cfail=0; declare -A combo=()
while IFS= read -r cmd; do
    eval "set -- $cmd"                       # same word splitting / quote removal as a user's shell
    [[ "$1" == aws ]] || { echo "BAD COMMAND: $cmd"; cfail=$((cfail + 1)); continue; }
    shift
    svc="$1"; op="$2"; act=""; opt=""; prev=""
    for w in "$@"; do
        [[ "$prev" == --apply-action ]] && act="$w"; [[ "$prev" == --opt-in-type ]] && opt="$w"; prev="$w"
    done
    run_real "$@"
    if [[ "$OUTP" == *"Could not connect to the endpoint URL"* ]]; then
        cpass=$((cpass + 1))
        if [[ "$op" == apply-pending-maintenance-action ]]; then combo["$svc $act $opt"]=1
        elif [[ "$op" == wait ]]; then combo["$svc wait $3"]=1; else combo["$svc $op"]=1; fi
        [[ "$cmd" == *"--opt-in-type next-maintenance"* || "$cmd" == *undo-opt-in* || "$cmd" == *--apply-immediately* ]] \
            && { echo "UNEXPECTED (removed in 1.3.0 / must not be printed): $cmd"; cfail=$((cfail + 1)); }
    else cfail=$((cfail + 1)); echo "FAIL ($RC): $cmd :: ${OUTP:0:300}"; fi
done <"$OUT/cmds.txt"
echo "printed immediate/status/pending/minor-upgrade/backup/wait commands accepted by real CLI: $cpass, rejected: $cfail"
for svc in rds docdb neptune; do
    for op in describe-db-instances describe-db-clusters describe-pending-maintenance-actions modify-db-cluster; do
        [[ -n "${combo[$svc $op]:-}" ]] || { echo "MISSING $svc $op"; cfail=$((cfail + 1)); }
    done
done
for k in "rds modify-db-instance" "rds create-db-snapshot" "rds create-db-cluster-snapshot" "docdb create-db-cluster-snapshot" \
         "neptune create-db-cluster-snapshot" "rds wait db-snapshot-available" "rds wait db-cluster-snapshot-available"; do
    [[ -n "${combo[$k]:-}" ]] || { echo "MISSING $k"; cfail=$((cfail + 1)); }
done
for act in system-update db-upgrade os-upgrade hardware-maintenance ca-certificate-rotation; do
    printf '%s\n' "${!combo[@]}" | grep -qE "^rds $act immediate$" || { echo "MISSING rds $act immediate"; cfail=$((cfail + 1)); }
done
for svc in docdb neptune; do
    printf '%s\n' "${!combo[@]}" | grep -qE "^$svc [a-z-]+ immediate$" || { echo "MISSING $svc immediate"; cfail=$((cfail + 1)); }
done
echo "coverage: $(printf '%s\n' "${!combo[@]}" | sort | paste -sd';' -)"
# negative control for the printed form: a misspelled option and a missing ARN must be rejected client-side
# (note: --opt-in-type is a free string for the CLI; invalid values are only rejected by the service)
neg2=0
run_real --output json --region us-east-1 rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:x --apply-actoin system-update --opt-in-type immediate
[[ "$OUTP" != *"Could not connect"* ]] && neg2=$((neg2 + 1))
run_real --output json --region us-east-1 docdb apply-pending-maintenance-action --apply-action system-update --opt-in-type immediate
[[ "$OUTP" != *"Could not connect"* ]] && neg2=$((neg2 + 1))
run_real --output json --region us-east-1 rds modify-db-cluster --engine-version 16.10
[[ "$OUTP" != *"Could not connect"* ]] && neg2=$((neg2 + 1))
run_real --output json --region us-east-1 rds modify-db-instance --db-instance-identifier x --engine-verison 16.8
[[ "$OUTP" != *"Could not connect"* ]] && neg2=$((neg2 + 1))
run_real --output json --region us-east-1 rds create-db-cluster-snapshot --db-cluster-snapshot-identifier pre-maint-x-20261013-1200
[[ "$OUTP" != *"Could not connect"* ]] && neg2=$((neg2 + 1))
run_real --output json --region us-east-1 docdb wait db-cluster-snapshot-available --db-cluster-snapshot-identifier x
[[ "$OUTP" != *"Could not connect"* ]] && neg2=$((neg2 + 1))   # docdb has no snapshot waiter -> the report uses aws rds wait
echo "printed-command negative control rejected: $neg2/6"
(( neg2 == 6 )) || fail=$((fail + 1))
fail=$((fail + cfail))
# 5. pagination end-to-end with the REAL CLI: run the script against a local fake RDS/STS endpoint that
#    splits every response into pages (Marker). The CLI must follow all pages with the script's exact
#    options (no --max-items / --no-paginate / --page-size), and the report must contain everything.
python3 "$HERE/fake_rds_endpoint.py" "$OUT/fport" "$OUT/freq.jsonl" &
FAKE=$!
for _ in $(seq 50); do [[ -s "$OUT/fport" ]] && break; sleep 0.1; done
mkdir -p "$OUT/realbin"
cat >"$OUT/realbin/aws" <<WRAP
#!/usr/bin/env bash
# real AWS CLI, every service call redirected to the local fake endpoint
case " \$* " in *" configure "*|*" --version "*) exec "$REAL_AWS" "\$@" ;; esac
exec "$REAL_AWS" "\$@" --endpoint-url "http://127.0.0.1:$(cat "$OUT/fport")"
WRAP
chmod +x "$OUT/realbin/aws"
PATH="$OUT/realbin:$PATH" "$S" -r us-east-1 --include-docdb -F json >"$OUT/pag.json" 2>"$OUT/pag.err"; prc=$?
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
pg_ok=1
summ="$(jq -sc 'group_by(.action) | map({key: .[0].action, value: {requests: length, pages_after_first: (map(select(.marker != null)) | length)}}) | from_entries' "$OUT/freq.jsonl")"
echo "fake endpoint requests: $summ"
jq -e '.DescribePendingMaintenanceActions.requests == 6 and .DescribePendingMaintenanceActions.pages_after_first == 4
       and .DescribeDBInstances.requests == 14 and .DescribeDBInstances.pages_after_first == 9
       and .DescribeDBClusters.requests == 2 and .DescribeDBClusters.pages_after_first == 1
       and .DescribeDBEngineVersions.requests == 2' <<<"$summ" >/dev/null || pg_ok=0
jq -e '.summary.total == 260 and .summary.resources == 260 and ([.rows[] | select(.resolved | not)] | length) == 0
       and ([.rows[] | select(.resource_type == "instance")] | length) == 230 and .summary.errors == 0
       and ([.rows[] | select(.engine == "postgres")] | all(.latest_minor_version == "16.8"))
       and ([.rows[] | select(.engine == "aurora-postgresql")] | all(.next_minor_version == "up to date"))' "$OUT/pag.json" >/dev/null 2>&1 || pg_ok=0
if (( pg_ok )) && [[ "$prc" == 10 || "$prc" == 11 ]]; then
    echo "pagination: OK (real CLI followed every Marker page; report has all 260 actions on 260 resources, rc=$prc)"
else
    echo "pagination: FAIL (rc=$prc)"; tail -5 "$OUT/pag.err"; fail=$((fail + 1))
fi
(( fail == 0 ))
