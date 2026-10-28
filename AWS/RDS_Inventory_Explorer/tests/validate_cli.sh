#!/usr/bin/env bash
# Validates rds_inventory_explorer.sh against the REAL AWS CLI v2 without ever reaching AWS:
#  1. every distinct command line the script issued (logged by the mock) is replayed through the real CLI with
#     fake credentials and a dead local endpoint (127.0.0.1:9). The CLI parses options, the --query expression and
#     parameter validation before connecting, so "Could not connect" == accepted; bad syntax fails earlier.
#  2. negative controls: deliberately broken command lines must be rejected.
#  3. shape check: every key the mock returns exists in `--generate-cli-skeleton output`.
#  4. end-to-end: the real CLI, with the script's exact options, against a local fake endpoint (STS/EC2/RDS query XML)
#     that pages the lists; -A discovery must probe both regions and read only the one with databases, the page
#     model must match the expected counts, and no CloudWatch / Secrets Manager / KMS request may arrive.
# Guard: fake credentials, AWS_CONFIG_FILE=/dev/null, every real-CLI call gets a 127.0.0.1 --endpoint-url,
# and a wrapper refuses any call without one.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_AWS="${REAL_AWS:-/usr/local/bin/aws}"
[[ -x "$REAL_AWS" ]] || { echo "real aws CLI not found at $REAL_AWS"; exit 2; }
OUT="$(mktemp -d /tmp/rexp_cli.XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$OUT"' EXIT
export MOCK_LOG="$OUT/calls.jsonl" TMPDIR="$OUT" MOCK_NOW=1792218600 RDS_EXPLORER_NOW=1792218600
S="$HERE/../rds_inventory_explorer.sh"
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_MAX_ATTEMPTS=1 AWS_CONFIG_FILE=/dev/null \
       AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_SESSION_TOKEN AWS_ENDPOINT_URL MOCK_SCENARIO
real() {   # guard: the real CLI only ever runs with a loopback endpoint (or for offline skeletons)
    local a ok=0
    for a in "$@"; do [[ "$a" == http://127.0.0.1:* || "$a" == --generate-cli-skeleton ]] && ok=1; done
    (( ok )) || { echo "GUARD: refusing real aws call without a 127.0.0.1 endpoint: $*" >&2; return 99; }
    "$REAL_AWS" "$@"
}
model() { sed -n 's|.*<script type="application/json" id="explorer-data">\(.*\)</script>.*|\1|p' "$1"; }
echo "real CLI: $("$REAL_AWS" --version 2>&1)"

for s in "fleet -P prod,nonprod,broken -A" "fleet -P prod -r us-east-1,ap-south-1 --include-docdb" "globalfail -P prod -r us-east-1"; do
    read -r scen args <<<"$s"
    # shellcheck disable=SC2086
    MOCK_SCENARIO="$scen" PATH="$HERE/mock:$PATH" "$S" $args -o "$OUT/mockrun" >/dev/null 2>&1
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
    svcop="$(jq -r '. as $a | ([range(length)] | map(select($a[.] | IN("rds","sts","ec2","cloudwatch","secretsmanager","kms","logs"))) | .[0]) as $i | "\($a[$i]) \($a[$i+1])"' <<<"$line")"
    [[ "$svcop" == rds* || "$svcop" == "sts get-caller-identity" || "$svcop" == "ec2 describe-regions" ]] \
        || { echo "FAIL: script issued a non-allowed call: $line"; fail=$((fail + 1)); continue; }
    [[ "$svcop" == "rds describe-"* || "$svcop" != rds* ]] || { echo "FAIL: non-describe RDS call: $line"; fail=$((fail + 1)); continue; }
    run_real "${argv[@]}"
    [[ "$line" == *--no-paginate* ]] && svcop+=" (probe)"
    seen_ops["$svcop"]=1
    if [[ "$OUTP" == *"Could not connect to the endpoint URL"* ]]; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL ($RC) $svcop: ${OUTP:0:300}"; fi
done <"$OUT/uniq.jsonl"
echo "accepted by real CLI: $pass, rejected: $fail"
echo "operations covered: $(printf '%s\n' "${!seen_ops[@]}" | sort | paste -sd, -)"
OPS=("rds describe-db-clusters" "rds describe-db-instances" "rds describe-global-clusters" "rds describe-db-cluster-endpoints"
     "rds describe-pending-maintenance-actions" "rds describe-certificates" "sts get-caller-identity" "ec2 describe-regions"
     "rds describe-db-instances (probe)" "rds describe-db-clusters (probe)")
for op in "${OPS[@]}"; do
    [[ -n "${seen_ops[$op]:-}" ]] || { echo "NOT COVERED: $op"; fail=$((fail + 1)); }
done

neg=0; nneg=0
for bad in "rds describe-db-instances --max-records abc" "rds describe-db-clusters --query length(DBClusters" \
           "rds describe-global-clusters --bogus 1" "rds describe-db-instances --filters Name" \
           "rds describe-db-cluster-endpoints --no-paginate-all" "rds modify-db-instance"; do
    nneg=$((nneg + 1))
    # shellcheck disable=SC2086
    run_real --output json --region us-east-1 $bad
    if [[ "$OUTP" != *"Could not connect"* && "$RC" -ne 0 ]]; then neg=$((neg + 1)); else echo "NEGATIVE CONTROL NOT REJECTED: $bad"; fail=$((fail + 1)); fi
done
echo "negative controls rejected: $neg/$nneg"
real rds describe-db-clusters --region us-east-1 >/dev/null 2>&1; grc=$?
if [[ "$grc" == 99 ]]; then echo "guard: real call without loopback endpoint refused"; else echo "GUARD FAILED (rc=$grc)"; fail=$((fail + 1)); fi

shape_ok=0; n_shapes=0
for cmd in "rds describe-db-clusters" "rds describe-db-instances" "rds describe-global-clusters" "rds describe-db-cluster-endpoints" \
           "rds describe-pending-maintenance-actions" "rds describe-certificates" "sts get-caller-identity" "ec2 describe-regions"; do
    n_shapes=$((n_shapes + 1))
    if [[ "$cmd" == "sts get-caller-identity" ]]; then
        echo '{"UserId": "", "Account": "", "Arn": ""}' >"$OUT/skel.json"   # this CLI cannot build the sts skeleton offline
    else
        # shellcheck disable=SC2086
        real $cmd --region us-east-1 --generate-cli-skeleton output >"$OUT/skel.json" 2>"$OUT/skel.err" || { echo "skeleton failed: $cmd"; fail=$((fail + 1)); continue; }
    fi
    : >"$OUT/mock.json"
    for r in us-east-1 ap-south-1; do   # union of both mock regions (us-east-1 lacks some shapes ap-south-1 has, and vice versa)
        # shellcheck disable=SC2086
        MOCK_SCENARIO=fleet PATH="$HERE/mock:$PATH" aws --output json --no-cli-pager --profile prod --region "$r" $cmd >>"$OUT/mock.json" 2>/dev/null
    done
    missing="$(jq -n --slurpfile s "$OUT/skel.json" --slurpfile m "$OUT/mock.json" '
        [$m[] | paths | map(if type == "number" then 0 else . end)] | unique
        | map(select(. as $p | ($s[0] | try getpath($p) catch null) == null))
        | map(map(tostring) | join("."))')"
    if [[ "$(jq length <<<"$missing")" == 0 && -s "$OUT/mock.json" && "$(jq -s '[.[] | paths] | length' "$OUT/mock.json")" -gt 1 ]]; then shape_ok=$((shape_ok + 1))
    else echo "SHAPE MISMATCH $cmd: $missing"; fail=$((fail + 1)); fi
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
PATH="$OUT/realbin:$PATH" "$S" -A -o "$OUT/e2e" >"$OUT/e2e.out" 2>"$OUT/e2e.err"; erc=$?
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
summ="$(jq -sc 'group_by(.action + "@" + .region) | map({key: (.[0].action + "@" + .[0].region), value: {requests: length, pages_after_first: (map(select(.marker != null)) | length)}}) | from_entries' "$OUT/freq.jsonl")"
echo "fake endpoint requests: $summ"
html="$(find "$OUT/e2e" -name '*.html' 2>/dev/null | head -1)"
[[ -n "$html" ]] && model "$html" >"$OUT/e2e.json"
exp="$(cat "$OUT/expected.json")"
got="$(jq -c '.meta.counts' "$OUT/e2e.json" 2>/dev/null)"
paged="$(jq -r '[to_entries[] | select(.value.pages_after_first > 0)] | length' <<<"$summ")"
forbidden="$(jq -s '[.[] | select(.service | IN("monitoring", "secretsmanager", "kms", "logs"))] | length' "$OUT/freq.jsonl")"
probes="$(jq -s '[.[] | select(.max_records == "20")] | map(.region) | sort' "$OUT/freq.jsonl" | jq -c .)"
eu_full="$(jq -s '[.[] | select(.region == "eu-west-1" and .max_records == null and .service == "rds")] | length' "$OUT/freq.jsonl")"
if [[ "$erc" == 0 && "$(jq -S . <<<"$exp")" == "$(jq -S . <<<"$got")" && "$paged" -ge 2 && "$forbidden" == 0 \
      && "$probes" == '["eu-west-1","eu-west-1","us-east-1","us-east-1"]' && "$eu_full" == 0 ]] \
   && jq -e '[.resources[] | select(.name == "fake-global")][0] as $g | $g.d.primary_region == "us-east-1" and ($g.d.members[0].id != null)
             and ([.resources[] | select(.name == "fake-aurora")][0].d | .writer == "fake-aurora-1" and (.members | length) == 3
                  and (.custom_endpoints | length) == 1 and .master.managed and .backup.retention_days == 14
                  and .maintenance_window.local == "sun:02:30-sun:03:00 IST")
             and ([.resources[] | select(.name == "fake-pg-000")][0].d | (.replicas[0].id != null) and (.pending | length) == 1 and .auto_minor == true)
             and ([.resources[] | select(.name == "fake-pg-000-rr")][0].d.source.name == "fake-pg-000")' "$OUT/e2e.json" >/dev/null; then
    echo "end-to-end via real CLI + paging fake endpoint: OK (counts $got, $paged paged operation(s), probes $probes, eu-west-1 skipped, 0 forbidden-service requests)"
else
    echo "END-TO-END FAILED (rc=$erc, expected $exp, got $got, paged=$paged, probes=$probes, eu_full=$eu_full, forbidden=$forbidden)"; tail -5 "$OUT/e2e.err"; fail=$((fail + 1))
fi

echo
if (( fail == 0 )); then echo "VALIDATION PASSED"; else echo "VALIDATION FAILED: $fail problem(s)"; fi
(( fail == 0 ))
