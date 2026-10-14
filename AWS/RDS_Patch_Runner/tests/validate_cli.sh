#!/usr/bin/env bash
# Validate every AWS CLI command the runner issues against the REAL AWS CLI v2 - without ever reaching AWS.
#  1. Run the runner against the stateful mock for every scenario and record each argv (MOCK_CALLS).
#  2. Replay each distinct command shape through the real CLI with fake credentials, no config files, a dead
#     proxy and --endpoint-url http://127.0.0.1:9 (closed port). "Could not connect" = the CLI accepted the
#     command and its parameters and tried to send it; anything else (unknown option, missing parameter,
#     invalid choice) = failure.
#  3. Negative controls (bad commands) must be REJECTED before any connection.
#  4. Every mock response must only use keys that exist in the real output shape (--generate-cli-skeleton output).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$HERE")"
RUNNER="$ROOT/rds_patch_runner.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/rds_pr_validate.XXXXXX")"
trap 'rm -rf -- "$T"' EXIT

if [[ -z "${REAL_AWS:-}" ]]; then
    while IFS= read -r c; do
        [[ "$c" == "$HERE/mock/aws" ]] && continue
        "$c" --version 2>&1 | grep -q '(mock)' && continue
        REAL_AWS="$c"; break
    done < <(type -ap aws)
fi
[[ -n "${REAL_AWS:-}" && -x "$REAL_AWS" ]] || { echo "real AWS CLI v2 not found (set REAL_AWS)"; exit 1; }
if ! "$REAL_AWS" --version 2>&1 | grep -q '^aws-cli/2' || "$REAL_AWS" --version 2>&1 | grep -q '(mock)'; then echo "REAL_AWS is not the real AWS CLI v2"; exit 1; fi
echo "real CLI: $REAL_AWS ($("$REAL_AWS" --version 2>&1))"

# ---- guard: nothing below can reach AWS --------------------------------------------------------------------
export AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE AWS_SECRET_ACCESS_KEY=fakefakefakefakefakefakefakefakefakefake
unset AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
# profiles 'prod' / 'default' exist only in throw-away files with fake keys (the runner passes --profile)
printf '[default]\nregion = us-east-1\n[profile prod]\nregion = us-east-1\n' >"$T/config"
printf '[default]\naws_access_key_id = AKIAFAKEFAKEFAKEFAKE\naws_secret_access_key = fakefakefakefakefakefakefakefakefakefake\n[prod]\naws_access_key_id = AKIAFAKEFAKEFAKEFAKE\naws_secret_access_key = fakefakefakefakefakefakefakefakefakefake\n' >"$T/credentials"
export AWS_CONFIG_FILE="$T/config" AWS_SHARED_CREDENTIALS_FILE="$T/credentials" AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9
export https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 NO_PROXY='' no_proxy='' AWS_MAX_ATTEMPTS=1 AWS_PAGER=''
real() {   # real <argv...> : always forces the dead endpoint, whatever the argv says
    local a; for a in "$@"; do [[ "$a" == --endpoint-url* ]] && { echo "GUARD: argv carries --endpoint-url" >&2; return 99; }; done
    timeout 60 "$REAL_AWS" --endpoint-url http://127.0.0.1:9 --cli-connect-timeout 2 --cli-read-timeout 2 "$@"
}

# the CLI only gets this far after parsing + validating argv and building the request; the proxy / dead endpoint
# then refuses the connection
CONNECT_RE='Could not connect to the endpoint URL|Failed to connect to proxy URL'
PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }

echo "== 1. record commands from mock runs"
EX=(--execute --yes --poll-sec 0 --grace-sec 2)
i=0
rec() {   # rec <scenario> args...
    local s="$1"; shift; i=$(( i + 1 ))
    PATH="$HERE/mock:$PATH" MOCK_SCENARIO="$s" MOCK_STATE="$T/st$i.json" MOCK_CALLS="$T/calls" MOCK_OUTPUTS="$T/outputs" \
        RDS_PR_LOCK_DIR="$T/locks" "$RUNNER" -c orders-prod -o "$T/o$i" "$@" </dev/null >/dev/null 2>&1 || true
}
rec ok -P prod -r us-east-1 "${EX[@]}" --html
rec ok -r us-east-1 "${EX[@]}"                       # no --profile
rec failover -P prod -r eu-west-1 "${EX[@]}"
rec earlyfailover -P prod -r us-east-1 "${EX[@]}"
rec minor -P prod -r us-east-1 "${EX[@]}" --minor-upgrade latest
rec docdb -P prod -r us-east-1 "${EX[@]}"
rec neptune -P prod -r us-east-1 "${EX[@]}"
rec waitgiveup -P prod -r us-east-1 "${EX[@]}"
rec clusteronly -P prod -r us-east-1 "${EX[@]}"
rec readererror -P prod -r us-east-1 "${EX[@]}"
rec ok -P prod -r us-east-1 --minor-upgrade 15.6
rec ok -P prod -r us-east-1 "${EX[@]}" --action system-update --skip-snapshot
rec ordered -P prod -r us-east-1 "${EX[@]}"           # all action types, one rolling pass, minor last
rec dbtolatest -P prod -r us-east-1 "${EX[@]}"        # minor recompute -> already at latest
rec ok -P prod -r us-east-1 "${EX[@]}" --minor-upgrade none
rec neptune -P prod -r us-east-1 "${EX[@]}" --minor-upgrade 1.3.2.0
# normalise: identical shape -> one replay (values that vary per run are kept; they are real argv)
jq -c 'select(.[0] != "--version")' "$T/calls" | sort -u >"$T/uniq"
echo "  recorded $(wc -l <"$T/calls") calls, $(wc -l <"$T/uniq") distinct"
ops="$(jq -r '. as $a | ([range(length) | select($a[.] | IN("rds", "docdb", "neptune", "sts"))][0]) as $k
              | $a[$k] + " " + $a[$k + 1] + (if $a[$k + 1] == "wait" then " " + $a[$k + 2] else "" end)' "$T/uniq" | sort -u)"
printf '%s\n' "$ops" | sed 's/^/    /'

echo "== 2. replay through the real CLI (dead endpoint)"
n=0
while IFS= read -r line; do
    mapfile -t argv < <(jq -r '.[]' <<<"$line")
    n=$(( n + 1 ))
    out="$(real "${argv[@]}" 2>&1)"; rc=$?
    if grep -qE "$CONNECT_RE" <<<"$out"; then ok "$(jq -r '. as $a | ([range(length) | select($a[.] | IN("rds", "docdb", "neptune", "sts"))][0]) as $k | $a[$k:] | join(" ")' <<<"$line")"
    else bad "accepted: $line" "rc=$rc $(head -c 300 <<<"$out")"; fi
done <"$T/uniq"
check_ops() {
    local want
    for want in "sts get-caller-identity" "rds describe-db-clusters" "rds describe-db-instances" "rds describe-pending-maintenance-actions" \
                "rds apply-pending-maintenance-action" "docdb apply-pending-maintenance-action" "neptune apply-pending-maintenance-action" \
                "rds create-db-cluster-snapshot" "docdb create-db-cluster-snapshot" "neptune create-db-cluster-snapshot" \
                "rds wait db-cluster-snapshot-available" "rds describe-db-cluster-snapshots" "rds describe-db-engine-versions" "rds modify-db-cluster" \
                "docdb describe-pending-maintenance-actions" "neptune describe-pending-maintenance-actions"; do
        if grep -qxF "$want" <<<"$ops"; then ok "covered: $want"; else bad "not covered: $want"; fi
    done
}
check_ops

echo "== 3. negative controls (must be rejected without connecting)"
neg() {   # neg <label> argv...
    local label="$1"; shift
    local out; out="$(real "$@" 2>&1)"
    if grep -qE "$CONNECT_RE" <<<"$out"; then bad "negative control accepted: $label"; else ok "rejected: $label"; fi
}
neg "misspelt option"  rds apply-pending-maintenance-action --resource-identifier arn:x --apply-action system-update --opt-in-tipe immediate
neg "missing --apply-action" rds apply-pending-maintenance-action --resource-identifier arn:x --opt-in-type immediate
neg "no such waiter"   rds wait cluster-snapshot-available --db-cluster-snapshot-identifier x
neg "docdb waiter (none exists)" docdb wait db-cluster-snapshot-available --db-cluster-snapshot-identifier x
neg "modify-db-cluster w/o id" rds modify-db-cluster --engine-version 15.6 --apply-immediately
neg "snapshot w/o snapshot id" rds create-db-cluster-snapshot --db-cluster-identifier x

echo "== 4. mock output shapes vs real output skeletons"
env -u AWS_ENDPOINT_URL python3 - "$T/outputs" "$REAL_AWS" <<'PY' >"$T/shape.txt" 2>&1
import json, subprocess, sys
def paths(o, p=""):
    out = set()
    if isinstance(o, dict):
        for k, v in o.items(): out.add(p + "." + k); out |= paths(v, p + "." + k)
    elif isinstance(o, list):
        for v in o: out |= paths(v, p + "[]")
    return out
seen = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r["out"] is None: continue
    key = (r["service"], r["op"])
    seen.setdefault(key, set()).update(paths(r["out"]))
bad = 0
for (svc, op), ps in sorted(seen.items()):
    if op.startswith("wait"): continue
    req = {"apply-pending-maintenance-action": ["--resource-identifier", "arn:aws:rds:us-east-1:123456789012:db:x", "--apply-action", "x", "--opt-in-type", "immediate"],
           "create-db-cluster-snapshot": ["--db-cluster-identifier", "x", "--db-cluster-snapshot-identifier", "x"],
           "modify-db-cluster": ["--db-cluster-identifier", "x"]}.get(op, [])
    sk = subprocess.run([sys.argv[2], svc, op, *req, "--generate-cli-skeleton", "output"], capture_output=True, text=True)
    if sk.returncode != 0 or not sk.stdout.strip():
        print(f"SKIP {svc} {op} (no output skeleton from the CLI)"); continue
    allowed = paths(json.loads(sk.stdout))
    missing = sorted(ps - allowed)
    print(("OK  " if not missing else "BAD ") + f"{svc} {op}" + ("" if not missing else " unknown keys: " + ", ".join(missing)))
    bad += bool(missing)
sys.exit(1 if bad else 0)
PY
src=$?
while IFS= read -r l; do if [[ "$l" == OK* ]]; then ok "shape ${l#OK  }"; elif [[ "$l" == SKIP* ]]; then printf '  skip %s\n' "${l#SKIP }"; else bad "shape ${l#BAD }"; fi; done <"$T/shape.txt"
(( src == 0 )) || bad "shape check returned $src"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
