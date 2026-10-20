#!/usr/bin/env bash
# Validates rds_backup_compliance_report.sh against the REAL AWS CLI v2 without ever reaching AWS:
#  1. every distinct command line the script issued (logged by the mock) is replayed through the real CLI with
#     fake credentials and a dead local endpoint (127.0.0.1:9). The CLI parses options and runs parameter
#     validation before connecting, so "Could not connect" == accepted; bad syntax fails earlier.
#  2. negative control: deliberately broken command lines must be rejected.
#  3. shape check: every key the mock returns exists in `--generate-cli-skeleton output`.
#  4. every PRINTED delete command (never run by the script) is syntactically accepted by the real CLI - checked
#     only against the dead loopback endpoint with fake credentials.
#  5. end-to-end: the real CLI, with the script's exact options, against a local fake endpoint (RDS/STS query XML +
#     AWS Backup REST-JSON) that pages every list; the report must contain everything and match the expected counts.
# Guard: fake credentials, AWS_CONFIG_FILE=/dev/null, every real-CLI call gets a 127.0.0.1 --endpoint-url,
# and a wrapper refuses any call without one.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_AWS="${REAL_AWS:-/usr/local/bin/aws}"
[[ -x "$REAL_AWS" ]] || { echo "real aws CLI not found at $REAL_AWS"; exit 2; }
OUT="$(mktemp -d /tmp/rbc_cli.XXXXXX)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$OUT"' EXIT
export MOCK_LOG="$OUT/calls.jsonl" TMPDIR="$OUT"
S="$HERE/../rds_backup_compliance_report.sh"
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_MAX_ATTEMPTS=1 AWS_CONFIG_FILE=/dev/null \
       AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
unset AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_SESSION_TOKEN AWS_ENDPOINT_URL
real() {   # guard: the real CLI only ever runs with a loopback endpoint (or for offline skeletons)
    local a ok=0
    for a in "$@"; do [[ "$a" == http://127.0.0.1:* || "$a" == --generate-cli-skeleton ]] && ok=1; done
    (( ok )) || { echo "GUARD: refusing real aws call without a 127.0.0.1 endpoint: $*" >&2; return 99; }
    "$REAL_AWS" "$@"
}
echo "real CLI: $("$REAL_AWS" --version 2>&1)"

for s in "fleet -P prod,nonprod -r us-east-1,ap-south-1,eu-west-1" "fleet -P nonprod --all-regions" \
         "backupdenied -P prod -r us-east-1" "snapfail -P prod -r us-east-1" "fleet -P prod,broken -r us-east-1"; do
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
    svcop="$(jq -r '. as $a | ([range(length)] | map(select($a[.] | IN("rds","sts","ec2","backup"))) | .[0]) as $i | "\($a[$i]) \($a[$i+1])"' <<<"$line")"
    seen_ops["$svcop"]=1
    if [[ "$OUTP" == *"Could not connect to the endpoint URL"* ]]; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL ($RC) $svcop: ${OUTP:0:300}"; fi
done <"$OUT/uniq.jsonl"
echo "accepted by real CLI: $pass, rejected: $fail"
echo "operations covered: $(printf '%s\n' "${!seen_ops[@]}" | sort | paste -sd, -)"
for op in "rds describe-db-clusters" "rds describe-db-instances" "rds describe-db-snapshots" "rds describe-db-cluster-snapshots" \
          "backup list-backup-vaults" "backup list-recovery-points-by-backup-vault" "sts get-caller-identity" "ec2 describe-regions"; do
    [[ -n "${seen_ops[$op]:-}" ]] || { echo "NOT COVERED: $op"; fail=$((fail + 1)); }
done

neg=0
for bad in "rds describe-db-snapshots --snapshot-kind manual" "rds describe-db-cluster-snapshots --bogus x" \
           "backup list-recovery-points-by-backup-vault --by-created-after 2026-01-01" \
           "backup list-recovery-points-by-backup-vault --backup-vault-name v --by-created-after not-a-date" \
           "backup list-backup-vaults --max-results abc" "rds delete-db-snapshot"; do
    # shellcheck disable=SC2086
    run_real --output json --region us-east-1 $bad
    if [[ "$OUTP" != *"Could not connect"* && "$RC" -ne 0 ]]; then neg=$((neg + 1)); else echo "NEGATIVE CONTROL NOT REJECTED: $bad"; fail=$((fail + 1)); fi
done
echo "negative control rejected: $neg/6"
real rds describe-db-clusters --region us-east-1 >/dev/null 2>&1; grc=$?
if [[ "$grc" == 99 ]]; then echo "guard: real call without loopback endpoint refused"; else echo "GUARD FAILED (rc=$grc)"; fail=$((fail + 1)); fi

shape_ok=0; n_shapes=0
for spec in "rds describe-db-clusters" "rds describe-db-instances" "rds describe-db-snapshots|--snapshot-type automated" \
            "rds describe-db-cluster-snapshots|--snapshot-type manual" "backup list-backup-vaults" \
            "backup list-recovery-points-by-backup-vault|--backup-vault-name rds-weekly-vault" "sts get-caller-identity" "ec2 describe-regions"; do
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

MOCK_SCENARIO=fleet PATH="$HERE/mock:$PATH" "$S" -P prod,nonprod -r us-east-1,ap-south-1 -F json 2>/dev/null >"$OUT/fleet.json"
cpass=0; cfail=0; declare -A combo=()
while IFS= read -r cmd; do
    eval "set -- $cmd"
    [[ "$1" == aws ]] || { echo "BAD COMMAND: $cmd"; cfail=$((cfail + 1)); continue; }
    shift
    run_real "$@"   # dead loopback endpoint + fake credentials: parameter validation only, nothing is deleted anywhere
    if [[ "$OUTP" == *"Could not connect to the endpoint URL"* ]]; then cpass=$((cpass + 1)); combo["$1 $2"]=1
    else cfail=$((cfail + 1)); echo "FAIL ($RC): $cmd :: ${OUTP:0:300}"; fi
done < <(jq -r '.manual[].delete_command' "$OUT/fleet.json")
for k in "rds delete-db-snapshot" "rds delete-db-cluster-snapshot"; do
    [[ -n "${combo[$k]:-}" ]] || { echo "MISSING printed $k"; cfail=$((cfail + 1)); }
done
echo "printed delete commands accepted by real CLI (dead endpoint): $cpass, rejected: $cfail"
fail=$((fail + cfail))

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
got="$(jq -c '{total: .summary.total, compliant: .summary.compliant, manual: .summary.manual.count}' "$OUT/e2e.json" 2>/dev/null)"
paged="$(jq -r '[.[] | select(.pages_after_first > 0)] | length' <<<"$summ")"
if [[ "$erc" == 0 && "$(jq -S . <<<"$exp")" == "$(jq -S . <<<"$got")" && "$paged" -ge 5 ]] \
   && jq -e '.errors == [] and ([.servers[] | select(.identifier == "fake-aurora")][0] | .compliance_status == "COMPLIANT" and (.members | length) == 2)
             and ([.manual[] | select(.orphan)] | length) == 1' "$OUT/e2e.json" >/dev/null; then
    echo "end-to-end via real CLI + paging fake endpoint: OK (expected $exp, got $got, $paged paged operation(s))"
else
    echo "END-TO-END FAILED (rc=$erc, expected $exp, got $got, paged=$paged)"; tail -5 "$OUT/e2e.err"; fail=$((fail + 1))
fi

echo
if (( fail == 0 )); then echo "VALIDATION PASSED"; else echo "VALIDATION FAILED: $fail problem(s)"; fi
(( fail == 0 ))
