#!/usr/bin/env bash
#
# rds_backup_compliance_report.sh - daily / weekly / monthly backup compliance of RDS instances and Aurora /
# Multi-AZ DB clusters across profiles (accounts) and regions, plus old manual snapshots.
# READ-ONLY: describe-* / list-* calls only. Delete commands for old manual snapshots are PRINTED, never run.
#
# Rules (defaults; all configurable):
#   Daily   - RDS automated backups: BackupRetentionPeriod >= 7 AND an automated snapshot in each of the last 7 x 24h.
#   Weekly  - AWS Backup recovery points with 28-35 day retention: >= 4 COMPLETED in the last 30 days, one per week.
#   Monthly - AWS Backup recovery points with 360-370 day retention: >= 12 COMPLETED, one per calendar month (12 months).
#   COMPLIANT only if all three PASS; UNKNOWN when a listing failed; servers without AWS Backup points are flagged.
#   Aurora / Multi-AZ clusters are judged per cluster (cluster automated snapshots + retention); members are listed.
#
# Output: text | csv | json | html (several at once with -F csv,html -o DIR).
# Exit:   0 report produced, 5 NON-COMPLIANT found with --fail-on-noncompliant, 1 usage, 2 pre-check /
#         no usable profile, 4 output/internal error, 130 interrupted.
# Logic and rendering live in lib/backup_compliance.jq.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIB="${RDS_BCR_LIB:-$SCRIPT_DIR/lib}/backup_compliance.jq"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

PROFILES=()
REGIONS=()
ALL_REGIONS=0
ENGINES=()
IDENTIFIERS=()
TAG_COLUMNS=(Environment Owner Application)
FORMATS=()
OUTPUT_DIR=""
PREFIX="rds_backup_compliance"
DISPLAY_TZ="Asia/Kolkata"
MIN_RETENTION=7
DAILY_DAYS=7
WEEKLY_MIN_DAYS=28
WEEKLY_MAX_DAYS=35
WEEKLY_WINDOW_DAYS=30
WEEKLY_REQUIRED=4
MONTHLY_MIN_DAYS=360
MONTHLY_MAX_DAYS=370
MONTHLY_REQUIRED=12
MONTHLY_GRACE_DAYS=7
RULE_NAME_FALLBACK=0
WEEKLY_RULE_REGEX='(?i)week'
MONTHLY_RULE_REGEX='(?i)month'
INCLUDE_REPLICAS=0
MAX_MANUAL_AGE=90
PRICE_PER_GB=0.095
TOP_N=10
NC_ONLY=0
FAIL_ON_NC=0
LOG_FILE=""
CONFIG_FILE=""
AWS_TIMEOUT=30
MAX_ATTEMPTS=5
KEEP_WORKDIR=0
DRY_RUN=0
VERBOSE=0

WORK=""
AWS_CALLS=0
AWS_FAILS=0
NOW=0
REPORT=""
CFG_JSON=""
declare -a ACCOUNTS_JSON=() ALL_REGIONS_SEEN=() WRITTEN=()

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() {
    local level="$1"; shift
    local line; line="$(_ts) [$level] $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
}
log_info()  { _log INFO "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local code="$1"; shift; log_error "$@"; exit "$code"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - RDS / Aurora backup compliance report (read-only)

Usage: $SCRIPT_NAME [options]

Scope:
  -P, --profile NAME        AWS CLI profile / account; repeatable or comma-separated (default: default chain)
  -r, --region REGION       Region(s); repeatable or comma-separated (default: env / profile region)
  -A, --all-regions         Every region enabled in each account (ec2 describe-regions)
  -e, --engine GLOB         postgres, mysql, mariadb, 'aurora-*', 'sqlserver-*', 'oracle-*' ... [repeatable]
  -i, --identifier GLOB     instance / cluster identifier (a cluster also matches by member)   [repeatable]
      --include-replicas    Also judge read replicas (default: skipped and counted)

Daily (RDS automated backups):
      --min-retention N     BackupRetentionPeriod must be >= N days (default: 7)
      --daily-days N        Automated snapshot required in each of the last N x 24h (default: 7)

Weekly / monthly (AWS Backup recovery points, classified by retention days):
      --weekly-retention MIN-MAX    retention range of a weekly point (default: 28-35)
      --weekly-window N             count weekly points created in the last N days (default: 30)
      --weekly-required N           need >= N, one per 7-day week (default: 4)
      --monthly-retention MIN-MAX   retention range of a monthly point (default: 360-370)
      --monthly-required N          need >= N, one per calendar month over N months (default: 12)
      --monthly-grace-days N        current month counts as pending (not a gap) until day N (default: 7; 0 = off)
      --rule-name-fallback          also classify points whose retention matches neither range by backup rule name
      --weekly-rule-regex RE        (default: '(?i)week')
      --monthly-rule-regex RE       (default: '(?i)month')

Manual snapshots:
      --max-manual-age N    list manual snapshots older than N days (default: 90)
      --price-per-gb P      USD per GB-month for the approximate cost (default: 0.095)

Report:
  -T, --tag-columns LIST    Tag keys shown as CSV columns (default: Environment,Owner,Application; '' = none)
  -F, --format LIST         text,csv,json,html (default: text). Several formats need -o
  -o, --output-dir DIR      Write <prefix>_YYYYmmdd_HHMMSS.<ext> files into DIR (csv also writes
                            _manual_snapshots.csv and _summary.csv)
      --prefix NAME         File name prefix (default: rds_backup_compliance)
      --top N               Size of the top-failures list (default: 10)
      --tz ZONE             Second time zone for the generated time (default: Asia/Kolkata)
      --non-compliant-only  List only NON-COMPLIANT / UNKNOWN servers (the summary still counts everything)
      --fail-on-noncompliant  Exit 5 when any NON-COMPLIANT server is found
  -l, --log-file FILE       Append log lines to FILE

Behaviour:
      --config FILE         key=value settings (parsed, never sourced; CLI overrides)
      --aws-timeout SEC     AWS CLI connect/read timeout (default: 30)
      --max-attempts N      AWS CLI retry attempts (default: 5)
      --keep-workdir        Keep raw AWS responses for debugging
      --dry-run             Print the AWS calls that would run; call nothing
  -v, --verbose             Debug logging
  -h, --help / -V, --version

Printed per old manual snapshot (NEVER run): aws rds delete-db-snapshot / delete-db-cluster-snapshot.
Exit codes: 0 report produced, 5 NON-COMPLIANT found (only with --fail-on-noncompliant), 1 usage,
            2 pre-check (aws/jq missing, no profile has valid credentials), 4 output error, 130 interrupted.
USAGE
}

# ----------------------------------------------------------------------------
# Helpers
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
json_array() { if (( $# )); then printf '%s\n' "$@" | jq -R . | jq -cs .; else printf '[]'; fi; }
set_range() {   # set_range <MIN var> <MAX var> <MIN-MAX> <option>
    [[ "$3" =~ ^([0-9]+)-([0-9]+)$ ]] || die 1 "$4 must be MIN-MAX days (e.g. 28-35)"
    (( 10#${BASH_REMATCH[1]} <= 10#${BASH_REMATCH[2]} )) || die 1 "$4: MIN must be <= MAX"
    printf -v "$1" '%d' "$((10#${BASH_REMATCH[1]}))"; printf -v "$2" '%d' "$((10#${BASH_REMATCH[2]}))"
}

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
            profile|profiles)       PROFILES=(); add_list PROFILES "$val" ;;
            region|regions)         REGIONS=(); add_list REGIONS "$val" ;;
            all_regions)            if is_true "$val"; then ALL_REGIONS=1; else ALL_REGIONS=0; fi ;;
            engine|engines)         ENGINES=(); add_list ENGINES "$val" ;;
            identifier|identifiers) IDENTIFIERS=(); add_list IDENTIFIERS "$val" ;;
            include_replicas)       if is_true "$val"; then INCLUDE_REPLICAS=1; else INCLUDE_REPLICAS=0; fi ;;
            min_retention)          MIN_RETENTION="$val" ;;
            daily_days)             DAILY_DAYS="$val" ;;
            weekly_retention)       set_range WEEKLY_MIN_DAYS WEEKLY_MAX_DAYS "$val" "Config $file:$lineno: weekly_retention" ;;
            weekly_window)          WEEKLY_WINDOW_DAYS="$val" ;;
            weekly_required)        WEEKLY_REQUIRED="$val" ;;
            monthly_retention)      set_range MONTHLY_MIN_DAYS MONTHLY_MAX_DAYS "$val" "Config $file:$lineno: monthly_retention" ;;
            monthly_required)       MONTHLY_REQUIRED="$val" ;;
            monthly_grace_days)     MONTHLY_GRACE_DAYS="$val" ;;
            rule_name_fallback)     if is_true "$val"; then RULE_NAME_FALLBACK=1; else RULE_NAME_FALLBACK=0; fi ;;
            weekly_rule_regex)      WEEKLY_RULE_REGEX="$val" ;;
            monthly_rule_regex)     MONTHLY_RULE_REGEX="$val" ;;
            max_manual_age)         MAX_MANUAL_AGE="$val" ;;
            price_per_gb|price_per_gb_month) PRICE_PER_GB="$val" ;;
            tag_columns)            TAG_COLUMNS=(); add_list TAG_COLUMNS "$val" ;;
            format|formats)         FORMATS=(); add_list FORMATS "$val" ;;
            output_dir)             OUTPUT_DIR="${val/#\~/$HOME}" ;;
            prefix)                 PREFIX="$val" ;;
            tz)                     DISPLAY_TZ="$val" ;;
            top)                    TOP_N="$val" ;;
            non_compliant_only)     if is_true "$val"; then NC_ONLY=1; else NC_ONLY=0; fi ;;
            fail_on_noncompliant)   if is_true "$val"; then FAIL_ON_NC=1; else FAIL_ON_NC=0; fi ;;
            log_file)               LOG_FILE="${val/#\~/$HOME}" ;;
            aws_timeout)            AWS_TIMEOUT="$val" ;;
            max_attempts)           MAX_ATTEMPTS="$val" ;;
            verbose)                if is_true "$val"; then VERBOSE=1; else VERBOSE=0; fi ;;
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
    local -A seen=()
    local opt
    reset_once() { [[ -n "${seen[$1]:-}" ]] && return 0; seen[$1]=1; local -n _a="$1"; _a=(); }
    while (( $# )); do
        opt="$1"
        if [[ "$opt" == --*=* ]]; then set -- "${opt%%=*}" "${opt#*=}" "${@:2}"; opt="$1"; fi
        case "$opt" in
            -P|--profile)       need_arg "$opt" $#; reset_once PROFILES; add_list PROFILES "$2"; shift 2 ;;
            -r|--region)        need_arg "$opt" $#; reset_once REGIONS; add_list REGIONS "$2"; shift 2 ;;
            -A|--all-regions)   ALL_REGIONS=1; shift ;;
            -e|--engine)        need_arg "$opt" $#; reset_once ENGINES; add_list ENGINES "$2"; shift 2 ;;
            -i|--identifier)    need_arg "$opt" $#; reset_once IDENTIFIERS; add_list IDENTIFIERS "$2"; shift 2 ;;
            --include-replicas) INCLUDE_REPLICAS=1; shift ;;
            --min-retention)    need_arg "$opt" $#; MIN_RETENTION="$2"; shift 2 ;;
            --daily-days)       need_arg "$opt" $#; DAILY_DAYS="$2"; shift 2 ;;
            --weekly-retention) need_arg "$opt" $#; set_range WEEKLY_MIN_DAYS WEEKLY_MAX_DAYS "$2" "$opt"; shift 2 ;;
            --weekly-window)    need_arg "$opt" $#; WEEKLY_WINDOW_DAYS="$2"; shift 2 ;;
            --weekly-required)  need_arg "$opt" $#; WEEKLY_REQUIRED="$2"; shift 2 ;;
            --monthly-retention) need_arg "$opt" $#; set_range MONTHLY_MIN_DAYS MONTHLY_MAX_DAYS "$2" "$opt"; shift 2 ;;
            --monthly-required) need_arg "$opt" $#; MONTHLY_REQUIRED="$2"; shift 2 ;;
            --monthly-grace-days) need_arg "$opt" $#; MONTHLY_GRACE_DAYS="$2"; shift 2 ;;
            --rule-name-fallback) RULE_NAME_FALLBACK=1; shift ;;
            --weekly-rule-regex)  need_arg "$opt" $#; WEEKLY_RULE_REGEX="$2"; shift 2 ;;
            --monthly-rule-regex) need_arg "$opt" $#; MONTHLY_RULE_REGEX="$2"; shift 2 ;;
            --max-manual-age)   need_arg "$opt" $#; MAX_MANUAL_AGE="$2"; shift 2 ;;
            --price-per-gb)     need_arg "$opt" $#; PRICE_PER_GB="$2"; shift 2 ;;
            -T|--tag-columns)   need_arg "$opt" $#; TAG_COLUMNS=(); add_list TAG_COLUMNS "$2"; shift 2 ;;
            -F|--format)        need_arg "$opt" $#; reset_once FORMATS; add_list FORMATS "$2"; shift 2 ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix)           need_arg "$opt" $#; PREFIX="$2"; shift 2 ;;
            --tz)               need_arg "$opt" $#; DISPLAY_TZ="$2"; shift 2 ;;
            --top)              need_arg "$opt" $#; TOP_N="$2"; shift 2 ;;
            --non-compliant-only) NC_ONLY=1; shift ;;
            --fail-on-noncompliant) FAIL_ON_NC=1; shift ;;
            -l|--log-file)      need_arg "$opt" $#; LOG_FILE="$2"; shift 2 ;;
            --config)           shift 2 ;;
            --aws-timeout)      need_arg "$opt" $#; AWS_TIMEOUT="$2"; shift 2 ;;
            --max-attempts)     need_arg "$opt" $#; MAX_ATTEMPTS="$2"; shift 2 ;;
            --keep-workdir)     KEEP_WORKDIR=1; shift ;;
            --dry-run)          DRY_RUN=1; shift ;;
            -v|--verbose)       VERBOSE=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            -V|--version)       echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *)                  die 1 "Unknown option: $opt (see --help)" ;;
        esac
    done
}

posint() {   # posint <var> <option> [allow0]
    local -n _v="$1"
    if [[ ! "$_v" =~ ^[0-9]+$ ]] || { [[ -z "${3:-}" ]] && (( 10#$_v == 0 )); }; then
        die 1 "$2 must be a ${3:+non-negative}${3:-positive} whole number"
    fi
    _v=$(( 10#$_v ))
}

validate() {
    command -v jq >/dev/null 2>&1 || die 2 "jq not found in PATH (install jq 1.6+)"
    local x
    (( ${#FORMATS[@]} )) || FORMATS=(text)
    for x in "${FORMATS[@]}"; do case "${x,,}" in text|txt|csv|json|html) ;; *) die 1 "Unknown format '$x' (text,csv,json,html)" ;; esac; done
    mapfile -t FORMATS < <(printf '%s\n' "${FORMATS[@],,}" | sed 's/^txt$/text/' | awk '!s[$0]++')
    if (( ${#FORMATS[@]} > 1 )) && [[ -z "$OUTPUT_DIR" ]]; then die 1 "Several formats need --output-dir"; fi
    if [[ " ${FORMATS[*]} " == *" csv "* && -z "$OUTPUT_DIR" ]]; then log_info "csv to stdout: servers only (use -o for the manual-snapshot and summary CSVs)"; fi
    if [[ -n "$OUTPUT_DIR" && "$DRY_RUN" -eq 0 ]]; then
        if ! mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || [[ ! -w "$OUTPUT_DIR" ]]; then die 1 "Output directory not writable: $OUTPUT_DIR"; fi
    fi
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--prefix may contain only letters, digits, . _ -"
    (( ALL_REGIONS && ${#REGIONS[@]} )) && die 1 "Use either --region or --all-regions, not both"
    for x in "${REGIONS[@]}"; do [[ "$x" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die 1 "Invalid region: $x"; done
    for x in "${PROFILES[@]}"; do [[ "$x" =~ ^[A-Za-z0-9_.+@-]+$ ]] || die 1 "Invalid profile name: $x"; done
    posint MIN_RETENTION --min-retention; posint DAILY_DAYS --daily-days
    posint WEEKLY_WINDOW_DAYS --weekly-window; posint WEEKLY_REQUIRED --weekly-required
    posint MONTHLY_REQUIRED --monthly-required; posint MONTHLY_GRACE_DAYS --monthly-grace-days 0
    posint MAX_MANUAL_AGE --max-manual-age 0; posint TOP_N --top
    posint AWS_TIMEOUT --aws-timeout; posint MAX_ATTEMPTS --max-attempts
    (( DAILY_DAYS <= 35 )) || die 1 "--daily-days must be <= 35 (the RDS retention maximum)"
    (( WEEKLY_REQUIRED * 7 <= WEEKLY_WINDOW_DAYS + 6 )) || die 1 "--weekly-required $WEEKLY_REQUIRED weeks do not fit in --weekly-window $WEEKLY_WINDOW_DAYS days"
    (( MONTHLY_REQUIRED <= 120 )) || die 1 "--monthly-required must be <= 120"
    (( MONTHLY_GRACE_DAYS <= 28 )) || die 1 "--monthly-grace-days must be <= 28"
    [[ "$PRICE_PER_GB" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die 1 "--price-per-gb must be a number (USD per GB-month)"
    for x in "$WEEKLY_RULE_REGEX" "$MONTHLY_RULE_REGEX"; do
        jq -n --arg r "$x" '"" | test($r)' >/dev/null 2>&1 || die 1 "Invalid rule-name regex: $x"
    done
    [[ -e "/usr/share/zoneinfo/$DISPLAY_TZ" || "$DISPLAY_TZ" == UTC ]] || die 1 "Unknown time zone: $DISPLAY_TZ"
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then touch -- "$LOG_FILE" 2>/dev/null || die 1 "Cannot write log file: $LOG_FILE"; fi
    (( ${#PROFILES[@]} )) || PROFILES=("")
}

filters_text() {
    local -a p=()
    (( ${#ENGINES[@]} )) && p+=("engine=$(IFS=,; echo "${ENGINES[*]}")")
    (( ${#IDENTIFIERS[@]} )) && p+=("identifier=$(IFS=,; echo "${IDENTIFIERS[*]}")")
    (( NC_ONLY )) && p+=("non-compliant only")
    (( INCLUDE_REPLICAS )) && p+=("read replicas included")
    local out="" x
    for x in "${p[@]}"; do out+="${out:+; }$x"; done
    echo "$out"
}

build_cfg() {
    CFG_JSON="$(jq -cn \
        --argjson engines "$(json_array "${ENGINES[@]}")" --argjson identifiers "$(json_array "${IDENTIFIERS[@]}")" \
        --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}")" \
        --argjson min_retention "$MIN_RETENTION" --argjson daily_days "$DAILY_DAYS" \
        --argjson wmin "$WEEKLY_MIN_DAYS" --argjson wmax "$WEEKLY_MAX_DAYS" --argjson wwin "$WEEKLY_WINDOW_DAYS" --argjson wreq "$WEEKLY_REQUIRED" \
        --argjson mmin "$MONTHLY_MIN_DAYS" --argjson mmax "$MONTHLY_MAX_DAYS" --argjson mreq "$MONTHLY_REQUIRED" --argjson mgrace "$MONTHLY_GRACE_DAYS" \
        --argjson rnf "$RULE_NAME_FALLBACK" --arg wre "$WEEKLY_RULE_REGEX" --arg mre "$MONTHLY_RULE_REGEX" \
        --argjson rep "$INCLUDE_REPLICAS" --argjson mage "$MAX_MANUAL_AGE" --argjson price "$PRICE_PER_GB" \
        --argjson top "$TOP_N" --argjson nc "$NC_ONLY" \
        '{engines: $engines, identifiers: $identifiers, tagcols: $tagcols, min_retention: $min_retention, daily_days: $daily_days,
          weekly_min_days: $wmin, weekly_max_days: $wmax, weekly_window_days: $wwin, weekly_required: $wreq,
          monthly_min_days: $mmin, monthly_max_days: $mmax, monthly_required: $mreq, monthly_grace_days: $mgrace,
          rule_name_fallback: ($rnf == 1), weekly_rule_regex: $wre, monthly_rule_regex: $mre,
          include_replicas: ($rep == 1), max_manual_age: $mage, price_per_gb_month: $price, top_n: $top, nc_only: ($nc == 1)}')"
}

# every jq call into the library gets the same mode / now / cfg
rjq() {   # rjq <mode> [extra jq args...]
    local mode="$1"; shift
    TZ="$DISPLAY_TZ" jq --arg mode "$mode" --argjson now "$NOW" --argjson cfg "$CFG_JSON" -f "$LIB" "$@"
}

# ----------------------------------------------------------------------------
# AWS access (read-only)
# ----------------------------------------------------------------------------
aws_base() {   # aws_base <profile> <region>
    AWS_CMD=(aws --output json --no-cli-pager --cli-connect-timeout "$AWS_TIMEOUT" --cli-read-timeout "$AWS_TIMEOUT")
    [[ -n "$1" ]] && AWS_CMD+=(--profile "$1")
    [[ -n "$2" ]] && AWS_CMD+=(--region "$2")
    return 0
}
LAST_ERR=""
aws_call() {   # aws_call <outfile> <profile> <region> <service> <operation> [args...]
    local out="$1" profile="$2" region="$3"; shift 3
    local rc=0
    case "$2" in describe-*|list-*|get-*) ;; *) die 4 "internal: refusing non-read-only call aws $1 $2" ;; esac
    aws_base "$profile" "$region"
    AWS_CALLS=$(( AWS_CALLS + 1 ))
    log_debug "[${profile:-default}/$region] aws $*"
    "${AWS_CMD[@]}" "$@" >"$out" 2>"$out.err" || rc=$?
    if (( rc == 0 )) && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    LAST_ERR="$(tr -s '\n' ' ' <"$out.err" | sed -E 's/aws: \[ERROR\]: //g; s/^ +//; s/ +$//')"
    [[ -n "$LAST_ERR" ]] || LAST_ERR="exit $rc, invalid or empty JSON output"
    (( ${#LAST_ERR} > 400 )) && LAST_ERR="${LAST_ERR:0:400}..."
    AWS_FAILS=$(( AWS_FAILS + 1 ))
    log_error "[${profile:-default}/$region] 'aws $1 $2' failed (rc=$rc): $LAST_ERR"
    return 1
}
add_error() {   # add_error <account> <profile> <region> <call> <message>
    jq -cn --arg a "$1" --arg p "${2:-default}" --arg r "$3" --arg c "$4" --arg m "$5" \
        '{account: $a, profile: $p, region: $r, call: $c, message: $m}' >>"$WORK/errors.jsonl"
}

precheck() {
    command -v aws >/dev/null 2>&1 || die 2 "AWS CLI not found in PATH (install AWS CLI v2)"
    local v; v="$(aws --version 2>&1 || true)"
    [[ "$v" =~ aws-cli/([0-9]+) ]] || die 2 "Cannot determine AWS CLI version: ${v%%$'\n'*}"
    (( BASH_REMATCH[1] >= 2 )) || die 2 "AWS CLI v2 required (found ${v%% *})"
    v="$(jq --version 2>/dev/null || true)"
    [[ "$v" =~ ^jq-1\.([6-9]|[1-9][0-9]) ]] || die 2 "jq 1.6 or newer required (found ${v:-unknown})"
    [[ -r "$LIB" ]] || die 2 "Library missing: $LIB"
}

default_region() {   # default_region <profile>
    local r="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    if [[ -z "$r" ]]; then
        local -a p=(); [[ -n "$1" ]] && p=(--profile "$1")
        r="$(aws configure get region "${p[@]}" 2>/dev/null || true)"
    fi
    printf '%s' "$r"
}

# oldest recovery point that can matter: start of the oldest required month, minus a margin
rp_created_after() {
    local months=$(( MONTHLY_REQUIRED + 1 )) days
    days=$(( months * 31 > WEEKLY_WINDOW_DAYS + 7 ? months * 31 : WEEKLY_WINDOW_DAYS + 7 ))
    date -u -d "@$(( NOW - days * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ'
}

# snap <out-json> <key> <profile> <region> <op> <type>  -> 0 ok / 1 failed (error recorded)
snap() {
    local out="$1" key="$2" profile="$3" region="$4" op="$5" type="$6" account="$7"
    if aws_call "$out.raw" "$profile" "$region" rds "$op" --snapshot-type "$type"; then
        jq -c --arg k "$key" '.[$k] // []' "$out.raw" >"$out"; return 0
    fi
    add_error "$account" "$profile" "$region" "rds $op --snapshot-type $type" "$LAST_ERR"
    printf '[]' >"$out"; return 1
}

collect_region() {   # collect_region <profile> <account> <region> <dir>
    local profile="$1" account="$2" region="$3" d="$4" autoi=true autoc=true man=true bk=true v n=0
    mkdir -p "$d"
    if ! aws_call "$d/r_clusters.json" "$profile" "$region" rds describe-db-clusters; then
        add_error "$account" "$profile" "$region" "rds describe-db-clusters" "$LAST_ERR"; return 0
    fi
    if ! aws_call "$d/r_instances.json" "$profile" "$region" rds describe-db-instances; then
        add_error "$account" "$profile" "$region" "rds describe-db-instances" "$LAST_ERR"; return 0
    fi
    jq -c '.DBClusters // []' "$d/r_clusters.json" >"$d/clusters.json"
    jq -c '.DBInstances // []' "$d/r_instances.json" >"$d/instances.json"
    snap "$d/sa_i.json" DBSnapshots "$profile" "$region" describe-db-snapshots automated "$account" || autoi=false
    snap "$d/sa_c.json" DBClusterSnapshots "$profile" "$region" describe-db-cluster-snapshots automated "$account" || autoc=false
    snap "$d/sm_i.json" DBSnapshots "$profile" "$region" describe-db-snapshots manual "$account" || man=false
    snap "$d/sm_c.json" DBClusterSnapshots "$profile" "$region" describe-db-cluster-snapshots manual "$account" || man=false
    : >"$d/rp.jsonl"
    if aws_call "$d/r_vaults.json" "$profile" "$region" backup list-backup-vaults; then
        local after; after="$(rp_created_after)"
        while IFS= read -r v; do
            n=$(( n + 1 ))
            if aws_call "$d/r_rp_$n.json" "$profile" "$region" backup list-recovery-points-by-backup-vault --backup-vault-name "$v" --by-created-after "$after"; then
                jq -c '.RecoveryPoints[]? | select(.ResourceType == "RDS" or .ResourceType == "Aurora" or ((.ResourceArn // "") | test(":rds:")))' "$d/r_rp_$n.json" >>"$d/rp.jsonl"
            else
                add_error "$account" "$profile" "$region" "backup list-recovery-points-by-backup-vault ($v)" "$LAST_ERR"; bk=false
            fi
        done < <(jq -r '.BackupVaultList[]?.BackupVaultName' "$d/r_vaults.json")
    else
        add_error "$account" "$profile" "$region" "backup list-backup-vaults" "$LAST_ERR (weekly/monthly UNKNOWN)"; bk=false
    fi
    jq -cs . "$d/rp.jsonl" >"$d/rp.json"
    log_info "[${profile:-default}/$region] $(jq length "$d/clusters.json") cluster(s), $(jq length "$d/instances.json") instance(s), $(jq length "$d/sa_i.json")+$(jq length "$d/sa_c.json") automated / $(jq length "$d/sm_i.json")+$(jq length "$d/sm_c.json") manual snapshot(s), $n vault(s), $(jq length "$d/rp.json") RDS recovery point(s)"
    rjq rows -n --arg profile "${profile:-default}" --arg account "$account" --arg region "$region" \
        --argjson ok "{\"snap_auto_i\": $autoi, \"snap_auto_c\": $autoc, \"snap_manual\": $man, \"backup\": $bk}" \
        --slurpfile inst "$d/instances.json" --slurpfile clus "$d/clusters.json" \
        --slurpfile sa_i "$d/sa_i.json" --slurpfile sa_c "$d/sa_c.json" --slurpfile sm_i "$d/sm_i.json" --slurpfile sm_c "$d/sm_c.json" \
        --slurpfile rp "$d/rp.json" >"$d/rows.json" || die 4 "Building rows failed for ${profile:-default}/$region"
    log_info "[${profile:-default}/$region] $(jq -r '.servers | group_by(.compliance_status) | map("\(.[0].compliance_status)=\(length)") | join(" ") | if . == "" then "no matching servers" else . end' "$d/rows.json"); old manual snapshots=$(jq '.manual | length' "$d/rows.json")"
}

collect_profile() {   # collect_profile <index> <profile>
    local idx="$1" profile="$2" account region base
    local -a regions=()
    base="${REGIONS[0]:-$(default_region "$profile")}"
    if [[ -z "$base" ]]; then
        if (( ALL_REGIONS )); then base="us-east-1"
        else add_error "-" "$profile" "-" "region" "no region given and profile has none"; return 1; fi
    fi
    mkdir -p "$WORK/p$idx"
    if ! aws_call "$WORK/p$idx/sts.json" "$profile" "$base" sts get-caller-identity; then
        local hint=""
        [[ "$LAST_ERR" == *[Ss][Ss][Oo]* || "$LAST_ERR" == *[Ee]xpired* ]] && hint=" (run: aws sso login${profile:+ --profile $profile})"
        add_error "-" "$profile" "-" "sts get-caller-identity" "credentials invalid: $LAST_ERR$hint"
        return 1
    fi
    account="$(jq -r '.Account' "$WORK/p$idx/sts.json")"
    log_info "Profile ${profile:-default}: account $account ($(jq -r '.Arn' "$WORK/p$idx/sts.json"))"
    ACCOUNTS_JSON+=("$(jq -cn --arg a "$account" --arg p "${profile:-default}" '{account: $a, profile: $p}')")
    if (( ALL_REGIONS )); then
        if ! aws_call "$WORK/p$idx/regions.json" "$profile" "$base" ec2 describe-regions; then
            add_error "$account" "$profile" "-" "ec2 describe-regions" "$LAST_ERR"; return 0
        fi
        mapfile -t regions < <(jq -r '.Regions[].RegionName' "$WORK/p$idx/regions.json" | sort)
    elif (( ${#REGIONS[@]} )); then regions=("${REGIONS[@]}")
    else regions=("$base"); fi
    for region in "${regions[@]}"; do
        ALL_REGIONS_SEEN+=("$region")
        collect_region "$profile" "$account" "$region" "$WORK/p$idx/$region"
    done
    return 0
}

# ----------------------------------------------------------------------------
# Report assembly and output
# ----------------------------------------------------------------------------
build_report() {
    local -a rowfiles=()
    mapfile -t rowfiles < <(find "$WORK" -name rows.json -type f | sort)
    # large data goes to jq only as FILES, never as arguments (ARG_MAX)
    if (( ${#rowfiles[@]} )); then
        jq -cs '{servers: (map(.servers) | add // []), manual: (map(.manual) | add // []), skipped_replicas: (map(.skipped_replicas) | add // [])}' -- "${rowfiles[@]}" >"$WORK/all_rows.json"
    else printf '{"servers":[],"manual":[],"skipped_replicas":[]}' >"$WORK/all_rows.json"; fi
    if [[ -s "$WORK/errors.jsonl" ]]; then jq -cs . "$WORK/errors.jsonl" >"$WORK/all_errors.json"; else printf '[]' >"$WORK/all_errors.json"; fi
    : >"$WORK/accounts.jsonl"
    if (( ${#ACCOUNTS_JSON[@]} )); then printf '%s\n' "${ACCOUNTS_JSON[@]}" >"$WORK/accounts.jsonl"; fi
    jq -n --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" \
        --arg gu "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M UTC')" --arg gl "$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Y-%m-%d %H:%M %Z')" \
        --arg tz "$DISPLAY_TZ" --arg host "$(hostname 2>/dev/null || echo unknown)" \
        --slurpfile accounts "$WORK/accounts.jsonl" \
        --argjson regions "$(json_array "${ALL_REGIONS_SEEN[@]}" | jq -c 'unique')" \
        --arg ft "$(filters_text)" --argjson cfg "$CFG_JSON" --argjson calls "$AWS_CALLS" --argjson fails "$AWS_FAILS" \
        '{script: $script, version: $version, generated_utc: $gu, generated_local: $gl, tz: $tz, host: $host,
          accounts: $accounts, regions: $regions, filters_text: $ft, rules: $cfg, aws_calls: $calls, aws_failures: $fails}' >"$WORK/meta.json" \
        || die 4 "Building report metadata failed"
    REPORT="$WORK/report.json"
    jq -n --slurpfile meta "$WORK/meta.json" --slurpfile rows "$WORK/all_rows.json" --slurpfile errors "$WORK/all_errors.json" \
        '{meta: $meta[0]} + $rows[0] + {errors: $errors[0]}' >"$WORK/raw_report.json" || die 4 "Assembling the report failed"
    rjq finalize "$WORK/raw_report.json" >"$REPORT" || die 4 "Finalizing the report failed"
}

render() {   # render <mode>  -> stdout
    case "$1" in
        json) rjq json "$REPORT" ;;
        *)    rjq "$1" -r "$REPORT" ;;
    esac
}

write_file() {   # write_file <mode> <file>
    local tmp="$WORK/out.$1" file="$2"
    render "$1" >"$tmp" || die 4 "Rendering $1 failed"
    if ! { cp -- "$tmp" "$file.tmp.$$" && mv -f -- "$file.tmp.$$" "$file"; }; then die 4 "Cannot write $file"; fi
    chmod 0640 -- "$file" 2>/dev/null || true
    WRITTEN+=("$(cd -- "$(dirname -- "$file")" && pwd -P)/${file##*/}")
    log_info "Wrote ${WRITTEN[-1]}"
}

write_outputs() {
    local fmt ext base stamp
    stamp="$(date -d "@$NOW" '+%Y%m%d_%H%M%S')"
    for fmt in "${FORMATS[@]}"; do
        if [[ -z "$OUTPUT_DIR" ]]; then render "$fmt" || die 4 "Rendering $fmt failed"; continue; fi
        ext="$fmt"; [[ "$fmt" == text ]] && ext="txt"
        base="${OUTPUT_DIR%/}/${PREFIX}_${stamp}"
        write_file "$fmt" "$base.$ext"
        if [[ "$fmt" == csv ]]; then
            write_file csv_manual "${base}_manual_snapshots.csv"
            write_file csv_summary "${base}_summary.csv"
        fi
    done
}

dry_run_plan() {
    local p r
    echo "$SCRIPT_NAME v$SCRIPT_VERSION dry run - no AWS calls are made"
    echo "  profiles : $(for p in "${PROFILES[@]}"; do printf '%s ' "${p:-default}"; done)"
    echo "  regions  : $( (( ALL_REGIONS )) && echo "all enabled per account" || echo "${REGIONS[*]:-profile default}")"
    echo "  filters  : $(filters_text)"
    echo "  daily    : retention >= $MIN_RETENTION, automated snapshot in each of the last $DAILY_DAYS x 24h"
    echo "  weekly   : ${WEEKLY_MIN_DAYS}-${WEEKLY_MAX_DAYS}d retention, >= $WEEKLY_REQUIRED in ${WEEKLY_WINDOW_DAYS}d, one per week"
    echo "  monthly  : ${MONTHLY_MIN_DAYS}-${MONTHLY_MAX_DAYS}d retention, >= $MONTHLY_REQUIRED, one per calendar month"
    echo "  manual   : older than ${MAX_MANUAL_AGE}d at \$${PRICE_PER_GB}/GB-month (approximate)"
    echo "  formats  : ${FORMATS[*]} -> ${OUTPUT_DIR:-stdout}"
    for p in "${PROFILES[@]}"; do
        r="${REGIONS[0]:-<region>}"
        echo "Profile ${p:-default}:"
        aws_base "$p" "$r"; printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" sts get-caller-identity)"
        (( ALL_REGIONS )) && printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" ec2 describe-regions)"
        for r in "${REGIONS[@]:-<each-region>}"; do
            aws_base "$p" "$r"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-clusters)"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-instances)"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-snapshots --snapshot-type automated)" "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-snapshots --snapshot-type manual)"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-cluster-snapshots --snapshot-type automated)" "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-cluster-snapshots --snapshot-type manual)"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" backup list-backup-vaults)"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" backup list-recovery-points-by-backup-vault --backup-vault-name "<each vault>" --by-created-after "<~$(( MONTHLY_REQUIRED + 1 )) months ago>")"
        done
    done
}

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
    validate
    NOW="$(date +%s)"
    [[ -n "${RDS_BCR_NOW:-}" ]] && NOW="$RDS_BCR_NOW"   # tests: fixed clock
    build_cfg
    export AWS_PAGER="" AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
    if (( DRY_RUN )); then dry_run_plan; exit 0; fi
    precheck
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_bcr.XXXXXX")"
    : >"$WORK/errors.jsonl"
    local i ok=0
    for i in "${!PROFILES[@]}"; do
        if collect_profile "$i" "${PROFILES[$i]}"; then ok=$(( ok + 1 )); fi
    done
    if (( ok == 0 )); then
        jq -r '"\(.profile): \(.message)"' "$WORK/errors.jsonl" | while IFS= read -r l; do log_error "$l"; done
        die 2 "No profile could be used (credentials / region); nothing to report"
    fi
    build_report
    write_outputs
    local rc=0 nc
    nc="$(jq -r '.summary.non_compliant' "$REPORT")"
    (( FAIL_ON_NC && nc > 0 )) && rc=5
    log_info "$(jq -r '"Result: \(.summary.total) server(s)/cluster(s): COMPLIANT \(.summary.compliant), NON-COMPLIANT \(.summary.non_compliant), UNKNOWN \(.summary.unknown) (\(.summary.pct_compliant)% compliant); no AWS Backup \(.summary.no_aws_backup); old manual snapshots \(.summary.manual.count) (\(.summary.manual.total_gb) GB, ~$\(.summary.manual.est_monthly_usd)/month); \(.summary.errors) error(s)"' "$REPORT"); $AWS_CALLS AWS call(s); exit $rc"
    exit "$rc"
}

main "$@"
