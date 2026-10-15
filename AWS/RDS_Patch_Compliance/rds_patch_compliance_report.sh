#!/usr/bin/env bash
#
# rds_patch_compliance_report.sh - minor-version patch compliance of Aurora / RDS / Multi-AZ DB cluster /
# DocumentDB / Neptune databases, across profiles (accounts) and regions. READ-ONLY: describe-* only.
#
# Rule: versions_behind = number of valid MINOR upgrade targets RDS returns for the current version
# (describe-db-engine-versions --engine E --engine-version V: ValidUpgradeTarget[] with IsMajorVersionUpgrade=false).
# COMPLIANT if <= --max-behind (default 2), NON-COMPLIANT otherwise, UNKNOWN if the lookup failed or the current
# version is not returned (deprecated). Clusters are judged per cluster.
#
# Output: text | csv | json | html (several at once with -F csv,html -o DIR).
# Exit:   0 report produced, 5 NON-COMPLIANT found with --fail-on-noncompliant, 1 usage, 2 pre-check /
#         no usable profile, 4 output/internal error, 130 interrupted.
# Logic and rendering live in lib/compliance.jq.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.1.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIB="${RDS_PCR_LIB:-$SCRIPT_DIR/lib}/compliance.jq"

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
PREFIX="rds_patch_compliance"
DISPLAY_TZ="Asia/Kolkata"
MAX_BEHIND=2
WARN_DAYS=180
TOP_N=10
NC_ONLY=0
FAIL_ON_NC=0
readonly SLACK_MAX_CHARS=35000
LOG_FILE=""
CONFIG_FILE=""
AWS_TIMEOUT=30
MAX_ATTEMPTS=5
KEEP_WORKDIR=0
DRY_RUN=0
VERBOSE=0
ALERT_EMAILS=()
ALERT_WEBHOOKS=()
ALERT_ON="noncompliant"
ALERT_WEBHOOK_FORMAT="slack"
ALERT_FROM=""
ALERT_TEST=0

WORK=""
AWS_CALLS=0
AWS_FAILS=0
NOW=0
REPORT=""
LC_UNSUPPORTED=0
declare -a ACCOUNTS_JSON=() ALL_REGIONS_SEEN=() WRITTEN=()

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() {
    local level="$1"; shift
    local line; line="$(_ts) [$level] $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
}
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local code="$1"; shift; log_error "$@"; exit "$code"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - minor-version patch compliance report for AWS databases (read-only)

Usage: $SCRIPT_NAME [options]

Scope:
  -P, --profile NAME        AWS CLI profile / account; repeatable or comma-separated (default: default chain)
  -r, --region REGION       Region(s); repeatable or comma-separated (default: env / profile region)
  -A, --all-regions         Every region enabled in each account (ec2 describe-regions)
  -e, --engine GLOB         aurora-postgresql, aurora-mysql, postgres, mysql, mariadb, 'sqlserver-*',
                            'oracle-*', docdb, neptune (globs * ?, case-insensitive)      [repeatable]
  -i, --identifier GLOB     cluster / instance identifier (a cluster also matches by member) [repeatable]

Compliance:
      --max-behind N        COMPLIANT when RDS lists at most N valid minor upgrade targets for the
                            current version (default: 2; N+1 or more = NON-COMPLIANT)
      --warn-days N         Flag majors whose standard support ends within N days (default: 180)
      --non-compliant-only  Show only NON-COMPLIANT rows (the summary still counts everything)
      --fail-on-noncompliant  Exit 5 when any NON-COMPLIANT server is found (default: exit 0)

Report:
  -T, --tag-columns LIST    Tag keys shown as columns (default: Environment,Owner,Application; '' = none)
  -F, --format LIST         text,csv,json,html (default: text). Several formats need -o
  -o, --output-dir DIR      Write <prefix>_YYYYmmdd_HHMMSS.<ext> files into DIR
      --prefix NAME         File name prefix (default: rds_patch_compliance)
      --top N               Size of the "most behind" list (default: 10)
      --tz ZONE             Second time zone for the generated time (default: Asia/Kolkata)
  -l, --log-file FILE       Append log lines to FILE

Alerts (optional):
      --alert-email ADDR    E-mail the text report (mail/mailx/sendmail)        [repeatable]
      --alert-webhook URL   POST to a webhook via curl                         [repeatable]
      --alert-webhook-format F  slack | json                                    (default: slack)
      --alert-on WHEN       noncompliant (NON-COMPLIANT found or AWS errors) | always (default: noncompliant)
      --alert-from ADDR     From address for e-mail
      --alert-test          Send a test alert and exit

Behaviour:
      --config FILE         key=value settings (parsed, never sourced; CLI overrides)
      --aws-timeout SEC     AWS CLI connect/read timeout (default: 30)
      --max-attempts N      AWS CLI retry attempts (default: 5)
      --keep-workdir        Keep raw AWS responses for debugging
      --dry-run             Print the AWS calls that would run; call nothing
  -v, --verbose             Debug logging
  -h, --help / -V, --version

Printed per row (NEVER run): upgrade_command = modify-db-cluster / modify-db-instance --engine-version
<latest minor> without --apply-immediately (applies in the next maintenance window).

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
redact_url() { if [[ "$1" =~ ^([a-zA-Z]+://[^/]+) ]]; then printf '%s/...' "${BASH_REMATCH[1]}"; else printf '<webhook>'; fi; }
json_array() { if (( $# )); then printf '%s\n' "$@" | jq -R . | jq -cs .; else printf '[]'; fi; }

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
            tag_columns)            TAG_COLUMNS=(); add_list TAG_COLUMNS "$val" ;;
            format|formats)         FORMATS=(); add_list FORMATS "$val" ;;
            output_dir)             OUTPUT_DIR="${val/#\~/$HOME}" ;;
            prefix)                 PREFIX="$val" ;;
            tz)                     DISPLAY_TZ="$val" ;;
            max_behind)             MAX_BEHIND="$val" ;;
            warn_days)              WARN_DAYS="$val" ;;
            top)                    TOP_N="$val" ;;
            non_compliant_only)     if is_true "$val"; then NC_ONLY=1; else NC_ONLY=0; fi ;;
            fail_on_noncompliant)   if is_true "$val"; then FAIL_ON_NC=1; else FAIL_ON_NC=0; fi ;;
            log_file)               LOG_FILE="${val/#\~/$HOME}" ;;
            aws_timeout)            AWS_TIMEOUT="$val" ;;
            max_attempts)           MAX_ATTEMPTS="$val" ;;
            verbose)                if is_true "$val"; then VERBOSE=1; else VERBOSE=0; fi ;;
            alert_email|alert_emails)     ALERT_EMAILS=(); add_list ALERT_EMAILS "$val" ;;
            alert_webhook|alert_webhooks) ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$val" ;;
            alert_webhook_format)   ALERT_WEBHOOK_FORMAT="$val" ;;
            alert_on)               ALERT_ON="$val" ;;
            alert_from)             ALERT_FROM="$val" ;;
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
            -T|--tag-columns)   need_arg "$opt" $#; TAG_COLUMNS=(); add_list TAG_COLUMNS "$2"; shift 2 ;;
            -F|--format)        need_arg "$opt" $#; reset_once FORMATS; add_list FORMATS "$2"; shift 2 ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix)           need_arg "$opt" $#; PREFIX="$2"; shift 2 ;;
            --tz)               need_arg "$opt" $#; DISPLAY_TZ="$2"; shift 2 ;;
            --max-behind)       need_arg "$opt" $#; MAX_BEHIND="$2"; shift 2 ;;
            --warn-days)        need_arg "$opt" $#; WARN_DAYS="$2"; shift 2 ;;
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
            --alert-email)      need_arg "$opt" $#; reset_once ALERT_EMAILS; add_list ALERT_EMAILS "$2"; shift 2 ;;
            --alert-webhook)    need_arg "$opt" $#; reset_once ALERT_WEBHOOKS; add_list ALERT_WEBHOOKS "$2"; shift 2 ;;
            --alert-webhook-format) need_arg "$opt" $#; ALERT_WEBHOOK_FORMAT="$2"; shift 2 ;;
            --alert-on)         need_arg "$opt" $#; ALERT_ON="$2"; shift 2 ;;
            --alert-from)       need_arg "$opt" $#; ALERT_FROM="$2"; shift 2 ;;
            --alert-test)       ALERT_TEST=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            -V|--version)       echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *)                  die 1 "Unknown option: $opt (see --help)" ;;
        esac
    done
}

validate() {
    command -v jq >/dev/null 2>&1 || die 2 "jq not found in PATH (install jq 1.6+)"
    local x
    (( ${#FORMATS[@]} )) || FORMATS=(text)
    for x in "${FORMATS[@]}"; do case "${x,,}" in text|txt|csv|json|html) ;; *) die 1 "Unknown format '$x' (text,csv,json,html)" ;; esac; done
    mapfile -t FORMATS < <(printf '%s\n' "${FORMATS[@],,}" | sed 's/^txt$/text/' | awk '!s[$0]++')
    if (( ${#FORMATS[@]} > 1 )) && [[ -z "$OUTPUT_DIR" ]]; then die 1 "Several formats need --output-dir"; fi
    if [[ -n "$OUTPUT_DIR" && "$DRY_RUN" -eq 0 ]]; then
        if ! mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || [[ ! -w "$OUTPUT_DIR" ]]; then die 1 "Output directory not writable: $OUTPUT_DIR"; fi
    fi
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--prefix may contain only letters, digits, . _ -"
    (( ALL_REGIONS && ${#REGIONS[@]} )) && die 1 "Use either --region or --all-regions, not both"
    for x in "${REGIONS[@]}"; do [[ "$x" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die 1 "Invalid region: $x"; done
    for x in "${PROFILES[@]}"; do [[ "$x" =~ ^[A-Za-z0-9_.+@-]+$ ]] || die 1 "Invalid profile name: $x"; done
    [[ "$MAX_BEHIND" =~ ^[0-9]+$ ]] || die 1 "--max-behind must be a whole number (0 or more)"
    [[ "$WARN_DAYS" =~ ^[0-9]+$ ]] || die 1 "--warn-days must be a whole number"
    if [[ ! "$TOP_N" =~ ^[0-9]+$ ]] || (( TOP_N == 0 )); then die 1 "--top must be a positive integer"; fi
    MAX_BEHIND=$(( 10#$MAX_BEHIND )); WARN_DAYS=$(( 10#$WARN_DAYS )); TOP_N=$(( 10#$TOP_N ))
    [[ -e "/usr/share/zoneinfo/$DISPLAY_TZ" || "$DISPLAY_TZ" == UTC ]] || die 1 "Unknown time zone: $DISPLAY_TZ"
    if [[ ! "$AWS_TIMEOUT" =~ ^[0-9]+$ ]] || (( AWS_TIMEOUT == 0 )); then die 1 "--aws-timeout must be a positive integer"; fi
    if [[ ! "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || (( MAX_ATTEMPTS == 0 )); then die 1 "--max-attempts must be a positive integer"; fi
    case "${ALERT_ON,,}" in noncompliant|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be noncompliant or always" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be slack or json" ;; esac
    for x in "${ALERT_EMAILS[@]}"; do
        [[ "$x" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $x"
    done
    for x in "${ALERT_WEBHOOKS[@]}"; do [[ "$x" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$x")"; done
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then touch -- "$LOG_FILE" 2>/dev/null || die 1 "Cannot write log file: $LOG_FILE"; fi
    (( ${#PROFILES[@]} )) || PROFILES=("")
}

filters_json() {
    jq -cn --argjson e "$(json_array "${ENGINES[@]}")" --argjson i "$(json_array "${IDENTIFIERS[@]}")" '{engines: $e, identifiers: $i}'
}
filters_text() {
    local -a p=()
    (( ${#ENGINES[@]} )) && p+=("engine=$(IFS=,; echo "${ENGINES[*]}")")
    (( ${#IDENTIFIERS[@]} )) && p+=("identifier=$(IFS=,; echo "${IDENTIFIERS[*]}")")
    (( NC_ONLY )) && p+=("non-compliant only")
    local out="" x
    for x in "${p[@]}"; do out+="${out:+; }$x"; done
    echo "$out"
}

# compliance.jq needs every $variable defined in every mode
rjq() {   # rjq <mode> [extra jq args...]
    local mode="$1"; shift
    TZ="$DISPLAY_TZ" jq --arg mode "$mode" --argjson now "$NOW" --argjson max_behind "$MAX_BEHIND" --argjson warn_days "$WARN_DAYS" \
        --argjson top_n "$TOP_N" --argjson nc_only "$( (( NC_ONLY )) && echo true || echo false)" \
        --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}")" --argjson f "$FILTERS_JSON" -f "$LIB" "$@"
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
AWS_SOFT=0
aws_call() {   # aws_call <outfile> <profile> <region> <service> <operation> [args...]
    local out="$1" profile="$2" region="$3"; shift 3
    local rc=0
    aws_base "$profile" "$region"
    AWS_CALLS=$(( AWS_CALLS + 1 ))
    log_debug "[${profile:-default}/$region] aws $*"
    "${AWS_CMD[@]}" "$@" >"$out" 2>"$out.err" || rc=$?
    if (( rc == 0 )) && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    LAST_ERR="$(tr -s '\n' ' ' <"$out.err" | sed -E 's/aws: \[ERROR\]: //g; s/^ +//; s/ +$//')"
    [[ -n "$LAST_ERR" ]] || LAST_ERR="exit $rc, invalid or empty JSON output"
    (( ${#LAST_ERR} > 400 )) && LAST_ERR="${LAST_ERR:0:400}..."
    if (( AWS_SOFT )); then   # supplementary lookup: the caller warns, it does not count as a failure
        log_debug "[${profile:-default}/$region] 'aws $1 $2' failed (rc=$rc): $LAST_ERR"; return 1
    fi
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

# engine matches the -e globs (case-insensitive); no -e = every in-scope engine
engine_wanted() {
    (( ${#ENGINES[@]} )) || return 0
    local g; shopt -s nocasematch
    for g in "${ENGINES[@]}"; do
        # shellcheck disable=SC2053  # glob match intended
        if [[ "$1" == $g ]]; then shopt -u nocasematch; return 0; fi
    done
    shopt -u nocasematch; return 1
}
svc_of() { case "$1" in docdb) echo docdb ;; neptune) echo neptune ;; *) echo rds ;; esac; }

# Valid upgrade targets from RDS metadata ONLY: one describe-db-engine-versions --engine E --engine-version V per
# (engine, current version, region) - docdb / neptune through their own CLI - cached in $WORK/ev/<region>/ and
# shared by all profiles. Only that version's ValidUpgradeTarget[] is kept; the full version list is never read.
# Lifecycle dates (rds describe-db-major-engine-versions) are cached the same way; docdb / neptune have none.
collect_versions() {   # collect_versions <profile> <region> <dir>
    local profile="$1" region="$2" d="$3" engine ver svc cache lc key
    local -a evs=() lcs=()
    mkdir -p "$WORK/ev/$region"
    while IFS=$'\t' read -r engine ver; do
        svc="$(svc_of "$engine")"
        key="$(printf '%s_%s' "$engine" "$ver" | tr -c 'A-Za-z0-9._-' '_')"
        cache="$WORK/ev/$region/ev_$key.json"
        if [[ ! -s "$cache" ]]; then
            AWS_SOFT=1
            if aws_call "$cache.raw" "$profile" "$region" "$svc" describe-db-engine-versions --engine "$engine" --engine-version "$ver"; then
                jq -c --arg e "$engine" --arg v "$ver" '[.DBEngineVersions[]? | select(.Engine == $e and .EngineVersion == $v)][0] as $x
                    | {key: ($e + "|" + $v), value: {ok: true, error: null, returned: ($x != null),
                       major: ($x.MajorEngineVersion // (($x.DBParameterGroupFamily // "") | sub("^[A-Za-z-]+"; "") | if . == "" then null else . end)),
                       targets: [($x.ValidUpgradeTarget // [])[] | {Engine, EngineVersion, IsMajorVersionUpgrade, AutoUpgrade}]}}' \
                    "$cache.raw" >"$cache" || die 4 "Parsing describe-db-engine-versions failed for $engine $ver"
                if [[ "$(jq -r '.value.returned' "$cache")" != true ]]; then
                    log_warn "[${profile:-default}/$region] $engine $ver is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN"
                fi
            else
                log_warn "[${profile:-default}/$region] engine-version lookup for $engine $ver failed ($LAST_ERR); its servers are UNKNOWN"
                jq -cn --arg e "$engine" --arg v "$ver" --arg m "$LAST_ERR" '{key: ($e + "|" + $v), value: {ok: false, error: $m, returned: false, major: null, targets: []}}' >"$cache"
            fi
            AWS_SOFT=0
        fi
        evs+=("$cache")
        [[ "$svc" == rds ]] || continue
        lc="$WORK/ev/$region/lc_$engine.json"
        if [[ ! -s "$lc" ]] && (( ! LC_UNSUPPORTED )); then
            AWS_SOFT=1
            if aws_call "$lc.raw" "$profile" "$region" rds describe-db-major-engine-versions --engine "$engine"; then
                jq -c --arg e "$engine" '{key: $e, value: {majors: [.DBMajorEngineVersions[]? | {MajorEngineVersion, SupportedEngineLifecycles}]}}' \
                    "$lc.raw" >"$lc" || die 4 "Parsing describe-db-major-engine-versions failed for $engine"
            else
                if [[ "$LAST_ERR" == *"nvalid choice"* ]]; then
                    LC_UNSUPPORTED=1
                    log_warn "This AWS CLI has no 'rds describe-db-major-engine-versions' (upgrade the CLI); support end dates show 'unknown'"
                else
                    log_warn "[${profile:-default}/$region] lifecycle lookup for $engine failed ($LAST_ERR); support end dates show 'unknown'"
                fi
                printf '{}' >"$lc"
            fi
            AWS_SOFT=0
        fi
        [[ -s "$lc" ]] && lcs+=("$lc")
    done < <(jq -r -s '[.[0][], .[1][]] | map(select((.Engine // "") != "" and (.EngineVersion // "") != "") | [.Engine, .EngineVersion]) | unique[]
                       | select(.[0] | test("^(aurora-postgresql|aurora-mysql|postgres|mysql|mariadb|sqlserver-(ee|se|ex|web)|oracle-(ee|se2|ee-cdb|se2-cdb)|docdb|neptune)$")) | @tsv' \
                 "$d/instances.json" "$d/clusters.json" | while IFS=$'\t' read -r e v; do if engine_wanted "$e"; then printf '%s\t%s\n' "$e" "$v"; fi; done)
    if (( ${#evs[@]} )); then jq -cs 'from_entries' -- "${evs[@]}" >"$d/ev.json"; else printf '{}' >"$d/ev.json"; fi
    if (( ${#lcs[@]} )); then jq -cs 'map(select(has("key"))) | from_entries' -- "${lcs[@]}" >"$d/lc.json"; else printf '{}' >"$d/lc.json"; fi
}

collect_region() {   # collect_region <profile> <account> <region> <dir>
    local profile="$1" account="$2" region="$3" d="$4"
    mkdir -p "$d"
    if ! aws_call "$d/r_clusters.json" "$profile" "$region" rds describe-db-clusters; then
        add_error "$account" "$profile" "$region" "rds describe-db-clusters" "$LAST_ERR"; return 0
    fi
    if ! aws_call "$d/r_instances.json" "$profile" "$region" rds describe-db-instances; then
        add_error "$account" "$profile" "$region" "rds describe-db-instances" "$LAST_ERR"; return 0
    fi
    jq -c '.DBClusters // []' "$d/r_clusters.json" >"$d/clusters.json"
    jq -c '.DBInstances // []' "$d/r_instances.json" >"$d/instances.json"
    if aws_call "$d/r_pma.json" "$profile" "$region" rds describe-pending-maintenance-actions; then
        jq -c '.PendingMaintenanceActions // []' "$d/r_pma.json" >"$d/pma.json"
    else
        add_error "$account" "$profile" "$region" "rds describe-pending-maintenance-actions" "$LAST_ERR (pending_actions shown as 0)"
        printf '[]' >"$d/pma.json"
    fi
    log_info "[${profile:-default}/$region] $(jq length "$d/clusters.json") cluster(s), $(jq length "$d/instances.json") instance(s), $(jq length "$d/pma.json") resource(s) with pending maintenance"
    collect_versions "$profile" "$region" "$d"
    rjq rows -n --arg profile "${profile:-default}" --arg account "$account" --arg region "$region" \
        --slurpfile clusters "$d/clusters.json" --slurpfile instances "$d/instances.json" --slurpfile pma "$d/pma.json" \
        --slurpfile ev "$d/ev.json" --slurpfile lc "$d/lc.json" \
        >"$d/rows.json" || die 4 "Building rows failed for ${profile:-default}/$region"
    log_info "[${profile:-default}/$region] $(jq -r 'group_by(.compliance_status) | map("\(.[0].compliance_status)=\(length)") | join(" ") | if . == "" then "no matching servers" else . end' "$d/rows.json")"
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
# Report assembly, output, alerts
# ----------------------------------------------------------------------------
build_report() {
    local -a rowfiles=()
    mapfile -t rowfiles < <(find "$WORK" -name rows.json -type f | sort)
    # Large data goes to jq only as FILES, never as arguments (MAX_ARG_STRLEN 128 KiB / ARG_MAX)
    if (( ${#rowfiles[@]} )); then jq -cs 'add // []' -- "${rowfiles[@]}" >"$WORK/all_rows.json"; else printf '[]' >"$WORK/all_rows.json"; fi
    if [[ -s "$WORK/errors.jsonl" ]]; then jq -cs . "$WORK/errors.jsonl" >"$WORK/all_errors.json"; else printf '[]' >"$WORK/all_errors.json"; fi
    : >"$WORK/accounts.jsonl"
    if (( ${#ACCOUNTS_JSON[@]} )); then printf '%s\n' "${ACCOUNTS_JSON[@]}" >"$WORK/accounts.jsonl"; fi
    jq -n --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" \
        --arg gu "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M UTC')" --arg gl "$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Y-%m-%d %H:%M %Z')" \
        --arg tz "$DISPLAY_TZ" --arg host "$(hostname 2>/dev/null || echo unknown)" \
        --slurpfile accounts "$WORK/accounts.jsonl" \
        --argjson regions "$(json_array "${ALL_REGIONS_SEEN[@]}" | jq -c 'unique')" --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}")" \
        --argjson mb "$MAX_BEHIND" --argjson warn "$WARN_DAYS" --arg ft "$(filters_text)" --argjson f "$FILTERS_JSON" \
        --argjson calls "$AWS_CALLS" --argjson fails "$AWS_FAILS" --argjson lcu "$LC_UNSUPPORTED" \
        '{script: $script, version: $version, generated_utc: $gu, generated_local: $gl, tz: $tz, host: $host,
          accounts: $accounts, regions: $regions, tag_columns: $tagcols, max_behind: $mb, warn_days: $warn,
          filters: $f, filters_text: $ft, aws_calls: $calls, aws_failures: $fails, lifecycle_api: ($lcu == 0)}' >"$WORK/meta.json" || die 4 "Building report metadata failed"
    REPORT="$WORK/report.json"
    jq -n --slurpfile meta "$WORK/meta.json" --slurpfile rows "$WORK/all_rows.json" --slurpfile errors "$WORK/all_errors.json" \
        '{meta: $meta[0], rows: $rows[0], errors: $errors[0]}' >"$WORK/raw_report.json" || die 4 "Assembling the report failed"
    rjq finalize "$WORK/raw_report.json" >"$REPORT" || die 4 "Finalizing the report failed"
}

render() {   # render <format>  -> stdout
    case "$1" in
        json) rjq json "$REPORT" ;;
        text) rjq text -r "$REPORT" ;;
        csv)  rjq csv -r "$REPORT" ;;
        html) rjq html -r "$REPORT" ;;
    esac
}

write_outputs() {
    local fmt ext file stamp tmp
    stamp="$(date -d "@$NOW" '+%Y%m%d_%H%M%S')"
    for fmt in "${FORMATS[@]}"; do
        tmp="$WORK/out.$fmt"
        render "$fmt" >"$tmp" || die 4 "Rendering $fmt failed"
        if [[ -z "$OUTPUT_DIR" ]]; then cat -- "$tmp"; continue; fi
        ext="$fmt"; [[ "$fmt" == text ]] && ext="txt"
        file="${OUTPUT_DIR%/}/${PREFIX}_${stamp}.$ext"
        if ! { cp -- "$tmp" "$file.tmp.$$" && mv -f -- "$file.tmp.$$" "$file"; }; then die 4 "Cannot write $file"; fi
        chmod 0640 -- "$file" 2>/dev/null || true
        WRITTEN+=("$(cd -- "$(dirname -- "$file")" && pwd -P)/${file##*/}")
        log_info "Wrote ${WRITTEN[-1]}"
    done
}

send_email_alert() {   # send_email_alert <subject> <body-file>   (body is streamed from the file)
    local subject="$1" bodyfile="$2" mailer="" to
    local -a tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout 60)
    if command -v mail >/dev/null 2>&1; then mailer="mail"
    elif command -v mailx >/dev/null 2>&1; then mailer="mailx"
    elif command -v sendmail >/dev/null 2>&1; then mailer="sendmail"
    elif [[ -x /usr/sbin/sendmail ]]; then mailer=/usr/sbin/sendmail
    else log_warn "Alert: no mail/mailx/sendmail found"; return 1; fi
    if [[ "$mailer" == mail || "$mailer" == mailx ]]; then
        local -a from=(); [[ -n "$ALERT_FROM" ]] && from=(-r "$ALERT_FROM")
        "${tmo[@]}" "$mailer" "${from[@]}" -s "$subject" -- "${ALERT_EMAILS[@]}" <"$bodyfile"
    else
        to="$(IFS=,; printf '%s' "${ALERT_EMAILS[*]}")"
        { [[ -n "$ALERT_FROM" ]] && printf 'From: %s\n' "$ALERT_FROM"
          printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n' "$to" "$subject"; cat -- "$bodyfile"; } | "${tmo[@]}" "$mailer" -t -oi
    fi
}
send_webhook_alert() {   # send_webhook_alert <url> <payload-file>
    local url="$1" payload="$2" out
    command -v curl >/dev/null 2>&1 || { log_warn "Alert: curl not installed; webhook skipped"; return 1; }
    out="$(printf 'url = "%s"\n' "${url//\"/\\\"}" | curl -sS --fail --max-time 20 --retry 2 \
            -H 'Content-Type: application/json' --data-binary "@$payload" -o /dev/null -w '%{http_code}' -K - 2>&1)" \
        || { log_warn "Alert: webhook $(redact_url "$url") failed: ${out%%$'\n'*}"; return 1; }
    log_info "Alert: webhook $(redact_url "$url") -> HTTP $out"
}
send_alerts() {   # send_alerts <rc> [test]
    local rc="$1" mode="${2:-}" subject url status
    (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || return 0
    local body="$WORK/alert_body.txt" payload="$WORK/alert_payload.json"
    if [[ "$mode" == test ]]; then
        status="TEST"; subject="[rds_patch_compliance] TEST alert from $(hostname 2>/dev/null || echo unknown)"
        printf 'Test alert from %s v%s at %s. No AWS calls were made.\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(date '+%Y-%m-%d %H:%M:%S %Z')" >"$body"
        jq -cn --arg s "$subject" --rawfile b "$body" '{status: "TEST", text: ($s + "\n\n" + $b)}' >"$payload"
    else
        if [[ "$ALERT_ON" == noncompliant ]] && [[ "$(jq -r '.summary.non_compliant + .summary.errors' "$REPORT")" == 0 ]]; then return 0; fi
        status="$(jq -r 'if .summary.non_compliant > 0 then "NON-COMPLIANT" elif .summary.errors > 0 then "ERRORS" else "COMPLIANT" end' "$REPORT")"
        subject="[rds_patch_compliance] $status: $(jq -r '"\(.summary.non_compliant) non-compliant of \(.summary.total), \(.summary.pct_compliant)% compliant"' "$REPORT")"
        render text >"$body" || { log_warn "Alert: rendering the body failed"; return 0; }
        if (( ${#WRITTEN[@]} )); then printf '\n\nReport files:\n' >>"$body"; printf '  %s\n' "${WRITTEN[@]}" >>"$body"; fi
        if ! { rjq alert -c "$REPORT" >"$payload.tmp" \
               && jq -c --arg s "$subject" --arg st "$status" --rawfile b "$body" '. + {status: $st, text: ($s + "\n\n" + $b)}' "$payload.tmp" >"$payload"; }; then
            log_warn "Alert: building the webhook payload failed"; return 0
        fi
    fi
    if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
        jq -cn --arg h "$subject" --rawfile b "$body" --argjson max "$SLACK_MAX_CHARS" \
            '{text: ("*" + $h + "*\n```" + (if ($b | length) > $max then $b[0:$max] + "\n... (truncated - see the report files / e-mail)" else $b end) + "```")}' >"$payload"
    fi
    if (( ${#ALERT_EMAILS[@]} )); then
        if send_email_alert "$subject" "$body"; then log_info "Alert: e-mail ($status) sent to ${ALERT_EMAILS[*]}"
        else log_warn "Alert: e-mail to ${ALERT_EMAILS[*]} failed"; fi
    fi
    for url in "${ALERT_WEBHOOKS[@]}"; do send_webhook_alert "$url" "$payload" || true; done
    return 0
}

dry_run_plan() {
    local p r
    echo "$SCRIPT_NAME v$SCRIPT_VERSION dry run - no AWS calls are made"
    echo "  profiles : $(for p in "${PROFILES[@]}"; do printf '%s ' "${p:-default}"; done)"
    echo "  regions  : $( (( ALL_REGIONS )) && echo "all enabled per account" || echo "${REGIONS[*]:-profile default}")"
    echo "  filters  : $(filters_text)"
    echo "  rule     : COMPLIANT <= $MAX_BEHIND minor version(s) behind; support warning ${WARN_DAYS}d"
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
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-pending-maintenance-actions)"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-engine-versions --engine "<engine>" --engine-version "<current>") (once per engine+version+region; docdb / neptune CLI for those)"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-major-engine-versions --engine "<engine>") (once per RDS engine+region)"
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
    [[ -n "${RDS_PCR_NOW:-}" ]] && NOW="$RDS_PCR_NOW"   # tests: fixed clock
    FILTERS_JSON="$(filters_json)"
    export AWS_PAGER="" AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
    if (( ALERT_TEST )); then
        (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || die 1 "--alert-test needs --alert-email or --alert-webhook"
        WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_pcr.XXXXXX")"
        send_alerts 0 test; exit 0
    fi
    if (( DRY_RUN )); then dry_run_plan; exit 0; fi
    precheck
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_pcr.XXXXXX")"
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
    log_info "$(jq -r '"Result: \(.summary.total) server(s)/cluster(s): COMPLIANT \(.summary.compliant), NON-COMPLIANT \(.summary.non_compliant), UNKNOWN \(.summary.unknown) (\(.summary.pct_compliant)% compliant); \(.summary.errors) error(s)"' "$REPORT"); $AWS_CALLS AWS call(s); exit $rc"
    send_alerts "$rc"
    exit "$rc"
}

main "$@"
