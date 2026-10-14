#!/usr/bin/env bash
#
# rds_patch_runner.sh - apply pending RDS maintenance to ONE Aurora (PostgreSQL / MySQL), DocumentDB or Neptune
# cluster in a safe order: preflight -> confirm -> cluster snapshot -> [minor upgrade] -> readers one at a time
# -> cluster-level actions -> writer last -> verify.
#
# DRY RUN BY DEFAULT: without --execute it only reads (describe-*) and prints the plan.
# Exit: 0 ok / nothing to do, 1 usage, 2 preflight abort, 3 step failure or timeout, 4 declined, 130 interrupted.
# Rendering lives in lib/runner.jq.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIB="${RDS_PR_LIB:-$SCRIPT_DIR/lib}/runner.jq"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 1
fi

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
PROFILE=""
REGION=""
CLUSTER=""
EXECUTE=0
ASSUME_YES=0
ACTIONS=(all)
MINOR=""
SKIP_SNAPSHOT=0
TIMEOUT_MIN=60
POLL_SEC=30
GRACE_SEC=600
OUTPUT_DIR=""
HTML=0
LOG_FILE=""
CONFIG_FILE=""
AWS_TIMEOUT=30
MAX_ATTEMPTS=5
LOCK_DIR="${RDS_PR_LOCK_DIR:-${TMPDIR:-/tmp}/rds_patch_runner_locks}"
VERBOSE=0
ALERT_EMAILS=()
ALERT_WEBHOOKS=()
ALERT_WEBHOOK_FORMAT="slack"
ALERT_FROM=""
ALERT_ON="always"

WORK=""
LOCK=""
SVC="rds"
ACCOUNT="-"
STAMP=""
SNAP_NAME=""
CURRENT_STEP=""
IN_FLIGHT=""
FINISHED=0
RUN_RC=0
RUN_MSG=""
STEP_N=0
TIMEOUT_SEC=3600
declare -a TODO=() DONE_IDS=()

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
utc() { date -u '+%Y-%m-%d %H:%M:%S'; }
_log() {
    local level="$1"; shift
    local line; line="$(_ts) [$level] $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
}
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local code="$1"; shift; log_error "$@"; exit "$code"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - apply pending maintenance to ONE Aurora / DocumentDB / Neptune cluster, safely

Usage: $SCRIPT_NAME -c CLUSTER [-P PROFILE] [-r REGION] [options]

DRY RUN IS THE DEFAULT: the plan is printed and nothing is changed. Add --execute to patch.

Target:
  -c, --cluster ID          DB cluster identifier (aurora-postgresql, aurora-mysql, docdb, neptune)   [required]
  -P, --profile NAME        AWS CLI profile (default: default credential chain)
  -r, --region REGION       Region (default: AWS_REGION / profile region)

What to apply:
  -a, --action LIST         all (default) | system-update | db-upgrade | os-upgrade | hardware-maintenance |
                            ca-certificate-rotation ... (comma-separated; others stay pending)
      --minor-upgrade V     Also upgrade the cluster to minor version V, or 'latest' (newest minor target):
                            modify-db-cluster --engine-version V --apply-immediately, right after the snapshot
      --skip-snapshot       Do not take the pre-maintenance cluster snapshot (not recommended)

Run control:
      --dry-run             Print the plan only (default)
      --execute             Really apply (asks 'Patch <cluster>? [y/N]' unless --yes)
  -y, --yes                 Do not ask (needed when there is no terminal, e.g. cron / CodeBuild)
      --timeout-min N       Per-step timeout in minutes (default 60; decimals allowed)
      --poll-sec N          Seconds between status checks (default 30; decimals allowed)
      --grace-sec N         How long an applied action may stay pending with no status change before the
                            step fails as 'not started by AWS' (default 600)
  -o, --output-dir DIR      Where log + summary go (default ./rds_patch_runs); --html adds an HTML summary
      --html                Also write <cluster>_<stamp>_summary.html
  -l, --log-file FILE       Log file (default <output-dir>/<cluster>_<stamp>.log)
      --lock-dir DIR        Lock directory (default \$TMPDIR/rds_patch_runner_locks): one run per cluster

Alerts (sent at the end of an --execute run):
      --alert-email ADDR    mail/mailx/sendmail                                [repeatable]
      --alert-webhook URL   POST via curl                                      [repeatable]
      --alert-webhook-format F  slack | json (default slack)
      --alert-on WHEN       always (default) | failure
      --alert-from ADDR     From address for e-mail

Behaviour:
      --config FILE         key=value settings (parsed, never sourced; CLI overrides)
      --aws-timeout SEC     AWS CLI connect/read timeout (default 30)
      --max-attempts N      AWS CLI retry attempts (default 5)
  -v, --verbose             Debug logging
  -h, --help / -V, --version

Order: snapshot -> minor upgrade (if asked) -> readers one at a time -> cluster-level actions -> current writer
last -> verify. Stops at the first failure (the writer is never touched after a reader failed).
Exit codes: 0 ok / nothing to do, 1 usage, 2 preflight abort (cluster/member not available, global cluster,
unsupported engine, lock held, AWS read error), 3 step failure / timeout, 4 declined, 130 interrupted.
USAGE
}

# ----------------------------------------------------------------------------
# Helpers / config
# ----------------------------------------------------------------------------
add_list() {
    local -n _arr="$1"
    local _item; local -a _parts
    IFS=',' read -r -a _parts <<<"$2"
    for _item in "${_parts[@]}"; do
        _item="${_item#"${_item%%[![:space:]]*}"}"; _item="${_item%"${_item##*[![:space:]]}"}"
        [[ -n "$_item" ]] && _arr+=("$_item")
    done
    return 0
}
is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
redact_url() { if [[ "$1" =~ ^([a-zA-Z]+://[^/]+) ]]; then printf '%s/...' "${BASH_REMATCH[1]}"; else printf '<webhook>'; fi; }
is_num() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
json_array() { if (( $# )); then printf '%s\n' "$@" | jq -R . | jq -cs .; else printf '[]'; fi; }
now() { date +%s; }

load_config() {
    local file="$1" line key val lineno=0
    [[ -r "$file" ]] || die 1 "Config file not readable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$(( lineno + 1 )); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
            || die 1 "Config $file:$lineno: invalid line (expected key=value)"
        key="${BASH_REMATCH[1],,}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"([^\"]*)\" || "$val" =~ ^\'([^\']*)\' ]]; then val="${BASH_REMATCH[1]}"
        else
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        case "$key" in
            profile)                PROFILE="$val" ;;
            region)                 REGION="$val" ;;
            cluster)                CLUSTER="$val" ;;
            action|actions)         ACTIONS=(); add_list ACTIONS "$val" ;;
            minor_upgrade)          MINOR="$val" ;;
            skip_snapshot)          if is_true "$val"; then SKIP_SNAPSHOT=1; else SKIP_SNAPSHOT=0; fi ;;
            timeout_min)            TIMEOUT_MIN="$val" ;;
            poll_sec)               POLL_SEC="$val" ;;
            grace_sec)              GRACE_SEC="$val" ;;
            output_dir)             OUTPUT_DIR="$val" ;;
            html)                   if is_true "$val"; then HTML=1; else HTML=0; fi ;;
            log_file)               LOG_FILE="$val" ;;
            lock_dir)               LOCK_DIR="$val" ;;
            aws_timeout)            AWS_TIMEOUT="$val" ;;
            max_attempts)           MAX_ATTEMPTS="$val" ;;
            verbose)                if is_true "$val"; then VERBOSE=1; else VERBOSE=0; fi ;;
            alert_email|alert_emails)     ALERT_EMAILS=(); add_list ALERT_EMAILS "$val" ;;
            alert_webhook|alert_webhooks) ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$val" ;;
            alert_webhook_format)   ALERT_WEBHOOK_FORMAT="$val" ;;
            alert_on)               ALERT_ON="$val" ;;
            alert_from)             ALERT_FROM="$val" ;;
            execute|yes|assume_yes)
                die 1 "Config $file:$lineno: '$key' is not accepted in a config file; pass --execute / --yes on the command line" ;;
            aws_access_key_id|aws_secret_access_key|aws_session_token|secret|password)
                die 1 "Config $file:$lineno: credentials are not accepted here; use an AWS CLI profile / SSO / role" ;;
            *) die 1 "Config $file:$lineno: unknown key '$key'" ;;
        esac
    done <"$file"
}

parse_args() {
    local i j
    for (( i = 1; i <= $#; i++ )); do
        case "${!i}" in
            --config=*) CONFIG_FILE="${!i#--config=}" ;;
            --config)   j=$(( i + 1 )); (( j <= $# )) || die 1 "Option --config requires a value"; CONFIG_FILE="${!j}" ;;
        esac
    done
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"
    local opt acts_reset=0
    while (( $# )); do
        opt="$1"
        if [[ "$opt" == --*=* ]]; then set -- "${opt%%=*}" "${opt#*=}" "${@:2}"; opt="$1"; fi
        case "$opt" in
            -c|--cluster)       need_arg "$opt" $#; CLUSTER="$2"; shift 2 ;;
            -P|--profile)       need_arg "$opt" $#; PROFILE="$2"; shift 2 ;;
            -r|--region)        need_arg "$opt" $#; REGION="$2"; shift 2 ;;
            -a|--action)        need_arg "$opt" $#; (( acts_reset )) || ACTIONS=(); acts_reset=1; add_list ACTIONS "$2"; shift 2 ;;
            --minor-upgrade)    need_arg "$opt" $#; MINOR="$2"; shift 2 ;;
            --skip-snapshot)    SKIP_SNAPSHOT=1; shift ;;
            --dry-run)          EXECUTE=0; shift ;;
            --execute)          EXECUTE=1; shift ;;
            -y|--yes)           ASSUME_YES=1; shift ;;
            --timeout-min)      need_arg "$opt" $#; TIMEOUT_MIN="$2"; shift 2 ;;
            --poll-sec)         need_arg "$opt" $#; POLL_SEC="$2"; shift 2 ;;
            --grace-sec)        need_arg "$opt" $#; GRACE_SEC="$2"; shift 2 ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --html)             HTML=1; shift ;;
            -l|--log-file)      need_arg "$opt" $#; LOG_FILE="$2"; shift 2 ;;
            --lock-dir)         need_arg "$opt" $#; LOCK_DIR="$2"; shift 2 ;;
            --config)           shift 2 ;;
            --aws-timeout)      need_arg "$opt" $#; AWS_TIMEOUT="$2"; shift 2 ;;
            --max-attempts)     need_arg "$opt" $#; MAX_ATTEMPTS="$2"; shift 2 ;;
            -v|--verbose)       VERBOSE=1; shift ;;
            --alert-email)      need_arg "$opt" $#; add_list ALERT_EMAILS "$2"; shift 2 ;;
            --alert-webhook)    need_arg "$opt" $#; add_list ALERT_WEBHOOKS "$2"; shift 2 ;;
            --alert-webhook-format) need_arg "$opt" $#; ALERT_WEBHOOK_FORMAT="$2"; shift 2 ;;
            --alert-on)         need_arg "$opt" $#; ALERT_ON="$2"; shift 2 ;;
            --alert-from)       need_arg "$opt" $#; ALERT_FROM="$2"; shift 2 ;;
            -h|--help)          usage; exit 0 ;;
            -V|--version)       echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *)                  die 1 "Unknown option: $opt (see --help)" ;;
        esac
    done
}

validate() {
    local x
    command -v jq >/dev/null 2>&1 || die 1 "jq not found in PATH (install jq 1.6+)"
    [[ -n "$CLUSTER" ]] || die 1 "--cluster is required (see --help)"
    [[ "$CLUSTER" =~ ^[A-Za-z][A-Za-z0-9-]{0,62}$ ]] || die 1 "Invalid cluster identifier: $CLUSTER"
    [[ -z "$REGION" || "$REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die 1 "Invalid region: $REGION"
    [[ -z "$PROFILE" || "$PROFILE" =~ ^[A-Za-z0-9_.+@-]+$ ]] || die 1 "Invalid profile name: $PROFILE"
    (( ${#ACTIONS[@]} )) || ACTIONS=(all)
    for x in "${ACTIONS[@]}"; do [[ "$x" =~ ^[a-z][a-z-]*$ ]] || die 1 "Invalid --action: $x"; done
    [[ -z "$MINOR" || "$MINOR" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "Invalid --minor-upgrade version: $MINOR"
    if ! { is_num "$TIMEOUT_MIN" && awk -v v="$TIMEOUT_MIN" 'BEGIN{exit !(v > 0)}'; }; then die 1 "--timeout-min must be a positive number"; fi
    is_num "$POLL_SEC" || die 1 "--poll-sec must be a number"
    is_num "$GRACE_SEC" || die 1 "--grace-sec must be a number"
    [[ "$AWS_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 1 "--aws-timeout must be a positive integer"
    [[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die 1 "--max-attempts must be a positive integer"
    case "${ALERT_ON,,}" in always|failure) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be always or failure" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be slack or json" ;; esac
    for x in "${ALERT_EMAILS[@]}"; do
        [[ "$x" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $x"
    done
    for x in "${ALERT_WEBHOOKS[@]}"; do [[ "$x" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$x")"; done
    TIMEOUT_SEC="$(awk -v v="$TIMEOUT_MIN" 'BEGIN{printf "%d", (v * 60 < 1 ? 1 : v * 60)}')"
    GRACE_SEC="$(awk -v v="$GRACE_SEC" 'BEGIN{printf "%d", v}')"
}

rjq() {   # rjq <mode> [jq args...]
    local mode="$1"; shift
    jq --arg mode "$mode" -f "$LIB" "$@"
}

# ----------------------------------------------------------------------------
# AWS access
# ----------------------------------------------------------------------------
LAST_ERR=""
aws_call() {   # aws_call <outfile> <service> <operation> [args...]   -> 0 ok (valid JSON or empty for wait-like)
    local out="$1"; shift
    local rc=0
    local -a cmd=(aws --output json --no-cli-pager --cli-connect-timeout "$AWS_TIMEOUT" --cli-read-timeout "$AWS_TIMEOUT")
    [[ -n "$PROFILE" ]] && cmd+=(--profile "$PROFILE")
    [[ -n "$REGION" ]] && cmd+=(--region "$REGION")
    log_debug "aws $*"
    "${cmd[@]}" "$@" >"$out" 2>"$out.err" || rc=$?
    if (( rc == 0 )) && { [[ ! -s "$out" ]] || jq -e . "$out" >/dev/null 2>&1; }; then return 0; fi
    LAST_ERR="$(tr -s '\n' ' ' <"$out.err" | sed -E 's/aws: \[ERROR\]: //g; s/^ +//; s/ +$//')"
    [[ -n "$LAST_ERR" ]] || LAST_ERR="exit $rc, invalid or empty JSON output"
    (( ${#LAST_ERR} > 400 )) && LAST_ERR="${LAST_ERR:0:400}..."
    return 1
}
# read-only lookups used everywhere (files in $WORK)
get_cluster() { aws_call "$WORK/cluster.json" rds describe-db-clusters --db-cluster-identifier "$CLUSTER"; }
get_members() { aws_call "$WORK/members.json" rds describe-db-instances --filters "Name=db-cluster-id,Values=$CLUSTER"; }
get_pending() {   # get_pending <arn> <outfile>
    aws_call "$2" "$SVC" describe-pending-maintenance-actions --resource-identifier "$1"
}
cluster_field() { jq -r ".DBClusters[0].$1 // \"\"" "$WORK/cluster.json"; }
current_writer() { jq -r '[.DBClusters[0].DBClusterMembers[]? | select(.IsClusterWriter) | .DBInstanceIdentifier][0] // ""' "$WORK/cluster.json"; }

# ----------------------------------------------------------------------------
# Lock (one run per cluster)
# ----------------------------------------------------------------------------
take_lock() {
    mkdir -p "$LOCK_DIR" 2>/dev/null || die 2 "Cannot create lock directory $LOCK_DIR"
    LOCK="$LOCK_DIR/${PROFILE:-default}_${REGION:-default}_${CLUSTER}.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
        local pid; pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            LOCK=""; die 2 "Another run (pid $pid) is working on $CLUSTER (lock $LOCK_DIR); not starting"
        fi
        log_warn "Removing stale lock for $CLUSTER (pid ${pid:-unknown} is gone)"
        rm -rf -- "$LOCK"; mkdir "$LOCK" 2>/dev/null || { LOCK=""; die 2 "Cannot take lock for $CLUSTER"; }
    fi
    printf '%s\n' "$$" >"$LOCK/pid"
    printf 'host=%s started=%s\n' "$(hostname 2>/dev/null || echo unknown)" "$(utc)" >"$LOCK/info"
}
# shellcheck disable=SC2317  # called from the EXIT trap
release_lock() { if [[ -n "$LOCK" && -d "$LOCK" ]]; then rm -rf -- "$LOCK"; fi; LOCK=""; }

# ----------------------------------------------------------------------------
# Step bookkeeping (steps.jsonl -> summary)
# ----------------------------------------------------------------------------
STEP_START=0; STEP_KIND=""; STEP_TARGET=""; STEP_ACTIONS=""; STEP_VBEFORE=""
step_begin() {   # step_begin <kind> <target> <actions> <version_before>
    STEP_N=$(( STEP_N + 1 )); STEP_START="$(now)"; STEP_KIND="$1"; STEP_TARGET="$2"; STEP_ACTIONS="$3"; STEP_VBEFORE="$4"
    CURRENT_STEP="step $STEP_N: $1 $2${3:+ ($3)}"
    log_info "=== $CURRENT_STEP - start"
}
step_end() {   # step_end <result> <detail> <version_after>
    local end; end="$(now)"
    jq -cn --argjson n "$STEP_N" --arg kind "$STEP_KIND" --arg target "$STEP_TARGET" --arg actions "$STEP_ACTIONS" \
        --arg s "$(date -u -d "@$STEP_START" '+%Y-%m-%d %H:%M:%S')" --arg e "$(date -u -d "@$end" '+%Y-%m-%d %H:%M:%S')" \
        --argjson d "$(( end - STEP_START ))" --arg r "$1" --arg detail "$2" --arg vb "$STEP_VBEFORE" --arg va "$3" \
        '{n: $n, kind: $kind, target: $target, actions: $actions, start_utc: $s, end_utc: $e, duration_s: $d, result: $r,
          detail: $detail, version_before: $vb, version_after: $va}' >>"$WORK/steps.jsonl"
    log_info "=== $CURRENT_STEP - $1 after $(( end - STEP_START ))s${2:+: $2}"
    CURRENT_STEP=""; IN_FLIGHT=""
}
record_failover() {   # record_failover <from> <to>
    jq -cn --arg a "$(utc)" --arg f "$1" --arg t "$2" '{at_utc: $a, from: $f, to: $t}' >>"$WORK/failovers.jsonl"
    log_warn "FAILOVER: writer changed $1 -> $2"
}

sleep_poll() { sleep "$POLL_SEC"; }
FAILED_STATES=" failed incompatible-parameters incompatible-restore incompatible-network inaccessible-encryption-credentials storage-full restore-error incompatible-option-group "

# ----------------------------------------------------------------------------
# Preflight + plan
# ----------------------------------------------------------------------------
preflight() {
    command -v aws >/dev/null 2>&1 || die 2 "AWS CLI not found in PATH (install AWS CLI v2)"
    local v; v="$(aws --version 2>&1 || true)"
    if ! { [[ "$v" =~ aws-cli/([0-9]+) ]] && (( BASH_REMATCH[1] >= 2 )); }; then die 2 "AWS CLI v2 required (found ${v%% *})"; fi
    [[ -r "$LIB" ]] || die 2 "Library missing: $LIB"
    if [[ -z "$REGION" ]]; then
        REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
        if [[ -z "$REGION" ]]; then
            local -a p=(); [[ -n "$PROFILE" ]] && p=(--profile "$PROFILE")
            REGION="$(aws configure get region "${p[@]}" 2>/dev/null || true)"
        fi
        [[ -n "$REGION" ]] || die 2 "No region: pass -r REGION"
    fi
    aws_call "$WORK/sts.json" sts get-caller-identity || die 2 "Credentials not usable: $LAST_ERR"
    ACCOUNT="$(jq -r '.Account' "$WORK/sts.json")"
    log_info "Account $ACCOUNT ($(jq -r '.Arn' "$WORK/sts.json")), region $REGION, cluster $CLUSTER"
    get_cluster || die 2 "describe-db-clusters $CLUSTER failed: $LAST_ERR"
    [[ "$(jq '.DBClusters | length' "$WORK/cluster.json")" == 1 ]] || die 2 "Cluster $CLUSTER not found in $REGION"
    local engine status global mode
    engine="$(cluster_field Engine)"; status="$(cluster_field Status)"; global="$(cluster_field GlobalClusterIdentifier)"; mode="$(cluster_field EngineMode)"
    case "$engine" in
        aurora-postgresql|aurora-mysql) SVC=rds ;;
        docdb)   SVC=docdb ;;
        neptune) SVC=neptune ;;
        *) die 2 "Engine '$engine' is not supported (Aurora PostgreSQL / MySQL, DocumentDB, Neptune clusters only; RDS instances and Multi-AZ DB clusters come later)" ;;
    esac
    [[ "$mode" == serverless ]] && die 2 "Aurora Serverless v1 (EngineMode serverless) is not supported"
    [[ -z "$global" ]] || die 2 "$CLUSTER is a member of global database '$global'; global databases are not supported yet (patch secondaries, then the primary, by hand)"
    [[ "$status" == available ]] || die 2 "Cluster $CLUSTER status is '$status', not 'available'; not starting"
    get_members || die 2 "describe-db-instances for $CLUSTER failed: $LAST_ERR"
    local bad
    bad="$(jq -r '[.DBInstances[] | select(.DBInstanceStatus != "available") | "\(.DBInstanceIdentifier)=\(.DBInstanceStatus)"] | join(", ")' "$WORK/members.json")"
    [[ -z "$bad" ]] || die 2 "Member(s) not available: $bad; not starting"
    [[ "$(jq '.DBInstances | length' "$WORK/members.json")" -gt 0 ]] || die 2 "Cluster $CLUSTER has no instances"
    # pending actions: the cluster ARN and every member ARN (one call each, read-only)
    local arn i=0
    : >"$WORK/pma_all.jsonl"
    while IFS= read -r arn; do
        get_pending "$arn" "$WORK/pma_$i.json" || die 2 "describe-pending-maintenance-actions $arn failed: $LAST_ERR"
        jq -c '.PendingMaintenanceActions[]?' "$WORK/pma_$i.json" >>"$WORK/pma_all.jsonl"
        i=$(( i + 1 ))
    done < <(jq -r '.DBClusters[0].DBClusterArn' "$WORK/cluster.json"; jq -r '.DBInstances[].DBInstanceArn' "$WORK/members.json")
    jq -cs . "$WORK/pma_all.jsonl" >"$WORK/pma.json"
    # --minor-upgrade latest|V -> concrete target (minor targets only)
    local target=""
    if [[ -n "$MINOR" ]]; then
        local cur; cur="$(cluster_field EngineVersion)"
        aws_call "$WORK/ev.json" "$SVC" describe-db-engine-versions --engine "$engine" --engine-version "$cur" \
            || die 2 "describe-db-engine-versions $engine $cur failed: $LAST_ERR"
        jq -r --arg cur "$cur" -f <(cat <<'J'
def vkey: [scan("[0-9]+|[A-Za-z]+") | (tonumber? // .)];
[.DBEngineVersions[]?.ValidUpgradeTarget[]? | select((.IsMajorVersionUpgrade // false) == false) | .EngineVersion
 | select(vkey > ($cur | vkey))] | unique_by(vkey) | .[]
J
) "$WORK/ev.json" >"$WORK/minor_targets.txt"
        if [[ "$MINOR" == latest ]]; then
            target="$(tail -n 1 "$WORK/minor_targets.txt")"
            if [[ -z "$target" ]]; then log_info "--minor-upgrade latest: $CLUSTER is already on the latest minor version ($cur); no upgrade step"
            else log_info "--minor-upgrade latest -> $target (current $cur)"; fi
        elif [[ "$MINOR" == "$cur" ]]; then log_info "--minor-upgrade $MINOR: already on that version; no upgrade step"
        elif grep -qxF -- "$MINOR" "$WORK/minor_targets.txt"; then target="$MINOR"
        else die 2 "--minor-upgrade $MINOR is not a valid minor upgrade target from $cur (valid: $(paste -sd, "$WORK/minor_targets.txt" | sed 's/^$/none/'))"
        fi
    fi
    rjq plan -n --slurpfile cluster "$WORK/cluster.json" --slurpfile members "$WORK/members.json" --slurpfile pma "$WORK/pma.json" \
        --argjson actions "$(json_array "${ACTIONS[@]}")" --arg minor "$target" >"$WORK/plan.json" || die 2 "Building the plan failed"
}

print_plan() {   # stdout, and into the log file on execute runs
    rjq plan_text -r --arg account "$ACCOUNT" --arg profile "${PROFILE:-default}" --arg region "$REGION" \
        --arg skip_snapshot "$SKIP_SNAPSHOT" "$WORK/plan.json" >"$WORK/plan.txt"
    cat -- "$WORK/plan.txt"
    if [[ -n "$LOG_FILE" ]]; then cat -- "$WORK/plan.txt" >>"$LOG_FILE" 2>/dev/null || true; fi
}

# ----------------------------------------------------------------------------
# Waiting
# ----------------------------------------------------------------------------
# wait_resource <instance|cluster> <id> <arn> <actions-csv> [version]
# Done when: status is available AND none of the applied actions is still pending (AND version matches, if given).
# A quick action may finish without a visible status change. If an action is still pending and the status never
# left 'available' after --grace-sec, AWS has not started it -> failure (it may be deferred / queued).
WAIT_DETAIL=""
wait_resource() {
    local kind="$1" id="$2" arn="$3" acts="$4" want_ver="${5:-}"
    local start saw=0 st="" remaining ver="" el last_st=""
    start="$(now)"
    while :; do
        if [[ "$kind" == instance ]]; then
            aws_call "$WORK/w.json" rds describe-db-instances --db-instance-identifier "$id" || { WAIT_DETAIL="describe failed: $LAST_ERR"; return 1; }
            st="$(jq -r '.DBInstances[0].DBInstanceStatus // "unknown"' "$WORK/w.json")"
            ver="$(jq -r '.DBInstances[0].EngineVersion // ""' "$WORK/w.json")"
        else
            get_cluster || { WAIT_DETAIL="describe failed: $LAST_ERR"; return 1; }
            st="$(cluster_field Status)"; ver="$(cluster_field EngineVersion)"
            if [[ "$st" == available ]]; then   # whole cluster: every member must be available too
                get_members || { WAIT_DETAIL="describe failed: $LAST_ERR"; return 1; }
                local mb; mb="$(jq -r '[.DBInstances[] | select(.DBInstanceStatus != "available" or ($v != "" and .EngineVersion != $v))
                                         | "\(.DBInstanceIdentifier)=\(.DBInstanceStatus)/\(.EngineVersion)"] | join(",")' --arg v "$want_ver" "$WORK/members.json")"
                [[ -n "$mb" ]] && { st="members:$mb"; saw=1; }
            fi
        fi
        remaining=0
        if [[ -n "$acts" ]]; then
            get_pending "$arn" "$WORK/wp.json" || { WAIT_DETAIL="describe-pending-maintenance-actions failed: $LAST_ERR"; return 1; }
            remaining="$(jq --arg a ",$acts," '[.PendingMaintenanceActions[]?.PendingMaintenanceActionDetails[] | .Action as $x | select($a | contains("," + $x + ","))] | length' "$WORK/wp.json")" \
                || { WAIT_DETAIL="cannot parse pending actions"; return 1; }
        fi
        el=$(( $(now) - start ))
        [[ "$st" != "$last_st" ]] && log_info "    $id: status $st, ${remaining} selected action(s) still pending${want_ver:+, version $ver} (${el}s)"
        last_st="$st"
        [[ "$FAILED_STATES" == *" $st "* ]] && { WAIT_DETAIL="status '$st'"; return 1; }
        [[ "$st" != available ]] && saw=1
        if [[ "$st" == available && "$remaining" == 0 && ( -z "$want_ver" || "$ver" == "$want_ver" ) ]]; then
            if (( saw )); then WAIT_DETAIL="status went through maintenance and is available again"
            else WAIT_DETAIL="completed without a visible status change (quick action)"; fi
            return 0
        fi
        if (( el >= TIMEOUT_SEC )); then WAIT_DETAIL="TIMEOUT after ${el}s (status $st, $remaining action(s) pending)"; return 2; fi
        if (( ! saw && el >= GRACE_SEC )); then
            WAIT_DETAIL="not started by AWS within ${GRACE_SEC}s (status stayed available, $remaining action(s) still pending - deferred or queued?)"; return 1
        fi
        sleep_poll
    done
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------
snap_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-' | tr -s '-' | sed -E 's/^-+//; s/^(.{0,231}).*/\1/; s/-+$//'; }

step_snapshot() {
    SNAP_NAME="pre-maint-$(snap_id "$CLUSTER")-$(date -u +%Y%m%d-%H%M)"
    step_begin snapshot "$CLUSTER" "" "$(cluster_field EngineVersion)"
    IN_FLIGHT="cluster snapshot $SNAP_NAME is being created (it continues in AWS if this run stops)"
    if ! aws_call "$WORK/snap.json" "$SVC" create-db-cluster-snapshot --db-cluster-identifier "$CLUSTER" --db-cluster-snapshot-identifier "$SNAP_NAME"; then
        step_end failed "create-db-cluster-snapshot $SNAP_NAME: $LAST_ERR" ""; return 3
    fi
    log_info "    snapshot $SNAP_NAME requested; waiting (aws rds wait, then polling)"
    local start rem rc=0 st=""
    start="$(now)"
    # the CLI waiter checks every 30 s and gives up after 60 attempts (30 min): wrap it in the step timeout and
    # fall back to polling if it gives up earlier
    if command -v timeout >/dev/null 2>&1; then
        rem=$(( TIMEOUT_SEC - ($(now) - start) )); (( rem < 1 )) && rem=1
        timeout "$rem" aws --no-cli-pager ${PROFILE:+--profile "$PROFILE"} --region "$REGION" rds wait db-cluster-snapshot-available \
            --db-cluster-snapshot-identifier "$SNAP_NAME" >"$WORK/snapwait.out" 2>&1 || rc=$?
    else rc=1; fi
    (( rc != 0 )) && log_info "    waiter ended rc=$rc ($(tr -s '\n' ' ' <"$WORK/snapwait.out" | cut -c1-200)); polling"
    while :; do
        aws_call "$WORK/snapd.json" rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "$SNAP_NAME" \
            || { step_end failed "describe-db-cluster-snapshots: $LAST_ERR" ""; return 3; }
        st="$(jq -r '.DBClusterSnapshots[0].Status // "unknown"' "$WORK/snapd.json")"
        [[ "$st" == available ]] && break
        [[ "$st" == failed || "$st" == error ]] && { step_end failed "snapshot $SNAP_NAME status $st" ""; return 3; }
        (( $(now) - start >= TIMEOUT_SEC )) && { step_end timeout "snapshot $SNAP_NAME still '$st' after $(( $(now) - start ))s" ""; return 3; }
        sleep_poll
    done
    step_end ok "snapshot $SNAP_NAME available" "$(cluster_field EngineVersion)"
}

step_minor() {   # step_minor <version>
    local to="$1" from rc=0
    get_cluster || true
    from="$(cluster_field EngineVersion)"
    step_begin minor-upgrade "$CLUSTER" "engine-version $to" "$from"
    IN_FLIGHT="modify-db-cluster --engine-version $to --apply-immediately was accepted; the upgrade continues in AWS"
    if ! aws_call "$WORK/mod.json" "$SVC" modify-db-cluster --db-cluster-identifier "$CLUSTER" --engine-version "$to" --apply-immediately; then
        IN_FLIGHT=""; step_end failed "modify-db-cluster: $LAST_ERR" "$from"; return 3
    fi
    wait_resource cluster "$CLUSTER" "" "" "$to" || rc=$?
    case "$rc" in
        0) step_end ok "$WAIT_DETAIL" "$(cluster_field EngineVersion)" ;;
        2) step_end timeout "$WAIT_DETAIL" "$(cluster_field EngineVersion)"; return 3 ;;
        *) step_end failed "$WAIT_DETAIL" "$(cluster_field EngineVersion)"; return 3 ;;
    esac
}

# apply all selected pending actions on one resource (instance or the cluster), then wait
step_apply() {   # step_apply <instance|cluster> <id> <arn> <role>
    local kind="$1" id="$2" arn="$3" role="$4" acts a rc=0 vb
    get_pending "$arn" "$WORK/sp.json" || { log_error "describe-pending-maintenance-actions $arn: $LAST_ERR"; step_begin "$role" "$id" "" ""; step_end failed "describe-pending-maintenance-actions: $LAST_ERR" ""; return 3; }
    acts="$(jq -r --argjson sel "$(json_array "${ACTIONS[@]}")" '[.PendingMaintenanceActions[]?.PendingMaintenanceActionDetails[] | .Action
             | select(. as $x | ($sel | index("all")) != null or ($sel | index($x)) != null)] | unique | join(",")' "$WORK/sp.json")"
    if [[ "$kind" == instance ]]; then
        aws_call "$WORK/vb.json" rds describe-db-instances --db-instance-identifier "$id" || true
        vb="$(jq -r '.DBInstances[0].EngineVersion // ""' "$WORK/vb.json" 2>/dev/null || true)"
    else vb="$(cluster_field EngineVersion)"; fi
    step_begin "$role" "$id" "$acts" "$vb"
    if [[ -z "$acts" ]]; then step_end skipped "no selected action pending any more (already applied, e.g. by an earlier step)" "$vb"; return 0; fi
    local -a list; IFS=',' read -r -a list <<<"$acts"
    for a in "${list[@]}"; do
        log_info "    apply-pending-maintenance-action $a --opt-in-type immediate on $id"
        if ! aws_call "$WORK/apply.json" "$SVC" apply-pending-maintenance-action --resource-identifier "$arn" --apply-action "$a" --opt-in-type immediate; then
            step_end failed "apply $a: $LAST_ERR" "$vb"; return 3
        fi
        IN_FLIGHT="$a on $id was opted in 'immediate' and continues in AWS even if this run stops"
    done
    wait_resource "$kind" "$id" "$arn" "$acts" || rc=$?
    local va="$vb"
    if [[ "$kind" == instance ]]; then va="$(jq -r '.DBInstances[0].EngineVersion // ""' "$WORK/w.json" 2>/dev/null || echo "$vb")"
    else va="$(cluster_field EngineVersion)"; fi
    case "$rc" in
        0) step_end ok "$WAIT_DETAIL" "$va" ;;
        2) step_end timeout "$WAIT_DETAIL" "$va"; return 3 ;;
        *) step_end failed "$WAIT_DETAIL" "$va"; return 3 ;;
    esac
}

LAST_WRITER=""
check_writer() {   # refresh the cluster, log a failover if the writer changed
    get_cluster || { log_warn "describe-db-clusters failed while checking the writer: $LAST_ERR"; return 0; }
    local w; w="$(current_writer)"
    if [[ -n "$LAST_WRITER" && -n "$w" && "$w" != "$LAST_WRITER" ]]; then record_failover "$LAST_WRITER" "$w"; fi
    [[ -n "$w" ]] && LAST_WRITER="$w"
    return 0
}

run_steps() {
    local plan="$WORK/plan.json" minor has_cluster cl_done=0 id next w x
    minor="$(jq -r '.minor_to' "$plan")"
    has_cluster="$(jq -r '[.steps[] | select(.kind == "cluster")] | length' "$plan")"
    LAST_WRITER="$(jq -r '.writer' "$plan")"
    mapfile -t TODO < <(jq -r '.steps[] | select(.kind == "instance") | .target' "$plan")
    if (( SKIP_SNAPSHOT )); then log_warn "--skip-snapshot: NO pre-maintenance snapshot is taken"
    else step_snapshot || return 3; fi
    if [[ -n "$minor" ]]; then step_minor "$minor" || return 3; check_writer; fi
    # readers first, one at a time; the CURRENT writer is always last (re-read after every step)
    while (( ${#TODO[@]} )); do
        check_writer; w="$LAST_WRITER"; next=""
        for x in "${TODO[@]}"; do [[ "$x" != "$w" ]] && { next="$x"; break; }; done
        if [[ -z "$next" ]]; then
            if (( has_cluster && ! cl_done )); then
                step_apply cluster "$CLUSTER" "$(cluster_field DBClusterArn)" cluster || return 3; cl_done=1; check_writer; continue
            fi
            next="$w"
        fi
        local role=reader; [[ "$next" == "$w" ]] && role=writer
        id="$next"
        if [[ "$role" == writer ]] && [[ "$(jq -r '.writer' "$plan")" != "$id" ]]; then
            log_warn "writer is now $id (planned writer was $(jq -r '.writer' "$plan")); patching the current writer last"
        fi
        step_apply instance "$id" "$(jq -r --arg i "$id" '.members[] | select(.id == $i) | .arn' "$plan")" "$role" || return 3
        DONE_IDS+=("$id")
        local -a rest=(); for x in "${TODO[@]}"; do [[ "$x" != "$id" ]] && rest+=("$x"); done; TODO=("${rest[@]}")
        check_writer
    done
    if (( has_cluster && ! cl_done )); then step_apply cluster "$CLUSTER" "$(cluster_field DBClusterArn)" cluster || return 3; check_writer; fi
    return 0
}

collect_state() {   # current versions + pending actions -> $WORK/verify.json (used by verify and by failed runs)
    get_cluster && get_members || return 1
    local arn i=0
    : >"$WORK/vp.jsonl"
    while IFS= read -r arn; do
        if get_pending "$arn" "$WORK/vp_$i.json"; then jq -c '.PendingMaintenanceActions[]?' "$WORK/vp_$i.json" >>"$WORK/vp.jsonl"; fi
        i=$(( i + 1 ))
    done < <(jq -r '.DBClusters[0].DBClusterArn' "$WORK/cluster.json"; jq -r '.DBInstances[].DBInstanceArn' "$WORK/members.json")
    jq -s --slurpfile c "$WORK/cluster.json" --slurpfile m "$WORK/members.json" --argjson sel "$(json_array "${ACTIONS[@]}")" '
        [.[] | .ResourceIdentifier as $r | .PendingMaintenanceActionDetails[]
         | {resource: ($r | split(":") | .[6:] | join(":")), action: .Action, opt_in_status: (.OptInStatus // ""),
            selected: (.Action as $x | ($sel | index("all")) != null or ($sel | index($x)) != null)}] as $rem
        | {remaining: $rem, cluster_status: $c[0].DBClusters[0].Status,
           not_available: [$m[0].DBInstances[] | select(.DBInstanceStatus != "available") | .DBInstanceIdentifier],
           versions_after: ([{resource: $c[0].DBClusters[0].DBClusterIdentifier, after: $c[0].DBClusters[0].EngineVersion}]
                            + [$m[0].DBInstances[] | {resource: .DBInstanceIdentifier, after: .EngineVersion}])}' "$WORK/vp.jsonl" >"$WORK/verify.json"
}

verify() {   # returns 1 if a selected action is still pending or something is not available
    step_begin verify "$CLUSTER" "" "$(jq -r '.cluster.version' "$WORK/plan.json")"
    if ! collect_state; then step_end failed "describe failed: $LAST_ERR" ""; return 1; fi
    local sel_left na cs
    sel_left="$(jq '[.remaining[] | select(.selected)] | length' "$WORK/verify.json")"
    na="$(jq -r '.not_available | join(",")' "$WORK/verify.json")"; cs="$(jq -r '.cluster_status' "$WORK/verify.json")"
    if [[ "$sel_left" != 0 || -n "$na" || "$cs" != available ]]; then
        step_end failed "$sel_left selected action(s) still pending; cluster $cs; not available: ${na:-none}" "$(cluster_field EngineVersion)"; return 1
    fi
    step_end ok "nothing selected left pending; cluster and all members available ($(jq '.remaining | length' "$WORK/verify.json") unselected action(s) left)" "$(cluster_field EngineVersion)"
}

# ----------------------------------------------------------------------------
# Summary + alerts
# ----------------------------------------------------------------------------
write_summary() {   # write_summary <result> <exit> <message>
    [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]] || return 0
    if [[ ! -s "$WORK/verify.json" ]] && ! collect_state 2>/dev/null; then
        log_warn "Could not read the final state for the summary: $LAST_ERR"
        echo '{"remaining":[],"versions_after":[],"unknown":true}' >"$WORK/verify.json"
    fi
    touch "$WORK/steps.jsonl" "$WORK/failovers.jsonl"
    local base="${OUTPUT_DIR%/}/${CLUSTER}_${STAMP}"
    jq -n --slurpfile plan "$WORK/plan.json" --slurpfile v "$WORK/verify.json" --slurpfile steps <(jq -cs . "$WORK/steps.jsonl") \
        --slurpfile fo <(jq -cs . "$WORK/failovers.jsonl") \
        --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" --arg account "$ACCOUNT" --arg region "$REGION" --arg profile "${PROFILE:-default}" \
        --arg started "$RUN_STARTED" --arg finished "$(utc)" --arg result "$1" --argjson exit "$2" --arg msg "$3" --arg snap "$SNAP_NAME" \
        --arg mode "$( (( EXECUTE )) && echo execute || echo dry-run)" '
        ($plan[0]) as $p
        | {meta: {script: $script, version: $version, cluster: $p.cluster.id, engine: $p.cluster.engine, account: $account, region: $region,
                  profile: $profile, started_utc: $started, finished_utc: $finished, result: $result, exit_code: $exit, message: $msg,
                  snapshot: $snap, mode: $mode},
           plan: $p, steps: $steps[0], failovers: $fo[0], remaining: $v[0].remaining, state_unknown: ($v[0].unknown // false),
           versions: ([{resource: $p.cluster.id, before: $p.cluster.version}] + [$p.members[] | {resource: .id, before: .version}]
                      | map(. as $b | $b + {after: ([$v[0].versions_after[] | select(.resource == $b.resource) | .after] | .[0] // "")}))}' \
        >"$base.json" || { log_warn "Writing the summary failed"; return 0; }
    rjq summary_text -r "$base.json" >"$base.summary.txt"
    rjq summary_csv -r "$base.json" >"$base.summary.csv"
    (( HTML )) && rjq summary_html -r "$base.json" >"$base.summary.html"
    chmod 0640 "$base".* 2>/dev/null || true
    SUMMARY_TXT="$base.summary.txt"
    log_info "Summary: $base.summary.txt, $base.summary.csv$( (( HTML )) && echo ", $base.summary.html"), $base.json; log: $LOG_FILE"
}
SUMMARY_TXT=""
RUN_STARTED=""

send_alerts() {   # send_alerts <rc>
    (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || return 0
    [[ "$ALERT_ON" == failure && "$1" == 0 ]] && return 0
    local subject body="$WORK/alert.txt" payload="$WORK/alert.json" url mailer=""
    subject="[rds_patch_runner] $CLUSTER: $( (( $1 == 0 )) && echo OK || echo "FAILED (exit $1)")"
    { printf '%s\n\n' "$RUN_MSG"; [[ -n "$SUMMARY_TXT" && -r "$SUMMARY_TXT" ]] && cat -- "$SUMMARY_TXT"; } >"$body"
    if (( ${#ALERT_EMAILS[@]} )); then
        if command -v mail >/dev/null 2>&1; then mailer="mail"; elif command -v mailx >/dev/null 2>&1; then mailer="mailx"; fi
        if [[ -n "$mailer" ]]; then
            local -a from=(); [[ -n "$ALERT_FROM" ]] && from=(-r "$ALERT_FROM")
            if "$mailer" "${from[@]}" -s "$subject" -- "${ALERT_EMAILS[@]}" <"$body"; then log_info "Alert e-mail sent to ${ALERT_EMAILS[*]}"; else log_warn "Alert e-mail failed"; fi
        elif command -v sendmail >/dev/null 2>&1; then
            if { [[ -n "$ALERT_FROM" ]] && printf 'From: %s\n' "$ALERT_FROM"
              printf 'To: %s\nSubject: %s\n\n' "$(IFS=,; echo "${ALERT_EMAILS[*]}")" "$subject"; cat -- "$body"; } | sendmail -t -oi; then
                log_info "Alert e-mail sent"; else log_warn "Alert e-mail failed"; fi
        else log_warn "Alert: no mail/mailx/sendmail found"; fi
    fi
    if (( ${#ALERT_WEBHOOKS[@]} )); then
        if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
            jq -cn --arg h "$subject" --rawfile b "$body" '{text: ("*" + $h + "*\n```" + ($b | .[0:35000]) + "```")}' >"$payload"
        else
            jq -cn --arg h "$subject" --rawfile b "$body" --argjson rc "$1" --arg c "$CLUSTER" '{cluster: $c, exit_code: $rc, subject: $h, text: $b}' >"$payload"
        fi
        for url in "${ALERT_WEBHOOKS[@]}"; do
            if printf 'url = "%s"\n' "${url//\"/\\\"}" | curl -sS --fail --max-time 20 -H 'Content-Type: application/json' --data-binary "@$payload" -o /dev/null -K - 2>/dev/null; then
                log_info "Alert webhook $(redact_url "$url") sent"; else log_warn "Alert webhook $(redact_url "$url") failed"; fi
        done
    fi
}

finish() {   # finish <rc> <result> <message>
    RUN_RC="$1"; RUN_MSG="$3"
    FINISHED=1
    if (( RUN_RC == 0 )); then log_info "$3"; else log_error "$3"; fi
    write_summary "$2" "$1" "$3"
    send_alerts "$1"
    exit "$1"
}

# ----------------------------------------------------------------------------
# Traps
# ----------------------------------------------------------------------------
# shellcheck disable=SC2317  # invoked via trap
on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    release_lock
    if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi
    exit "$rc"
}
# shellcheck disable=SC2317
on_signal() {
    trap - INT TERM
    log_error "INTERRUPTED by signal during: ${CURRENT_STEP:-no step running}"
    [[ -n "$IN_FLIGHT" ]] && log_error "STILL RUNNING IN AWS (not cancelled): $IN_FLIGHT"
    log_error "Steps done so far: ${DONE_IDS[*]:-none}; not started: ${TODO[*]:-none}"
    log_error "Check: aws rds describe-db-clusters --db-cluster-identifier $CLUSTER${REGION:+ --region $REGION}${PROFILE:+ --profile $PROFILE} and describe-pending-maintenance-actions; re-run this script to continue (it re-reads what is still pending)"
    if (( EXECUTE )) && [[ -n "$CURRENT_STEP" ]]; then step_end interrupted "${IN_FLIGHT:-stopped while waiting}" ""; fi
    (( FINISHED )) || { FINISHED=1; RUN_MSG="interrupted during ${CURRENT_STEP:-preflight}"; write_summary interrupted 130 "$RUN_MSG"; send_alerts 130; }
    exit 130
}

main() {
    trap on_exit EXIT
    trap on_signal INT TERM
    parse_args "$@"
    validate
    STAMP="$(date -u '+%Y%m%d_%H%M%S')"; RUN_STARTED="$(utc)"
    export AWS_PAGER="" AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_pr.XXXXXX")"
    : >"$WORK/steps.jsonl"; : >"$WORK/failovers.jsonl"
    if (( EXECUTE )); then
        [[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="./rds_patch_runs"
        if ! { mkdir -p -- "$OUTPUT_DIR" 2>/dev/null && [[ -w "$OUTPUT_DIR" ]]; }; then die 1 "Output directory not writable: $OUTPUT_DIR"; fi
        [[ -n "$LOG_FILE" ]] || LOG_FILE="${OUTPUT_DIR%/}/${CLUSTER}_${STAMP}.log"
        touch -- "$LOG_FILE" 2>/dev/null || die 1 "Cannot write log file: $LOG_FILE"
        log_info "$SCRIPT_NAME v$SCRIPT_VERSION EXECUTE run for cluster $CLUSTER (log $LOG_FILE)"
        take_lock
    else
        if [[ -n "$OUTPUT_DIR" ]]; then mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || die 1 "Output directory not writable: $OUTPUT_DIR"; fi
        log_info "$SCRIPT_NAME v$SCRIPT_VERSION DRY RUN for cluster $CLUSTER (read-only; add --execute to patch)"
    fi
    preflight
    print_plan
    if [[ "$(jq -r '.nothing_to_do' "$WORK/plan.json")" == true ]]; then
        RUN_MSG="nothing to do for $CLUSTER"; log_info "$RUN_MSG"; FINISHED=1; exit 0
    fi
    if (( ! EXECUTE )); then
        FINISHED=1; log_info "Dry run only - nothing changed. Re-run with --execute to apply this plan."; exit 0
    fi
    if (( ! ASSUME_YES )); then
        if [[ -t 0 ]]; then
            local ans=""
            read -r -p "Patch $CLUSTER (account $ACCOUNT, $REGION)? [y/N] " ans || true
            [[ "${ans,,}" == y || "${ans,,}" == yes ]] || { FINISHED=1; log_warn "Declined - nothing changed"; exit 4; }
        else
            FINISHED=1; die 4 "No terminal to confirm on and --yes not given - nothing changed"
        fi
    fi
    log_info "Starting (confirmed$( (( ASSUME_YES )) && echo " by --yes"))"
    if ! run_steps; then
        finish 3 failed "Step failed: stopped here, later steps were NOT run$( [[ ${#TODO[@]} -gt 0 ]] && echo " (not patched: ${TODO[*]})")"
    fi
    if ! verify; then finish 3 failed "Verification failed: see the remaining actions / statuses"; fi
    finish 0 ok "Done: $CLUSTER patched$( [[ -n "$SNAP_NAME" ]] && echo "; pre-maintenance snapshot $SNAP_NAME")"
}

main "$@"
