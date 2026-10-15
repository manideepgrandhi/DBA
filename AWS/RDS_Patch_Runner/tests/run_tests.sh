#!/usr/bin/env bash
# Tests for rds_patch_runner.sh against the stateful mock AWS CLI (tests/mock/aws).  Never reaches real AWS:
# the mock is first in PATH (checked), credentials are fake, config files are /dev/null, and every proxy /
# endpoint variable points at a closed local port, so even a stray real `aws` could not connect.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$HERE")"
RUNNER="$ROOT/rds_patch_runner.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/rds_pr_tests.XXXXXX")"
trap 'rm -rf -- "$T"' EXIT

# ---- real-AWS guard -----------------------------------------------------------------------------------------
export PATH="$HERE/mock:$PATH"
export AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE AWS_SECRET_ACCESS_KEY=fakefakefakefakefakefakefakefakefakefake AWS_SESSION_TOKEN=
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 NO_PROXY='' no_proxy=''
unset AWS_PROFILE AWS_DEFAULT_PROFILE
if [[ "$(command -v aws)" != "$HERE/mock/aws" ]]; then echo "GUARD: aws resolves to $(command -v aws), not the mock - refusing to run" >&2; exit 99; fi
if ! aws --version | grep -q '(mock)'; then echo "GUARD: aws is not the mock - refusing to run" >&2; exit 99; fi

PASS=0; FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
check() { if (set +o pipefail; eval "$2"); then ok "$1"; else bad "$1" "${3:-}"; fi; }

N=0; OUT=""; RC=0; CALLS=""; ODIR=""
run() {   # run <scenario> [runner args...]
    local scen="$1"; shift
    N=$(( N + 1 )); local d="$T/case$N"; mkdir -p "$d"
    CALLS="$d/calls"; ODIR="$d/out"; OUT="$d/output"
    MOCK_SCENARIO="$scen" MOCK_STATE="$d/state.json" MOCK_CALLS="$CALLS" RDS_PR_LOCK_DIR="$d/locks" \
        "$RUNNER" -P prod -r us-east-1 -c orders-prod -o "$ODIR" "$@" </dev/null >"$OUT" 2>&1
    RC=$?
    touch "$CALLS"
}
EX=(--execute --yes --poll-sec 0 --grace-sec 3)
applies_are() { local got; got="$(applies)"; [[ "$got" == "$1" ]] || { echo "       got: $got"; return 1; }; }
has()  { grep -qF -- "$1" "$OUT"; }
nohas(){ ! grep -qF -- "$1" "$OUT"; }
applies() { jq -r 'select(.[ (index("apply-pending-maintenance-action")) ] != null) | (.[index("--resource-identifier") + 1] | split(":") | .[-1]) + "/" + .[index("--apply-action") + 1]' "$CALLS" 2>/dev/null | paste -sd' '; }
writes() { jq -r '[.[] | select(test("^(apply-pending-maintenance-action|create-db-cluster-snapshot|modify-db-cluster)$"))] | .[]' "$CALLS" | wc -l; }

echo "== static"
check "shellcheck runner" "shellcheck '$RUNNER'"
check "shellcheck tests" "shellcheck '$HERE/run_tests.sh' '$HERE/validate_cli.sh'"
check "bash -n" "bash -n '$RUNNER'"
check "jq library compiles" "jq -n --arg mode none -f '$ROOT/lib/runner.jq' >/dev/null"

echo "== usage (exit 1)"
"$RUNNER" -h >/dev/null 2>&1; check "-h exit 0" "[[ $? == 0 ]]"
"$RUNNER" -V 2>&1 | grep -q '1.1.1'; check "-V shows version" "[[ $? == 0 ]]"
run ok --bogus;               check "unknown option -> 1" "[[ $RC == 1 ]]"
"$RUNNER" -r us-east-1 >/dev/null 2>&1; check "missing --cluster -> 1" "[[ $? == 1 ]]"
run ok --timeout-min 0;       check "timeout 0 -> 1" "[[ $RC == 1 ]]"
run ok --timeout-min abc;     check "timeout abc -> 1" "[[ $RC == 1 ]]"
run ok --poll-sec -1;         check "poll -1 -> 1" "[[ $RC == 1 ]]"
run ok --action 'Sys;rm';     check "bad action -> 1" "[[ $RC == 1 ]]"
run ok --minor-upgrade 'a b'; check "bad version -> 1" "[[ $RC == 1 ]]"
run ok --alert-webhook ftp://x; check "bad webhook -> 1" "[[ $RC == 1 ]]"
run ok --config "$ROOT/rds_patch_runner.conf.example"; check "shipped conf example parses (dry run)" "[[ $RC == 0 ]] && has 'PLAN (exact execution order'"
printf 'execute=true\n' >"$T/x.conf"; run ok --config "$T/x.conf"; check "execute in config refused -> 1" "[[ $RC == 1 ]] && has 'not accepted in a config file'"
printf 'aws_secret_access_key=x\n' >"$T/y.conf"; run ok --config "$T/y.conf"; check "credentials in config refused" "[[ $RC == 1 ]]"
printf 'nonsense\n' >"$T/z.conf"; run ok --config "$T/z.conf"; check "invalid config line -> 1" "[[ $RC == 1 ]]"

echo "== dry run (default)"
run ok
check "dry run exit 0" "[[ $RC == 0 ]]"
check "dry run made no write calls" "[[ \$(writes) == 0 ]]"
plan_kinds() { grep -E '^  [0-9]+\. +[a-z]' "$OUT" | sed -E 's/^  [0-9]+\. +//; s/ +:.*//; s/ upg$//' | paste -sd, ; }
plan_targets() { grep -E '^  [0-9]+\. +(reader|cluster|writer) ' "$OUT" | sed -E 's/^.*: ([^ ]+) <- ([^ ]+) .*/\1\/\2/' | paste -sd' ' ; }
check "plan: snapshot, readers, cluster, writer, verify, minor LAST" "[[ \$(plan_kinds) == snapshot,reader,reader,reader,cluster,writer,verify,minor ]]" "got: $(plan_kinds)"
check "plan: per instance system-update before os-upgrade" "[[ \$(plan_targets) == 'orders-prod-2/system-update orders-prod-2/os-upgrade orders-prod-3/system-update orders-prod/db-upgrade orders-prod-1/system-update' ]]" "got: $(plan_targets)"
check "preflight shows minor availability" "has 'MINOR VERSION AVAILABILITY' && has 'next minor             : 15.5' && has 'latest minor           : 15.10' && has 'available minors       : 15.5, 15.6, 15.10' && has 'auto minor upgrade     : true'"
check "preflight shows pending details with dates" "has 'PENDING MAINTENANCE (per resource' && grep -qE 'orders-prod-2 +os-upgrade +OS update +2026-11-01T04:00:00Z +2026-12-01T04:00:00Z +OS upgrade' '$OUT'"
check "minor default is latest -> 15.10 last" "has 'latest -> 15.10 (runs LAST' && grep -E '^  [0-9]+\. ' '$OUT' | tail -1 | grep -q 'modify-db-cluster --engine-version 15.10 --apply-immediately'"
check "plan says dry run" "has 'Dry run only - nothing changed'"
check "no lock taken in dry run" "[[ ! -d '$T/case$N/locks' ]] || [[ -z \$(ls -A '$T/case$N/locks') ]]"
run ok --dry-run --execute --yes --poll-sec 0 --dry-run
check "--dry-run after --execute wins" "[[ $RC == 0 ]] && [[ \$(writes) == 0 ]]"
run ok --skip-snapshot
check "dry run shows snapshot skipped" "has 'SKIPPED (--skip-snapshot)'"
run ok --action system-update
check "--action filter marks others not selected" "has 'os-upgrade (not selected)' && has 'Not selected by --action (left pending): db-upgrade, os-upgrade'"
check "--action plan has no cluster step" "nohas 'cluster    : orders-prod <-'"

echo "== dry run saves its output (v1.1.1)"
run ok
check "dry run with -o: dryrun.log, plan.txt, plan.json, no html" "ls '$ODIR'/orders-prod_*_dryrun.log '$ODIR'/orders-prod_*_plan.txt '$ODIR'/orders-prod_*_plan.json >/dev/null && ! ls '$ODIR'/*_plan.html >/dev/null 2>&1"
check "stamp is UTC YYYYMMDD_HHMMSS" "ls '$ODIR' | grep -Eq '^orders-prod_[0-9]{8}_[0-9]{6}_dryrun\.log$' && [[ \$(ls '$ODIR' | sed -E 's/^orders-prod_([0-9]{8})_.*/\1/' | sort -u) == \$(date -u +%Y%m%d) || \$(ls '$ODIR' | sed -E 's/^orders-prod_([0-9]{8})_.*/\1/' | sort -u) == \$(date -u -d '-1 min' +%Y%m%d) ]]"
check "log has the full console output (preflight + plan)" "grep -q 'MINOR VERSION AVAILABILITY' '$ODIR'/*_dryrun.log && grep -q 'PLAN (exact execution order' '$ODIR'/*_dryrun.log && grep -q 'Dry run only' '$ODIR'/*_dryrun.log"
check "plan.txt == printed plan; plan.json has meta + plan" "grep -q '^  8\.  minor upg' '$ODIR'/*_plan.txt && jq -e '.meta.mode == \"dry-run\" and .meta.result == \"dry-run\" and (.plan.steps | length) == 8' '$ODIR'/*_plan.json >/dev/null"
check "final line lists absolute paths" "tail -1 '$OUT' | grep -q \"Saved (dry-run): $ODIR/orders-prod_\" && tail -1 '$OUT' | grep -q '_dryrun.log$'"
check "dry run: zero write calls, no lock" "[[ \$(writes) == 0 ]] && { [[ ! -d '$T/case$N/locks' ]] || [[ -z \$(ls -A '$T/case$N/locks') ]]; }"
run ok --html
check "--html adds plan.html with preflight sections" "grep -q 'Minor version availability' '$ODIR'/*_plan.html && grep -q 'Pending maintenance' '$ODIR'/*_plan.html && grep -q '2026-12-01T04:00:00Z' '$ODIR'/*_plan.html && grep -q 'Plan (exact execution order)' '$ODIR'/*_plan.html && tail -1 '$OUT' | grep -q '_plan.html'"
check "--html dry run: zero writes" "[[ \$(writes) == 0 ]]"
run ok --no-save
check "--no-save: no files at all" "[[ $RC == 0 ]] && [[ ! -e '$ODIR' ]] && nohas 'Saved ('"
run nothing --minor-upgrade none --html
check "nothing to do: still saved (plan.json result nothing-to-do)" "[[ $RC == 0 ]] && jq -e '.meta.result == \"nothing-to-do\"' '$ODIR'/*_plan.json >/dev/null && ls '$ODIR'/*_plan.html '$ODIR'/*_dryrun.log >/dev/null && [[ \$(writes) == 0 ]]"
run notavailable
check "preflight abort: log + plan.json with the error, exit 2" "[[ $RC == 2 ]] && jq -e '.meta.result == \"aborted\" and (.meta.message | test(\"modifying\")) and .plan == null' '$ODIR'/*_plan.json >/dev/null && grep -q \"status is 'modifying'\" '$ODIR'/*_dryrun.log && tail -1 '$OUT' | grep -q 'Saved (aborted)'"
run ok -l "$T/custom_dry.log"
check "-l custom log used for the dry run" "grep -q 'PLAN (exact' '$T/custom_dry.log' && ! ls '$ODIR'/*_dryrun.log >/dev/null 2>&1 && ls '$ODIR'/*_plan.txt >/dev/null"
N=$(( N + 1 )); d="$T/case$N"; mkdir -p "$d/cwd"
( cd "$d/cwd" && MOCK_SCENARIO=ok MOCK_STATE="$d/s.json" MOCK_CALLS="$d/c" RDS_PR_LOCK_DIR="$d/l" "$RUNNER" -P prod -r us-east-1 -c orders-prod --html </dev/null >"$d/out" 2>&1 ); R=$?
check "default dir ./rds_patch_runs (absolute paths printed)" "[[ $R == 0 ]] && [[ \$(ls '$d/cwd/rds_patch_runs' | wc -l) == 4 ]] && tail -1 '$d/out' | grep -q \"$d/cwd/rds_patch_runs/orders-prod_\""
touch "$d/c"; check "default dir run: zero writes" "[[ \$(jq -r '[.[] | select(test(\"^(apply-pending-maintenance-action|create-db-cluster-snapshot|modify-db-cluster)$\"))] | .[]' '$d/c' | wc -l) == 0 ]]"
run ok "${EX[@]}" --html
check "execute --html: summary.html + absolute paths in the last lines" "ls '$ODIR'/orders-prod_*.summary.html >/dev/null && grep -q \"Saved: $ODIR/orders-prod_.*summary.html\" '$OUT' && ! ls '$ODIR'/*_plan.json >/dev/null 2>&1"

echo "== preflight aborts (exit 2)"
run notavailable; check "cluster not available -> 2" "[[ $RC == 2 ]] && has \"status is 'modifying'\""
run notavailable "${EX[@]}"; check "not available + execute -> 2, no writes" "[[ $RC == 2 ]] && [[ \$(writes) == 0 ]]"
run membernotavailable "${EX[@]}"; check "member not available -> 2" "[[ $RC == 2 ]] && has 'orders-prod-3=rebooting' && [[ \$(writes) == 0 ]]"
run global "${EX[@]}"; check "global member -> 2" "[[ $RC == 2 ]] && has 'global databases are not supported yet' && [[ \$(writes) == 0 ]]"
run unsupported; check "non-Aurora engine -> 2" "[[ $RC == 2 ]] && has 'not supported'"
MOCK_STATE="$T/nf.json" "$RUNNER" -r us-east-1 -c other-cluster -o "$T/nfout" </dev/null >"$T/nf" 2>&1; R=$?
check "cluster not found -> 2" "[[ $R == 2 ]] && grep -q 'DBClusterNotFoundFault' '$T/nf'" 2>/dev/null
run ok --minor-upgrade 15.99; check "invalid minor target -> 2" "[[ $RC == 2 ]] && has 'not a valid minor (non-major) upgrade target' && has '15.5,15.6,15.10'"
run ok --minor-upgrade 16.4; check "major version refused -> 2" "[[ $RC == 2 ]]"
mkdir -p "$T/lk"; (sleep 30 & echo $! >"$T/lk/pid.tmp"); LP="$(cat "$T/lk/pid.tmp")"
mkdir -p "$T/lk/prod_us-east-1_orders-prod.lock"; echo "$LP" >"$T/lk/prod_us-east-1_orders-prod.lock/pid"
N=$(( N + 1 )); mkdir -p "$T/case$N"; MOCK_SCENARIO=ok MOCK_STATE="$T/case$N/s.json" MOCK_CALLS="$T/case$N/c" RDS_PR_LOCK_DIR="$T/lk" \
    "$RUNNER" -P prod -r us-east-1 -c orders-prod "${EX[@]}" -o "$T/case$N/o" </dev/null >"$T/case$N/out" 2>&1; R=$?
check "lock held by live pid -> 2" "[[ $R == 2 ]] && grep -q 'Another run' '$T/case$N/out'"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
MOCK_SCENARIO=nothing MOCK_STATE="$T/case$N/s2.json" MOCK_CALLS="$T/case$N/c2" RDS_PR_LOCK_DIR="$T/lk" \
    "$RUNNER" -P prod -r us-east-1 -c orders-prod "${EX[@]}" -o "$T/case$N/o" </dev/null >"$T/case$N/out2" 2>&1; R=$?
check "stale lock removed and run continues" "[[ $R == 0 ]] && grep -q 'Removing stale lock' '$T/case$N/out2'"
check "lock released at exit" "[[ ! -e '$T/lk/prod_us-east-1_orders-prod.lock' ]]"

echo "== nothing to do"
run nothing "${EX[@]}" --minor-upgrade none; check "nothing pending -> 0 'nothing to do'" "[[ $RC == 0 ]] && has 'nothing to do' && [[ \$(writes) == 0 ]]"
run ok --action hardware-maintenance --minor-upgrade none; check "only unselected actions -> nothing to do" "[[ $RC == 0 ]] && has 'nothing to do'"
run nothing --minor-upgrade latest; check "minor latest gives a plan when nothing pending" "has 'modify-db-cluster --engine-version 15.10'"

echo "== confirmation"
run ok --execute --poll-sec 0; check "no TTY and no --yes -> 4, no writes" "[[ $RC == 4 ]] && [[ \$(writes) == 0 ]]"
if command -v script >/dev/null; then
    N=$(( N + 1 )); d="$T/case$N"; mkdir -p "$d"
    printf 'n\n' | MOCK_SCENARIO=ok MOCK_STATE="$d/s.json" MOCK_CALLS="$d/c" RDS_PR_LOCK_DIR="$d/l" \
        script -qec "'$RUNNER' -P prod -r us-east-1 -c orders-prod --execute --poll-sec 0 -o '$d/o'" /dev/null >"$d/out" 2>&1; R=$?
    check "answer 'n' at the prompt -> 4" "[[ $R == 4 ]] && grep -q 'Patch orders-prod' '$d/out' && [[ \$(jq -r '.[]' '$d/c' | grep -c apply-pending) == 0 ]]"
    N=$(( N + 1 )); d="$T/case$N"; mkdir -p "$d"
    printf 'y\n' | MOCK_SCENARIO=nothing MOCK_STATE="$d/s.json" MOCK_CALLS="$d/c" RDS_PR_LOCK_DIR="$d/l" \
        script -qec "'$RUNNER' -P prod -r us-east-1 -c orders-prod --execute --poll-sec 0 --minor-upgrade latest -o '$d/o'" /dev/null >"$d/out" 2>&1; R=$?
    check "answer 'y' at the prompt -> runs (0)" "[[ $R == 0 ]] && grep -q 'Done: orders-prod patched' '$d/out'"
fi

echo "== execute: happy path"
run ok "${EX[@]}" --html
check "exit 0" "[[ $RC == 0 ]]" "$(tail -5 "$OUT")"
check "apply order: reader (system-update, os-upgrade) -> reader -> cluster -> writer" "applies_are 'orders-prod-2/system-update orders-prod-2/os-upgrade orders-prod-3/system-update orders-prod/db-upgrade orders-prod-1/system-update'"
check "minor upgrade is the very last write, after verify" "[[ \$(jq -r '.[]' '$CALLS' | grep -E '^(create-db-cluster-snapshot|apply-pending-maintenance-action|modify-db-cluster)$' | tail -1) == modify-db-cluster ]] && [[ \$(jq -r '.steps[-1].kind + \"/\" + .steps[-2].kind' '$ODIR'/orders-prod_*.json) == minor-upgrade/verify ]]"
check "db-upgrade moved 15.4 -> 15.5, minor then 15.5 -> 15.10" "jq -e '.steps[] | select(.actions == \"db-upgrade\") | .version_after == \"15.5\"' '$ODIR'/orders-prod_*.json >/dev/null && jq -e '.minor_result.from == \"15.5\" and .minor_result.version_after == \"15.10\" and .minor_result.result == \"ok\"' '$ODIR'/orders-prod_*.json >/dev/null"
check "summary has before info + minor result" "grep -q 'latest minor           : 15.10' '$ODIR'/orders-prod_*.summary.txt && grep -q 'MINOR UPGRADE (last step): ok - 15.5 -> 15.10' '$ODIR'/orders-prod_*.summary.txt && grep -q 'Minor version (before)' '$ODIR'/orders-prod_*.summary.html"
check "snapshot created before the first apply" "jq -r '.[]' '$CALLS' | grep -E '^(create-db-cluster-snapshot|apply-pending-maintenance-action)$' | head -1 | grep -qx create-db-cluster-snapshot"
check "snapshot name format" "jq -r 'select(index(\"create-db-cluster-snapshot\")) | .[index(\"--db-cluster-snapshot-identifier\")+1]' '$CALLS' | grep -Eqx 'pre-maint-orders-prod-[0-9]{8}-[0-9]{4}'"
check "waiter used" "jq -r '.[]' '$CALLS' | grep -qx db-cluster-snapshot-available"
check "every apply is --opt-in-type immediate" "[[ \$(jq -r 'select(index(\"apply-pending-maintenance-action\")) | .[index(\"--opt-in-type\")+1]' '$CALLS' | sort -u) == immediate ]]"
check "every call has --region and --profile" "[[ \$(jq -r 'select(index(\"--version\") == null) | select((index(\"--region\") == null) or (index(\"--profile\") == null)) | 1' '$CALLS' | wc -l) == 0 ]]"
check "summary files written" "ls '$ODIR'/orders-prod_*.summary.txt '$ODIR'/orders-prod_*.summary.csv '$ODIR'/orders-prod_*.summary.html '$ODIR'/orders-prod_*.json '$ODIR'/orders-prod_*.log >/dev/null"
check "summary: 8 steps all ok" "[[ \$(jq '[.steps[] | select(.result == \"ok\")] | length' '$ODIR'/orders-prod_*.json) == 8 ]]"
check "CSV header + 8 rows" "[[ \$(wc -l <'$ODIR'/orders-prod_*.summary.csv) == 9 ]] && head -1 '$ODIR'/orders-prod_*.summary.csv | grep -q '\"step\",\"kind\",\"target\"'"
check "log file has timestamps + steps" "grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} \\[INFO\\] === step 6: writer' '$ODIR'/orders-prod_*.log"
check "HTML escapes and renders" "grep -q '<h1>RDS patch runner: orders-prod' '$ODIR'/orders-prod_*.summary.html"
check "lock released" "[[ -z \$(ls -A '$T/case$N/locks' 2>/dev/null) ]]"

echo "== failover during the writer patch"
run failover "${EX[@]}"
check "exit 0" "[[ $RC == 0 ]]" "$(tail -5 "$OUT")"
check "failover logged" "has 'FAILOVER: writer changed orders-prod-1 -> orders-prod-2'"
check "failover recorded in summary" "jq -e '.failovers[0].to == \"orders-prod-2\"' '$ODIR'/orders-prod_*.json >/dev/null"
check "writer was still patched last" "[[ \$(applies | awk '{print \$NF}') == orders-prod-1/system-update ]]"

echo "== failover before the writer step (current writer last)"
run earlyfailover "${EX[@]}"
check "exit 0" "[[ $RC == 0 ]]" "$(tail -5 "$OUT")"
check "failover 1 -> 3 logged" "has 'FAILOVER: writer changed orders-prod-1 -> orders-prod-3'"
check "old writer patched as reader, new writer (3) last" "applies_are 'orders-prod-2/system-update orders-prod-1/system-update orders-prod/db-upgrade orders-prod-3/system-update'"
check "warns that the writer moved" "has 'writer is now orders-prod-3'"

echo "== reader API error stops before the writer"
run readererror "${EX[@]}"
check "exit 3" "[[ $RC == 3 ]]"
check "writer never touched" "! applies | grep -q 'orders-prod-1/' && ! applies | grep -q 'orders-prod/db-upgrade'" "got: $(applies)"
check "summary marks failure + not patched list" "has 'later steps were NOT run' && has 'not patched: orders-prod-2 orders-prod-3 orders-prod-1'"
check "failure summary lists what is still pending" "grep -q 'orders-prod-1: system-update' '$ODIR'/orders-prod_*.summary.txt"
check "plan is in the log file" "grep -q '^PLAN (exact execution order' '$ODIR'/orders-prod_*.log"
check "reader failure: no minor upgrade" "! jq -r '.[]' '$CALLS' | grep -qx modify-db-cluster"
check "summary json result failed" "jq -e '.meta.result == \"failed\" and .meta.exit_code == 3' '$ODIR'/orders-prod_*.json >/dev/null"

echo "== reader goes to 'failed' status"
run readerfailed "${EX[@]}"
check "exit 3 and writer untouched" "[[ $RC == 3 ]] && ! applies | grep -q 'orders-prod-1/'"
check "detail names the status" "has \"status 'failed'\""

echo "== timeout"
run timeout --execute --yes --poll-sec 0.2 --timeout-min 0.02
check "exit 3" "[[ $RC == 3 ]]"
check "TIMEOUT in detail, writer untouched" "has 'TIMEOUT after' && ! applies | grep -q 'orders-prod-1/'"
check "summary row result timeout" "jq -e '[.steps[] | select(.result == \"timeout\")] | length == 1' '$ODIR'/orders-prod_*.json >/dev/null"

echo "== quick / deferred actions"
run quick "${EX[@]}"
check "quick: exit 0, 'quick action' noted" "[[ $RC == 0 ]] && has 'without a visible status change (quick action)'"
run deferred --execute --yes --poll-sec 0.2 --grace-sec 1
check "deferred: exit 3 'not started by AWS' after grace" "[[ $RC == 3 ]] && has 'not started by AWS within 1s'"
check "deferred: writer untouched" "! applies | grep -q 'orders-prod-1/'"

echo "== minor upgrade"
run minor "${EX[@]}" --minor-upgrade latest
check "exit 0" "[[ $RC == 0 ]]" "$(tail -5 "$OUT")"
check "modify-db-cluster --engine-version 15.10 --apply-immediately after the snapshot" "jq -r '.[]' '$CALLS' | grep -E '^(create-db-cluster-snapshot|modify-db-cluster)$' | paste -sd, | grep -qx 'create-db-cluster-snapshot,modify-db-cluster' && jq -e 'select(index(\"modify-db-cluster\")) | (.[index(\"--engine-version\")+1] == \"15.10\") and (index(\"--apply-immediately\") != null)' '$CALLS' >/dev/null"
check "versions before -> after in summary" "grep -q 'orders-prod-1 *15.4 -> 15.10' '$ODIR'/orders-prod_*.summary.txt"
run minor "${EX[@]}" --minor-upgrade 15.6
check "explicit minor version" "[[ $RC == 0 ]] && grep -q '15.4 -> 15.6' '$ODIR'/orders-prod_*.summary.txt"
run minor --minor-upgrade 15.4
check "same version -> nothing to do" "[[ $RC == 0 ]] && has 'already on that version' && has 'nothing to do'"

run minor "${EX[@]}" --minor-upgrade none
check "--minor-upgrade none with nothing pending -> nothing to do" "[[ $RC == 0 ]] && has 'nothing to do' && [[ \$(writes) == 0 ]]"
run ok "${EX[@]}" --minor-upgrade none
check "--minor-upgrade none: pass runs, no modify-db-cluster" "[[ $RC == 0 ]] && [[ \$(applies | wc -w) == 5 ]] && ! jq -r '.[]' '$CALLS' | grep -qx modify-db-cluster && has 'no upgrade step (--minor-upgrade none)'"
run ok --minor-upgrade 16.4; check "major target (dry run) refused -> 2" "[[ $RC == 2 ]] && has 'not a valid minor (non-major)'"
run minorfail "${EX[@]}"
check "modify-db-cluster rejected -> 3, result failed" "[[ $RC == 3 ]] && has 'Minor upgrade failed' && jq -e '.minor_result.result == \"failed\"' '$ODIR'/orders-prod_*.json >/dev/null"

echo "== one rolling pass: order of action types"
run ordered
check "dry run plan in exact order" "[[ \$(plan_targets) == 'orders-prod-2/system-update orders-prod-2/os-upgrade orders-prod-2/ca-certificate-rotation orders-prod-3/system-update orders-prod-3/os-upgrade orders-prod/system-update orders-prod/db-upgrade orders-prod-1/system-update orders-prod-1/os-upgrade orders-prod-1/future-action' ]]" "got: $(plan_targets)"
check "unknown action typed as DB update (other)" "grep -qE 'future-action +DB update \(other type\)' '$OUT'"
run ordered "${EX[@]}"
check "exit 0" "[[ $RC == 0 ]]" "$(tail -5 "$OUT")"
check "execute order matches the plan" "applies_are 'orders-prod-2/system-update orders-prod-2/os-upgrade orders-prod-2/ca-certificate-rotation orders-prod-3/system-update orders-prod-3/os-upgrade orders-prod/system-update orders-prod/db-upgrade orders-prod-1/system-update orders-prod-1/os-upgrade orders-prod-1/future-action'"
check "one step per action (13 steps: snapshot, 10 applies, verify, minor)" "[[ \$(jq '.steps | length' '$ODIR'/orders-prod_*.json) == 13 ]]"
check "every reader action before any cluster action before any writer action" "applies | tr ' ' '\\n' | cut -d/ -f1 | uniq | paste -sd, | grep -qx 'orders-prod-2,orders-prod-3,orders-prod,orders-prod-1'"
check "minor upgrade after the last apply" "[[ \$(jq -r '.[]' '$CALLS' | grep -E '^(apply-pending-maintenance-action|modify-db-cluster)$' | tail -1) == modify-db-cluster ]]"

echo "== minor recompute / up to date"
run dbtolatest "${EX[@]}"
check "db-upgrade reached latest -> minor skipped 'already at latest', no modify" "[[ $RC == 0 ]] && has 'already at latest minor version 15.10' && ! jq -r '.[]' '$CALLS' | grep -qx modify-db-cluster && jq -e '.minor_result.result == \"skipped\"' '$ODIR'/orders-prod_*.json >/dev/null"
run uptodate
check "up to date: preflight says so, no minor step" "[[ $RC == 0 ]] && has 'already on the latest minor' && has 'available minors       : none' && nohas 'minor upg  :'"
run uptodate "${EX[@]}"
check "up to date execute: pass only" "[[ $RC == 0 ]] && ! jq -r '.[]' '$CALLS' | grep -qx modify-db-cluster"

echo "== failures in the rolling pass -> no minor upgrade"
run writerfailed "${EX[@]}"
check "writer failure -> 3, no minor upgrade" "[[ $RC == 3 ]] && ! jq -r '.[]' '$CALLS' | grep -qx modify-db-cluster"
run newpending "${EX[@]}"
check "verify fails (new action appeared) -> 3, no minor upgrade" "[[ $RC == 3 ]] && has 'the minor upgrade was NOT run' && ! jq -r '.[]' '$CALLS' | grep -qx modify-db-cluster"
run timeout --execute --yes --poll-sec 0.2 --timeout-min 0.02
check "timeout on a reader -> no minor upgrade, writer untouched" "[[ $RC == 3 ]] && ! jq -r '.[]' '$CALLS' | grep -qx modify-db-cluster && ! applies | grep -q 'orders-prod-1/'"

echo "== snapshot paths"
run waitgiveup "${EX[@]}"
check "waiter gives up -> polling -> ok" "[[ $RC == 0 ]] && has 'waiter ended rc=255' && [[ \$(jq -r '.[]' '$CALLS' | grep -c describe-db-cluster-snapshots) -ge 3 ]]"
run snapfail "${EX[@]}"
check "snapshot failure -> 3, nothing applied" "[[ $RC == 3 ]] && [[ -z \$(applies) ]] && has 'SnapshotQuotaExceeded'"
run ok "${EX[@]}" --skip-snapshot
check "--skip-snapshot: no snapshot call, warning" "[[ $RC == 0 ]] && ! jq -r '.[]' '$CALLS' | grep -q create-db-cluster-snapshot && has 'NO pre-maintenance snapshot'"

echo "== other engines"
run docdb "${EX[@]}"
check "docdb: exit 0, apply via docdb CLI" "[[ $RC == 0 ]] && [[ \$(jq -r 'select(index(\"apply-pending-maintenance-action\")) | .[index(\"apply-pending-maintenance-action\")-1]' '$CALLS' | sort -u) == docdb ]]"
check "docdb: snapshot via docdb, waiter via rds" "jq -e 'select(index(\"create-db-cluster-snapshot\")) | .[index(\"create-db-cluster-snapshot\")-1] == \"docdb\"' '$CALLS' >/dev/null && jq -e 'select(index(\"wait\")) | .[index(\"wait\")-1] == \"rds\"' '$CALLS' >/dev/null"
run neptune "${EX[@]}"
check "neptune: exit 0, apply via neptune CLI" "[[ $RC == 0 ]] && [[ \$(jq -r 'select(index(\"apply-pending-maintenance-action\")) | .[index(\"apply-pending-maintenance-action\")-1]' '$CALLS' | sort -u) == neptune ]]"
run clusteronly "${EX[@]}"
check "cluster-only action: one cluster apply" "[[ $RC == 0 ]] && applies_are orders-prod/db-upgrade"

echo "== --action filter on execute"
run ok "${EX[@]}" --action system-update
check "only system-update applied" "[[ $RC == 0 ]] && [[ \$(applies | tr ' ' '\\n' | cut -d/ -f2 | sort -u) == system-update ]]"
check "unselected actions listed as left" "grep -q 'orders-prod: db-upgrade' '$ODIR'/orders-prod_*.summary.txt && grep -q 'orders-prod-2: os-upgrade' '$ODIR'/orders-prod_*.summary.txt"

echo "== Ctrl-C"
N=$(( N + 1 )); d="$T/case$N"; mkdir -p "$d"
# background jobs of a non-interactive shell start with SIGINT ignored; restore the default so the runner's
# INT trap is armed exactly as when a user presses Ctrl-C in a terminal
MOCK_SCENARIO=timeout MOCK_STATE="$d/s.json" MOCK_CALLS="$d/c" RDS_PR_LOCK_DIR="$d/l" \
    python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' "$RUNNER" -P prod -r us-east-1 -c orders-prod --execute --yes --poll-sec 0.2 --timeout-min 5 -o "$d/o" </dev/null >"$d/out" 2>&1 &
P=$!
for _ in $(seq 1 100); do grep -q 'orders-prod-2: status upgrading' "$d/out" 2>/dev/null && break; sleep 0.1; done
kill -INT "$P"; wait "$P"; R=$?
check "SIGINT -> 130" "[[ $R == 130 ]]" "rc=$R"
check "reports in-flight action" "grep -q 'STILL RUNNING IN AWS (not cancelled): system-update on orders-prod-2' '$d/out'"
check "reports not started list" "grep -q 'not started: orders-prod-2 orders-prod-3 orders-prod-1' '$d/out'"
check "summary written as interrupted" "jq -e '.meta.result == \"interrupted\" and (.steps[-1].result == \"interrupted\")' '$d'/o/orders-prod_*.json >/dev/null"
check "lock released after SIGINT" "[[ -z \$(ls -A '$d/l' 2>/dev/null) ]]"

echo "== SIGTERM"
N=$(( N + 1 )); d="$T/case$N"; mkdir -p "$d"
MOCK_SCENARIO=timeout MOCK_STATE="$d/s.json" MOCK_CALLS="$d/c" RDS_PR_LOCK_DIR="$d/l" \
    "$RUNNER" -P prod -r us-east-1 -c orders-prod --execute --yes --poll-sec 0.2 --timeout-min 5 -o "$d/o" </dev/null >"$d/out" 2>&1 &
P=$!
for _ in $(seq 1 100); do grep -q 'orders-prod-2: status upgrading' "$d/out" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$P"; wait "$P"; R=$?
check "SIGTERM -> 130 + interrupted summary" "[[ $R == 130 ]] && jq -e '.meta.result == \"interrupted\"' '$d'/o/orders-prod_*.json >/dev/null"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
