#!/usr/bin/env bash
#
# aurora_pg_check.sh - read-only health checks for Amazon Aurora PostgreSQL clusters
#                      using the AWS CLI v2 (describe-*/list-*/get-* calls only).
#
# Groups: cluster, versions, config, backups, metrics (CloudWatch), events.
# Output: text | json | html, to stdout or a file. Optional e-mail / webhook alerts.
# Exit:   0 OK, 10 WARN, 11 CRIT, 1 usage, 2 pre-check, 3 AWS call failure(s), 4 output, 130 interrupted.
#
# Check logic lives in lib/checks.jq, report rendering in lib/render.jq.
# The script never modifies AWS resources.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIB_DIR="${AURORA_PG_CHECK_LIB:-$SCRIPT_DIR/lib}"
readonly ALL_GROUPS="cluster versions config backups metrics events"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
PROFILE=""
REGIONS=()
ALL_REGIONS=0
CLUSTERS=()
CHECKS=()
EXCLUDE_CHECKS=()
LOOKBACK="24h"
PERIOD=300
FORMAT="text"
OUTPUT=""
ONLY_PROBLEMS=0
DETAILS=0
LOG_FILE=""
CONFIG_FILE=""
AWS_TIMEOUT=30
MAX_ATTEMPTS=5
KEEP_WORKDIR=0
DRY_RUN=0
VERBOSE=0
LIST_THRESHOLDS=0
ALERT_EMAILS=()
ALERT_WEBHOOKS=()
ALERT_ON="warn"
ALERT_WEBHOOK_FORMAT="slack"
ALERT_FROM=""
ALERT_TEST=0

# key  default  description   (metric thresholds compare the folded value with ">" / "<")
readonly TH_SPEC='
min_readers                 1           cluster: WARN if fewer reader instances
min_azs                     2           cluster: WARN if instances span fewer AZs (capped at instance count)
support_warn_days           180         versions: WARN when Aurora standard support of the major ends within N days
minor_behind_warn           0           versions: WARN if N+ newer minor versions exist (0 = report only)
maint_crit_days             7           versions: CRIT if a pending action is auto-applied within N days
require_auto_minor_upgrade  1           versions: 1 = WARN when auto minor version upgrade is off, 0 = INFO
cert_warn_days              60          versions: WARN if CA/server certificate expires within N days
cert_crit_days              14          versions: CRIT if it expires within N days
require_iam_auth            0           config: 1 = WARN when IAM DB authentication is off
public_access_crit          0           config: 1 = publicly accessible instance is CRIT instead of WARN
pi_min_retention_days       7           config: WARN if Performance Insights retention is shorter
em_max_interval             60          config: WARN if enhanced monitoring is off or coarser (seconds)
backup_retention_warn       7           backups: WARN if retention (days) below
backup_retention_crit       3           backups: CRIT if retention (days) below
restore_lag_warn_min        15          backups: WARN if LatestRestorableTime lags more (minutes)
restore_lag_crit_min        60          backups: CRIT above (minutes)
auto_snapshot_warn_hours    26          backups: WARN if newest automated snapshot is older (hours)
auto_snapshot_crit_hours    50          backups: CRIT above (hours)
manual_snapshot_max_age_days 0          backups: WARN if no manual snapshot newer than N days (0 = off)
manual_snapshot_count_warn  80          backups: WARN if a cluster has more manual snapshots
cpu_warn                    80          metrics: CPUUtilization peak period average (%)
cpu_crit                    95
mem_free_warn_mb            1024        metrics: FreeableMemory minimum (MiB, low = bad)
mem_free_crit_mb            256
max_connections             0           metrics: force max_connections (0 = derive from parameter group)
conn_pct_warn               80          metrics: DatabaseConnections peak as % of max_connections
conn_pct_crit               95
conn_warn                   0           metrics: absolute connection thresholds when max is unknown (0 = off)
conn_crit                   0
replica_lag_warn_ms         1000        metrics: AuroraReplicaLag / AuroraReplicaLagMaximum (ms)
replica_lag_crit_ms         10000
local_storage_warn_mb       10240       metrics: FreeLocalStorage minimum (MiB, low = bad)
local_storage_crit_mb       2048
disk_queue_warn             20          metrics: DiskQueueDepth peak period average
disk_queue_crit             100
read_latency_warn_ms        20          metrics: ReadLatency peak period average (ms)
read_latency_crit_ms        100
write_latency_warn_ms       20          metrics: WriteLatency peak period average (ms)
write_latency_crit_ms       100
deadlocks_warn              0           metrics: Deadlocks peak rate (/s); 0 = any deadlock warns
deadlocks_crit              0.1
cache_hit_warn              95          metrics: BufferCacheHitRatio lowest period average (%, low = bad)
cache_hit_crit              90
xid_warn                    500000000   metrics: MaximumUsedTransactionIDs (wraparound at ~2.1B)
xid_crit                    1000000000
txlog_warn_mb               10240       metrics: TransactionLogsDiskUsage (MiB)
txlog_crit_mb               51200
slot_disk_warn_mb           10240       metrics: ReplicationSlotDiskUsage (MiB)
slot_disk_crit_mb           51200
slot_lag_warn_mb            1024        metrics: OldestReplicationSlotLag (MiB)
slot_lag_crit_mb            10240
acu_util_warn               90          metrics: ACUUtilization peak (% of max ACU, serverless v2)
acu_util_crit               99
failover_crit_count         4           events: CRIT if more failover events in the window (one failover logs ~2)
events_show                 10          events: number of recent events listed in details
'
declare -A TH=() TH_DESC=()
TH_KEYS=()
while read -r _k _v _d; do
    [[ -n "$_k" ]] || continue
    TH[$_k]="$_v"; TH_DESC[$_k]="$_d"; TH_KEYS+=("$_k")
done <<<"$TH_SPEC"
unset _k _v _d

# runtime state
WORK=""
ACCOUNT="-"
CALLER_ARN="-"
AWS_CALLS=0
AWS_FAILS=0
NOW=0
LOOKBACK_S=0
EV_LOOKBACK_S=0
GROUPS_ON=()
FOUND_CLUSTERS=()
REPORT=""

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() {
    local level="$1"; shift
    local line
    line="$(_ts) [$level] $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
}
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local code="$1"; shift; log_error "$@"; exit "$code"; }

# ----------------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------------
usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - read-only Aurora PostgreSQL health checks via the AWS CLI v2

Usage: $SCRIPT_NAME [options]

Scope:
  -P, --profile NAME          AWS CLI profile (SSO profiles: run 'aws sso login' first)
  -r, --region REGION         Region(s) to check; repeatable or comma-separated
                              (default: AWS_REGION / AWS_DEFAULT_REGION / profile region)
  -A, --all-regions           Check every region enabled for the account
  -c, --cluster ID            Cluster identifier(s); repeatable or comma-separated
                              (default: every aurora-postgresql cluster in the region(s))
  -C, --checks LIST           Groups to run: $(tr ' ' ',' <<<"$ALL_GROUPS") (default: all)
  -X, --exclude-checks LIST   Groups to skip
  -L, --lookback DUR          Metric/event window, e.g. 90m, 6h, 2d (bare number = hours; default: 24h;
                              events are capped at 14d by RDS)
      --period SEC            CloudWatch period, multiple of 60 (default: 300)

Thresholds:
  -s, --set KEY=VALUE         Override a threshold; repeatable (config: KEY=VALUE)
      --list-thresholds       Print every threshold, its value and meaning, then exit

Output:
  -f, --format FMT            text | json | html                       (default: text)
  -o, --output FILE           Write the report to FILE instead of stdout
  -q, --only-problems         Text: show only WARN/CRIT/ERROR rows (summary always shown)
  -D, --details               Text: show detail lines for every row (default: problems only)
  -l, --log-file FILE         Append log lines to FILE (logs always go to stderr too)

Alerts:
      --alert-email ADDR      Mail the problem report to ADDR (mail/mailx/sendmail) [repeatable]
      --alert-webhook URL     POST the report as JSON via curl                    [repeatable]
      --alert-webhook-format F  slack ({"text": ...}; Slack/Teams/Google Chat) | json (default: slack)
      --alert-on WHEN         warn (WARN/CRIT/ERROR) | crit (CRIT/ERROR) | always  (default: warn)
      --alert-from ADDR       From address for e-mail alerts
      --alert-test            Send a test alert and exit (no AWS calls)

Behaviour:
      --config FILE           Load key=value settings (CLI options override them)
      --aws-timeout SEC       AWS CLI connect/read timeout per call         (default: 30)
      --max-attempts N        AWS CLI retry attempts (AWS_MAX_ATTEMPTS)     (default: 5)
      --keep-workdir          Keep the raw AWS JSON responses (debugging)
      --dry-run               Validate options, print the AWS calls that would run, exit
  -v, --verbose               Debug logging (each AWS call)
  -h, --help                  Show this help
  -V, --version               Show version

Exit codes: 0 OK, 10 WARN, 11 CRIT, 1 usage, 2 pre-check (aws/jq missing, bad credentials),
            3 AWS call failure(s) and no CRIT, 4 output/internal error, 130 interrupted.
Precedence when several apply: CRIT (11) > AWS failure (3) > WARN (10) > OK (0).
USAGE
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
add_list() {   # add_list ARRAY_NAME "a,b, c"
    local -n _arr="$1"
    local _item
    local -a _parts
    IFS=',' read -r -a _parts <<<"$2"
    for _item in "${_parts[@]}"; do
        _item="${_item#"${_item%%[![:space:]]*}"}"
        _item="${_item%"${_item##*[![:space:]]}"}"
        [[ -n "$_item" ]] && _arr+=("$_item")
    done
    return 0
}
is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
redact_url() {
    if [[ "$1" =~ ^([a-zA-Z]+://[^/]+) ]]; then printf '%s/...' "${BASH_REMATCH[1]}"; else printf '<webhook>'; fi
}
group_on() { [[ " ${GROUPS_ON[*]} " == *" $1 "* ]]; }
json_array() { if (( $# )); then printf '%s\n' "$@" | jq -R . | jq -cs .; else printf '[]'; fi; }

parse_duration() {   # parse_duration 90m|6h|2d|1w|3600s|24 -> seconds on stdout
    local v="${1,,}"
    [[ "$v" =~ ^([0-9]+)([smhdw]?)$ ]] || return 1
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]:-h}"
    case "$u" in s) echo "$n" ;; m) echo $(( n * 60 )) ;; h) echo $(( n * 3600 )) ;; d) echo $(( n * 86400 )) ;; w) echo $(( n * 604800 )) ;; esac
}
human_secs() {
    local s="$1"
    if (( s % 86400 == 0 )); then echo "$(( s / 86400 ))d"; elif (( s % 3600 == 0 )); then echo "$(( s / 3600 ))h"
    elif (( s % 60 == 0 )); then echo "$(( s / 60 ))m"; else echo "${s}s"; fi
}
iso_utc() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

set_threshold() {   # set_threshold KEY=VALUE <origin>
    local kv="$1" origin="$2" k v
    [[ "$kv" == *=* ]] || die 1 "$origin: expected KEY=VALUE, got '$kv'"
    k="${kv%%=*}"; v="${kv#*=}"; k="${k,,}"
    [[ -n "${TH[$k]+x}" ]] || die 1 "$origin: unknown threshold '$k' (see --list-thresholds)"
    [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 1 "$origin: threshold '$k' must be a non-negative number, got '$v'"
    TH["$k"]="$v"
}
th_json() {
    local k out="{" sep=""
    for k in "${TH_KEYS[@]}"; do out+="$sep\"$k\":${TH[$k]}"; sep=","; done
    printf '%s}' "$out"
}

# ----------------------------------------------------------------------------
# Config file: key=value, parsed (never sourced). Threshold keys allowed directly.
# ----------------------------------------------------------------------------
load_config() {
    local file="$1" line key val lineno=0
    [[ -r "$file" ]] || die 1 "Config file not readable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$(( lineno + 1 ))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
            || die 1 "Config $file:$lineno: invalid line (expected key=value)"
        key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"([^\"]*)\" || "$val" =~ ^\'([^\']*)\' ]]; then
            val="${BASH_REMATCH[1]}"
        else
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        case "$key" in
            profile)                PROFILE="$val" ;;
            region|regions)         REGIONS=(); add_list REGIONS "$val" ;;
            all_regions)            if is_true "$val"; then ALL_REGIONS=1; else ALL_REGIONS=0; fi ;;
            cluster|clusters)       CLUSTERS=(); add_list CLUSTERS "$val" ;;
            checks)                 CHECKS=(); add_list CHECKS "$val" ;;
            exclude_checks)         EXCLUDE_CHECKS=(); add_list EXCLUDE_CHECKS "$val" ;;
            lookback)               LOOKBACK="$val" ;;
            period)                 PERIOD="$val" ;;
            format)                 FORMAT="$val" ;;
            output)                 OUTPUT="$val" ;;
            only_problems)          if is_true "$val"; then ONLY_PROBLEMS=1; else ONLY_PROBLEMS=0; fi ;;
            details)                if is_true "$val"; then DETAILS=1; else DETAILS=0; fi ;;
            log_file)               LOG_FILE="$val" ;;
            aws_timeout)            AWS_TIMEOUT="$val" ;;
            max_attempts)           MAX_ATTEMPTS="$val" ;;
            verbose)                if is_true "$val"; then VERBOSE=1; else VERBOSE=0; fi ;;
            alert_email|alert_emails)     ALERT_EMAILS=(); add_list ALERT_EMAILS "$val" ;;
            alert_webhook|alert_webhooks) ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$val" ;;
            alert_webhook_format)   ALERT_WEBHOOK_FORMAT="$val" ;;
            alert_on)               ALERT_ON="$val" ;;
            alert_from)             ALERT_FROM="$val" ;;
            aws_access_key_id|aws_secret_access_key|aws_session_token|secret|password)
                die 1 "Config $file:$lineno: credentials are not accepted here; use an AWS CLI profile / SSO / instance role" ;;
            *)  if [[ -n "${TH[$key]+x}" ]]; then set_threshold "$key=$val" "Config $file:$lineno"
                else die 1 "Config $file:$lineno: unknown key '$key'"; fi ;;
        esac
    done <"$file"
}

# ----------------------------------------------------------------------------
# Arguments ("-x val", "--opt val", "--opt=val"); CLI overrides the config file.
# ----------------------------------------------------------------------------
parse_args() {
    local i
    for (( i = 1; i <= $#; i++ )); do        # find --config first
        case "${!i}" in
            --config=*) CONFIG_FILE="${!i#--config=}" ;;
            --config)   local j=$(( i + 1 )); (( j <= $# )) || die 1 "Option --config requires a value"; CONFIG_FILE="${!j}" ;;
        esac
    done
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"
    local cli_r=0 cli_c=0 cli_ae=0 cli_aw=0 cli_ck=0 cli_xk=0 opt
    while (( $# )); do
        opt="$1"
        if [[ "$opt" == --*=* ]]; then set -- "${opt%%=*}" "${opt#*=}" "${@:2}"; opt="$1"; fi
        case "$opt" in
            -P|--profile)        need_arg "$opt" $#; PROFILE="$2"; shift 2 ;;
            -r|--region)         need_arg "$opt" $#; (( cli_r++ )) || REGIONS=(); add_list REGIONS "$2"; shift 2 ;;
            -A|--all-regions)    ALL_REGIONS=1; shift ;;
            -c|--cluster)        need_arg "$opt" $#; (( cli_c++ )) || CLUSTERS=(); add_list CLUSTERS "$2"; shift 2 ;;
            -C|--checks)         need_arg "$opt" $#; (( cli_ck++ )) || CHECKS=(); add_list CHECKS "$2"; shift 2 ;;
            -X|--exclude-checks) need_arg "$opt" $#; (( cli_xk++ )) || EXCLUDE_CHECKS=(); add_list EXCLUDE_CHECKS "$2"; shift 2 ;;
            -L|--lookback)       need_arg "$opt" $#; LOOKBACK="$2"; shift 2 ;;
            --period)            need_arg "$opt" $#; PERIOD="$2"; shift 2 ;;
            -s|--set)            need_arg "$opt" $#; set_threshold "$2" "--set"; shift 2 ;;
            --list-thresholds)   LIST_THRESHOLDS=1; shift ;;
            -f|--format)         need_arg "$opt" $#; FORMAT="$2"; shift 2 ;;
            -o|--output)         need_arg "$opt" $#; OUTPUT="$2"; shift 2 ;;
            -q|--only-problems)  ONLY_PROBLEMS=1; shift ;;
            -D|--details)        DETAILS=1; shift ;;
            -l|--log-file)       need_arg "$opt" $#; LOG_FILE="$2"; shift 2 ;;
            --config)            shift 2 ;;
            --aws-timeout)       need_arg "$opt" $#; AWS_TIMEOUT="$2"; shift 2 ;;
            --max-attempts)      need_arg "$opt" $#; MAX_ATTEMPTS="$2"; shift 2 ;;
            --keep-workdir)      KEEP_WORKDIR=1; shift ;;
            --dry-run)           DRY_RUN=1; shift ;;
            -v|--verbose)        VERBOSE=1; shift ;;
            --alert-email)       need_arg "$opt" $#; (( cli_ae++ )) || ALERT_EMAILS=(); add_list ALERT_EMAILS "$2"; shift 2 ;;
            --alert-webhook)     need_arg "$opt" $#; (( cli_aw++ )) || ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$2"; shift 2 ;;
            --alert-webhook-format) need_arg "$opt" $#; ALERT_WEBHOOK_FORMAT="$2"; shift 2 ;;
            --alert-on)          need_arg "$opt" $#; ALERT_ON="$2"; shift 2 ;;
            --alert-from)        need_arg "$opt" $#; ALERT_FROM="$2"; shift 2 ;;
            --alert-test)        ALERT_TEST=1; shift ;;
            -h|--help)           usage; exit 0 ;;
            -V|--version)        echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *)                   die 1 "Unknown option: $opt (see --help)" ;;
        esac
    done
}

validate() {
    local g
    command -v jq >/dev/null 2>&1 || die 2 "jq not found in PATH (install jq 1.6+)"
    FORMAT="${FORMAT,,}"
    case "$FORMAT" in text|json|html) ;; *) die 1 "--format must be text, json or html" ;; esac
    LOOKBACK_S="$(parse_duration "$LOOKBACK")" || die 1 "Invalid --lookback '$LOOKBACK' (e.g. 90m, 6h, 2d)"
    if [[ ! "$PERIOD" =~ ^[0-9]+$ ]] || (( PERIOD < 60 || PERIOD % 60 != 0 )); then die 1 "--period must be a multiple of 60 seconds"; fi
    (( LOOKBACK_S >= PERIOD )) || die 1 "--lookback must be at least one --period"
    (( LOOKBACK_S <= 63 * 86400 )) || die 1 "--lookback is limited to 63d (CloudWatch keeps 5-minute data for 63 days)"
    (( PERIOD < 300 && LOOKBACK_S > 15 * 86400 )) && log_warn "CloudWatch keeps 1-minute data for 15 days only; use --period 300 or more"
    EV_LOOKBACK_S=$LOOKBACK_S
    if (( EV_LOOKBACK_S > 14 * 86400 )); then EV_LOOKBACK_S=$(( 14 * 86400 )); log_info "Events lookback capped at 14d (RDS event retention)"; fi
    if [[ ! "$AWS_TIMEOUT" =~ ^[0-9]+$ ]] || (( AWS_TIMEOUT == 0 )); then die 1 "--aws-timeout must be a positive integer"; fi
    if [[ ! "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || (( MAX_ATTEMPTS == 0 )); then die 1 "--max-attempts must be a positive integer"; fi
    (( ALL_REGIONS && ${#REGIONS[@]} )) && die 1 "Use either --region or --all-regions, not both"
    local r c
    for r in "${REGIONS[@]}"; do [[ "$r" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die 1 "Invalid region: $r"; done
    for c in "${CLUSTERS[@]}"; do
        [[ "$c" =~ ^[A-Za-z][A-Za-z0-9-]{0,62}$ || "$c" =~ ^arn:aws[a-z-]*:rds:[a-z0-9-]+:[0-9]{12}:cluster:[A-Za-z0-9-]+$ ]] \
            || die 1 "Invalid cluster identifier: $c"
    done
    [[ -z "$PROFILE" || "$PROFILE" =~ ^[A-Za-z0-9_.+@-]+$ ]] || die 1 "Invalid profile name: $PROFILE"
    for g in "${CHECKS[@]}" "${EXCLUDE_CHECKS[@]}"; do
        [[ "$g" == all || " $ALL_GROUPS " == *" ${g,,} "* ]] || die 1 "Unknown check group '$g' (valid: $ALL_GROUPS)"
    done
    GROUPS_ON=()
    for g in $ALL_GROUPS; do
        if (( ${#CHECKS[@]} )) && [[ " ${CHECKS[*],,} " != *" $g "* && " ${CHECKS[*],,} " != *" all "* ]]; then continue; fi
        [[ " ${EXCLUDE_CHECKS[*],,} " == *" $g "* ]] && continue
        GROUPS_ON+=("$g")
    done
    (( ${#GROUPS_ON[@]} )) || die 1 "No check groups left to run"
    case "${ALERT_ON,,}" in warn|crit|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be warn, crit or always" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be slack or json" ;; esac
    local a
    for a in "${ALERT_EMAILS[@]}"; do
        [[ "$a" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $a"
    done
    for a in "${ALERT_WEBHOOKS[@]}"; do [[ "$a" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$a")"; done
    local pair w c
    for pair in backup_retention cert:days restore_lag:min auto_snapshot:hours cpu replica_lag:ms xid; do
        if [[ "$pair" == *:* ]]; then w="${pair%%:*}_warn_${pair#*:}"; c="${pair%%:*}_crit_${pair#*:}"
        else w="${pair}_warn"; c="${pair}_crit"; fi
        if [[ "$pair" == backup_retention || "$pair" == cert:days ]]; then   # low-is-bad pairs: crit <= warn
            jq -en --argjson w "${TH[$w]}" --argjson c "${TH[$c]}" '$c <= $w' >/dev/null || die 1 "$c must be <= $w"
        else
            jq -en --argjson w "${TH[$w]}" --argjson c "${TH[$c]}" '$c >= $w' >/dev/null || die 1 "$c must be >= $w"
        fi
    done
    if [[ -n "$OUTPUT" ]]; then
        [[ -d "$(dirname -- "$OUTPUT")" ]] || die 1 "Output directory does not exist: $(dirname -- "$OUTPUT")"
    fi
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then
        touch -- "$LOG_FILE" 2>/dev/null || die 1 "Cannot write log file: $LOG_FILE"
    fi
}

# ----------------------------------------------------------------------------
# AWS CLI access (read-only operations only)
# ----------------------------------------------------------------------------
aws_base() {   # aws_base <region> -> fills global AWS_CMD
    AWS_CMD=(aws --output json --no-cli-pager --cli-connect-timeout "$AWS_TIMEOUT" --cli-read-timeout "$AWS_TIMEOUT")
    [[ -n "$PROFILE" ]] && AWS_CMD+=(--profile "$PROFILE")
    [[ -n "$1" ]] && AWS_CMD+=(--region "$1")
    return 0
}

record_error() {   # record_error <dir> <key> <message>
    local f="$1/errors.json"
    jq --arg k "$2" --arg v "$3" '. + {($k): $v}' "$f" >"$f.tmp" && mv -f -- "$f.tmp" "$f"
}

# aws_call <outfile> <errkey> <region> <service> <operation> [args...]
# errkey "opt:..." marks an optional enrichment call: failures are logged, not counted.
aws_call() {
    local out="$1" key="$2" region="$3"; shift 3
    local msg rc=0
    aws_base "$region"
    AWS_CALLS=$(( AWS_CALLS + 1 ))
    log_debug "[$region] aws $*"
    "${AWS_CMD[@]}" "$@" >"$out" 2>"$out.err" || rc=$?
    if (( rc == 0 )) && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    msg="$(tr -s '\n' ' ' <"$out.err" | sed -E 's/^ +//; s/ +$//; s/aws: \[ERROR\]: //g')"
    [[ -n "$msg" ]] || msg="exit $rc, invalid or empty JSON output"
    (( ${#msg} > 400 )) && msg="${msg:0:400}..."
    if [[ "$key" == opt:* ]]; then
        log_warn "[$region] optional call 'aws $1 $2' failed (rc=$rc): $msg"
    else
        AWS_FAILS=$(( AWS_FAILS + 1 ))
        log_error "[$region] 'aws $1 $2' failed (rc=$rc): $msg"
    fi
    [[ -d "$WORK/$region" ]] && record_error "$WORK/$region" "$key" "$msg"
    return 1
}

precheck() {
    command -v aws >/dev/null 2>&1 || die 2 "AWS CLI not found in PATH (install AWS CLI v2)"
    command -v jq  >/dev/null 2>&1 || die 2 "jq not found in PATH (install jq 1.6+)"
    local v
    v="$(jq --version 2>/dev/null || true)"
    [[ "$v" =~ ^jq-1\.([6-9]|[1-9][0-9]) ]] || die 2 "jq 1.6 or newer required (found ${v:-unknown})"
    v="$(aws --version 2>&1 || true)"
    [[ "$v" =~ aws-cli/([0-9]+) ]] || die 2 "Cannot determine AWS CLI version: ${v%%$'\n'*}"
    (( BASH_REMATCH[1] >= 2 )) || die 2 "AWS CLI v2 required (found ${v%% *})"
    log_debug "using ${v%% *} and $(jq --version)"
    [[ -r "$LIB_DIR/checks.jq" && -r "$LIB_DIR/render.jq" ]] || die 2 "Library files missing in $LIB_DIR"
}

resolve_regions() {
    if (( ${#REGIONS[@]} == 0 )); then
        local r="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
        if [[ -z "$r" ]]; then
            local -a p=(); [[ -n "$PROFILE" ]] && p=(--profile "$PROFILE")
            r="$(aws configure get region "${p[@]}" 2>/dev/null || true)"
        fi
        if (( ALL_REGIONS )); then BASE_REGION="${r:-us-east-1}"; return 0; fi
        [[ -n "$r" ]] || die 1 "No region: use --region, --all-regions, AWS_REGION or a profile with a region"
        REGIONS=("$r")
    fi
    BASE_REGION="${REGIONS[0]}"
}

check_credentials() {
    local out="$WORK/sts.json"
    mkdir -p "$WORK/_global"
    if ! aws_call "$out" sts "$BASE_REGION" sts get-caller-identity; then
        local msg; msg="$(tr -s '\n' ' ' <"$out.err" | sed -E 's/aws: \[ERROR\]: //g; s/^ +//; s/ +$//')"
        if [[ "$msg" == *[Ss][Ss][Oo]* || "$msg" == *[Ee]xpired* ]]; then
            msg+=" (SSO/temporary credentials: run 'aws sso login${PROFILE:+ --profile $PROFILE}' or refresh them)"
        fi
        die 2 "AWS credentials check failed (sts get-caller-identity): $msg"
    fi
    ACCOUNT="$(jq -r '.Account // "-"' "$out")"
    CALLER_ARN="$(jq -r '.Arn // "-"' "$out")"
    log_info "Authenticated as $CALLER_ARN (account $ACCOUNT)"
    if (( ALL_REGIONS )); then
        aws_call "$WORK/_global/regions.json" regions "$BASE_REGION" ec2 describe-regions \
            || die 3 "Could not list enabled regions (ec2 describe-regions)"
        mapfile -t REGIONS < <(jq -r '.Regions[].RegionName' "$WORK/_global/regions.json" | sort)
        (( ${#REGIONS[@]} )) || die 3 "ec2 describe-regions returned no regions"
        log_info "All enabled regions: ${#REGIONS[@]} (${REGIONS[*]})"
    fi
}

# ----------------------------------------------------------------------------
# Collection: one directory of JSON files per region, consumed by lib/checks.jq
# ----------------------------------------------------------------------------
merge_obj() {   # merge_obj <file> <key> <jq-filter> <source>  : file[key] = (source | filter)
    jq --arg k "$2" --slurpfile s "$4" ". + {(\$k): (\$s[0] | $3)}" "$1" >"$1.tmp" && mv -f -- "$1.tmp" "$1"
}

collect_region() {
    local region="$1" d="$WORK/$1" f i chunk filt
    local -a ids=() vers=() majors=() pgs=() classes=()
    mkdir -p "$d"
    printf '{}' >"$d/errors.json"
    for f in clusters instances pma certs engver major params itypes snaps events metrics; do printf 'null' >"$d/$f.json"; done

    if (( ${#CLUSTERS[@]} )); then
        # explicit cluster list: 50 ids per --filters value (small argv, within the API's filter-value limit)
        local -a got=()
        for (( i = 0; i < ${#CLUSTERS[@]}; i += 50 )); do
            filt="Name=db-cluster-id,Values=$(IFS=,; echo "${CLUSTERS[*]:i:50}")"
            aws_call "$d/r_clusters_$i.json" clusters "$region" rds describe-db-clusters --filters "$filt" || return 0
            got+=("$d/r_clusters_$i.json")
        done
        jq -s 'map(.DBClusters // []) | add // [] | unique_by(.DBClusterArn)' -- "${got[@]}" >"$d/clusters.json"
    else
        filt="Name=engine,Values=aurora-postgresql"
        aws_call "$d/r_clusters.json" clusters "$region" rds describe-db-clusters --filters "$filt" || return 0
        jq '.DBClusters // []' "$d/r_clusters.json" >"$d/clusters.json"
    fi
    mapfile -t -O "${#FOUND_CLUSTERS[@]}" FOUND_CLUSTERS < <(jq -r '.[] | .DBClusterIdentifier, .DBClusterArn' "$d/clusters.json")
    mapfile -t ids < <(jq -r '.[] | select(.Engine == "aurora-postgresql") | .DBClusterIdentifier' "$d/clusters.json")
    if (( ${#ids[@]} == 0 )); then log_info "[$region] no aurora-postgresql clusters"; return 0; fi
    if (( ${#ids[@]} > 20 )); then log_info "[$region] ${#ids[@]} cluster(s): ${ids[*]:0:20} ..."
    else log_info "[$region] ${#ids[@]} cluster(s): ${ids[*]}"; fi

    # instances, 50 cluster ids per filter
    for (( i = 0; i < ${#ids[@]}; i += 50 )); do
        chunk="$(IFS=,; echo "${ids[*]:i:50}")"
        aws_call "$d/r_inst_$i.json" instances "$region" rds describe-db-instances \
            --filters "Name=db-cluster-id,Values=$chunk" || break
    done
    if [[ -n "$(jq -r '.instances // empty' "$d/errors.json")" ]]; then printf '[]' >"$d/instances.json"
    else jq -s 'map(.DBInstances // []) | add // []' "$d"/r_inst_*.json >"$d/instances.json"; fi

    if group_on versions; then
        aws_call "$d/r_pma.json" pma "$region" rds describe-pending-maintenance-actions \
            && jq '.PendingMaintenanceActions // []' "$d/r_pma.json" >"$d/pma.json"
        aws_call "$d/r_certs.json" certs "$region" rds describe-certificates \
            && jq '.Certificates // []' "$d/r_certs.json" >"$d/certs.json"
        printf '{}' >"$d/engver.json"; printf '{}' >"$d/major.json"
        mapfile -t vers < <(jq -r '[.[] | select(.Engine == "aurora-postgresql") | .EngineVersion] | unique[]' "$d/clusters.json")
        for f in "${vers[@]}"; do
            aws_call "$d/r_ev_$f.json" "engver:$f" "$region" rds describe-db-engine-versions \
                    --engine aurora-postgresql --engine-version "$f" --include-all \
                && merge_obj "$d/engver.json" "$f" '.DBEngineVersions[0]' "$d/r_ev_$f.json"
        done
        mapfile -t majors < <(jq -r --slurpfile ev "$d/engver.json" \
            '[.[] | select(.Engine == "aurora-postgresql") | ($ev[0][.EngineVersion].MajorEngineVersion // (.EngineVersion | split(".")[0]))] | unique[]' "$d/clusters.json")
        for f in "${majors[@]}"; do
            aws_call "$d/r_mj_$f.json" "opt:major:$f" "$region" rds describe-db-major-engine-versions \
                    --engine aurora-postgresql --major-engine-version "$f" \
                && merge_obj "$d/major.json" "$f" '.DBMajorEngineVersions[0]' "$d/r_mj_$f.json"
        done
    fi

    if group_on backups; then
        printf '{}' >"$d/snaps.json"
        for f in "${ids[@]}"; do
            aws_call "$d/r_snap_$f.json" "snapshots:$f" "$region" rds describe-db-cluster-snapshots --db-cluster-identifier "$f" \
                && merge_obj "$d/snaps.json" "$f" '.DBClusterSnapshots // []' "$d/r_snap_$f.json"
        done
    fi

    if group_on events; then
        local evs evok=1
        evs="$(iso_utc $(( NOW - EV_LOOKBACK_S )))"
        for f in db-cluster db-instance; do
            aws_call "$d/r_events_$f.json" events "$region" rds describe-events --source-type "$f" \
                --start-time "$evs" --end-time "$(iso_utc "$NOW")" || evok=0
        done
        (( evok )) && jq -s 'map(.Events // []) | add // []' "$d/r_events_db-cluster.json" "$d/r_events_db-instance.json" >"$d/events.json"
    fi

    if group_on metrics; then
        collect_metrics "$region" "$d"
    fi
    return 0
}

collect_metrics() {
    local region="$1" d="$2" f n k ok=1
    local -a pgs=() classes=()
    printf '{}' >"$d/params.json"
    if [[ "${TH[max_connections]}" == 0 ]]; then
        mapfile -t pgs < <(jq -r '[.[].DBParameterGroups[]?.DBParameterGroupName] | unique[]' "$d/instances.json")
        for f in "${pgs[@]}"; do
            aws_call "$d/r_par_$f.json" "opt:params:$f" "$region" rds describe-db-parameters \
                    --db-parameter-group-name "$f" --query "Parameters[?ParameterName=='max_connections']" \
                && merge_obj "$d/params.json" "$f" '.' "$d/r_par_$f.json"
        done
        if jq -e '[.[][] | .ParameterValue // "" | select(test("^[0-9]+$") | not)] | length > 0' "$d/params.json" >/dev/null 2>&1; then
            mapfile -t classes < <(jq -r '[.[].DBInstanceClass | select(. != "db.serverless") | sub("^db\\."; "")] | unique[]' "$d/instances.json")
            if (( ${#classes[@]} )); then
                aws_call "$d/r_itypes.json" opt:itypes "$region" ec2 describe-instance-types --instance-types "${classes[@]}" \
                    && jq '.InstanceTypes // []' "$d/r_itypes.json" >"$d/itypes.json"
            fi
        fi
    fi
    run_checks_jq queries "$region" >"$d/queries.json" || die 4 "Building metric queries failed for $region"
    n="$(jq 'length' "$d/queries.json")"
    (( n > 0 )) || return 0
    log_debug "[$region] $n metric queries"
    local start end
    start="$(iso_utc $(( NOW - LOOKBACK_S )))"; end="$(iso_utc "$NOW")"
    for (( k = 0; k * 500 < n; k++ )); do
        jq --argjson k "$k" '.[($k * 500):(($k + 1) * 500)]' "$d/queries.json" >"$d/mdq_$k.json"
        aws_call "$d/r_metrics_$k.json" metrics "$region" cloudwatch get-metric-data \
            --metric-data-queries "file://$d/mdq_$k.json" --start-time "$start" --end-time "$end" \
            --scan-by TimestampAscending || { ok=0; break; }
    done
    (( ok )) || return 0
    # the CLI concatenates pages; one query's datapoints may be split over several entries
    jq -s 'map(.MetricDataResults // []) | add // [] | group_by(.Id)
           | map(.[0] + {Values: (map(.Values // []) | add), Timestamps: (map(.Timestamps // []) | add)})' \
        "$d"/r_metrics_*.json >"$d/metrics.json"
}

run_checks_jq() {   # run_checks_jq <mode> <region>
    local d="$WORK/$2"
    jq -n --arg mode "$1" --arg region "$2" --argjson now "$NOW" --argjson lookback "$LOOKBACK_S" \
        --argjson lookback_events "$EV_LOOKBACK_S" --argjson period "$PERIOD" --argjson th "$TH_JSON" \
        --argjson groups "$(json_array "${GROUPS_ON[@]}")" \
        --slurpfile clusters "$d/clusters.json" --slurpfile instances "$d/instances.json" \
        --slurpfile pma "$d/pma.json" --slurpfile certs "$d/certs.json" --slurpfile engver "$d/engver.json" \
        --slurpfile major "$d/major.json" --slurpfile params "$d/params.json" --slurpfile itypes "$d/itypes.json" \
        --slurpfile snaps "$d/snaps.json" --slurpfile events "$d/events.json" --slurpfile metrics "$d/metrics.json" \
        --slurpfile errors "$d/errors.json" -f "$LIB_DIR/checks.jq"
}

# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------
build_report() {
    local region
    # cluster name lists go to jq as files, not argv (MAX_ARG_STRLEN = 128 KiB per argument)
    : >"$WORK/req_clusters.txt"; : >"$WORK/found_clusters.txt"
    if (( ${#CLUSTERS[@]} )); then printf '%s\n' "${CLUSTERS[@]}" >"$WORK/req_clusters.txt"; fi
    if (( ${#FOUND_CLUSTERS[@]} )); then printf '%s\n' "${FOUND_CLUSTERS[@]}" >"$WORK/found_clusters.txt"; fi
    for region in "${REGIONS[@]}"; do
        run_checks_jq evaluate "$region" >"$WORK/$region/eval.json" || die 4 "Evaluating checks failed for $region"
    done
    jq -n --rawfile reqf "$WORK/req_clusters.txt" --rawfile foundf "$WORK/found_clusters.txt" --arg regions "${REGIONS[*]}" \
        '($reqf | split("\n") | map(select(. != ""))) as $req | ($foundf | split("\n") | map(select(. != ""))) as $found
         | ($found | map({key: ., value: true}) | from_entries) as $fs
         | [$req[] | select($fs[.] | not)
            | {region: "-", cluster: ., group: "cluster", check: "cluster_found", status: "CRIT", value: "",
               reason: "cluster not found in region(s): \($regions)", details: []}] as $missing
         | if ($req | length) == 0 and ($found | length) == 0 then
             [{region: ($regions | gsub(" "; ",")), cluster: "(none)", group: "cluster", check: "clusters_found", status: "WARN",
               value: "0", reason: "no aurora-postgresql clusters found", details: []}]
           else $missing end' >"$WORK/extra.json" || die 4 "Building cluster checks failed"
    jq -n --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" --arg generated "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
        --arg host "$(hostname 2>/dev/null || echo unknown)" --arg account "$ACCOUNT" --arg arn "$CALLER_ARN" \
        --arg profile "${PROFILE:-default}" --argjson regions "$(json_array "${REGIONS[@]}")" \
        --arg lookback "$(human_secs "$LOOKBACK_S")" --argjson period "$PERIOD" --argjson checks "$(json_array "${GROUPS_ON[@]}")" \
        --argjson aws_calls "$AWS_CALLS" --argjson aws_failures "$AWS_FAILS" --argjson thresholds "$TH_JSON" \
        '{script: $script, version: $version, generated: $generated, host: $host, account: $account, caller_arn: $arn,
          profile: $profile, regions: $regions, lookback: $lookback, period: $period, checks: $checks,
          aws_calls: $aws_calls, aws_failures: $aws_failures, thresholds: $thresholds}' >"$WORK/meta.json" || die 4 "Building report metadata failed"
    REPORT="$WORK/report.json"
    local -a evals=()
    for region in "${REGIONS[@]}"; do evals+=("$WORK/$region/eval.json"); done
    jq -s --slurpfile meta "$WORK/meta.json" --slurpfile extra "$WORK/extra.json" \
        '($meta[0]) as $meta | ($extra[0]) as $extra | {meta: $meta, clusters: (map(.clusters) | add // []), results: ((map(.results) | add // []) + $extra)}' \
        "${evals[@]}" >"$WORK/raw_report.json" || die 4 "Assembling the report failed"
    render finalize <"$WORK/raw_report.json" >"$REPORT" || die 4 "Finalizing the report failed"
}

render() {   # render <mode> [only_problems] [details]  (report JSON on stdin)
    jq -r --arg mode "$1" --arg only_problems "${2:-0}" --arg details "${3:-0}" -f "$LIB_DIR/render.jq"
}

write_output() {
    local tmp
    tmp="$(mktemp "$WORK/out.XXXXXX")"
    case "$FORMAT" in
        json) jq . "$REPORT" >"$tmp" ;;
        text) render text "$ONLY_PROBLEMS" "$DETAILS" <"$REPORT" >"$tmp" ;;
        html) render html <"$REPORT" >"$tmp" ;;
    esac || die 4 "Rendering $FORMAT output failed"
    if [[ -n "$OUTPUT" ]]; then
        if ! { cp -- "$tmp" "$OUTPUT.tmp.$$" && mv -f -- "$OUTPUT.tmp.$$" "$OUTPUT"; }; then die 4 "Cannot write $OUTPUT"; fi
        chmod 0640 -- "$OUTPUT" 2>/dev/null || true
        log_info "Report written to $OUTPUT ($FORMAT)"
    else
        cat -- "$tmp"
    fi
}

# ----------------------------------------------------------------------------
# Alerts (never change the exit code)
# ----------------------------------------------------------------------------
should_alert() {
    case "$ALERT_ON" in
        always) return 0 ;;
        warn)   (( $1 != 0 )) ;;
        crit)   (( $1 == 11 || $1 == 3 )) ;;
    esac
}

send_email_alert() {   # send_email_alert <subject> <body-file>   (body streamed from the file)
    local subject="$1" bodyfile="$2" mailer="" to
    local -a tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout 60)
    if command -v mail >/dev/null 2>&1; then mailer="mail"
    elif command -v mailx >/dev/null 2>&1; then mailer="mailx"
    elif command -v sendmail >/dev/null 2>&1; then mailer="sendmail"
    elif [[ -x /usr/sbin/sendmail ]]; then mailer=/usr/sbin/sendmail
    else log_warn "Alert: no mail/mailx/sendmail found; cannot e-mail ${ALERT_EMAILS[*]}"; return 1; fi
    if [[ "$mailer" == mail || "$mailer" == mailx ]]; then
        local -a from=()
        [[ -n "$ALERT_FROM" ]] && from=(-r "$ALERT_FROM")
        "${tmo[@]}" "$mailer" "${from[@]}" -s "$subject" -- "${ALERT_EMAILS[@]}" <"$bodyfile"
    else
        to="$(IFS=,; printf '%s' "${ALERT_EMAILS[*]}")"
        {
            [[ -n "$ALERT_FROM" ]] && printf 'From: %s\n' "$ALERT_FROM"
            printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n' "$to" "$subject"
            cat -- "$bodyfile"
        } | "${tmo[@]}" "$mailer" -t -oi
    fi
}

send_webhook_alert() {   # send_webhook_alert <url> <payload-file>
    local url="$1" payload="$2" out
    command -v curl >/dev/null 2>&1 || { log_warn "Alert: curl not installed; webhook skipped"; return 1; }
    # URL goes through a curl config on stdin so it never shows up in `ps`
    out="$(printf 'url = "%s"\n' "${url//\"/\\\"}" | curl -sS --fail --max-time 20 --retry 2 \
            -H 'Content-Type: application/json' --data-binary "@$payload" -o /dev/null -w '%{http_code}' -K - 2>&1)" \
        || { log_warn "Alert: webhook $(redact_url "$url") failed: ${out%%$'\n'*}"; return 1; }
    log_info "Alert: webhook $(redact_url "$url") -> HTTP $out"
}

send_alerts() {   # send_alerts <rc> [test]
    local rc="$1" mode="${2:-}" status subject url
    (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || return 0
    # body and payload can be large: keep them in files, never in argv
    [[ -n "$WORK" && -d "$WORK" ]] || WORK="$(mktemp -d "${TMPDIR:-/tmp}/aurora_pg_check.XXXXXX")"
    local body="$WORK/alert_body.txt" payload="$WORK/alert_payload.json"
    if [[ "$mode" == test ]]; then
        status="TEST"
        subject="[aurora_pg_check] TEST alert from $(hostname 2>/dev/null || echo unknown)"
        printf 'Test alert from %s v%s on %s at %s. No checks were run.\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" \
            "$(hostname 2>/dev/null || echo unknown)" "$(date '+%Y-%m-%d %H:%M:%S %Z')" >"$body"
        jq -n --arg s "$subject" --rawfile b "$body" '{status: "TEST", exit_code: 0, text: ($s + "\n\n" + $b)}' >"$payload"
    else
        should_alert "$rc" || return 0
        status="$(jq -r '.summary.overall' "$REPORT")"
        local regs; regs="$(IFS=,; echo "${REGIONS[*]:0:4}")"
        if (( ${#REGIONS[@]} > 4 )); then regs+=",..."; fi
        subject="[aurora_pg_check] $status: $(jq -r '.summary.cluster_count' "$REPORT") cluster(s), account $ACCOUNT, $regs (exit $rc)"
        render text 1 0 <"$REPORT" >"$body" || { log_warn "Alert: rendering the body failed"; return 0; }
        if ! { render alert <"$REPORT" >"$payload.tmp" \
               && jq -c --arg s "$subject" --rawfile b "$body" '. + {text: ($s + "\n\n" + $b)}' "$payload.tmp" >"$payload"; }; then
            log_warn "Alert: building the webhook payload failed"; return 0
        fi
    fi
    if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
        # Slack rejects/truncates messages over ~40k characters
        jq -cn --arg h "$subject" --rawfile b "$body" --argjson max 35000 \
            '{text: ("*" + $h + "*\n```" + (if ($b | length) > $max then $b[0:$max] + "\n... (truncated - see the full report)" else $b end) + "```")}' >"$payload"
    fi
    if (( ${#ALERT_EMAILS[@]} )); then
        if send_email_alert "$subject" "$body"; then log_info "Alert: e-mail ($status) sent to ${ALERT_EMAILS[*]}"
        else log_warn "Alert: e-mail to ${ALERT_EMAILS[*]} failed"; fi
    fi
    for url in "${ALERT_WEBHOOKS[@]}"; do send_webhook_alert "$url" "$payload" || true; done
    return 0
}

# ----------------------------------------------------------------------------
# Dry run: show what would be called, call nothing
# ----------------------------------------------------------------------------
show_cmd() { printf '    %s\n' "$(printf '%q ' "$@")"; }
dry_run_plan() {
    local r g
    local -a regs=("${REGIONS[@]}")
    (( ALL_REGIONS )) && regs=("<each-enabled-region>")
    echo "$SCRIPT_NAME v$SCRIPT_VERSION dry run - no AWS calls are made"
    echo "  profile      : ${PROFILE:-default}"
    echo "  regions      : $( (( ALL_REGIONS )) && echo "all enabled (listed via $BASE_REGION)" || echo "${REGIONS[*]}")"
    echo "  clusters     : ${CLUSTERS[*]:-all aurora-postgresql clusters}"
    echo "  checks       : ${GROUPS_ON[*]}"
    echo "  lookback     : $(human_secs "$LOOKBACK_S") (events $(human_secs "$EV_LOOKBACK_S")), period ${PERIOD}s"
    echo "  output       : $FORMAT -> ${OUTPUT:-stdout}"
    echo "  alerts       : emails=${#ALERT_EMAILS[@]} webhooks=${#ALERT_WEBHOOKS[@]} on=$ALERT_ON"
    echo "  thresholds   : $TH_JSON"
    echo "Pre-checks:"
    aws_base "$BASE_REGION"; show_cmd "${AWS_CMD[@]}" sts get-caller-identity
    (( ALL_REGIONS )) && show_cmd "${AWS_CMD[@]}" ec2 describe-regions
    for r in "${regs[@]}"; do
        echo "Region $r:"
        aws_base "$r"
        if (( ${#CLUSTERS[@]} )); then show_cmd "${AWS_CMD[@]}" rds describe-db-clusters --filters "Name=db-cluster-id,Values=$(IFS=,; echo "${CLUSTERS[*]:0:50}")"
            (( ${#CLUSTERS[@]} > 50 )) && echo "    ... ($(( (${#CLUSTERS[@]} + 49) / 50 )) calls, 50 cluster ids each)"
        else show_cmd "${AWS_CMD[@]}" rds describe-db-clusters --filters "Name=engine,Values=aurora-postgresql"; fi
        show_cmd "${AWS_CMD[@]}" rds describe-db-instances --filters "Name=db-cluster-id,Values=<found-cluster-ids>"
        for g in "${GROUPS_ON[@]}"; do
            case "$g" in
                versions)
                    show_cmd "${AWS_CMD[@]}" rds describe-pending-maintenance-actions
                    show_cmd "${AWS_CMD[@]}" rds describe-certificates
                    show_cmd "${AWS_CMD[@]}" rds describe-db-engine-versions --engine aurora-postgresql --engine-version "<version>" --include-all
                    show_cmd "${AWS_CMD[@]}" rds describe-db-major-engine-versions --engine aurora-postgresql --major-engine-version "<major>" ;;
                backups)
                    show_cmd "${AWS_CMD[@]}" rds describe-db-cluster-snapshots --db-cluster-identifier "<cluster>" ;;
                events)
                    show_cmd "${AWS_CMD[@]}" rds describe-events --source-type db-cluster --start-time "$(iso_utc $(( NOW - EV_LOOKBACK_S )))" --end-time "$(iso_utc "$NOW")"
                    show_cmd "${AWS_CMD[@]}" rds describe-events --source-type db-instance --start-time "$(iso_utc $(( NOW - EV_LOOKBACK_S )))" --end-time "$(iso_utc "$NOW")" ;;
                metrics)
                    [[ "${TH[max_connections]}" == 0 ]] && {
                        show_cmd "${AWS_CMD[@]}" rds describe-db-parameters --db-parameter-group-name "<param-group>" --query "Parameters[?ParameterName=='max_connections']"
                        show_cmd "${AWS_CMD[@]}" ec2 describe-instance-types --instance-types "<class>"; }
                    show_cmd "${AWS_CMD[@]}" cloudwatch get-metric-data --metric-data-queries "file://<queries.json>" \
                        --start-time "$(iso_utc $(( NOW - LOOKBACK_S )))" --end-time "$(iso_utc "$NOW")" --scan-by TimestampAscending ;;
            esac
        done
    done
}

# ----------------------------------------------------------------------------
# Exit handling and main
# ----------------------------------------------------------------------------
# shellcheck disable=SC2317  # invoked via trap
on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        if (( KEEP_WORKDIR )); then log_info "Raw AWS responses kept in $WORK"; else rm -rf -- "$WORK"; fi
    fi
    exit "$rc"
}
# shellcheck disable=SC2317
on_signal() { log_error "Interrupted"; exit 130; }

main() {
    trap on_exit EXIT
    trap on_signal INT TERM
    parse_args "$@"
    if (( LIST_THRESHOLDS )); then
        printf '%-30s %-12s %s\n' KEY VALUE MEANING
        local k; for k in "${TH_KEYS[@]}"; do printf '%-30s %-12s %s\n' "$k" "${TH[$k]}" "${TH_DESC[$k]}"; done
        exit 0
    fi
    validate
    TH_JSON="$(th_json)"
    NOW="$(date +%s)"
    export AWS_PAGER="" AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
    if (( ALERT_TEST )); then
        (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || die 1 "--alert-test needs --alert-email or --alert-webhook"
        send_alerts 0 test; exit 0
    fi
    if (( DRY_RUN )); then resolve_regions; dry_run_plan; exit 0; fi

    precheck
    resolve_regions
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/aurora_pg_check.XXXXXX")"
    check_credentials
    log_info "Checking ${#REGIONS[@]} region(s): ${REGIONS[*]}; groups: ${GROUPS_ON[*]}; lookback $(human_secs "$LOOKBACK_S")"
    local region rc
    for region in "${REGIONS[@]}"; do collect_region "$region"; done
    build_report
    write_output
    rc="$(jq -r '.summary.exit_code' "$REPORT")"
    log_info "$(jq -r '"Result: \(.summary.overall) - \(.summary.cluster_count) cluster(s), \(.summary.counts.warn) warn, \(.summary.counts.crit) crit, \(.summary.counts.error) error"' "$REPORT"); $AWS_CALLS AWS call(s), $AWS_FAILS failed; exit $rc"
    send_alerts "$rc"
    exit "$rc"
}

main "$@"
