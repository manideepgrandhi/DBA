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
         "accessdenied -P prod -r eu-west-1" "fleet -P prod,broken -r us-east-1"; do
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
    svcop="$(jq -r '. as $a | ([range(length)] | map(select($a[.] | IN("rds","sts","ec2","docdb"))) | .[0]) as $i | "\($a[$i]) \($a[$i+1])"' <<<"$line")"
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
           "docdb describe-pending-maintenance-actions --max-records abc"; do
    # shellcheck disable=SC2086
    run_real --output json --region us-east-1 $bad
    if [[ "$OUTP" != *"Could not connect"* && "$RC" -ne 0 ]]; then neg=$((neg + 1)); else echo "NEGATIVE CONTROL NOT REJECTED: $bad"; fail=$((fail + 1)); fi
done
echo "negative control rejected: $neg/4"

# shape check: mock output keys must be a subset of the real CLI output skeleton
shape_ok=0
for spec in "rds describe-pending-maintenance-actions" "docdb describe-pending-maintenance-actions" \
            "rds describe-db-instances|--filters Name=db-instance-id,Values=arn:aws:rds:us-east-1:111111111111:db:orders-prod-2,crm-sql-prod" \
            "rds describe-db-clusters|--filters Name=db-cluster-id,Values=orders-prod,catalog-docdb" \
            "sts get-caller-identity" "ec2 describe-regions"; do
    cmd="${spec%%|*}"; extra=""; [[ "$spec" == *"|"* ]] && extra="${spec#*|}"
    if [[ "$cmd" == "sts get-caller-identity" ]]; then
        # CLI 2.37 cannot build this skeleton (its placeholder Arn fails its own min-length check); use the documented shape
        echo '{"UserId": "", "Account": "", "Arn": ""}' >"$OUT/skel.json"
    else
        # shellcheck disable=SC2086
        "$REAL_AWS" $cmd --generate-cli-skeleton output >"$OUT/skel.json" 2>"$OUT/skel.err" || { echo "skeleton failed: $cmd"; fail=$((fail + 1)); continue; }
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
echo "mock response shapes matching CLI skeleton: $shape_ok/6"

# 4. the printed apply_command / undo_command strings (never run by the report) must be accepted by
#    the real CLI: every action type x both --apply-opt-in values, rds + docdb + neptune
: >"$OUT/cmds.txt"
for ao in next-maintenance immediate; do
    MOCK_SCENARIO=fleet PATH="$HERE/mock:$PATH" "$S" -P prod,nonprod -r us-east-1,ap-south-1,eu-west-1 --include-docdb \
        --apply-opt-in "$ao" -F json 2>/dev/null | jq -r '.rows[] | .apply_command, .undo_command | select(. != "")' >>"$OUT/cmds.txt"
done
sort -u -o "$OUT/cmds.txt" "$OUT/cmds.txt"
cpass=0; cfail=0; declare -A combo=()
while IFS= read -r cmd; do
    eval "set -- $cmd"                       # same word splitting / quote removal as a user's shell
    [[ "$1" == aws ]] || { echo "BAD COMMAND: $cmd"; cfail=$((cfail + 1)); continue; }
    shift
    svc="$1"; act=""; opt=""; prev=""
    for w in "$@"; do
        [[ "$prev" == --apply-action ]] && act="$w"; [[ "$prev" == --opt-in-type ]] && opt="$w"; prev="$w"
    done
    run_real --output json "$@"
    if [[ "$OUTP" == *"Could not connect to the endpoint URL"* ]]; then cpass=$((cpass + 1)); combo["$svc $act $opt"]=1
    else cfail=$((cfail + 1)); echo "FAIL ($RC): $cmd :: ${OUTP:0:300}"; fi
done <"$OUT/cmds.txt"
echo "printed apply/undo commands accepted by real CLI: $cpass, rejected: $cfail"
for act in system-update db-upgrade os-upgrade hardware-maintenance ca-certificate-rotation; do
    for opt in next-maintenance immediate undo-opt-in; do
        printf '%s\n' "${!combo[@]}" | grep -qE "^rds $act $opt$" || { echo "MISSING rds $act $opt"; cfail=$((cfail + 1)); }
    done
done
for svc in docdb neptune; do
    for opt in next-maintenance immediate undo-opt-in; do
        printf '%s\n' "${!combo[@]}" | grep -qE "^$svc [a-z-]+ $opt$" || { echo "MISSING $svc $opt"; cfail=$((cfail + 1)); }
    done
done
echo "coverage: $(printf '%s\n' "${!combo[@]}" | sort | paste -sd';' -)"
# negative control for the printed form: a misspelled option and a missing ARN must be rejected client-side
# (note: --opt-in-type is a free string for the CLI; invalid values are only rejected by the service)
neg2=0
run_real --output json --region us-east-1 rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:x --apply-actoin system-update --opt-in-type immediate
[[ "$OUTP" != *"Could not connect"* ]] && neg2=$((neg2 + 1))
run_real --output json --region us-east-1 docdb apply-pending-maintenance-action --apply-action system-update --opt-in-type immediate
[[ "$OUTP" != *"Could not connect"* ]] && neg2=$((neg2 + 1))
echo "apply-command negative control rejected: $neg2/2"
(( neg2 == 2 )) || fail=$((fail + 1))
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
       and .DescribeDBClusters.requests == 2 and .DescribeDBClusters.pages_after_first == 1' <<<"$summ" >/dev/null || pg_ok=0
jq -e '.summary.total == 260 and .summary.resources == 260 and ([.rows[] | select(.resolved | not)] | length) == 0
       and ([.rows[] | select(.resource_type == "instance")] | length) == 230 and .summary.errors == 0' "$OUT/pag.json" >/dev/null 2>&1 || pg_ok=0
if (( pg_ok )) && [[ "$prc" == 10 || "$prc" == 11 ]]; then
    echo "pagination: OK (real CLI followed every Marker page; report has all 260 actions on 260 resources, rc=$prc)"
else
    echo "pagination: FAIL (rc=$prc)"; tail -5 "$OUT/pag.err"; fail=$((fail + 1))
fi
(( fail == 0 ))
