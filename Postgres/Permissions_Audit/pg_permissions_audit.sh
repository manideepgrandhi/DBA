#!/usr/bin/env bash
#
# pg_permissions_audit.sh - READ-ONLY permissions audit for (Aurora) PostgreSQL, across many servers and databases.
# Database / schema / object / column grants, default privileges, foreign servers + user mappings, roles,
# membership chains, effective per-role access and risk flags. Only SELECTs on pg_catalog (lib/audit.sql),
# run inside a READ ONLY transaction. Works as a non-superuser (e.g. an rds_superuser member) on PG 13+.
#
# Output: text | csv | json | html (several at once with -F csv,html -o DIR). Rendering lives in lib/audit.jq.
# Exit:   0 report produced (even if some servers/dbs failed - see report), 1 usage, 2 pre-check,
#         3 nothing could be audited, 4 output error, 130 interrupted.

# shellcheck disable=SC2034  # KEEP_WORKDIR is read inside the EXIT trap string
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIBDIR="${PG_AUDIT_LIB:-$SCRIPT_DIR/lib}"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

SERVERS_FILE=""
S_HOST=""; S_PORT=""; S_USER=""; S_DBS=""; S_NAME=""; S_SSLMODE=""; S_AUTH=""; S_REGION=""
DB_GLOBS=(); SCHEMA_GLOBS=(); ROLES=(); FORMATS=()
INCLUDE_SYSTEM=0
SHOW_OWNER_GRANTS=0
OUTPUT_DIR=""
PREFIX="pg_permissions_audit"
CONNECT_TIMEOUT=10
STMT_TIMEOUT=120
TOP_N=10
DRY_RUN=0
KEEP_WORKDIR=0   # used in the EXIT trap
VERBOSE=0
WORK=""
declare -a WRITTEN=()

_log() { local l="$1"; shift; printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$l" "$*" >&2; }
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local c="$1"; shift; log_error "$@"; exit "$c"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - read-only PostgreSQL / Aurora PostgreSQL permissions audit

Usage: $SCRIPT_NAME -s SERVERS_FILE [options]
       $SCRIPT_NAME -h HOST [-p PORT] -U USER [-d DB[,DB..]|all] [options]

Targets:
  -s, --servers FILE      One server per line:  name host port user dbs [sslmode] [auth=password|iam] [region=R]
                          dbs = all | comma list. '#' comments. Parsed, never sourced. See servers.conf.example
  -h, --host HOST         Single server (instead of -s)
  -p, --port PORT         Default 5432
  -U, --user USER         Login role (non-superuser rds_superuser member is fine)
  -d, --dbname LIST       all (default) or comma list
  -n, --name NAME         Display name for the single server (default: host)
      --sslmode MODE      disable|allow|prefer|require|verify-ca|verify-full (default: prefer; require for IAM)
      --iam               Authenticate with an RDS IAM token (aws rds generate-db-auth-token)
      --region REGION     Region for the IAM token (default: parsed from the host, else AWS_REGION)
  Passwords come from ~/.pgpass or PGPASSWORD (never from the servers file).

Filters:
      --db GLOB           Only databases matching (repeatable / comma list; applied to 'all' and to lists)
      --schema GLOB       Only schemas matching (repeatable / comma list)
      --role NAME         Per-role view for these roles, and only grants that reach them (repeatable / comma list)
      --include-system    Include pg_catalog, information_schema, pg_toast (default: excluded; rdsadmin db and
                          template databases are always skipped)
      --show-owner-grants Show owners' own implicit grants in text/html (always in json)

Report:
  -F, --format LIST       text,csv,json,html (default: text). Several formats need -o
  -o, --output-dir DIR    Write <prefix>_YYYYmmdd_HHMMSS.<ext> (csv: _grants, _roles, _flags, _summary)
      --prefix NAME       File prefix (default: $PREFIX)
      --top N             Examples per risk flag in the text summary (default: $TOP_N)

Behaviour:
      --connect-timeout S Default $CONNECT_TIMEOUT
      --statement-timeout S  Per-database query timeout (default: $STMT_TIMEOUT)
      --dry-run           Show the parsed targets; connect to nothing
      --keep-workdir      Keep raw per-database JSON
  -v, --verbose / --help / -V, --version

Exit codes: 0 report produced (failed servers/databases are listed inside), 1 usage, 2 pre-check,
            3 nothing could be audited, 4 output error, 130 interrupted.
USAGE
}

add_list() {   # add_list ARRAYNAME "a,b,c"
    local -n _arr="$1"; local _v; local IFS=','
    for _v in $2; do _v="${_v#"${_v%%[![:space:]]*}"}"; _v="${_v%"${_v##*[![:space:]]}"}"; [[ -n "$_v" ]] && _arr+=("$_v"); done
    return 0
}
need_arg() { [[ $# -ge 2 && -n "$2" ]] || die 1 "Option $1 needs a value (see --help)"; }
is_uint()  { [[ "$1" =~ ^[0-9]+$ ]]; }

parse_args() {
    while (( $# )); do
        case "$1" in
            -s|--servers) need_arg "$@"; SERVERS_FILE="$2"; shift ;;
            -h|--host) need_arg "$@"; S_HOST="$2"; shift ;;
            -p|--port) need_arg "$@"; S_PORT="$2"; shift ;;
            -U|--user) need_arg "$@"; S_USER="$2"; shift ;;
            -d|--dbname) need_arg "$@"; S_DBS="$2"; shift ;;
            -n|--name) need_arg "$@"; S_NAME="$2"; shift ;;
            --sslmode) need_arg "$@"; S_SSLMODE="$2"; shift ;;
            --iam) S_AUTH=iam ;;
            --region) need_arg "$@"; S_REGION="$2"; shift ;;
            --db) need_arg "$@"; add_list DB_GLOBS "$2"; shift ;;
            --schema) need_arg "$@"; add_list SCHEMA_GLOBS "$2"; shift ;;
            --role) need_arg "$@"; add_list ROLES "$2"; shift ;;
            --include-system) INCLUDE_SYSTEM=1 ;;
            --exclude-system) INCLUDE_SYSTEM=0 ;;
            --show-owner-grants) SHOW_OWNER_GRANTS=1 ;;
            -F|--format) need_arg "$@"; add_list FORMATS "$2"; shift ;;
            -o|--output-dir) need_arg "$@"; OUTPUT_DIR="$2"; shift ;;
            --prefix) need_arg "$@"; PREFIX="$2"; shift ;;
            --top) need_arg "$@"; TOP_N="$2"; shift ;;
            --connect-timeout) need_arg "$@"; CONNECT_TIMEOUT="$2"; shift ;;
            --statement-timeout) need_arg "$@"; STMT_TIMEOUT="$2"; shift ;;
            --dry-run) DRY_RUN=1 ;;
            --keep-workdir) KEEP_WORKDIR=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            --help) usage; exit 0 ;;
            -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *) die 1 "Unknown option '$1' (see --help)" ;;
        esac
        shift
    done
    [[ -n "$SERVERS_FILE" && -n "$S_HOST" ]] && die 1 "Use either -s FILE or -h HOST, not both"
    [[ -z "$SERVERS_FILE" && -z "$S_HOST" ]] && die 1 "Give -s SERVERS_FILE or -h HOST (see --help)"
    (( ${#FORMATS[@]} )) || FORMATS=(text)
    local f; for f in "${FORMATS[@]}"; do case "$f" in text|csv|json|html) ;; *) die 1 "Unknown format '$f' (text,csv,json,html)" ;; esac; done
    (( ${#FORMATS[@]} > 1 )) && [[ -z "$OUTPUT_DIR" ]] && die 1 "Several formats need -o DIR"
    [[ " ${FORMATS[*]} " == *" csv "* && -z "$OUTPUT_DIR" ]] && die 1 "csv writes several files - give -o DIR"
    { is_uint "$TOP_N" && is_uint "$CONNECT_TIMEOUT" && is_uint "$STMT_TIMEOUT"; } || die 1 "--top / timeouts must be integers"
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--prefix: letters, digits . _ - only"
    return 0
}

# ---------------------------------------------------------------------------- targets
# Each target: name<TAB>host<TAB>port<TAB>user<TAB>dbs<TAB>sslmode<TAB>auth<TAB>region
TARGETS=()
validate_target() {   # name host port user dbs sslmode auth region where
    local name="$1" host="$2" port="$3" user="$4" dbs="$5" ssl="$6" auth="$7" region="$8" where="$9"
    [[ "$name" =~ ^[A-Za-z0-9._@:-]+$ ]] || die 1 "$where: bad server name '$name' (letters digits . _ - @ :)"
    [[ "$host" =~ ^[A-Za-z0-9._:/-]+$ ]] || die 1 "$where: bad host '$host'"
    { is_uint "$port" && (( port > 0 && port < 65536 )); } || die 1 "$where: bad port '$port'"
    [[ "$user" =~ ^[A-Za-z0-9_.@-]+$ ]] || die 1 "$where: bad user '$user'"
    [[ "$dbs" =~ ^[A-Za-z0-9_.,$-]+$ ]] || die 1 "$where: bad database list '$dbs' (all or comma list)"
    case "$ssl" in ''|disable|allow|prefer|require|verify-ca|verify-full) ;; *) die 1 "$where: bad sslmode '$ssl'" ;; esac
    case "$auth" in password|iam) ;; *) die 1 "$where: bad auth '$auth' (password|iam)" ;; esac
    [[ -z "$region" || "$region" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die 1 "$where: bad region '$region'"
    local t; for t in "${TARGETS[@]}"; do [[ "${t%%$'\t'*}" == "$name" ]] && die 1 "$where: duplicate server name '$name'"; done
    TARGETS+=("$name"$'\t'"$host"$'\t'"$port"$'\t'"$user"$'\t'"$dbs"$'\t'"$ssl"$'\t'"$auth"$'\t'"$region")
}

load_targets() {
    if [[ -n "$S_HOST" ]]; then
        [[ -n "$S_USER" ]] || S_USER="${PGUSER:-}"
        [[ -n "$S_USER" ]] || die 1 "-U USER is required"
        validate_target "${S_NAME:-$S_HOST}" "$S_HOST" "${S_PORT:-5432}" "$S_USER" "${S_DBS:-all}" "$S_SSLMODE" "${S_AUTH:-password}" "$S_REGION" "command line"
        return
    fi
    [[ -r "$SERVERS_FILE" ]] || die 1 "Cannot read servers file '$SERVERS_FILE'"
    local line n=0 tok
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1)); line="${line%%#*}"; line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        local -a f=(); read -r -a f <<<"$line"
        (( ${#f[@]} >= 5 )) || die 1 "$SERVERS_FILE:$n: need at least: name host port user dbs"
        local ssl="" auth=password region=""
        for tok in "${f[@]:5}"; do
            case "$tok" in
                auth=*) auth="${tok#auth=}" ;; sslmode=*) ssl="${tok#sslmode=}" ;; region=*) region="${tok#region=}" ;;
                *=*) die 1 "$SERVERS_FILE:$n: unknown option '$tok'" ;;
                *) [[ -z "$ssl" ]] || die 1 "$SERVERS_FILE:$n: unexpected '$tok'"; ssl="$tok" ;;
            esac
        done
        validate_target "${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" "$ssl" "$auth" "$region" "$SERVERS_FILE:$n"
    done <"$SERVERS_FILE"
    (( ${#TARGETS[@]} )) || die 1 "$SERVERS_FILE: no servers listed"
}

# ---------------------------------------------------------------------------- psql
glob_match() {   # glob_match VALUE GLOB...  (no globs = match)
    local v="$1" g; shift; (( $# )) || return 0
    for g in "$@"; do
        # shellcheck disable=SC2053  # intentional glob match
        [[ "$v" == $g ]] && return 0
    done
    return 1
}

# Connection is passed only through PG* env vars (no conninfo string building, no shell interpolation into SQL).
run_psql() {   # run_psql DB OUTFILE ERRFILE [psql args...]   uses CUR_* vars
    local db="$1" out="$2" err="$3"; shift 3
    (
    if [[ -n "$CUR_TOKEN" ]]; then export PGPASSWORD="$CUR_TOKEN"; fi   # env only - never on a command line
    PGHOST="$CUR_HOST" PGPORT="$CUR_PORT" PGUSER="$CUR_USER" PGDATABASE="$db" PGSSLMODE="$CUR_SSL" \
    PGCONNECT_TIMEOUT="$CONNECT_TIMEOUT" PGAPPNAME="$SCRIPT_NAME" \
    PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=${STMT_TIMEOUT}s -c lock_timeout=5s -c search_path=pg_catalog" \
        psql -X -A -t -q -w -v ON_ERROR_STOP=1 "$@" >"$out" 2>"$err"
    )
}

iam_token() {   # prints token
    local region="$CUR_REGION"
    if [[ -z "$region" && "$CUR_HOST" =~ \.([a-z]{2}(-[a-z]+)+-[0-9])\.rds\.amazonaws\.com$ ]]; then region="${BASH_REMATCH[1]}"; fi
    [[ -n "$region" ]] || region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    [[ -n "$region" ]] || { echo "IAM auth: cannot determine region (use region=... / --region)" >&2; return 1; }
    aws rds generate-db-auth-token --hostname "$CUR_HOST" --port "$CUR_PORT" --username "$CUR_USER" --region "$region" --output text
}

audit_server() {   # audit_server INDEX TARGET-LINE
    local idx="$1"; local name host port user dbs ssl auth region
    IFS=$'\t' read -r name host port user dbs ssl auth region <<<"$2"
    CUR_HOST="$host"; CUR_PORT="$port"; CUR_USER="$user"; CUR_REGION="$region"; CUR_TOKEN=""
    CUR_SSL="${ssl:-$([[ "$auth" == iam ]] && echo require || echo prefer)}"
    local sdir="$WORK/s$idx"; mkdir -p "$sdir"
    local meta="$sdir/meta.json"
    jq -n --arg name "$name" --arg host "$host" --argjson port "$port" --arg user "$user" --arg dbs "$dbs" \
          --arg ssl "$CUR_SSL" --arg auth "$auth" '{name:$name,host:$host,port:$port,user:$user,dbs_spec:$dbs,sslmode:$ssl,auth:$auth}' >"$meta"
    log_info "[$name] $user@$host:$port ($auth, sslmode=$CUR_SSL) dbs=$dbs"
    if [[ "$auth" == iam ]]; then
        if ! CUR_TOKEN="$(iam_token 2>"$sdir/err")"; then
            jq -Rs '{error: ("IAM token: " + (rtrimstr("\n") | gsub("\\s*\n\\s*"; " ")))}' "$sdir/err" >"$sdir/server_err.json"; log_error "[$name] IAM token failed"; return 0
        fi
    fi
    local -a list=()
    if [[ "$dbs" == all ]]; then
        if ! run_psql postgres "$sdir/dblist" "$sdir/err" -c \
            "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'rdsadmin' AND has_database_privilege(datname, 'CONNECT') ORDER BY 1"; then
            jq -Rs '{error: ("listing databases: " + (rtrimstr("\n") | gsub("\\s*\n\\s*"; " ")))}' "$sdir/err" >"$sdir/server_err.json"
            log_error "[$name] cannot connect: $(head -c 300 "$sdir/err")"; return 0
        fi
        mapfile -t list <"$sdir/dblist"
    else
        add_list list "$dbs"
    fi
    local db i=0 ok=0
    for db in "${list[@]}"; do
        [[ -n "$db" ]] || continue
        glob_match "$db" "${DB_GLOBS[@]}" || { log_debug "[$name] skip db $db (--db)"; continue; }
        [[ "$db" == rdsadmin ]] && continue
        i=$((i + 1)); local out="$sdir/db$i.json" err="$sdir/db$i.err"
        if run_psql "$db" "$out" "$err" -v incsys="$([[ $INCLUDE_SYSTEM -eq 1 ]] && echo on || echo off)" -f "$LIBDIR/audit.sql" \
           && jq -e 'type == "object"' "$out" >/dev/null 2>&1; then
            jq --arg db "$db" '{name: $db, status: "ok", data: .}' "$out" >"$out.w"; ok=$((ok + 1))
            log_info "[$name] $db: $(jq -r '"\(.data.objects|length) objects, \(.data.schemas|length) schemas"' "$out.w")"
        else
            jq -Rs --arg db "$db" '{name: $db, status: "error", error: (rtrimstr("\n") | gsub("\\s*\n\\s*"; " ") | if . == "" then "query returned no JSON" else . end)}' "$err" >"$out.w"
            log_error "[$name] $db: $(head -c 300 "$err")"
        fi
    done
    (( i )) || jq -n '{error: "no databases matched"}' >"$sdir/server_err.json"
    return 0
}

assemble() {   # -> $WORK/report.json
    local d parts=()
    for d in "$WORK"/s*; do
        local sf="$d/server.json"; local -a dbf=("$d"/db*.json.w)
        if [[ -e "${dbf[0]}" ]]; then jq -s '.' "${dbf[@]}" >"$d/dbs.json"; else echo '[]' >"$d/dbs.json"; fi
        [[ -f "$d/server_err.json" ]] || echo '{}' >"$d/server_err.json"
        jq -n --slurpfile m "$d/meta.json" --slurpfile e "$d/server_err.json" --slurpfile dbs "$d/dbs.json" \
           '$m[0] + $e[0] + {dbs: $dbs[0]}' >"$sf"
        parts+=("$sf")
    done
    jq -s '.' "${parts[@]}" >"$WORK/servers.json"
}

render() {   # render MODE OUTFILE
    jq -r --arg mode "$1" --slurpfile cfg "$WORK/cfg.json" --slurpfile S "$WORK/servers.json" \
       -n -f "$LIBDIR/audit.jq" >"$2"
}

main() {
    parse_args "$@"
    load_targets
    if (( DRY_RUN )); then
        printf 'Targets (%d):\n' "${#TARGETS[@]}"
        local t; for t in "${TARGETS[@]}"; do IFS=$'\t' read -r n h p u d s a r <<<"$t"
            printf '  %-20s %s@%s:%s dbs=%s sslmode=%s auth=%s%s\n' "$n" "$u" "$h" "$p" "$d" "${s:-default}" "$a" "${r:+ region=$r}"; done
        printf 'Filters: db=%s schema=%s role=%s include-system=%s\nNo connections made (--dry-run).\n' \
            "${DB_GLOBS[*]:-*}" "${SCHEMA_GLOBS[*]:-*}" "${ROLES[*]:--}" "$INCLUDE_SYSTEM"
        exit 0
    fi
    command -v psql >/dev/null || die 2 "psql not found (CloudShell: sudo dnf install -y postgresql15)"
    command -v jq >/dev/null || die 2 "jq not found"
    [[ -r "$LIBDIR/audit.sql" && -r "$LIBDIR/audit.jq" ]] || die 2 "lib/audit.sql or lib/audit.jq missing in $LIBDIR"
    if [[ " ${TARGETS[*]} " == *$'\t'iam$'\t'* ]]; then command -v aws >/dev/null || die 2 "aws CLI needed for IAM auth"; fi
    if [[ -n "$OUTPUT_DIR" ]]; then { mkdir -p -- "$OUTPUT_DIR" && [[ -w "$OUTPUT_DIR" ]]; } || die 4 "Cannot write to '$OUTPUT_DIR'"; fi

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/pgaudit.XXXXXX")"
    # shellcheck disable=SC2154,SC2016
    trap '(( KEEP_WORKDIR )) && log_info "workdir kept: $WORK" || rm -rf -- "$WORK"' EXIT
    trap 'exit 130' INT TERM

    local i=0 t
    for t in "${TARGETS[@]}"; do i=$((i + 1)); audit_server "$i" "$t"; done
    assemble
    local now; now="$(date -u +%s)"; now="${PG_AUDIT_NOW:-$now}"
    jq -n --argjson now "$now" --argjson top "$TOP_N" --argjson owner "$SHOW_OWNER_GRANTS" --argjson incsys "$INCLUDE_SYSTEM" \
          --arg ver "$SCRIPT_VERSION" \
          --args '{now:$now, top:$top, show_owner:($owner==1), include_system:($incsys==1), version:$ver,
                   schemas: $ARGS.positional[0] | fromjson, roles: $ARGS.positional[1] | fromjson, dbs: $ARGS.positional[2] | fromjson}' \
          "$(printf '%s\n' "${SCHEMA_GLOBS[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
          "$(printf '%s\n' "${ROLES[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
          "$(printf '%s\n' "${DB_GLOBS[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" >"$WORK/cfg.json"

    local okdbs; okdbs="$(jq '[.[].dbs[] | select(.status == "ok")] | length' "$WORK/servers.json")"
    local f ext stamp; stamp="$(date -u -d "@$now" +%Y%m%d_%H%M%S)"
    for f in "${FORMATS[@]}"; do
        if [[ -z "$OUTPUT_DIR" ]]; then render "$f" /dev/stdout || die 4 "render $f failed"; continue; fi
        local base="$OUTPUT_DIR/${PREFIX}_${stamp}"
        case "$f" in
            text) ext=txt ;; html) ext=html ;; json) ext=json ;;
            csv) local m; for m in grants roles flags summary; do render "csv_$m" "${base}_$m.csv" || die 4 "render csv_$m failed"; WRITTEN+=("${base}_$m.csv"); done; continue ;;
        esac
        render "$f" "$base.$ext" || die 4 "render $f failed"; WRITTEN+=("$base.$ext")
    done
    (( ${#WRITTEN[@]} )) && printf 'Wrote: %s\n' "${WRITTEN[@]}" >&2
    (( okdbs > 0 )) || { log_error "No database could be audited (see report for errors)"; exit 3; }
    return 0
}

main "$@"
