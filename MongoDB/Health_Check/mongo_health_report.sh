#!/usr/bin/env bash
#
# mongo_health_report.sh - READ-ONLY health check report for self-managed MongoDB (replica sets and standalones),
# across many servers. Replica set status and lag, rs.conf, oplog window, connections, memory, WiredTiger cache,
# opcounters, queues, long-running operations, asserts, page faults, database / collection sizes and disk free
# space (dbStats on every member, plus optional `df` over SSH). Risk flags with configurable thresholds.
#
# Collection runs in mongosh (lib/collect.js) with diagnostic commands only; nothing is written to MongoDB.
# Rendering lives in lib/report.jq. Output: self-contained HTML (+ optional CSV / JSON) and a console summary.
# Exit:   0 report produced, 1 usage, 2 pre-check, 3 no server reachable, 4 output error,
#         5 report produced and flags at/above --fail-on were raised, 130 interrupted.

# shellcheck disable=SC2034  # KEEP_WORKDIR is read inside the EXIT trap string
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIBDIR="${MONGO_HEALTH_LIB:-$SCRIPT_DIR/lib}"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

SERVERS_FILE=""
S_URI=""; S_NAME=""; S_SETS=()
ONLY=()
OUTPUT_DIR="."
PREFIX="mongo_health"
CSV=0; JSON_OUT=0; QUIET=0
TIMEOUT=10          # connect / server selection, seconds
MAXTIME=30          # per command maxTimeMS, seconds
SERVER_TIMEOUT=300  # whole mongosh run per server, seconds
SSH_TIMEOUT=10
SSH_MODE=""         # --ssh: run df on every server that has ssh= ; --no-ssh: never
SSH_ACCEPT_NEW=0
MEMBERS=1
LONG_OP=60; TOP_N=10; MAX_COLLS=500; INCLUDE_SYSTEM=0
LAG_WARN=60; LAG_CRIT=300
OPLOG_WARN=24; OPLOG_CRIT=6
CONN_WARN=80; CONN_CRIT=90
DIRTY_WARN=5; DIRTY_CRIT=20; CACHE_WARN=95
DISK_WARN=80; DISK_CRIT=90
QUEUE_WARN=10
FAIL_ON=""
DRY_RUN=0
KEEP_WORKDIR=0   # used in the EXIT trap
VERBOSE=0
WORK=""
MONGOSH="${MONGOSH:-mongosh}"
declare -a WRITTEN=()

_log() { local l="$1"; shift; printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$l" "$*" >&2; }
log_info()  { (( QUIET )) || _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local c="$1"; shift; log_error "$@"; exit "$c"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - read-only MongoDB health check report (replica sets + standalones, HTML)

Usage: $SCRIPT_NAME -s SERVERS_FILE [options]
       $SCRIPT_NAME -u URI|HOST:PORT [-n NAME] [--set key=value ...] [options]

Targets:
  -s, --servers FILE      One target per line:  name  uri|host:port[,host:port..]  [key=value ...]
                          keys: rs= authdb= user= pass_env= pass_file= authmech= tls=on|off tlsca= tlscert=
                                tls_insecure=on ssh=auto|[user@]host[,..] ssh_user= ssh_port= ssh_key=
                          '#' comments. Parsed, never sourced. Passwords are never read from this file.
                          See servers.conf.example
  -u, --uri TARGET        Single target (mongodb://, mongodb+srv:// or host:port) instead of -s
  -n, --name NAME         Display name for -u (default: the target)
      --set KEY=VALUE     servers.conf key for -u (repeatable), e.g. --set user=dba_mon --set pass_env=MONGO_PW
      --only NAME         Only these targets (repeatable / comma list; shell globs allowed)

Report:
  -o, --output-dir DIR    Where to write <prefix>_YYYYmmdd_HHMMSS.html (default: current directory)
      --prefix NAME       File prefix (default: $PREFIX)
      --csv               Also write _summary.csv and _flags.csv
      --json              Also write the raw collected data as .json
      --top N             Top N collections by size per server (default: $TOP_N)
      --max-collections N Stop collecting collection stats after N collections per server (default: $MAX_COLLS)
      --include-system    Include admin / local / config in the top collections list
      --no-members        Do not connect to each replica set member directly (default: connect, for per-host
                          connections, cache and data-disk usage)
  -q, --quiet             No progress log; console summary only

Disk free over SSH (optional; read-only 'df -PTk' and 'df -Pk <dbPath>'):
      --ssh               Run df on targets that have ssh=... in the servers file (default when ssh= is set)
      --no-ssh            Never use SSH, even if ssh= is set
      --ssh-timeout S     Default $SSH_TIMEOUT
      --ssh-accept-new    Pass StrictHostKeyChecking=accept-new (adds unknown host keys to ~/.ssh/known_hosts)

Thresholds (WARN / CRIT):
      --lag-warn S / --lag-crit S          Replication lag beyond the configured delay, seconds ($LAG_WARN / $LAG_CRIT)
      --oplog-warn H / --oplog-crit H      Oplog window below, hours ($OPLOG_WARN / $OPLOG_CRIT)
      --conn-warn P / --conn-crit P        Connections used, % of current+available ($CONN_WARN / $CONN_CRIT)
      --dirty-warn P / --dirty-crit P      WiredTiger cache dirty, % ($DIRTY_WARN / $DIRTY_CRIT)
      --cache-warn P                       WiredTiger cache used, % ($CACHE_WARN)
      --disk-warn P / --disk-crit P        Filesystem used, % ($DISK_WARN / $DISK_CRIT)
      --long-op S                          Operations running at least S seconds ($LONG_OP)
      --queue-warn N                       Queued readers+writers ($QUEUE_WARN)
      --fail-on warn|crit                  Exit 5 when a flag at or above this level is raised (for cron/monitoring)

Behaviour:
      --timeout S         Connect / server selection timeout (default: $TIMEOUT)
      --max-time S        Per-command maxTimeMS (default: $MAXTIME)
      --server-timeout S  Hard limit for one server's whole collection (default: $SERVER_TIMEOUT)
      --dry-run           Show the parsed targets; connect to nothing
      --keep-workdir      Keep raw per-server output
  -v, --verbose / -h, --help / -V, --version

Environment: MONGOSH=path to mongosh (default: mongosh on PATH).
Exit codes: 0 report produced (unreachable servers are CRIT rows inside), 1 usage, 2 pre-check,
            3 no server reachable, 4 output error, 5 flags at/above --fail-on, 130 interrupted.
USAGE
}

add_list() {   # add_list ARRAYNAME "a,b,c"
    local -n _arr="$1"; local _v; local IFS=','
    for _v in $2; do _v="${_v#"${_v%%[![:space:]]*}"}"; _v="${_v%"${_v##*[![:space:]]}"}"; [[ -n "$_v" ]] && _arr+=("$_v"); done
    return 0
}
need_arg() { [[ $# -ge 2 && -n "$2" ]] || die 1 "Option $1 needs a value (see --help)"; }
is_uint()  { [[ "$1" =~ ^[0-9]+$ ]]; }
is_num()   { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

parse_args() {
    while (( $# )); do
        case "$1" in
            -s|--servers) need_arg "$@"; SERVERS_FILE="$2"; shift ;;
            -u|--uri) need_arg "$@"; S_URI="$2"; shift ;;
            -n|--name) need_arg "$@"; S_NAME="$2"; shift ;;
            --set) need_arg "$@"; S_SETS+=("$2"); shift ;;
            --only) need_arg "$@"; add_list ONLY "$2"; shift ;;
            -o|--output-dir) need_arg "$@"; OUTPUT_DIR="$2"; shift ;;
            --prefix) need_arg "$@"; PREFIX="$2"; shift ;;
            --csv) CSV=1 ;;
            --json) JSON_OUT=1 ;;
            --top) need_arg "$@"; TOP_N="$2"; shift ;;
            --max-collections) need_arg "$@"; MAX_COLLS="$2"; shift ;;
            --include-system) INCLUDE_SYSTEM=1 ;;
            --no-members) MEMBERS=0 ;;
            -q|--quiet) QUIET=1 ;;
            --ssh) SSH_MODE=on ;;
            --no-ssh) SSH_MODE=off ;;
            --ssh-timeout) need_arg "$@"; SSH_TIMEOUT="$2"; shift ;;
            --ssh-accept-new) SSH_ACCEPT_NEW=1 ;;
            --lag-warn) need_arg "$@"; LAG_WARN="$2"; shift ;;
            --lag-crit) need_arg "$@"; LAG_CRIT="$2"; shift ;;
            --oplog-warn) need_arg "$@"; OPLOG_WARN="$2"; shift ;;
            --oplog-crit) need_arg "$@"; OPLOG_CRIT="$2"; shift ;;
            --conn-warn) need_arg "$@"; CONN_WARN="$2"; shift ;;
            --conn-crit) need_arg "$@"; CONN_CRIT="$2"; shift ;;
            --dirty-warn) need_arg "$@"; DIRTY_WARN="$2"; shift ;;
            --dirty-crit) need_arg "$@"; DIRTY_CRIT="$2"; shift ;;
            --cache-warn) need_arg "$@"; CACHE_WARN="$2"; shift ;;
            --disk-warn) need_arg "$@"; DISK_WARN="$2"; shift ;;
            --disk-crit) need_arg "$@"; DISK_CRIT="$2"; shift ;;
            --long-op) need_arg "$@"; LONG_OP="$2"; shift ;;
            --queue-warn) need_arg "$@"; QUEUE_WARN="$2"; shift ;;
            --fail-on) need_arg "$@"; FAIL_ON="$2"; shift ;;
            --timeout) need_arg "$@"; TIMEOUT="$2"; shift ;;
            --max-time) need_arg "$@"; MAXTIME="$2"; shift ;;
            --server-timeout) need_arg "$@"; SERVER_TIMEOUT="$2"; shift ;;
            --dry-run) DRY_RUN=1 ;;
            --keep-workdir) KEEP_WORKDIR=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *) die 1 "Unknown option '$1' (see --help)" ;;
        esac
        shift
    done
    [[ -n "$SERVERS_FILE" && -n "$S_URI" ]] && die 1 "Use either -s FILE or -u URI, not both"
    [[ -z "$SERVERS_FILE" && -z "$S_URI" ]] && die 1 "Give -s SERVERS_FILE or -u URI (see --help)"
    local v
    for v in TOP_N MAX_COLLS TIMEOUT MAXTIME SERVER_TIMEOUT SSH_TIMEOUT LONG_OP QUEUE_WARN LAG_WARN LAG_CRIT; do
        is_uint "${!v}" || die 1 "${v,,} must be a whole number (got '${!v}')"
    done
    for v in OPLOG_WARN OPLOG_CRIT CONN_WARN CONN_CRIT DIRTY_WARN DIRTY_CRIT CACHE_WARN DISK_WARN DISK_CRIT; do
        is_num "${!v}" || die 1 "${v,,} must be a number (got '${!v}')"
    done
    (( TIMEOUT > 0 && MAXTIME > 0 && SERVER_TIMEOUT > 0 )) || die 1 "timeouts must be > 0"
    case "$FAIL_ON" in ''|warn|crit) ;; *) die 1 "--fail-on: warn or crit" ;; esac
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--prefix: letters, digits . _ - only"
    return 0
}

# ---------------------------------------------------------------------------- targets
# TARGETS[i] = name ; TOPTS[i] = "key=value" lines (target=..., rs=..., ...)
TARGETS=(); TOPTS=()
readonly KNOWN_KEYS=" rs authdb user pass_env pass_file authmech tls tlsca tlscert tls_insecure ssh ssh_user ssh_port ssh_key "

add_target() {   # add_target WHERE NAME TARGET [key=value...]
    local where="$1" name="$2" target="$3"; shift 3
    [[ "$name" =~ ^[A-Za-z0-9._@:-]+$ ]] || die 1 "$where: bad name '$name' (letters digits . _ - @ :)"
    [[ "$target" =~ ^(mongodb(\+srv)?://)?[^[:space:]\'\"\`\$\\]+$ ]] || die 1 "$where: bad target '$target'"
    if [[ ! "$target" =~ ^mongodb(\+srv)?:// ]]; then
        [[ "$target" =~ ^[A-Za-z0-9._-]+(:[0-9]+)?(,[A-Za-z0-9._-]+(:[0-9]+)?)*$ ]] || die 1 "$where: '$target' is not host:port[,host:port] or a mongodb:// URI"
    fi
    if [[ "$target" =~ ^mongodb(\+srv)?://[^/@]*:[^/@]*@ ]]; then
        log_warn "$where: '$name' has a password inside the URI - move it to pass_env= or pass_file="
    fi
    local t; for t in "${TARGETS[@]}"; do [[ "$t" == "$name" ]] && die 1 "$where: duplicate name '$name'"; done
    local opts="target=$target" kv k v
    for kv in "$@"; do
        [[ "$kv" == *=* ]] || die 1 "$where: expected key=value, got '$kv'"
        k="${kv%%=*}"; v="${kv#*=}"
        [[ "$KNOWN_KEYS" == *" $k "* ]] || die 1 "$where: unknown key '$k' (known:$KNOWN_KEYS)"
        [[ -n "$v" && "$v" =~ ^[^[:space:]\'\"\`\$\\]+$ ]] || die 1 "$where: bad value for $k"
        case "$k" in
            tls) [[ "$v" == on || "$v" == off ]] || die 1 "$where: tls=on|off" ;;
            tls_insecure) [[ "$v" == on || "$v" == off ]] || die 1 "$where: tls_insecure=on|off" ;;
            pass_env) [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die 1 "$where: pass_env must be a variable name" ;;
            ssh_port) is_uint "$v" || die 1 "$where: ssh_port must be a number" ;;
            pass_file|ssh_key|tlsca|tlscert) [[ "$v" == \~/* ]] && v="$HOME/${v#\~/}" ;;
            ssh) [[ "$v" == auto || "$v" =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+(,([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+)*$ ]] || die 1 "$where: ssh=auto or [user@]host[,..]" ;;
        esac
        opts+=$'\n'"$k=$v"
    done
    TARGETS+=("$name"); TOPTS+=("$opts")
}

load_targets() {
    if [[ -n "$S_URI" ]]; then
        add_target "command line" "${S_NAME:-$(sed -E 's#^mongodb(\+srv)?://##; s#^[^@/]*@##; s#[/?].*##; s#[^A-Za-z0-9._:-]#_#g' <<<"$S_URI" | cut -c1-60)}" "$S_URI" "${S_SETS[@]}"
        return
    fi
    [[ -r "$SERVERS_FILE" ]] || die 1 "Cannot read servers file '$SERVERS_FILE'"
    local line n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1)); line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        line="$(sed -E 's/[[:space:]]+#.*$//' <<<"$line")"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        local -a f=(); read -r -a f <<<"$line"
        (( ${#f[@]} >= 2 )) || die 1 "$SERVERS_FILE:$n: need at least: name uri|host:port"
        add_target "$SERVERS_FILE:$n" "${f[@]}"
    done <"$SERVERS_FILE"
    (( ${#TARGETS[@]} )) || die 1 "$SERVERS_FILE: no servers listed"
}

opt() {   # opt INDEX KEY -> value or ""
    local line
    while IFS= read -r line; do [[ "${line%%=*}" == "$2" ]] && { printf '%s' "${line#*=}"; return 0; }; done <<<"${TOPTS[$1]}"
    return 0
}

selected() {   # selected NAME
    local g; (( ${#ONLY[@]} )) || return 0
    for g in "${ONLY[@]}"; do
        # shellcheck disable=SC2053  # intentional glob match
        [[ "$1" == $g ]] && return 0
    done
    return 1
}

redact() { sed -E 's#^(mongodb(\+srv)?://)[^@/]*@#\1***@#' <<<"$1"; }

# ---------------------------------------------------------------------------- collection
get_password() {   # get_password INDEX -> prints password (may be empty); returns 1 on error
    local pe pf; pe="$(opt "$1" pass_env)"; pf="$(opt "$1" pass_file)"
    if [[ -n "$pe" ]]; then
        [[ -n "${!pe-}" ]] || { echo "environment variable $pe is empty or not set" >&2; return 1; }
        printf '%s' "${!pe}"; return 0
    fi
    if [[ -n "$pf" ]]; then
        pf="${pf/#\~/$HOME}"
        [[ -r "$pf" ]] || { echo "cannot read pass_file $pf" >&2; return 1; }
        local mode; mode="$(stat -c '%a' -- "$pf" 2>/dev/null || echo 600)"
        [[ "$mode" =~ [0-7][0-7]0$ && "$mode" =~ [0-7]0[0-7]$ ]] || echo "pass_file $pf is readable by group/others (chmod 600 it)" >&2
        head -n 1 -- "$pf" | tr -d '\r\n'; return 0
    fi
    return 0
}

collect_server() {   # collect_server INDEX ; writes $WORK/sN/{meta,data}.json
    local i="$1" name="${TARGETS[$1]}" sdir="$WORK/s$1"; mkdir -p "$sdir"
    local target user; target="$(opt "$i" target)"; user="$(opt "$i" user)"
    local ssh; ssh="$(opt "$i" ssh)"
    jq -n --arg name "$name" --arg target "$(redact "$target")" --arg rs "$(opt "$i" rs)" --arg user "$user" \
          --arg authdb "$(opt "$i" authdb)" --arg tls "$(opt "$i" tls)" --arg ssh "$ssh" \
          '{name:$name, target:$target, rs:$rs, user:$user, authdb:(if $authdb == "" and $user != "" then "admin" else $authdb end), tls:$tls, ssh:$ssh}' >"$sdir/meta.json"
    log_info "[$name] $(redact "$target")${user:+ as $user}"
    local pw
    if ! pw="$(get_password "$i" 2>"$sdir/err")"; then
        jq -Rs '{ok:false, errors:{}, error: ("password: " + rtrimstr("\n"))}' "$sdir/err" >"$sdir/data.json"
        log_error "[$name] $(cat "$sdir/err")"; return 0
    fi
    [[ -s "$sdir/err" ]] && log_warn "[$name] $(cat "$sdir/err")"
    local tlsca tlscert; tlsca="$(opt "$i" tlsca)"; tlscert="$(opt "$i" tlscert)"
    tlsca="${tlsca/#\~/$HOME}"; tlscert="${tlscert/#\~/$HOME}"
    local rc=0
    # Everything goes through the environment: no credentials on any command line (ps-safe).
    # HOME points to a throw-away dir so mongosh keeps no history/logs, DO_NOT_TRACK disables telemetry.
    env -u MONGOSH_RC HOME="$WORK/home" DO_NOT_TRACK=1 \
        MHR_URI="$target" MHR_RS="$(opt "$i" rs)" MHR_USER="$user" MHR_PASS="$pw" MHR_AUTHDB="$(opt "$i" authdb)" \
        MHR_AUTHMECH="$(opt "$i" authmech)" MHR_TLS="$(opt "$i" tls)" MHR_TLSCA="$tlsca" MHR_TLSCERT="$tlscert" \
        MHR_TLS_INSECURE="$([[ "$(opt "$i" tls_insecure)" == on ]] && echo 1 || echo 0)" \
        MHR_TIMEOUT="$TIMEOUT" MHR_MAXTIME="$MAXTIME" MHR_LONG_OP="$LONG_OP" MHR_TOP="$TOP_N" MHR_MAX_COLLS="$MAX_COLLS" \
        MHR_INCLUDE_SYSTEM="$INCLUDE_SYSTEM" MHR_MEMBERS="$MEMBERS" \
        timeout --kill-after=10 "$SERVER_TIMEOUT" "$MONGOSH" --nodb --quiet --norc "$LIBDIR/collect.js" \
        >"$sdir/raw.out" 2>"$sdir/raw.err" </dev/null || rc=$?
    pw=""
    if grep -q '^@@MHR_JSON@@' "$sdir/raw.out" && sed -n 's/^@@MHR_JSON@@//p' "$sdir/raw.out" | head -n 1 | jq -e 'type == "object"' >/dev/null 2>&1; then
        sed -n 's/^@@MHR_JSON@@//p' "$sdir/raw.out" | head -n 1 >"$sdir/data.json"
    else
        local why; why="$( { cat "$sdir/raw.err" "$sdir/raw.out"; } | grep -v '^[[:space:]]*$' | tail -n 3 | tr '\n' ' ' | cut -c1-400)"
        (( rc == 124 || rc == 137 )) && why="no answer within --server-timeout ${SERVER_TIMEOUT}s. $why"
        jq -n --arg e "mongosh failed (rc=$rc): ${why:-no output}" '{ok:false, errors:{}, error:$e}' >"$sdir/data.json"
    fi
    if jq -e '.ok' "$sdir/data.json" >/dev/null; then
        log_info "[$name] $(jq -r '"v\(.server.version // "?") " + (if .repl then "replica set \(.repl.set) primary=\(.repl.primary // "NONE")" else "standalone" end) + " · \(.dbs|length) dbs" + (if (.errors|length) > 0 then " · \(.errors|length) section error(s)" else "" end)' "$sdir/data.json")"
    else
        log_error "[$name] $(jq -r .error "$sdir/data.json")"
    fi
    if [[ -n "$ssh" && "$SSH_MODE" != off ]]; then ssh_df "$i" "$sdir"; fi
    return 0
}

# ---------------------------------------------------------------------------- disk free over ssh
ssh_df() {   # ssh_df INDEX SDIR -> SDIR/ssh.json (array)
    local i="$1" sdir="$2" spec; spec="$(opt "$i" ssh)"
    local suser sport skey; suser="$(opt "$i" ssh_user)"; sport="$(opt "$i" ssh_port)"; skey="$(opt "$i" ssh_key)"
    local -a hosts=()
    if [[ "$spec" == auto ]]; then
        if jq -e '.repl.members | length > 0' "$sdir/data.json" >/dev/null 2>&1; then
            # one entry per member (host:port) so each member gets its own dbPath/log dir
            mapfile -t hosts < <(jq -r '.repl.members[].name' "$sdir/data.json")
        else
            local t; t="$(opt "$i" target)"; t="$(sed -E 's#^mongodb(\+srv)?://##; s#^[^@/]*@##; s#[/?].*##; s#,.*##; s#:[0-9]+$##' <<<"$t")"
            hosts=("$t")
        fi
    else
        add_list hosts "$spec"
    fi
    local -a sshopts=(-n -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" -o LogLevel=ERROR)
    (( SSH_ACCEPT_NEW )) && sshopts+=(-o StrictHostKeyChecking=accept-new)
    [[ -n "$sport" ]] && sshopts+=(-p "$sport")
    [[ -n "$skey" ]] && sshopts+=(-i "${skey/#\~/$HOME}")
    local h n=0 parts=()
    for h in "${hosts[@]}"; do
        n=$((n + 1))
        local member="" hn="${h#*@}"
        if [[ "$spec" == auto && "$hn" =~ :[0-9]+$ ]]; then member="$hn"; hn="${hn%:*}"; h="${h%:*}"; fi
        local dest="$h"
        [[ "$h" != *@* && -n "$suser" ]] && dest="$suser@$h"
        # dbPath / log dir of the member on this host (direct member data), else of the connected node
        local paths
        paths="$(jq -r --arg h "$hn" --arg mem "$member" '
            ([.members_direct[]? | select(.ok and (if $mem != "" then .name == $mem else (.name | sub(":[0-9]+$"; "")) == $h end))][0]) as $m
            | ($m // {dbpath: .cmdline.dbpath, logpath: .cmdline.logpath}) as $p
            | [($p.dbpath // empty | "dbPath\t" + .), ($p.logpath // empty | "log\t" + (sub("/[^/]*$"; "") | if . == "" then "/" else . end))] | .[]' "$sdir/data.json" 2>/dev/null)"
        local remote='df -PTk 2>&1; echo @@PATHS'
        local kind p
        while IFS=$'\t' read -r kind p; do
            [[ -n "$p" ]] || continue
            if [[ "$p" == /* ]]; then
                remote+="; echo $(printf '%q' "@@P $kind $p"); df -Pk -- $(printf '%q' "$p") 2>&1 | tail -n 1"
            else   # relative to mongod's working directory, which we cannot know remotely
                remote+="; echo $(printf '%q' "@@P $kind $p"); echo relative path - not checked"
            fi
        done <<<"$paths"
        log_debug "[${TARGETS[$i]}] ssh $dest: $remote"
        local o="$sdir/ssh$n.out" e="$sdir/ssh$n.err" rc=0
        timeout $((SSH_TIMEOUT + 20)) ssh "${sshopts[@]}" -- "$dest" "$remote" >"$o" 2>"$e" </dev/null || rc=$?
        if (( rc != 0 )) || ! grep -q '^@@PATHS' "$o"; then
            jq -n --arg host "$hn" --arg dest "$dest" --arg e "ssh rc=$rc: $(tr '\n' ' ' <"$e" | cut -c1-300)" \
               '{host:$host, dest:$dest, ok:false, error:$e}' >"$sdir/ssh$n.json"
            log_warn "[${TARGETS[$i]}] df over ssh to $dest failed (rc=$rc)"
        else
            awk -v host="$hn" -v dest="$dest" -v member="$member" '
                function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return "\"" s "\"" }
                BEGIN { sec = 0; nm = 0; np = 0 }
                /^@@PATHS/ { sec = 1; next }
                sec == 0 && $1 != "Filesystem" && NF >= 7 {
                    if ($2 ~ /^(tmpfs|devtmpfs|squashfs|overlay|efivarfs|proc|sysfs|cgroup2?)$/) next
                    mnt = $7; for (k = 8; k <= NF; k++) mnt = mnt " " $k
                    pc = $6; sub(/%/, "", pc)
                    m[++nm] = sprintf("{\"fs\":%s,\"type\":%s,\"size_kb\":%d,\"used_kb\":%d,\"avail_kb\":%d,\"pct\":%s,\"mount\":%s}", js($1), js($2), $3, $4, $5, (pc ~ /^[0-9]+$/ ? pc : "null"), js(mnt))
                    next }
                sec == 1 && /^@@P / { kind = $2; path = substr($0, length("@@P " kind " ") + 1); want = 1; next }
                sec == 1 && want == 1 {
                    want = 0
                    if (NF >= 6 && $5 ~ /%$/) { pc = $5; sub(/%/, "", pc); mnt = $6; for (k = 7; k <= NF; k++) mnt = mnt " " $k
                        p[++np] = sprintf("{\"kind\":%s,\"path\":%s,\"mount\":%s,\"pct\":%s,\"avail_kb\":%d}", js(kind), js(path), js(mnt), pc, $4) }
                    else p[++np] = sprintf("{\"kind\":%s,\"path\":%s,\"error\":%s}", js(kind), js(path), js($0)) }
                END {
                    printf "{\"host\":%s,\"member\":%s,\"dest\":%s,\"ok\":true,\"mounts\":[", js(host), (member == "" ? "null" : js(member)), js(dest)
                    for (k = 1; k <= nm; k++) printf "%s%s", (k > 1 ? "," : ""), m[k]
                    printf "],\"paths\":["
                    for (k = 1; k <= np; k++) printf "%s%s", (k > 1 ? "," : ""), p[k]
                    printf "]}\n" }' "$o" >"$sdir/ssh$n.json"
            jq -e . "$sdir/ssh$n.json" >/dev/null 2>&1 || jq -n --arg host "$hn" --arg dest "$dest" '{host:$host, dest:$dest, ok:false, error:"could not parse df output"}' >"$sdir/ssh$n.json"
        fi
        parts+=("$sdir/ssh$n.json")
    done
    if (( ${#parts[@]} )); then jq -s '.' "${parts[@]}" >"$sdir/ssh.json"; fi
    return 0
}

# ---------------------------------------------------------------------------- report
assemble() {   # -> $WORK/servers.json
    local d parts=()
    for d in "$WORK"/s*; do
        [[ -f "$d/ssh.json" ]] || echo 'null' >"$d/ssh.json"
        jq -n --slurpfile m "$d/meta.json" --slurpfile x "$d/data.json" --slurpfile s "$d/ssh.json" \
           '$m[0] + {data: $x[0], ssh: $s[0]}' >"$d/server.json"
        parts+=("$d/server.json")
    done
    jq -s '.' "${parts[@]}" >"$WORK/servers.json"
}

render() {   # render MODE OUTFILE|-
    if [[ "$2" == - ]]; then
        jq -r --arg mode "$1" --slurpfile cfg "$WORK/cfg.json" --slurpfile S "$WORK/servers.json" -n -f "$LIBDIR/report.jq"
    else
        jq -r --arg mode "$1" --slurpfile cfg "$WORK/cfg.json" --slurpfile S "$WORK/servers.json" -n -f "$LIBDIR/report.jq" >"$2.part" && mv -f -- "$2.part" "$2"
    fi
}

main() {
    parse_args "$@"
    load_targets
    local -a sel=(); local i
    for i in "${!TARGETS[@]}"; do selected "${TARGETS[$i]}" && sel+=("$i"); done
    (( ${#sel[@]} )) || die 1 "--only matched no targets"
    if [[ "$SSH_MODE" == on ]]; then
        local any=0; for i in "${sel[@]}"; do [[ -n "$(opt "$i" ssh)" ]] && any=1; done
        (( any )) || log_warn "--ssh given but no selected target has ssh=... (see servers.conf.example)"
    fi
    if (( DRY_RUN )); then
        printf 'Targets (%d of %d):\n' "${#sel[@]}" "${#TARGETS[@]}"
        for i in "${sel[@]}"; do
            printf '  %-20s %s\n' "${TARGETS[$i]}" "$(redact "$(opt "$i" target)")"
            local k; for k in rs user authdb authmech pass_env pass_file tls tlsca tlscert tls_insecure ssh ssh_user ssh_port ssh_key; do
                [[ -n "$(opt "$i" "$k")" ]] && printf '  %-20s   %s=%s\n' "" "$k" "$(opt "$i" "$k")"
            done
        done
        printf 'No connections made (--dry-run).\n'; exit 0
    fi
    command -v "$MONGOSH" >/dev/null || die 2 "mongosh not found (see README: install mongodb-mongosh from the MongoDB yum repo)"
    command -v jq >/dev/null || die 2 "jq not found (sudo dnf install -y jq  /  sudo yum install -y jq)"
    command -v timeout >/dev/null || die 2 "timeout (coreutils) not found"
    [[ -r "$LIBDIR/collect.js" && -r "$LIBDIR/report.jq" ]] || die 2 "lib/collect.js or lib/report.jq missing in $LIBDIR"
    if [[ "$SSH_MODE" != off ]]; then
        for i in "${sel[@]}"; do [[ -n "$(opt "$i" ssh)" ]] && { command -v ssh >/dev/null || die 2 "ssh= is set but no ssh client (use --no-ssh)"; break; }; done
    fi
    { mkdir -p -- "$OUTPUT_DIR" && [[ -w "$OUTPUT_DIR" ]]; } || die 4 "Cannot write to '$OUTPUT_DIR'"

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/mongohealth.XXXXXX")"
    mkdir -p "$WORK/home"
    # shellcheck disable=SC2154,SC2016
    trap '(( KEEP_WORKDIR )) && log_info "workdir kept: $WORK" || rm -rf -- "$WORK"' EXIT
    trap 'exit 130' INT TERM

    for i in "${sel[@]}"; do collect_server "$i"; done
    assemble
    local now; now="$(date -u +%s)"; now="${MONGO_HEALTH_NOW:-$now}"
    jq -n --argjson now "$now" --arg ver "$SCRIPT_VERSION" --arg host "$(hostname 2>/dev/null || echo '?')" \
          --argjson lw "$LAG_WARN" --argjson lc "$LAG_CRIT" --argjson ow "$OPLOG_WARN" --argjson oc "$OPLOG_CRIT" \
          --argjson cw "$CONN_WARN" --argjson cc "$CONN_CRIT" --argjson dw "$DIRTY_WARN" --argjson dc "$DIRTY_CRIT" \
          --argjson kw "$CACHE_WARN" --argjson sw "$DISK_WARN" --argjson sc "$DISK_CRIT" --argjson lo "$LONG_OP" \
          --argjson qw "$QUEUE_WARN" --argjson top "$TOP_N" \
          '{now:$now, version:$ver, runner:$host, top:$top,
            t:{lag_warn:$lw, lag_crit:$lc, oplog_warn:$ow, oplog_crit:$oc, conn_warn:$cw, conn_crit:$cc,
               dirty_warn:$dw, dirty_crit:$dc, cache_warn:$kw, disk_warn:$sw, disk_crit:$sc, long_op:$lo, queue_warn:$qw}}' >"$WORK/cfg.json"

    local stamp base; stamp="$(date -u -d "@$now" +%Y%m%d_%H%M%S)"; base="$OUTPUT_DIR/${PREFIX}_${stamp}"
    render html "$base.html" || die 4 "HTML render failed"; WRITTEN+=("$base.html")
    if (( CSV )); then
        render csv_summary "${base}_summary.csv" || die 4 "CSV render failed"
        render csv_flags "${base}_flags.csv" || die 4 "CSV render failed"
        WRITTEN+=("${base}_summary.csv" "${base}_flags.csv")
    fi
    if (( JSON_OUT )); then render json "$base.json" || die 4 "JSON render failed"; WRITTEN+=("$base.json"); fi
    render text - || die 4 "text render failed"
    printf 'Wrote: %s\n' "${WRITTEN[@]}" >&2

    local reach; reach="$(jq '[.[] | select(.data.ok)] | length' "$WORK/servers.json")"
    (( reach > 0 )) || { log_error "No server could be reached (see report)"; exit 3; }
    if [[ -n "$FAIL_ON" ]]; then
        local worst; worst="$(render worst -)"
        if [[ "$worst" == CRIT || ( "$FAIL_ON" == warn && "$worst" == WARN ) ]]; then exit 5; fi
    fi
    return 0
}

main "$@"
