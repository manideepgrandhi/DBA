#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # ok && ok || bad is fine; single-quoted mongo/js literals are intended
# Integration tests against the LOCAL throwaway test bed from tests/setup_local.sh (never a real server):
#   rs0 on BASE+1..3 (BASE+3 hidden, 120 s delayed), auth standalone on BASE+10, nothing on BASE+99.
# Usage: tests/setup_local.sh && tests/run_tests.sh [-k]
#   -k keeps the output dir. Optional: MHR_TEST_SSH_PORT / MHR_TEST_SSH_KEY to also test df over SSH against
#   127.0.0.1 (needs an sshd there that accepts that key). The member-down test stops and restarts BASE+2.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../mongo_health_report.sh"
BASE="${MHR_TEST_BASE:-28000}"; DIR="${MHR_TEST_DIR:-/tmp/mhr_testbed}"
P1=$((BASE + 1)); P2=$((BASE + 2)); P3=$((BASE + 3)); PS=$((BASE + 10)); PD=$((BASE + 99))
OUT="$(mktemp -d /tmp/mhr_tests.XXXXXX)"; KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1; export KEEP
trap '(( KEEP )) && echo "kept $OUT" || rm -rf -- "$OUT"' EXIT
export MON_PW="${MHR_TEST_PW:-Mon p@ss:/word}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
t()   { local n="$1" e="$2"; shift 2; "$SCRIPT" "$@" >"$OUT/$n.out" 2>"$OUT/$n.err"; local rc=$?
        [[ $rc == "$e" ]] && ok "$n rc=$rc" || { bad "$n rc=$rc expected $e"; tail -3 "$OUT/$n.err"; }; }
has()   { grep -qE -- "$3" "$OUT/$1.$2" && ok "$1 $2 has /$3/" || bad "$1 $2 lacks /$3/"; }
hasnt() { ! grep -qE -- "$3" "$OUT/$1.$2" && ok "$1 $2 has no /$3/" || bad "$1 $2 unexpectedly has /$3/"; }
jqt()   { jq -e "$2" "$OUT/$1"/*.json >/dev/null 2>&1 && ok "$1 json: $2" || bad "$1 json: $2"; }
cat >"$OUT/servers.conf" <<CONF
# test bed
rs0-local   127.0.0.1:$P1,127.0.0.1:$P2   rs=rs0
sa-auth     mongodb://127.0.0.1:$PS/      user=mon pass_env=MON_PW    # trailing comment
dead        127.0.0.1:$PD
CONF

echo "== static"
if command -v shellcheck >/dev/null; then
    shellcheck "$SCRIPT" "$HERE/run_tests.sh" "$HERE/setup_local.sh" && ok shellcheck || bad shellcheck
else echo "  skip shellcheck (not installed)"; fi
jq -n --arg mode json --slurpfile S /dev/null --slurpfile cfg /dev/null -f "$HERE/../lib/report.jq" >/dev/null 2>&1; [[ $? -ne 3 ]] && ok "report.jq compiles" || bad "report.jq compiles"
! grep -nE '\.(insert(One|Many)?|update(One|Many)?|replaceOne|delete(One|Many)?|remove|drop(Database|Index(es)?)?|createIndex(es)?|createCollection|createUser|grantRolesToUser|shutdownServer|fsyncLock|killOp|compact|reconfig|stepDown|add|freeze)\(|(cmd\([^,]+, *|[Cc]ommand\()\{ *(insert|update|delete|findAndModify|drop|dropDatabase|create|createIndexes|createUser|killOp|killSessions|shutdown|replSetStepDown|replSetReconfig|replSetFreeze|setParameter|compact|fsync|logRotate|setFeatureCompatibilityVersion) *:' "$HERE/../lib/collect.js" \
    && ok "collect.js has no write/admin-change commands" || bad "collect.js write command"

echo "== usage / validation"
t help 0 --help; has help out 'pass_env'; t ver 0 -V
t noargs 1
printf 'x 127.0.0.1:1 foo=bar\n' >"$OUT/bad1.conf"; t badkey 1 -s "$OUT/bad1.conf"; has badkey err "unknown key 'foo'"
printf 'x 127.0.0.1:1\nx 127.0.0.1:2\n' >"$OUT/bad2.conf"; t dup 1 -s "$OUT/bad2.conf"; has dup err duplicate
printf 'x h;rm:1\n' >"$OUT/bad3.conf"; t badhost 1 -s "$OUT/bad3.conf"
printf 'x $(id)\n' >"$OUT/bad4.conf"; t badsub 1 -s "$OUT/bad4.conf"
printf 'x 127.0.0.1:1 ssh_port=2x\n' >"$OUT/bad5.conf"; t badport 1 -s "$OUT/bad5.conf"
t badonly 1 -s "$OUT/servers.conf" --only nope
t dry 0 -s "$OUT/servers.conf" --dry-run --only rs0-local,sa-auth; has dry out 'Targets \(2 of 3\)'; has dry out 'No connections'
t uripw 0 -n u -u "mongodb://mon:secret@127.0.0.1:$PS/" --dry-run; has uripw err 'password inside the URI'; hasnt uripw out secret

echo "== healthy run (rs + auth standalone + unreachable)"
t multi 0 -s "$OUT/servers.conf" -o "$OUT/multi" --csv --json
has multi out 'CRIT +rs0-local|WARN +rs0-local|OK +rs0-local'; has multi out 'sa-auth +standalone'; has multi out 'CRIT +dead'
has multi out 'UNREACHABLE +dead'; has multi out 'STANDALONE +sa-auth'; has multi out 'members=3/3'
hasnt multi out 'REPL_LAG'; has multi out 'UTC · .* IST'
jqt multi '.servers | length == 3'
jqt multi '.servers[0].data.repl.members | length == 3'
jqt multi '[.servers[0].data.repl.members[] | select(.hidden and .delay_s == 120)] | length == 1'
jqt multi '.servers[0].data.oplog.window_h > 0'
jqt multi '.servers[0].data.members_direct | map(select(.ok)) | length == 3'
jqt multi '.servers[1].data.fs.pct > 0 and .servers[1].data.repl == null'
jqt multi '.servers[1].data.dbs | map(.name) | index("sales") != null'
jqt multi '.servers[0].data.top_colls[0].ns == "app.events"'
ls "$OUT/multi"/*_summary.csv "$OUT/multi"/*_flags.csv "$OUT/multi"/*.html >/dev/null 2>&1 && ok "csv + html written" || bad "csv + html written"
[[ "$(head -1 "$OUT"/multi/*_summary.csv)" == server,target,status,* ]] && ok "summary csv header" || bad "summary csv header"
h="$(ls "$OUT"/multi/*.html)"
grep -q '<h2>Summary</h2>\|Summary</h2>' "$h" && grep -q 'Replica set rs0' "$h" && grep -q 'Disk free' "$h" && ok "html sections" || bad "html sections"
! grep -qE 'https?://[^"]*\.(js|css)' "$h" && ok "html self-contained" || bad "html references external assets"
grep -rqF -e "$MON_PW" -e 'p%40ss' "$OUT/multi" "$OUT/multi.out" "$OUT/multi.err" && bad "password leaked" || ok "password not in outputs"

echo "== thresholds / fail-on / filters"
t lowdisk 0 -s "$OUT/servers.conf" --only sa-auth -o "$OUT/lowdisk" --disk-warn 1 --disk-crit 99; has lowdisk out 'WARN\] DISK_DATA_FS +sa-auth'
t failon 5 -s "$OUT/servers.conf" -o "$OUT/failon" --fail-on crit
t failwarn 5 -s "$OUT/servers.conf" --only sa-auth -o "$OUT/fw" --disk-warn 1 --fail-on warn
t onlysa 0 -s "$OUT/servers.conf" --only sa-auth -o "$OUT/onlysa"; hasnt onlysa out 'rs0-local'
t deadonly 3 -s "$OUT/servers.conf" --only dead -o "$OUT/dead"
MON_PW=wrong t badpw 3 -s "$OUT/servers.conf" --only sa-auth -o "$OUT/badpw"; has badpw out 'AuthenticationFailed'
env -u MON_PW "$SCRIPT" -s "$OUT/servers.conf" --only sa-auth -o "$OUT/nopw" >"$OUT/nopw.out" 2>&1; has nopw out 'MON_PW is empty or not set'
printf '%s\n' "$MON_PW" >"$OUT/pw"; chmod 644 "$OUT/pw"
t pwfile 0 -n sa -u "127.0.0.1:$PS" --set user=mon --set pass_file="$OUT/pw" -o "$OUT/pwfile"; has pwfile err 'readable by group/others'; has pwfile out 'OK +sa'

echo "== long-running op"
mongosh --quiet --port "$P1" --eval 'db.getSiblingDB("logs").l.find({$where: "sleep(1) || true"}).batchSize(20000).itcount()' >/dev/null 2>&1 &
sleep 6
t longop 0 -s "$OUT/servers.conf" --only rs0-local -o "$OUT/longop" --long-op 3; has longop out 'LONG_RUNNING_OPS +rs0-local'
wait

echo "== member down, then no primary (hidden survivor)"
mongosh --quiet --port "$P2" --eval 'db.adminCommand({shutdown:1, force:true})' >/dev/null 2>&1; sleep 4
t down 0 -s "$OUT/servers.conf" --only rs0-local -o "$OUT/down"; has down out "MEMBER_DOWN +rs0-local +127.0.0.1:$P2"; has down out 'members=2/3'
mongosh --quiet --port "$P1" --eval 'db.adminCommand({shutdown:1, force:true})' >/dev/null 2>&1; sleep 12
t noprim 0 -n rs0 -u "127.0.0.1:$P1,127.0.0.1:$P3" --set rs=rs0 -o "$OUT/noprim" --timeout 5
has noprim out 'NO_PRIMARY'; has noprim out 'RS_DISCOVERY_FAILED'; has noprim out 'NO_MAJORITY'
"$HERE/setup_local.sh" >/dev/null 2>&1; sleep 10
t back 0 -s "$OUT/servers.conf" --only rs0-local -o "$OUT/back"; has back out 'members=3/3'

if [[ -n "${MHR_TEST_SSH_PORT:-}" ]]; then
    echo "== df over ssh (127.0.0.1:$MHR_TEST_SSH_PORT)"
    printf 'rs0-ssh 127.0.0.1:%s,127.0.0.1:%s rs=rs0 ssh=auto ssh_port=%s %s\n' "$P1" "$P2" "$MHR_TEST_SSH_PORT" "${MHR_TEST_SSH_KEY:+ssh_key=$MHR_TEST_SSH_KEY}" >"$OUT/ssh.conf"
    t ssh 0 -s "$OUT/ssh.conf" -o "$OUT/ssh" --json --ssh-accept-new --disk-warn 1
    has ssh out "DISK_MOUNT +rs0-ssh +127.0.0.1:$P3 "; jqt ssh "[.servers[0].ssh[] | select(.ok)] | length == 3"
    jqt ssh "[.servers[0].ssh[].paths[] | select(.kind == \"dbPath\" and .path == \"$DIR/rs2\")] | length == 1"
    printf 'x 127.0.0.1:%s ssh=127.0.0.1 ssh_port=1\n' "$P1" >"$OUT/ssh2.conf"
    t sshfail 0 -s "$OUT/ssh2.conf" -o "$OUT/ssh2"; has sshfail out 'SSH_DF_FAILED'
else echo "== df over ssh: skipped (set MHR_TEST_SSH_PORT)"; fi

echo
echo "passed $PASS, failed $FAIL"
(( FAIL == 0 ))
