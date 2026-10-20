#!/usr/bin/env bash
# Validates rds_inventory_report.sh against the REAL AWS CLI v2 without ever reaching AWS:
#  1. every distinct command line the script issued (logged by the mock) is replayed through the real CLI with
#     fake credentials and a dead local endpoint (127.0.0.1:9). The CLI parses options and runs parameter
#     validation before connecting, so "Could not connect" == accepted; bad syntax fails earlier.
#  2. negative controls: deliberately broken command lines must be rejected.
#  3. shape check: every key the mock returns exists in `--generate-cli-skeleton output`.
#  4. end-to-end: the real CLI, with the script's exact options, against a local fake endpoint (STS/RDS query XML)
#     that pages every list; the report must match the expected counts and no CloudWatch request may arrive.
# Guard: fake credentials, AWS_CONFIG_FILE=/dev/null, every real-CLI call gets a 127.0.0.1 --endpoint-url,
# and a wrapper refuses any call without one.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_AWS="${REAL_AWS:-/usr/local/bin/aws}"
[[ -x "$REAL_AWS" ]] || { echo "real aws CLI not found at $REAL_AWS"; exit 2; }
OUT="$(mktemp -d /tmp/rinv_cli.XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$OUT"' EXIT
export MOCK_LOG="$OUT/calls.jsonl" TMPDIR="$OUT" MOCK_NOW=1792218600 RDS_INV_NOW=1792218600
S="$HERE/../rds_inventory_report.sh"
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_MAX_ATTEMPTS=1 AWS_CONFIG_FILE=/dev/null \
       AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_SESSION_TOKEN AWS_ENDPOINT_URL MOCK_SCENARIO
real() {   # guard: the real CLI only ever runs with a loopback endpoint (or for offline skeletons)
    local a ok=0
    for a in "$@"; do [[ "$a" == http://127.0.0.1:* || "$a" == --generate-cli-skeleton ]] && ok=1; done
    (( ok )) || { echo "GUARD: refusing real aws call without a 127.0.0.1 endpoint: $*" >&2; return 99; }
    "$REAL_AWS" "$@"
}
echo "real CLI: $("$REAL_AWS" --version 2>&1)"

for s in "fleet -P prod,nonprod -r us-east-1,ap-south-1" "fleet -P prod,nonprod -A --include-docdb" \
         "paramdenied -P prod -r us-east-1" "nolc -P prod -r us-east-1" "fleet -P prod -r us-east-1 --fast"; do
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
            --profile) skip=1; continue ;;
            --cli-connect-timeout|--cli-read-timeout) args+=("$a" 2); skip=1; continue ;;
        esac
        args+=("$a")
    done
    OUTP="$(real "${args[@]}" --endpoint-url http://127.0.0.1:9 2>&1)"; RC=$?
}
declare -A seen_ops=()
while IFS= read -r line; do
    mapfile -t argv < <(jq -r '.[]' <<<"$line")
    svcop="$(jq -r '. as $a | ([range(length)] | map(select($a[.] | IN("rds","sts","ec2","cloudwatch"))) | .[0]) as $i | "\($a[$i]) \($a[$i+1])"' <<<"$line")"
    [[ "$svcop" == cloudwatch* ]] && { echo "FAIL: script issued a CloudWatch call: $line"; fail=$((fail + 1)); continue; }
    run_real "${argv[@]}"
    seen_ops["$svcop"]=1
    if [[ "$OUTP" == *"Could not connect to the endpoint URL"* ]]; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL ($RC) $svcop: ${OUTP:0:300}"; fi
done <"$OUT/uniq.jsonl"
echo "accepted by real CLI: $pass, rejected: $fail"
echo "operations covered: $(printf '%s\n' "${!seen_ops[@]}" | sort | paste -sd, -)"
OPS=("rds describe-db-clusters" "rds describe-db-instances" "rds describe-global-clusters" "rds describe-db-cluster-endpoints"
     "rds describe-pending-maintenance-actions" "rds describe-certificates" "rds describe-db-major-engine-versions"
     "rds describe-db-parameters" "rds describe-db-cluster-parameters" "sts get-caller-identity" "ec2 describe-regions")
for op in "${OPS[@]}"; do
    [[ -n "${seen_ops[$op]:-}" ]] || { echo "NOT COVERED: $op"; fail=$((fail + 1)); }
done

neg=0; nneg=0
for bad in "rds describe-db-major-engine-versions --engin postgresx --bogus 1" "rds describe-db-parameters" \
           "rds describe-db-cluster-parameters --bogus x" "rds describe-global-clusters --max-records abc" \
           "rds describe-db-instances --filters Name" "rds modify-db-instance"; do
    nneg=$((nneg + 1))
    # shellcheck disable=SC2086
    run_real --output json --region us-east-1 $bad
    if [[ "$OUTP" != *"Could not connect"* && "$RC" -ne 0 ]]; then neg=$((neg + 1)); else echo "NEGATIVE CONTROL NOT REJECTED: $bad"; fail=$((fail + 1)); fi
done
echo "negative controls rejected: $neg/$nneg"
real rds describe-db-clusters --region us-east-1 >/dev/null 2>&1; grc=$?
if [[ "$grc" == 99 ]]; then echo "guard: real call without loopback endpoint refused"; else echo "GUARD FAILED (rc=$grc)"; fail=$((fail + 1)); fi

shape_ok=0; n_shapes=0
for spec in "rds describe-db-clusters" "rds describe-db-instances" "rds describe-global-clusters" "rds describe-db-cluster-endpoints" \
            "rds describe-pending-maintenance-actions" "rds describe-certificates" "rds describe-db-major-engine-versions|--engine postgres" \
            "rds describe-db-parameters|--db-parameter-group-name hr-sql15" "rds describe-db-cluster-parameters|--db-cluster-parameter-group-name pay-apg16" \
            "sts get-caller-identity" "ec2 describe-regions"; do
    n_shapes=$((n_shapes + 1))
    cmd="${spec%%|*}"; extra=""; [[ "$spec" == *"|"* ]] && extra="${spec#*|}"
    if [[ "$cmd" == "sts get-caller-identity" ]]; then
        echo '{"UserId": "", "Account": "", "Arn": ""}' >"$OUT/skel.json"   # this CLI cannot build the sts skeleton offline
    else
        # shellcheck disable=SC2086
        real $cmd $extra --region us-east-1 --generate-cli-skeleton output >"$OUT/skel.json" 2>"$OUT/skel.err" || { echo "skeleton failed: $cmd"; fail=$((fail + 1)); continue; }
    fi
    # shellcheck disable=SC2086
    MOCK_SCENARIO=fleet PATH="$HERE/mock:$PATH" aws --output json --no-cli-pager --profile prod --region us-east-1 $cmd $extra >"$OUT/mock.json" 2>/dev/null
    missing="$(jq -n --slurpfile s "$OUT/skel.json" --slurpfile m "$OUT/mock.json" '
        [$m[0] | paths | map(if type == "number" then 0 else . end)] | unique
        | map(select(. as $p | ($s[0] | try getpath($p) catch null) == null))
        | map(map(tostring) | join("."))')"
    if [[ "$(jq length <<<"$missing")" == 0 && -s "$OUT/mock.json" && "$(jq '[paths] | length' "$OUT/mock.json")" -gt 1 ]]; then shape_ok=$((shape_ok + 1))
    else echo "SHAPE MISMATCH $cmd $extra: $missing"; fail=$((fail + 1)); fi
done
echo "mock response shapes matching CLI skeleton: $shape_ok/$n_shapes"

python3 "$HERE/fake_aws_endpoint.py" "$OUT/fport" "$OUT/freq.jsonl" "$OUT/expected.json" &
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
PATH="$OUT/realbin:$PATH" "$S" -r us-east-1 -F json >"$OUT/e2e.json" 2>"$OUT/e2e.err"; erc=$?
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
summ="$(jq -sc 'group_by(.action) | map({key: .[0].action, value: {requests: length, pages_after_first: (map(select(.marker != null)) | length)}}) | from_entries' "$OUT/freq.jsonl")"
echo "fake endpoint requests: $summ"
exp="$(cat "$OUT/expected.json")"
got="$(jq -c '{groups: .summary.groups, instances: .summary.instances, clusters: .summary.clusters, global_clusters: .summary.global_clusters,
               rows: ([.groups[].rows[]] | length), errors: .summary.errors}' "$OUT/e2e.json" 2>/dev/null)"
paged="$(jq -r '[.[] | select(.pages_after_first > 0)] | length' <<<"$summ")"
cw="$(jq -s '[.[] | select(.action | test("Metric"))] | length' "$OUT/freq.jsonl")"
if [[ "$erc" == 0 && "$(jq -S . <<<"$exp")" == "$(jq -S . <<<"$got")" && "$paged" -ge 4 && "$cw" == 0 ]] \
   && jq -e '[.groups[] | select(.type == "global")][0] as $g | ($g.rows | map(.role) | .[0:3]) == ["global", "primary", "writer"]
             and ([.groups[].rows[] | select(.name == "fake-aurora")][0] | .reader_count == 2 and (.custom_endpoints | length) == 1)
             and ([.groups[].rows[] | select(.name == "fake-pg-000")][0] | .ssl.value == "rds.force_ssl=1" and (.pending_maintenance | length) == 1)
             and ([.groups[] | select(.title == "fake-pg-005")][0].rows | map(.name)) == ["fake-pg-005", "fake-pg-005-rr"]' "$OUT/e2e.json" >/dev/null; then
    echo "end-to-end via real CLI + paging fake endpoint: OK (expected $exp, $paged paged operation(s), 0 CloudWatch requests)"
else
    echo "END-TO-END FAILED (rc=$erc, expected $exp, got $got, paged=$paged, cloudwatch=$cw)"; tail -5 "$OUT/e2e.err"; fail=$((fail + 1))
fi

echo
if (( fail == 0 )); then echo "VALIDATION PASSED"; else echo "VALIDATION FAILED: $fail problem(s)"; fi
(( fail == 0 ))
