#!/usr/bin/env bash
#
# collect_sessions.sh - store pg_stat_activity snapshots in monitoring.session_history
#
# Calls monitoring.collect_sessions() (see functions.sql) through psql, either
# once (for cron) or in a loop at a fixed interval aligned to the clock, with
# optional retention (monitoring.purge_sessions) and partition pre-creation.
#
# Exit codes:
#   0    success (loop mode: also a clean stop via INT/TERM)
#   1    usage / validation error
#   2    pre-check failure (cannot connect, monitoring objects missing)
#   3    collection failed (loop mode: --max-failures consecutive failures)
#   4    purge / partition maintenance failed
#   5    another instance holds the lock file
#   130  interrupted (one-shot mode)
#
# Passwords are never accepted on the command line: use ~/.pgpass, --pgpassfile,
# PGPASSWORD, or -W to prompt.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

DB_HOST="${PGHOST:-}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-${USER:-postgres}}"
DB_NAME="${PGDATABASE:-postgres}"
PROMPT_PASSWORD=0
PGPASSFILE_OPT=""
PG_BIN=""
SERVER_ID=""
INCLUDE_IDLE=1
MIN_DURATION=""
EXCLUDE_TYPES=()
MAX_QUERY_LEN=""
INTERVAL=0            # 0 = one-shot
COUNT=0               # loop: number of snapshots (0 = until stopped)
ALIGN=1
MAX_FAILURES=0
RETENTION=""
PURGE_EVERY=3600
PURGE_ONLY=0
PARTITIONS_AHEAD=7
STATEMENT_TIMEOUT="30s"
LOCK_FILE=""
LOG_FILE=""
DRY_RUN=0
VERBOSE=0
QUIET=0
CONFIG_FILE=""

STOP=0
SLEEP_PID=""
LOCK_FD=""

# ----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S%z'; }
_log() {
    local level="$1"; shift
    local line; line="$(_ts) [$level] $*"
    if [[ "$level" != INFO || "$QUIET" -eq 0 ]]; then printf '%s\n' "$line" >&2; fi
    [[ -n "$LOG_FILE" ]] && { printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; }
    return 0
}
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local c="$1"; shift; log_error "$@"; exit "$c"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - store pg_stat_activity snapshots in monitoring.session_history

Usage:
  $SCRIPT_NAME [connection] [filters]                      one snapshot (cron)
  $SCRIPT_NAME --interval 60 [--count N] [options]        loop, one snapshot every 60 s
  $SCRIPT_NAME --purge-only --retention '14 days'          retention only

Connection:
  -h, --host HOST             Server host or socket directory     (default: \$PGHOST / local socket)
  -p, --port PORT             Server port                         (default: \$PGPORT or 5432)
  -U, --user USER             Role to connect as                  (default: \$PGUSER or \$USER)
  -d, --dbname DB             Database holding the monitoring schema (default: \$PGDATABASE or postgres)
  -W, --password              Prompt for the password (interactive use only)
      --pgpassfile FILE       Use this .pgpass file
      --pg-bin DIR            Directory containing psql

What to store (passed to monitoring.collect_sessions):
      --server-id ID          Server label stored with each row (default: cluster_name or addr:port)
      --no-idle               Do not store sessions in state 'idle'
      --min-duration IVL      Store active / idle-in-transaction sessions only if running >= IVL
                              (e.g. '5 seconds'); lock waiters and their blockers are always kept
      --exclude-backend-type T  Skip this backend_type (repeatable / comma list),
                              e.g. 'walwriter,checkpointer,background writer'
      --max-query-length N    Truncate stored query text to N characters

Scheduling:
      --interval SECONDS      Loop mode: take a snapshot every SECONDS (0 = one-shot, default)
      --count N               Loop mode: stop after N snapshots (default: run until stopped)
      --no-align              Do not align snapshots to multiples of the interval on the clock
      --max-failures N        Loop mode: exit 3 after N consecutive failures (default: never)
      --statement-timeout T   statement_timeout for the collector session  (default: 30s)
      --lock-file FILE        Skip the run if another instance holds FILE (needs flock)

Retention and partitions:
      --retention IVL         After collecting, purge history older than IVL (e.g. '30 days')
      --purge-every SECONDS   Loop mode: purge at most this often            (default: 3600)
      --purge-only            Only run the purge (and partition maintenance), no snapshot
      --partitions-ahead N    Pre-create daily partitions N days ahead     (default: 7)

General:
      --config FILE           key=value settings (CLI overrides them)
      --log-file FILE         Also append log lines to FILE
      --dry-run               Run everything inside a transaction that is rolled back;
                              purge only reports what it would remove
  -q, --quiet                 Only log warnings and errors (good for cron)
  -v, --verbose               Debug logging
      --help                  Show this help
      --version               Show version

Exit codes: 0 ok, 1 usage, 2 pre-check, 3 collection failed, 4 purge/partition failed,
            5 locked by another instance, 130 interrupted
USAGE
}

need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value"; }
is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }
add_list() {
    local -n _a="$1"; local _p _x
    IFS=',' read -r -a _p <<<"$2"
    for _x in "${_p[@]}"; do
        _x="${_x#"${_x%%[![:space:]]*}"}"; _x="${_x%"${_x##*[![:space:]]}"}"
        [[ -n "$_x" ]] && _a+=("$_x")
    done
    return 0
}

load_config() {
    local file="$1" line key val n=0
    [[ -r "$file" ]] || die 1 "Config file not readable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
            || die 1 "Config $file:$n: expected key=value"
        key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"([^\"]*)\" || "$val" =~ ^\'([^\']*)\' ]]; then val="${BASH_REMATCH[1]}"
        else
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        case "$key" in
            host) DB_HOST="$val" ;; port) DB_PORT="$val" ;; user) DB_USER="$val" ;; dbname) DB_NAME="$val" ;;
            pgpassfile) PGPASSFILE_OPT="$val" ;; pg_bin) PG_BIN="$val" ;; server_id) SERVER_ID="$val" ;;
            include_idle) is_true "$val" && INCLUDE_IDLE=1 || INCLUDE_IDLE=0 ;;
            min_duration) MIN_DURATION="$val" ;;
            exclude_backend_types) EXCLUDE_TYPES=(); add_list EXCLUDE_TYPES "$val" ;;
            max_query_length) MAX_QUERY_LEN="$val" ;;
            interval) INTERVAL="$val" ;; count) COUNT="$val" ;;
            align) is_true "$val" && ALIGN=1 || ALIGN=0 ;;
            max_failures) MAX_FAILURES="$val" ;; retention) RETENTION="$val" ;;
            purge_every) PURGE_EVERY="$val" ;; partitions_ahead) PARTITIONS_AHEAD="$val" ;;
            statement_timeout) STATEMENT_TIMEOUT="$val" ;; lock_file) LOCK_FILE="$val" ;;
            log_file) LOG_FILE="$val" ;;
            quiet) is_true "$val" && QUIET=1 || QUIET=0 ;;
            verbose) is_true "$val" && VERBOSE=1 || VERBOSE=0 ;;
            password) die 1 "Config $file:$n: 'password' is not supported; use ~/.pgpass" ;;
            *) die 1 "Config $file:$n: unknown key '$key'" ;;
        esac
    done <"$file"
}

parse_args() {
    local i j
    for ((i = 1; i <= $#; i++)); do
        case "${!i}" in
            --config=*) CONFIG_FILE="${!i#*=}" ;;
            --config) j=$((i + 1)); [[ $j -le $# ]] || die 1 "Option --config requires a value"; CONFIG_FILE="${!j}" ;;
        esac
    done
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"
    local c_ex=0
    while [[ $# -gt 0 ]]; do
        local opt="$1"
        if [[ "$opt" == --*=* ]]; then set -- "${opt%%=*}" "${opt#*=}" "${@:2}"; opt="$1"; fi
        case "$opt" in
            -h|--host)          need_arg "$opt" $#; DB_HOST="$2"; shift 2 ;;
            -p|--port)          need_arg "$opt" $#; DB_PORT="$2"; shift 2 ;;
            -U|--user)          need_arg "$opt" $#; DB_USER="$2"; shift 2 ;;
            -d|--dbname)        need_arg "$opt" $#; DB_NAME="$2"; shift 2 ;;
            -W|--password)      PROMPT_PASSWORD=1; shift ;;
            --pgpassfile)       need_arg "$opt" $#; PGPASSFILE_OPT="$2"; shift 2 ;;
            --pg-bin)           need_arg "$opt" $#; PG_BIN="$2"; shift 2 ;;
            --server-id)        need_arg "$opt" $#; SERVER_ID="$2"; shift 2 ;;
            --no-idle)          INCLUDE_IDLE=0; shift ;;
            --min-duration)     need_arg "$opt" $#; MIN_DURATION="$2"; shift 2 ;;
            --exclude-backend-type) need_arg "$opt" $#; ((c_ex++)) || EXCLUDE_TYPES=(); add_list EXCLUDE_TYPES "$2"; shift 2 ;;
            --max-query-length) need_arg "$opt" $#; MAX_QUERY_LEN="$2"; shift 2 ;;
            --interval)         need_arg "$opt" $#; INTERVAL="$2"; shift 2 ;;
            --count)            need_arg "$opt" $#; COUNT="$2"; shift 2 ;;
            --no-align)         ALIGN=0; shift ;;
            --max-failures)     need_arg "$opt" $#; MAX_FAILURES="$2"; shift 2 ;;
            --statement-timeout) need_arg "$opt" $#; STATEMENT_TIMEOUT="$2"; shift 2 ;;
            --lock-file)        need_arg "$opt" $#; LOCK_FILE="$2"; shift 2 ;;
            --retention)        need_arg "$opt" $#; RETENTION="$2"; shift 2 ;;
            --purge-every)      need_arg "$opt" $#; PURGE_EVERY="$2"; shift 2 ;;
            --purge-only)       PURGE_ONLY=1; shift ;;
            --partitions-ahead) need_arg "$opt" $#; PARTITIONS_AHEAD="$2"; shift 2 ;;
            --config)           shift 2 ;;
            --log-file)         need_arg "$opt" $#; LOG_FILE="$2"; shift 2 ;;
            --dry-run)          DRY_RUN=1; shift ;;
            -q|--quiet)         QUIET=1; shift ;;
            -v|--verbose)       VERBOSE=1; shift ;;
            --help)             usage; exit 0 ;;
            --version)          echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *)                  die 1 "Unknown argument: $opt (see --help)" ;;
        esac
    done
}

validate() {
    if [[ ! "$DB_PORT" =~ ^[0-9]+$ ]] || (( DB_PORT < 1 || DB_PORT > 65535 )); then die 1 "Invalid port: $DB_PORT"; fi
    [[ "$INTERVAL" =~ ^[0-9]+$ ]] || die 1 "--interval must be a whole number of seconds"
    [[ "$COUNT" =~ ^[0-9]+$ ]] || die 1 "--count must be a non-negative integer"
    [[ "$MAX_FAILURES" =~ ^[0-9]+$ ]] || die 1 "--max-failures must be a non-negative integer"
    [[ "$PURGE_EVERY" =~ ^[0-9]+$ ]] || die 1 "--purge-every must be seconds"
    [[ "$PARTITIONS_AHEAD" =~ ^[0-9]+$ ]] || die 1 "--partitions-ahead must be a non-negative integer"
    [[ -z "$MAX_QUERY_LEN" || "$MAX_QUERY_LEN" =~ ^[1-9][0-9]*$ ]] || die 1 "--max-query-length must be a positive integer"
    (( INTERVAL == 0 && COUNT > 0 )) && die 1 "--count needs --interval"
    (( PURGE_ONLY )) && [[ -z "$RETENTION" ]] && die 1 "--purge-only needs --retention"
    (( PURGE_ONLY && INTERVAL > 0 )) && die 1 "--purge-only is a one-shot action; do not combine with --interval"
    if [[ -n "$PGPASSFILE_OPT" ]]; then
        [[ -r "$PGPASSFILE_OPT" ]] || die 1 "pgpassfile not readable: $PGPASSFILE_OPT"
        export PGPASSFILE="$PGPASSFILE_OPT"
    fi
    if (( PROMPT_PASSWORD && INTERVAL > 0 )); then
        log_warn "-W prompts on every connection; for loop mode use ~/.pgpass instead"
    fi
    return 0
}

# ----------------------------------------------------------------------------
PSQL=()
build_psql() {
    local bin="psql"; [[ -n "$PG_BIN" ]] && bin="${PG_BIN%/}/psql"
    command -v "$bin" >/dev/null 2>&1 || die 2 "psql not found (install postgresql-client or use --pg-bin)"
    PSQL=("$bin" -X -q -At -F '|' -v ON_ERROR_STOP=1 -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME")
    [[ -n "$DB_HOST" ]] && PSQL+=(-h "$DB_HOST")
    if (( PROMPT_PASSWORD )); then PSQL+=(-W); else PSQL+=(-w); fi
    export PGAPPNAME="collect_sessions"
    export PGOPTIONS="-c statement_timeout=$STATEMENT_TIMEOUT -c lock_timeout=5s"
}
run_sql() {  # run_sql <sql> [psql -v args...]  -> stdout (stderr merged)
    local sql="$1"; shift
    printf '%s\n' "$sql" | "${PSQL[@]}" "$@" -f - 2>&1
}
wrap_txn() {  # wrap SQL for dry runs
    if (( DRY_RUN )); then printf 'BEGIN;\n%s\nROLLBACK;' "$1"; else printf '%s' "$1"; fi
}

# text[] literal for the excluded backend types
pg_array() {
    local out="" x
    for x in "$@"; do x="${x//\\/\\\\}"; x="${x//\"/\\\"}"; out+="\"$x\","; done
    printf '{%s}' "${out%,}"
}

precheck() {
    local out
    out="$(run_sql "SELECT to_regprocedure('monitoring.collect_sessions(text,boolean,interval,text[],integer)') IS NOT NULL,
                           to_regclass('monitoring.session_history') IS NOT NULL,
                           (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
                             OR pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER'),
                           current_setting('server_version_num')::int")" \
        || die 2 "Cannot connect to ${DB_HOST:-local socket}:$DB_PORT db=$DB_NAME as $DB_USER: ${out//$'\n'/ }"
    local has_fn has_tbl can_read ver
    IFS='|' read -r has_fn has_tbl can_read ver <<<"$out"
    [[ "$has_fn" == t && "$has_tbl" == t ]] || die 2 "monitoring objects not found in database '$DB_NAME' (run schema.sql and functions.sql)"
    (( ver >= 140000 )) || die 2 "PostgreSQL 14 or newer required (server_version_num=$ver)"
    [[ "$can_read" == t ]] || log_warn "Role '$DB_USER' is not a member of pg_read_all_stats (or pg_monitor): state, backend_type, wait events and query text of other roles' sessions will be NULL / '<insufficient privilege>'"
    local ivl
    for ivl in "$MIN_DURATION" "$RETENTION"; do
        [[ -n "$ivl" ]] || continue
        out="$(run_sql "SELECT :'v'::interval;" -v v="$ivl")" || { out="${out##*ERROR:  }"; die 1 "Invalid interval '$ivl': ${out%%$'\n'*}"; }
    done
    log_debug "precheck ok (server_version_num=$ver)"
}

maintain_partitions() {
    local out
    out="$(run_sql "$(wrap_txn "SELECT monitoring.create_partitions(:'ahead'::int);")" -v ahead="$PARTITIONS_AHEAD")" \
        || { log_error "Partition maintenance failed: ${out//$'\n'/ }"; return 4; }
    out="${out//[^0-9]/}"
    if [[ "${out:-0}" != 0 ]]; then log_info "Created $out daily partition(s)$( (( DRY_RUN )) && echo ' (dry run, rolled back)')"; fi
    return 0
}

collect_once() {
    local sql out line rows total client maxc at ms
    sql="SELECT monitoring.collect_sessions(NULLIF(:'server_id',''), :'idle'::boolean,
                NULLIF(:'min_dur','')::interval, :'excl'::text[], NULLIF(:'maxlen','')::int);
SELECT rows_stored, total_backends, client_backends, max_connections, collected_at, collect_ms
  FROM monitoring.session_snapshots WHERE snapshot_id = currval('monitoring.session_snapshot_id_seq');"
    out="$(run_sql "$(wrap_txn "$sql")" \
            -v server_id="$SERVER_ID" -v idle="$( (( INCLUDE_IDLE )) && echo true || echo false)" \
            -v min_dur="$MIN_DURATION" -v excl="$(pg_array "${EXCLUDE_TYPES[@]}")" -v maxlen="$MAX_QUERY_LEN")" \
        || { log_error "Snapshot failed: ${out//$'\n'/ }"; return 3; }
    while IFS= read -r line; do
        [[ "$line" == *WARNING:* ]] && log_warn "${line#*WARNING:  }"
    done <<<"$out"
    line="$(grep -E '^[0-9]+\|' <<<"$out" | tail -n 1 || true)"
    IFS='|' read -r rows total client maxc at ms <<<"$line"
    log_info "Snapshot at $at: stored $rows row(s); backends $total total, $client client of max_connections $maxc; ${ms} ms$( (( DRY_RUN )) && echo ' (dry run, rolled back)')"
    return 0
}

purge() {
    local out line action obj n
    out="$(run_sql "SELECT * FROM monitoring.purge_sessions(:'ret'::interval, :'dry'::boolean);" \
            -v ret="$RETENTION" -v dry="$( (( DRY_RUN )) && echo true || echo false)")" \
        || { log_error "Purge failed: ${out//$'\n'/ }"; return 4; }
    while IFS='|' read -r action obj n; do
        [[ -n "$action" ]] || continue
        if [[ "$action" == *partition* || "$n" != 0 ]]; then log_info "Purge (retention $RETENTION): $action $obj ($n rows)"
        else log_debug "Purge: $action $obj ($n rows)"; fi
    done <<<"$out"
    return 0
}

# ----------------------------------------------------------------------------
acquire_lock() {
    [[ -n "$LOCK_FILE" ]] || return 0
    command -v flock >/dev/null 2>&1 || { log_warn "flock not installed; --lock-file ignored"; return 0; }
    exec {LOCK_FD}>>"$LOCK_FILE" || die 1 "Cannot open lock file $LOCK_FILE"
    flock -n "$LOCK_FD" || die 5 "Another instance holds $LOCK_FILE; skipping this run"
}

# shellcheck disable=SC2317  # invoked via trap
on_signal() {
    if (( INTERVAL > 0 )); then
        log_info "Received $1, stopping after the current step"
        STOP=1
        [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null
    else
        log_error "Interrupted by $1"; exit 130
    fi
}

sleep_until_next() {
    local now secs
    now="$(date +%s)"
    if (( ALIGN )); then secs=$(( INTERVAL - now % INTERVAL )); else secs=$INTERVAL; fi
    log_debug "sleeping ${secs}s"
    sleep "$secs" & SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
}

main() {
    parse_args "$@"
    validate
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    acquire_lock
    build_psql
    precheck

    local rc=0
    if (( PURGE_ONLY )); then
        maintain_partitions || rc=$?
        purge || rc=$?
        exit "$rc"
    fi

    if (( INTERVAL == 0 )); then
        collect_once || exit $?
        if [[ -n "$RETENTION" ]]; then purge || rc=$?; fi
        exit "$rc"
    fi

    log_info "Loop mode: every ${INTERVAL}s$( (( ALIGN )) && echo ' (clock-aligned)')$( (( COUNT )) && echo ", $COUNT snapshot(s)")$( [[ -n "$RETENTION" ]] && echo ", retention $RETENTION")"
    maintain_partitions || rc=$?
    local n=0 fails=0 worst=$rc last_purge=0 day today
    day="$(date -u +%F)"
    (( ALIGN )) && sleep_until_next
    while (( !STOP )); do
        today="$(date -u +%F)"
        if [[ "$today" != "$day" ]]; then day="$today"; maintain_partitions || worst=4; fi
        if collect_once; then fails=0
        else
            fails=$((fails + 1)); worst=3
            if (( MAX_FAILURES && fails >= MAX_FAILURES )); then die 3 "$fails consecutive failures, giving up"; fi
        fi
        n=$((n + 1))
        if [[ -n "$RETENTION" ]] && (( $(date +%s) - last_purge >= PURGE_EVERY )); then
            purge || worst=4
            last_purge="$(date +%s)"
        fi
        (( COUNT && n >= COUNT )) && break
        (( STOP )) && break
        sleep_until_next
    done
    log_info "Loop finished after $n snapshot(s)"
    exit "$worst"
}

main "$@"
