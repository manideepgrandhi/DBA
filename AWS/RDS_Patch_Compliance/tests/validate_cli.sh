#!/usr/bin/env bash
# Validates rds_patch_compliance_report.sh against the REAL AWS CLI v2 without ever reaching AWS:
#  1. every distinct command line the script issued (logged by the mock) is replayed through the real CLI with
#     fake credentials and a dead local endpoint (127.0.0.1:9). The CLI parses options and runs parameter
#     validation before connecting, so "Could not connect" == accepted; bad syntax fails earlier.
#  2. negative control: deliberately broken command lines must be rejected.
#  3. shape check: every key the mock returns exists in `--generate-cli-skeleton output`.
#  4. every printed upgrade_command is accepted by the real CLI (rds / docdb / neptune, cluster / instance).
#     The replayed calls include describe-db-engine-versions --engine E --engine-version V for every engine.
#  5. pagination end-to-end: the real CLI, with the script's exact options, against a local fake endpoint that
#     pages every list with Marker; the report must contain everything.
# Guard: fake credentials, AWS_CONFIG_FILE=/dev/null, every real-CLI call gets a 127.0.0.1 --endpoint-url,
# and a wrapper refuses any call without one.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_AWS="${REAL_AWS:-/usr/local/bin/aws}"
[[ -x "$REAL_AWS" ]] || { echo "real aws CLI not found at $REAL_AWS"; exit 2; }
OUT="$(mktemp -d /tmp/rpc_cli.XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$OUT"' EXIT
export MOCK_LOG="$OUT/calls.jsonl" TMPDIR="$OUT"
S="$HERE/../rds_patch_compliance_report.sh"
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_MAX_ATTEMPTS=1 AWS_CONFIG_FILE=/dev/null \
       AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_SESSION_TOKEN
real() {   # guard: the real CLI only ever runs with a loopback endpoint (or for offline skeletons)
    local a ok=0
    for a in "$@"; do [[ "$a" == http://127.0.0.1:* || "$a" == --generate-cli-skeleton ]] && ok=1; done
    (( ok )) || { echo "GUARD: refusing real aws call without a 127.0.0.1 endpoint: $*" >&2; return 99; }
    "$REAL_AWS" "$@"
}

for s in "fleet -P prod,nonprod -r us-east-1,ap-south-1,eu-west-1" "fleet -P nonprod --all-regions" \
         "lookupfail -P prod -r us-east-1" "accessdenied -P prod -r eu-west-1" "fleet -P prod,broken -r us-east-1"; do
    read -r scen args <<<"$s"
    # shellcheck disable=SC2086
    MOCK_SCENARIO="$scen" PATH="$HERE/mock:$PATH" "$S" $args -F json >/dev/null 2>&1
done
jq -c 'select(.[0] != "--version" and .[0] != "configure")' "$MOCK_LOG" | sort -u >"$OUT/uniq.jsonl"
echo "distinct command lines: $(wc -l <"$OUT/uniq.jsonl")"
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
    OUTP="$(real "${args[@]}" --endpoint-url http://127.0.0.1:9 2>&1)"; RC=$?
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
for op in "rds describe-db-clusters" "rds describe-db-instances" "rds describe-pending-maintenance-actions" "rds describe-db-engine-versions" \
          "rds describe-db-major-engine-versions" "docdb describe-db-engine-versions" "neptune describe-db-engine-versions" "sts get-caller-identity" "ec2 describe-regions"; do
    [[ -n "${seen_ops[$op]:-}" ]] || { echo "NOT COVERED: $op"; fail=$((fail + 1)); }
done

neg=0
for bad in "rds describe-db-clusters --bogus-opt x" "rds describe-db-engine-versions --engine-versoin 16.8" \
           "rds describe-db-major-engine-versions --major-engine-versoin 16" "neptune describe-db-engine-versions --engine" \
           "docdb describe-db-engine-versions --max-records abc" "rds describe-db-instances --filters Nme=x"; do
    # shellcheck disable=SC2086
    run_real --output json --region us-east-1 $bad
    if [[ "$OUTP" != *"Could not connect"* && "$RC" -ne 0 ]]; then neg=$((neg + 1)); else echo "NEGATIVE CONTROL NOT REJECTED: $bad"; fail=$((fail + 1)); fi
done
echo "negative control rejected: $neg/6"
real rds describe-db-clusters --region us-east-1 >/dev/null 2>&1; grc=$?
if [[ "$grc" == 99 ]]; then echo "guard: real call without loopback endpoint refused"; else echo "GUARD FAILED (rc=$grc)"; fail=$((fail + 1)); fi

shape_ok=0; n_shapes=0
for spec in "rds describe-db-clusters" "rds describe-db-instances" "rds describe-pending-maintenance-actions" \
            "rds describe-db-engine-versions|--engine aurora-mysql --engine-version 8.0.mysql_aurora.3.05.2" "rds describe-db-engine-versions|--engine sqlserver-se --engine-version 15.00.4410.1.v1" \
            "docdb describe-db-engine-versions|--engine docdb --engine-version 5.0.0" "neptune describe-db-engine-versions|--engine neptune --engine-version 1.3.2.1" \
            "rds describe-db-major-engine-versions|--engine aurora-postgresql" "sts get-caller-identity" "ec2 describe-regions"; do
    n_shapes=$((n_shapes + 1))
    cmd="${spec%%|*}"; extra=""; [[ "$spec" == *"|"* ]] && extra="${spec#*|}"
    if [[ "$cmd" == "sts get-caller-identity" ]]; then
        echo '{"UserId": "", "Account": "", "Arn": ""}' >"$OUT/skel.json"   # CLI 2.37 cannot build this skeleton
    else
        # shellcheck disable=SC2086
        real $cmd --region us-east-1 --generate-cli-skeleton output >"$OUT/skel.json" 2>"$OUT/skel.err" || { echo "skeleton failed: $cmd"; fail=$((fail + 1)); continue; }
    fi
    # shellcheck disable=SC2086
    MOCK_SCENARIO=fleet PATH="$HERE/mock:$PATH" aws --output json --no-cli-pager --profile prod --region us-east-1 $cmd $extra >"$OUT/mock.json" 2>/dev/null
    missing="$(jq -n --slurpfile s "$OUT/skel.json" --slurpfile m "$OUT/mock.json" '
        [$m[0] | paths | map(if type == "number" then 0 else . end)] | unique
        | map(select(. as $p | ($s[0] | try getpath($p) catch null) == null))
        | map(map(tostring) | join("."))')"
    if [[ "$(jq length <<<"$missing")" == 0 && -s "$OUT/mock.json" ]]; then shape_ok=$((shape_ok + 1))
    else echo "SHAPE MISMATCH $cmd $extra: $missing"; fail=$((fail + 1)); fi
done
echo "mock response shapes matching CLI skeleton: $shape_ok/$n_shapes"

MOCK_SCENARIO=fleet PATH="$HERE/mock:$PATH" "$S" -P prod,nonprod -r us-east-1,ap-south-1 -F json 2>/dev/null >"$OUT/fleet.json"
cpass=0; cfail=0; declare -A combo=()
while IFS= read -r cmd; do
    eval "set -- $cmd"
    [[ "$1" == aws ]] || { echo "BAD COMMAND: $cmd"; cfail=$((cfail + 1)); continue; }
    shift
    [[ "$cmd" == *--apply-immediately* ]] && { echo "MUST NOT BE PRINTED: $cmd"; cfail=$((cfail + 1)); }
    run_real "$@"
    if [[ "$OUTP" == *"Could not connect to the endpoint URL"* ]]; then cpass=$((cpass + 1)); combo["$1 $2"]=1
    else cfail=$((cfail + 1)); echo "FAIL ($RC): $cmd :: ${OUTP:0:300}"; fi
done < <(jq -r '.rows[].upgrade_command | select(. != "")' "$OUT/fleet.json")
for k in "rds modify-db-cluster" "rds modify-db-instance" "neptune modify-db-cluster"; do
    [[ -n "${combo[$k]:-}" ]] || { echo "MISSING printed $k"; cfail=$((cfail + 1)); }
done
# docdb is up to date in the mock fleet: check its printed form separately
run_real --output json --region us-east-1 docdb modify-db-cluster --db-cluster-identifier x --engine-version 5.0.0
if [[ "$OUTP" == *"Could not connect"* ]]; then cpass=$((cpass + 1)); else echo "docdb modify-db-cluster form rejected"; cfail=$((cfail + 1)); fi
run_real --output json --region us-east-1 rds modify-db-cluster --engine-version 16.10
[[ "$OUTP" != *"Could not connect"* ]] || { echo "negative: missing identifier accepted"; cfail=$((cfail + 1)); }
echo "printed upgrade commands accepted by real CLI: $cpass, rejected: $cfail ($(printf '%s\n' "${!combo[@]}" | sort | paste -sd';' -))"
fail=$((fail + cfail))

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
PATH="$OUT/realbin:$PATH" "$S" -r us-east-1 -F json >"$OUT/pag.json" 2>"$OUT/pag.err"; prc=$?
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
summ="$(jq -sc 'group_by(.action) | map({key: .[0].action, value: {requests: length, pages_after_first: (map(select(.marker != null)) | length)}}) | from_entries' "$OUT/freq.jsonl")"
echo "fake endpoint requests: $summ"
pg_ok=1
jq -e '.DescribeDBInstances.requests == 12 and .DescribeDBClusters.requests == 2 and .DescribePendingMaintenanceActions.requests == 3
       and .DescribeDBEngineVersions.requests == 2 and .DescribeDBMajorEngineVersions.requests == 6' <<<"$summ" >/dev/null || pg_ok=0
jq -e '.summary.total == 230 and .summary.errors == 0 and .summary.with_pending == 50 and .summary.pending_by_action == {"system-update": 50}
       and ([.rows[] | select(.engine == "postgres")][0].default_auto_upgrade_target == "16.11")
       and ([.rows[] | select(.engine == "postgres")] | length == 200 and all(.versions_behind == 5 and .latest_minor_version == "16.11" and .compliance_status == "NON-COMPLIANT"))
       and ([.rows[] | select(.engine == "aurora-postgresql")] | length == 30 and all(.versions_behind == 1 and .members == "\(.identifier)-1 (writer)" and .standard_support_end == "2029-02-28"))
       and ([.rows[] | select(.engine == "postgres" and .tags.Environment != "prod & test")] | length == 0)' "$OUT/pag.json" >/dev/null 2>&1 || pg_ok=0
if (( pg_ok )) && [[ "$prc" == 0 ]]; then
    echo "pagination: OK (real CLI followed every Marker page; report has all 230 servers/clusters, rc=$prc)"
else
    echo "pagination: FAIL (rc=$prc)"; tail -5 "$OUT/pag.err"; fail=$((fail + 1))
fi
echo "validate_cli: $( (( fail == 0 )) && echo PASS || echo "FAIL ($fail)")"
(( fail == 0 ))
