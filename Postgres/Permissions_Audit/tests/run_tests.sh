#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2034  # ok && ok || bad is fine; literal $(id) on purpose; KEEP used in trap
# Integration tests against LOCAL PostgreSQL clusters only (never Aurora):
#   port 5432 with tests/fixture.sql loaded, port 5433 with tests/fixture2.sql, nothing on 5499 (unreachable server).
# Setup (Debian/Ubuntu):  sudo -u postgres psql -X -f tests/fixture.sql ; sudo -u postgres psql -p 5433 -X -f tests/fixture2.sql
# Usage: tests/run_tests.sh [-k]      NODE_PATH with puppeteer-core enables the headless HTML check.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/../pg_permissions_audit.sh"
OUT="$(mktemp -d /tmp/pgaudit_tests.XXXXXX)"; KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
trap '(( KEEP )) && echo "kept $OUT" || rm -rf -- "$OUT"' EXIT
export PGPASSWORD=test-only-audit PG_AUDIT_NOW=1792585800 PATH="$HERE/mock:$PATH" MOCK_LOG="$OUT/aws.log"
unset PGHOST PGPORT PGUSER PGDATABASE PGSERVICE
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
t()   { local n="$1" e="$2"; shift 2; "$SCRIPT" "$@" >"$OUT/$n.out" 2>"$OUT/$n.err"; local rc=$?
        [[ $rc == "$e" ]] && ok "$n rc=$rc" || { bad "$n rc=$rc expected $e"; tail -3 "$OUT/$n.err"; }; }
has() { grep -qE -- "$3" "$OUT/$1.$2" && ok "$1 $2 has /$3/" || bad "$1 $2 lacks /$3/"; }
hasnt() { ! grep -qE -- "$3" "$OUT/$1.$2" && ok "$1 $2 has no /$3/" || bad "$1 $2 unexpectedly has /$3/"; }
jqt() { jq -e "$2" "$OUT/$1.out" >/dev/null 2>&1 && ok "$1 json: $2" || bad "$1 json: $2"; }
cat >"$OUT/servers.conf" <<CONF
# test
local-main   127.0.0.1 5432 audit_user all disable
local-second 127.0.0.1 5433 audit_user billing,missingdb sslmode=disable auth=password   # trailing comment
dead-server  127.0.0.1 5499 audit_user all disable
CONF

echo "== static"
shellcheck "$SCRIPT" "$HERE/run_tests.sh" "$HERE/mock/aws" && ok shellcheck || bad shellcheck
jq -n --arg mode json --slurpfile S /dev/null --slurpfile cfg /dev/null -f "$HERE/../lib/audit.jq" >/dev/null 2>&1; [[ $? -ne 3 ]] && ok "jq compiles" || bad "jq compiles"
! grep -niE '^\s*(insert|update|delete|create|alter|drop|grant|revoke|truncate|copy|do)\b' "$HERE/../lib/audit.sql" && ok "audit.sql has no write statements" || bad "audit.sql write statement"
grep -q 'default_transaction_read_only=on' "$SCRIPT" && ok "sessions forced read-only" || bad "read-only session"

echo "== usage / validation"
t help 0 --help; has help out 'auth=password\|iam' ; t ver 0 -V
t noargs 1; t both 1 -s "$OUT/servers.conf" -h x -U y; t badfmt 1 -h x -U y -F xml; t multinodir 1 -h x -U y -F text,html
printf 'a 127.0.0.1 54x u all\n' >"$OUT/bad1.conf"; t badport 1 -s "$OUT/bad1.conf"; has badport err 'bad port'
printf 'a h 5432 u all disable\na h 5432 u all\n' >"$OUT/bad2.conf"; t dup 1 -s "$OUT/bad2.conf"; has dup err duplicate
printf 'a h 5432 u all bogus=1\n' >"$OUT/bad3.conf"; t badopt 1 -s "$OUT/bad3.conf"
printf 'a h;rm 5432 u all\n' >"$OUT/bad4.conf"; t badhost 1 -s "$OUT/bad4.conf"
printf 'a h 5432 u "$(id)"\n' >"$OUT/bad5.conf"; t baddbs 1 -s "$OUT/bad5.conf"
t dry 0 -s "$OUT/servers.conf" --dry-run; has dry out 'local-second .*sslmode=disable auth=password'; has dry out 'No connections'

echo "== multi-server text"
t multi 0 -s "$OUT/servers.conf"
has multi out 'local-main +ok +17'; has multi out 'local-second +partial'; has multi out 'dead-server +error'
has multi out 'DB_ERROR'; has multi out 'missingdb'; has multi out 'SERVER_ERROR'
for f in PUBLIC_CREATE_PUBLIC_SCHEMA PUBLIC_OBJECT_PRIV PUBLIC_EXEC_SECDEF DIRECT_GRANT_TO_LOGIN GRANT_OPTION OWNED_BY_LOGIN_USER \
         UNUSED_GROUP_ROLE RDS_SUPERUSER_MEMBER PASSWORD_EXPIRED PASSWORD_NO_EXPIRY; do has multi out "\\] $f \\("; done
has multi out 'for role app_owner in schema sales on tables: app_reader: SELECT; app_writer: DELETE,INSERT,UPDATE; bob: SELECT'
has multi out 'table +orders .*bob: SELECT\*'; has multi out 'column +orders.card .*svc_etl: UPDATE'
has multi out 'foreign table +ft_remote'; has multi out 'user mappings: app_owner, PUBLIC'; has multi out 'procedure +p_purge\(\)'
has multi out 'schema "Odd Name"'; has multi out 'we\|ird,tab"le'; has multi out 'alice -> app_user -> app_writer -> app_reader'
has multi out 'svc_etl .*SET ROLE only=\[app_reader,app_writer\]'; has multi out '2026-10-21 12:30 UTC / 2026-10-21 18:00 IST'
hasnt multi out 'pg_catalog'; hasnt multi out 'fixture-only'; hasnt multi out 'postgres_fdw_handler'
has multi err 'connection refused|Connection refused'

echo "== filters / per-role"
t role 0 -s "$OUT/servers.conf" --role svc_etl
has role out 'EFFECTIVE ACCESS for role svc_etl on local-main +\(via: svc_etl, PUBLIC\)'; has role out 'column sales.orders.card: UPDATE via svc_etl'
hasnt role out 'app_reader: SELECT'; has role out 'not on local-second: svc_etl'
t role2 0 -s "$OUT/servers.conf" --role alice; has role2 out 'table sales.orders: SELECT via app_reader, DELETE,INSERT,UPDATE via app_writer'
has role2 out 'schema hr \(OWNER\)'
t schema 0 -h 127.0.0.1 -U audit_user -d appdb --sslmode disable --schema 'sal*'; has schema out 'schema sales'; hasnt schema out 'schema hr'
t dbf 0 -s "$OUT/servers.conf" --db 'sales*,bill*'; has dbf out 'DATABASE salesdb'; hasnt dbf out 'DATABASE appdb'; has dbf out 'DATABASE billing'
t sys 0 -h 127.0.0.1 -U audit_user -d salesdb --sslmode disable --include-system; has sys out 'schema pg_catalog'
t owner 0 -h 127.0.0.1 -U audit_user -d salesdb --sslmode disable --show-owner-grants; has owner out 'accounts .*postgres: '
t onlydead 3 -h 127.0.0.1 -p 5499 -U audit_user --sslmode disable
t iam 3 -h 127.0.0.1 -U audit_user -d appdb,salesdb --sslmode disable --iam --region us-east-1   # mock token is sent as the password -> local auth rejects it
has iam err 'password authentication failed'   # proves the token (not PGPASSWORD) was used
grep -q 'generate-db-auth-token --hostname 127.0.0.1 --port 5432 --username audit_user --region us-east-1' "$OUT/aws.log" && ok "iam token requested" || bad "iam token requested"
hasnt iam out 'fake-iam-token' ; hasnt iam err 'fake-iam-token'

echo "== formats"
t all 0 -s "$OUT/servers.conf" -F text,csv,json,html -o "$OUT/rep"
J="$(ls "$OUT"/rep/*.json)"; cp "$J" "$OUT/json.out"
jqt json '.summary | length == 3'; jqt json '[.flags[] | select(.code == "SERVER_ERROR")] | length == 1'
jqt json '.servers[0].per_role_access | map(.role) | index("bob") != null'; jqt json '.generated_ist == "2026-10-21T18:00:00+05:30"'
jqt json '[.servers[0].dbs[] | select(.name == "appdb") | .data.objects[] | select(.name == "orders")][0].grants | any(.grantee == "bob" and .grantable)'
G="$(ls "$OUT"/rep/*_grants.csv)"; grep -q '"local-main","appdb","object","sales","orders","table","app_owner","bob","app_owner","SELECT",true' "$G" && ok "grants csv row" || bad "grants csv row"
[[ "$(python3 -c 'import csv,sys; print(sorted({len(r) for r in csv.reader(open(sys.argv[1]))}))' "$G")" == "[11]" ]] && ok "grants csv: 11 columns everywhere" || bad "grants csv columns"
[[ "$(wc -l <"$(ls "$OUT"/rep/*_summary.csv)")" == 4 ]] && ok "summary csv: 3 rows + header (errors on one line)" || bad "summary csv rows"
grep -q '"HIGH","PUBLIC_CREATE_PUBLIC_SCHEMA"' "$OUT"/rep/*_flags.csv && ok "flags csv" || bad "flags csv"
grep -q '"local-main","svc_etl",true' "$OUT"/rep/*_roles.csv && ok "roles csv" || bad "roles csv"
H="$(ls "$OUT"/rep/*.html)"; grep -q '&quot;we|ird,tab&quot;&quot;le&quot;\|we|ird,tab&quot;le' "$H" && ok "html escapes identifiers" || bad "html escape"
if [[ -n "${NODE_PATH:-}" ]] && node -e "require('puppeteer-core')" 2>/dev/null; then
    node "$HERE/html_check.js" "$H" >"$OUT/html.json" && ok "headless html: search, '/', filters, expand/collapse" || bad "headless html: $(cat "$OUT/html.json")"
else echo "  skip headless html check (set NODE_PATH to a dir with puppeteer-core)"; fi
echo; echo "passed $PASS, failed $FAIL"; (( FAIL == 0 ))
