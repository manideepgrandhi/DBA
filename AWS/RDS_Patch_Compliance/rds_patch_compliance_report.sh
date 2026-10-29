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
readonly SCRIPT_VERSION="1.3.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIB="${RDS_PCR_LIB:-$SCRIPT_DIR/lib}/compliance.jq"
MERGE_LIB="${RDS_PCR_LIB:-$SCRIPT_DIR/lib}/merge.jq"
PAGE_JS="${RDS_PCR_LIB:-$SCRIPT_DIR/lib}/compliance_page.js"
readonly DATA_SCHEMA="rds_patch_compliance_data" DATA_SCHEMA_VERSION=1

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

PROFILES=()
REGIONS=()
ALL_REGIONS=0
DISCOVER=1
PROBE_PARALLEL=8
ENGINES=()
IDENTIFIERS=()
TAG_COLUMNS=(Environment Owner Application)
FORMATS=()
FORMATS_SET=0
OUTPUT_DIR=""
PREFIX="rds_patch_compliance"
DISPLAY_TZ="Asia/Kolkata"
MAX_BEHIND=2
WARN_DAYS=180
TOP_N=10
NC_ONLY=0
ORACLE_ANY_LINE=0
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
SAVE_DATA=0
SAVE_DATA_FILE=""
MERGE=0
MERGE_ARGS=()
OUT_FILE=""
TZ_SET=0
MAX_BEHIND_SET=0
JQ_CRLF=0
STAMP=""

WORK=""
AWS_CALLS=0
AWS_FAILS=0
NOW=0
REPORT=""
LC_UNSUPPORTED=0
declare -a ACCOUNTS_JSON=() ALL_REGIONS_SEEN=() WRITTEN=()
REGION_MODE="explicit"   # explicit (-r / profile default) | discover (-A, probed) | full (-A --no-discover)

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
  -A, --all-regions         Every region enabled in each account (ec2 describe-regions). Each region is first
                            probed (2 one-page calls, in parallel); only regions with a DB instance or cluster
                            are scanned in full. A probe that fails (AccessDenied / SCP / timeout) is reported
                            as an error and that region is still scanned in full - never skipped silently
      --no-discover         With -A: no probe, scan every enabled region in full (the pre-1.2 behaviour)
      --probe-parallel N    Regions probed at the same time (default: 8, 1-32)
  -e, --engine GLOB         aurora-postgresql, aurora-mysql, postgres, mysql, mariadb, 'sqlserver-*',
                            'oracle-*', docdb, neptune (globs * ?, case-insensitive)      [repeatable]
  -i, --identifier GLOB     cluster / instance identifier (a cluster also matches by member) [repeatable]

Compliance:
      --max-behind N        COMPLIANT when RDS lists at most N valid minor upgrade targets for the
                            current version (default: 2; N+1 or more = NON-COMPLIANT)
      --warn-days N         Flag majors whose standard support ends within N days (default: 180)
      --non-compliant-only  Show only NON-COMPLIANT rows (the summary still counts everything)
      --oracle-any-patch-line
                            Oracle: also count targets on OTHER patch lines (e.g. spb when the server is on mrp).
                            Default off: only the same line counts (mrp->mrp, rur->rur, plain RU->plain RU),
                            matching the RDS console Modify page. See README "Oracle versions".
      --fail-on-noncompliant  Exit 5 when any NON-COMPLIANT server is found (default: exit 0)

Report:
  -T, --tag-columns LIST    Tag keys shown as columns (default: Environment,Owner,Application; '' = none)
  -F, --format LIST         text,csv,json,html (default: text). Several formats need -o
  -o, --output-dir DIR      Write <prefix>[_<account>]_YYYYmmdd_HHMMSS.<ext> files into DIR (the account number
                            is in the name when one account was scanned). With --merge, -o FILE.html names the file
      --save-data [FILE.json]  Also write the raw data (accounts, collected_at UTC, regions with databases,
                            per database engine / current + latest version / status / pending maintenance) for
                            --merge. Default: rds_patch_<ACCOUNTID>_<YYYYMMDD>.json per account, in -o DIR or .
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

Merge (offline, v1.3.0):
      --merge FILE|DIR...   Combine --save-data files from several accounts into one report. Zero AWS calls,
                            no AWS CLI needed (jq only; works in Git Bash on Windows). A DIR means every
                            --save-data JSON in it. The same account in two files: the newer collection wins.
                            Days to maintenance / end of support are counted from merge time.
                            Default format html; e.g. --merge a.json b.json -o combined.html

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
            2 pre-check (aws/jq missing, no profile has valid credentials), 3 bad --merge input file,
            4 output error, 130 interrupted.
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
            discover)               if is_true "$val"; then DISCOVER=1; else DISCOVER=0; fi ;;
            probe_parallel)         PROBE_PARALLEL="$val" ;;
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
            oracle_any_patch_line)  if is_true "$val"; then ORACLE_ANY_LINE=1; else ORACLE_ANY_LINE=0; fi ;;
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
            --no-discover)      DISCOVER=0; shift ;;
            --discover)         DISCOVER=1; shift ;;
            --probe-parallel)   need_arg "$opt" $#; PROBE_PARALLEL="$2"; shift 2 ;;
            -e|--engine)        need_arg "$opt" $#; reset_once ENGINES; add_list ENGINES "$2"; shift 2 ;;
            -i|--identifier)    need_arg "$opt" $#; reset_once IDENTIFIERS; add_list IDENTIFIERS "$2"; shift 2 ;;
            -T|--tag-columns)   need_arg "$opt" $#; TAG_COLUMNS=(); add_list TAG_COLUMNS "$2"; shift 2 ;;
            -F|--format)        need_arg "$opt" $#; reset_once FORMATS; add_list FORMATS "$2"; FORMATS_SET=1; shift 2 ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix)           need_arg "$opt" $#; PREFIX="$2"; shift 2 ;;
            --tz)               need_arg "$opt" $#; DISPLAY_TZ="$2"; TZ_SET=1; shift 2 ;;
            --max-behind)       need_arg "$opt" $#; MAX_BEHIND="$2"; MAX_BEHIND_SET=1; shift 2 ;;
            --save-data)        SAVE_DATA=1
                                if (( $# >= 2 )) && [[ "$2" != -* ]]; then SAVE_DATA_FILE="$2"; shift; fi
                                shift ;;
            --merge)            MERGE=1; shift
                                while (( $# )) && [[ "$1" != -* ]]; do MERGE_ARGS+=("$1"); shift; done ;;
            --warn-days)        need_arg "$opt" $#; WARN_DAYS="$2"; shift 2 ;;
            --top)              need_arg "$opt" $#; TOP_N="$2"; shift 2 ;;
            --non-compliant-only) NC_ONLY=1; shift ;;
            --oracle-any-patch-line) ORACLE_ANY_LINE=1; shift ;;
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
    if (( ! ${#FORMATS[@]} )); then if (( MERGE )); then FORMATS=(html); else FORMATS=(text); fi; fi   # --merge defaults to html
    for x in "${FORMATS[@]}"; do case "${x,,}" in text|txt|csv|json|html) ;; *) die 1 "Unknown format '$x' (text,csv,json,html)" ;; esac; done
    mapfile -t FORMATS < <(printf '%s\n' "${FORMATS[@],,}" | sed 's/^txt$/text/' | awk '!s[$0]++')
    if [[ "$OUTPUT_DIR" == *.[hH][tT][mM][lL] || "$OUTPUT_DIR" == *.[hH][tT][mM] ]]; then   # -o report.html: a file name
        OUT_FILE="${OUTPUT_DIR##*/}"; OUTPUT_DIR="$(dirname -- "$OUTPUT_DIR")"
        (( MERGE && ! FORMATS_SET )) && FORMATS=(html)
        [[ " ${FORMATS[*]} " == *" html "* ]] || die 1 "-o $OUT_FILE names an HTML file; add html to -F or give a directory"
    fi
    if (( MERGE )); then
        (( ${#MERGE_ARGS[@]} )) || die 1 "--merge needs at least one --save-data file or directory"
        (( ${#PROFILES[@]} || ${#REGIONS[@]} || ALL_REGIONS )) && die 1 "--merge works offline on saved data: -P / -r / -A do not apply"
        (( ${#ENGINES[@]} || ${#IDENTIFIERS[@]} )) && die 1 "--merge: -e / -i do not apply (filter in the HTML report instead)"
        (( DRY_RUN || SAVE_DATA || ALERT_TEST )) && die 1 "--merge cannot be combined with --dry-run, --save-data or --alert-test"
    fi
    if [[ -n "$SAVE_DATA_FILE" ]]; then
        [[ "$SAVE_DATA_FILE" == *.json ]] || die 1 "--save-data FILE must end in .json"
        local sd; sd="$(dirname -- "$SAVE_DATA_FILE")"
        if [[ "$DRY_RUN" -eq 0 ]] && { ! mkdir -p -- "$sd" 2>/dev/null || [[ ! -w "$sd" ]]; }; then die 1 "--save-data directory not writable: $sd"; fi
    fi
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
    if (( ! MERGE || TZ_SET )); then   # merge: Git Bash often has no zoneinfo; the saved files carry the offset
        [[ -e "/usr/share/zoneinfo/$DISPLAY_TZ" || "$DISPLAY_TZ" == UTC ]] || die 1 "Unknown time zone: $DISPLAY_TZ"
    fi
    if [[ ! "$AWS_TIMEOUT" =~ ^[0-9]+$ ]] || (( AWS_TIMEOUT == 0 )); then die 1 "--aws-timeout must be a positive integer"; fi
    if [[ ! "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || (( MAX_ATTEMPTS == 0 )); then die 1 "--max-attempts must be a positive integer"; fi
    if [[ ! "$PROBE_PARALLEL" =~ ^[0-9]+$ ]] || (( 10#$PROBE_PARALLEL < 1 || 10#$PROBE_PARALLEL > 32 )); then die 1 "--probe-parallel must be 1-32"; fi
    PROBE_PARALLEL=$(( 10#$PROBE_PARALLEL ))
    if (( ALL_REGIONS )); then if (( DISCOVER )); then REGION_MODE="discover"; else REGION_MODE="full"; fi; fi
    case "${ALERT_ON,,}" in noncompliant|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be noncompliant or always" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be slack or json" ;; esac
    for x in "${ALERT_EMAILS[@]}"; do
        [[ "$x" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $x"
    done
    for x in "${ALERT_WEBHOOKS[@]}"; do [[ "$x" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$x")"; done
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then touch -- "$LOG_FILE" 2>/dev/null || die 1 "Cannot write log file: $LOG_FILE"; fi
    (( MERGE )) || (( ${#PROFILES[@]} )) || PROFILES=("")
}

filters_json() {
    jq -cn --argjson e "$(json_array "${ENGINES[@]}")" --argjson i "$(json_array "${IDENTIFIERS[@]}")" '{engines: $e, identifiers: $i}'
}
filters_text() {
    local -a p=()
    (( ${#ENGINES[@]} )) && p+=("engine=$(IFS=,; echo "${ENGINES[*]}")")
    (( ${#IDENTIFIERS[@]} )) && p+=("identifier=$(IFS=,; echo "${IDENTIFIERS[*]}")")
    (( NC_ONLY )) && p+=("non-compliant only")
    (( ORACLE_ANY_LINE )) && p+=("oracle: any patch line")
    local out="" x
    for x in "${p[@]}"; do out+="${out:+; }$x"; done
    echo "$out"
}

# compliance.jq needs every $variable defined in every mode
rjq() {   # rjq <mode> [extra jq args...]
    local mode="$1"; shift
    TZ="$DISPLAY_TZ" jq --arg mode "$mode" --argjson now "$NOW" --argjson max_behind "$MAX_BEHIND" --argjson warn_days "$WARN_DAYS" \
        --argjson top_n "$TOP_N" --argjson nc_only "$( (( NC_ONLY )) && echo true || echo false)" \
        --argjson oracle_any "$( (( ORACLE_ANY_LINE )) && echo true || echo false)" \
        --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}")" --argjson f "$FILTERS_JSON" \
        "${PAGE_ARGS[@]}" -f "$LIB" "$@"
}
PAGE_ARGS=()
unix_eol() { if (( JQ_CRLF )); then tr -d '\r'; else cat; fi; }   # jq.exe (Windows) writes CRLF: keep HTML/JSON/text LF-only
detect_jq_eol() { if [[ "$(jq -jn '"x\n"' | wc -c | tr -d ' \r')" != 2 ]]; then JQ_CRLF=1; log_debug "jq writes CRLF line ends; adapting"; fi; }

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
    [[ -r "$PAGE_JS" ]] || die 2 "Library missing: $PAGE_JS"
}
precheck_jq() {
    local v; v="$(jq --version 2>/dev/null | tr -d '\r' || true)"
    [[ "$v" =~ ^jq-1\.([6-9]|[1-9][0-9]) ]] || die 2 "jq 1.6 or newer required (found ${v:-none}); in Git Bash put jq.exe on PATH"
    local x; for x in "$LIB" "$MERGE_LIB" "$PAGE_JS"; do [[ -r "$x" ]] || die 2 "Library missing: $x"; done
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
    local w
    while IFS= read -r w; do log_debug "[${profile:-default}/$region] $w"; done \
        < <(jq -r '.[] | . as $x | ((.version_warnings // [])[] | "\($x.identifier): \(.)"), ((.excluded_targets // [])[] | "\($x.identifier): \(.reason)")' "$d/rows.json")
    log_info "[${profile:-default}/$region] $(jq -r 'group_by(.compliance_status) | map("\(.[0].compliance_status)=\(length)") | join(" ") | if . == "" then "no matching servers" else . end' "$d/rows.json")"
}

# Region discovery (-A): two read-only, one-page calls per region tell whether it has any DB instance / cluster.
# --no-paginate + --max-records 20 = exactly one API call each; --query length(...) prints a number.
PROBE_ARGS_I=(rds describe-db-instances --max-records 20 --query 'length(DBInstances)' --no-paginate)
PROBE_ARGS_C=(rds describe-db-clusters --max-records 20 --query 'length(DBClusters)' --no-paginate)
probe_region() {   # probe_region <profile> <region> <outfile>   (runs in a background subshell: results go to the file)
    local profile="$1" region="$2" out="$3" kind n rc ni="" nc="" ei="" ec="" e
    local -a args
    for kind in i c; do
        if [[ "$kind" == i ]]; then args=("${PROBE_ARGS_I[@]}"); else args=("${PROBE_ARGS_C[@]}"); fi
        aws_base "$profile" "$region"
        rc=0; n="$("${AWS_CMD[@]}" "${args[@]}" 2>"$out.$kind.err")" || rc=$?
        n="${n//[[:space:]]/}"
        if (( rc == 0 )) && [[ "$n" =~ ^[0-9]+$ ]]; then e=""
        else
            e="$(tr -s '\n' ' ' <"$out.$kind.err" | sed -E 's/aws: \[ERROR\]: //g; s/^ +//; s/ +$//')"
            [[ -n "$e" ]] || e="exit $rc, not a number: ${n:0:80}"
            (( rc == 124 || rc == 137 )) && e="timed out ($e)"
            (( ${#e} > 400 )) && e="${e:0:400}..."; n=""
        fi
        if [[ "$kind" == i ]]; then ni="$n"; ei="$e"; else nc="$n"; ec="$e"; fi
    done
    jq -cn --arg r "$region" --arg ni "$ni" --arg nc "$nc" --arg ei "$ei" --arg ec "$ec" \
        '{region: $r, instances: (if $ni == "" then null else ($ni | tonumber) end), clusters: (if $nc == "" then null else ($nc | tonumber) end),
          errors: ([if $ei != "" then {call: "rds describe-db-instances (discovery probe)", message: $ei} else empty end,
                    if $ec != "" then {call: "rds describe-db-clusters (discovery probe)", message: $ec} else empty end])}' >"$out.tmp" \
        && mv -f -- "$out.tmp" "$out"
    return 0
}
discover_regions() {   # discover_regions <profile> <account> <dir> <region...>  -> $dir/probe/<region>.json
    local profile="$1" account="$2" dir="$3" region running=0 f c m
    shift 3
    mkdir -p "$dir/probe"
    log_info "[${profile:-default}] discovery: probing ${#} region(s), $PROBE_PARALLEL at a time"
    for region in "$@"; do
        probe_region "$profile" "$region" "$dir/probe/$region.json" &
        running=$(( running + 1 ))
        if (( running >= PROBE_PARALLEL )); then wait -n || true; running=$(( running - 1 )); fi
    done
    wait || true
    # the probes ran in subshells: count their calls / failures here
    for region in "$@"; do
        f="$dir/probe/$region.json"
        AWS_CALLS=$(( AWS_CALLS + 2 ))
        if [[ ! -s "$f" ]]; then   # the subshell died before writing: treat as an error, never as empty
            jq -cn --arg r "$region" '{region: $r, instances: null, clusters: null, errors: [{call: "rds discovery probe", message: "probe produced no result"}]}' >"$f"
        fi
        while IFS=$'\t' read -r c m; do
            AWS_FAILS=$(( AWS_FAILS + 1 ))
            log_error "[${profile:-default}/$region] discovery probe '$c' failed: $m"
            add_error "$account" "$profile" "$region" "$c" "$m (region scanned in full anyway)"
        done < <(jq -r '.errors[] | [.call, .message] | @tsv' "$f")
    done
}
region_status() {   # region_status <account> <profile> <region> <status> [probe-json-file]
    local probe='{}'
    [[ -n "${5:-}" && -s "${5:-}" ]] && probe="$(jq -c '{probe_instances: .instances, probe_clusters: .clusters}' "$5")"
    jq -cn --arg a "$1" --arg p "${2:-default}" --arg r "$3" --arg s "$4" --argjson x "$probe" \
        '{account: $a, profile: $p, region: $r, status: $s} + $x' >>"$WORK/region_status.jsonl"
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
    local pf st
    (( ALL_REGIONS && DISCOVER && ${#regions[@]} )) && discover_regions "$profile" "$account" "$WORK/p$idx" "${regions[@]}"
    for region in "${regions[@]}"; do
        ALL_REGIONS_SEEN+=("$region")
        st="scanned"; pf=""
        if (( ALL_REGIONS && DISCOVER )); then
            pf="$WORK/p$idx/probe/$region.json"
            st="$(jq -r 'if (.errors | length) > 0 then "probe-error" elif (.instances + .clusters) > 0 then "databases" else "empty" end' "$pf")"
        fi
        region_status "$account" "$profile" "$region" "$st" "$pf"
        if [[ "$st" == empty ]]; then log_debug "[${profile:-default}/$region] discovery: no DB instance or cluster; skipped"; continue; fi
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
    [[ -f "$WORK/region_status.jsonl" ]] || : >"$WORK/region_status.jsonl"
    if (( ${#ACCOUNTS_JSON[@]} )); then printf '%s\n' "${ACCOUNTS_JSON[@]}" >"$WORK/accounts.jsonl"; fi
    jq -n --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" \
        --arg gu "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M UTC')" --arg gl "$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Y-%m-%d %H:%M %Z')" \
        --arg tz "$DISPLAY_TZ" --arg host "$(hostname 2>/dev/null || echo unknown)" \
        --slurpfile accounts "$WORK/accounts.jsonl" --slurpfile rstat "$WORK/region_status.jsonl" \
        --arg rmode "$REGION_MODE" --argjson pp "$PROBE_PARALLEL" \
        --argjson regions "$(json_array "${ALL_REGIONS_SEEN[@]}" | jq -c 'unique')" --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}")" \
        --argjson mb "$MAX_BEHIND" --argjson warn "$WARN_DAYS" --arg ft "$(filters_text)" --argjson f "$FILTERS_JSON" \
        --argjson calls "$AWS_CALLS" --argjson fails "$AWS_FAILS" --argjson lcu "$LC_UNSUPPORTED" \
        --argjson oal "$( (( ORACLE_ANY_LINE )) && echo true || echo false)" \
        '{script: $script, version: $version, generated_utc: $gu, generated_local: $gl, tz: $tz, host: $host,
          accounts: $accounts, regions: $regions, tag_columns: $tagcols, max_behind: $mb, warn_days: $warn,
          filters: $f, filters_text: $ft,
          region_discovery: {mode: $rmode, probe_parallel: (if $rmode == "discover" then $pp else null end)}, region_status: $rstat, aws_calls: $calls, aws_failures: $fails, lifecycle_api: ($lcu == 0), oracle_any_patch_line: $oal}' >"$WORK/meta.json" || die 4 "Building report metadata failed"
    REPORT="$WORK/report.json"
    jq -n --slurpfile meta "$WORK/meta.json" --slurpfile rows "$WORK/all_rows.json" --slurpfile errors "$WORK/all_errors.json" \
        '{meta: $meta[0], rows: $rows[0], errors: $errors[0]}' >"$WORK/raw_report.json" || die 4 "Assembling the report failed"
    rjq finalize "$WORK/raw_report.json" >"$REPORT" || die 4 "Finalizing the report failed"
}

render() {   # render <format>  -> stdout
    case "$1" in
        json) rjq json "$REPORT" | unix_eol ;;
        text) rjq text -r "$REPORT" | unix_eol ;;
        csv)  rjq csv -r "$REPORT" ;;
        html) PAGE_ARGS=(--rawfile pagejs "$PAGE_JS"); rjq html -r "$REPORT" | unix_eol; PAGE_ARGS=() ;;
    esac
}

place() {   # place <tmp> <file>   atomic copy into the output dir
    if ! { cp -- "$1" "$2.tmp.$$" && mv -f -- "$2.tmp.$$" "$2"; }; then die 4 "Cannot write $2"; fi
    chmod 0640 -- "$2" 2>/dev/null || true
    WRITTEN+=("$(cd -- "$(dirname -- "$2")" && pwd -P)/${2##*/}")
    log_info "Wrote ${WRITTEN[-1]}"
}
write_outputs() {
    local fmt ext stamp tmp base acct
    stamp="${STAMP:-$(date -d "@$NOW" '+%Y%m%d_%H%M%S')}"
    acct="$(jq -r 'if (.meta.accounts | length) == 1 then .meta.accounts[0].account else "" end' "$REPORT" | tr -d '\r')"
    base="${PREFIX}_${acct:+${acct}_}${stamp}"
    for fmt in "${FORMATS[@]}"; do
        tmp="$WORK/out.$fmt"
        render "$fmt" >"$tmp" || die 4 "Rendering $fmt failed"
        if [[ -z "$OUTPUT_DIR" ]]; then cat -- "$tmp"; continue; fi
        ext="$fmt"; [[ "$fmt" == text ]] && ext="txt"
        if [[ -n "$OUT_FILE" ]]; then
            if [[ "$fmt" == html ]]; then place "$tmp" "${OUTPUT_DIR%/}/$OUT_FILE"; else place "$tmp" "${OUTPUT_DIR%/}/${OUT_FILE%.*}.$ext"; fi
        else place "$tmp" "${OUTPUT_DIR%/}/${base}.$ext"; fi
        if [[ "$fmt" == csv ]]; then   # region-wise breakdown next to the per-server CSV
            rjq csv_regions -r "$REPORT" >"$WORK/out.csv_regions" || die 4 "Rendering the region CSV failed"
            if [[ -n "$OUT_FILE" ]]; then place "$WORK/out.csv_regions" "${OUTPUT_DIR%/}/${OUT_FILE%.*}_regions.csv"
            else place "$WORK/out.csv_regions" "${OUTPUT_DIR%/}/${base}_regions.csv"; fi
        fi
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
    echo "  regions  : $(case "$REGION_MODE" in discover) echo "all enabled per account; discovery probe ($PROBE_PARALLEL in parallel), full scan only where databases (or a probe error) are found" ;;
                              full) echo "all enabled per account; every region scanned in full (--no-discover)" ;;
                              *) echo "${REGIONS[*]:-profile default} (queried directly, no probe)" ;; esac)"
    echo "  filters  : $(filters_text)"
    echo "  rule     : COMPLIANT <= $MAX_BEHIND minor version(s) behind; support warning ${WARN_DAYS}d"
    echo "  formats  : ${FORMATS[*]} -> ${OUTPUT_DIR:-stdout}"
    for p in "${PROFILES[@]}"; do
        r="${REGIONS[0]:-<region>}"
        echo "Profile ${p:-default}:"
        aws_base "$p" "$r"; printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" sts get-caller-identity)"
        (( ALL_REGIONS )) && printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" ec2 describe-regions)"
        if [[ "$REGION_MODE" == discover ]]; then
            echo "  discovery probe, every enabled region, $PROBE_PARALLEL at a time (2 calls per region):"
            aws_base "$p" "<each-region>"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" "${PROBE_ARGS_I[@]}")" "$(printf '%q ' "${AWS_CMD[@]}" "${PROBE_ARGS_C[@]}")"
            echo "  full scan, only regions where a probe found a DB instance / cluster or failed:"
        fi
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
    local j; for j in $(jobs -pr); do kill "$j" 2>/dev/null || true; done   # discovery probes still running
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        if (( KEEP_WORKDIR )); then log_info "Raw AWS responses kept in $WORK"; else rm -rf -- "$WORK"; fi
    fi
    exit "$rc"
}
# shellcheck disable=SC2317
on_signal() { log_error "Interrupted"; exit 130; }

# ----------------------------------------------------------------------------
# --save-data (collection side) and --merge (offline, Git Bash friendly: no aws, no GNU date -d)
# ----------------------------------------------------------------------------
save_data() {   # raw, unfiltered-by-display data: one file per account by default, or all accounts in FILE
    local off abbr utc day a f
    off="$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%z')"; abbr="$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Z')"
    off=$(( (${off:0:1}1) * (10#${off:1:2} * 3600 + 10#${off:3:2} * 60) ))
    utc="$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')"; day="$(date -u -d "@$NOW" '+%Y%m%d')"
    save_one() {   # save_one <file> <account-or-empty>
        jq --arg schema "$DATA_SCHEMA" --argjson sv "$DATA_SCHEMA_VERSION" --arg version "$SCRIPT_VERSION" \
           --argjson now "$NOW" --arg utc "$utc" --arg tz "$DISPLAY_TZ" --arg abbr "$abbr" --argjson off "$off" --arg acct "$2" '
          def mine: $acct == "" or . == $acct;
          .meta as $m
          | {schema: $schema, schema_version: $sv, script_version: $version, collected_epoch: $now, collected_at: $utc,
             collected_utc: ($m.generated_utc), collected_local: ($m.generated_local), tz: $tz, tz_abbr: $abbr, tz_offset: $off,
             read_only: "describe calls + sts get-caller-identity only",
             accounts: [$m.accounts[] | select(.account | mine) | {account, profile, collected_epoch: $now, collected_at: $utc}],
             settings: {max_behind: $m.max_behind, warn_days: $m.warn_days, filters: $m.filters, oracle_any_patch_line: $m.oracle_any_patch_line,
                        region_discovery: $m.region_discovery, lifecycle_api: $m.lifecycle_api, aws_calls: $m.aws_calls},
             regions: ([.rows[] | select(.account_id | mine) | .region] | unique),
             region_status: [($m.region_status // [])[] | select(.account | mine)],
             rows: [.rows[] | select(.account_id | mine)],
             errors: [.errors[] | select((.account | mine) or .account == "-" or .account == "")]}' \
           "$WORK/raw_report.json" | unix_eol >"$WORK/save.json" || die 4 "Building the data file failed"
        place "$WORK/save.json" "$1"
    }
    if [[ -n "$SAVE_DATA_FILE" ]]; then save_one "$SAVE_DATA_FILE" ""; return 0; fi
    while IFS= read -r a; do
        [[ "$a" =~ ^[0-9]{12}$ ]] || continue
        f="${OUTPUT_DIR:-.}"; f="${f%/}/rds_patch_${a}_${day}.json"
        save_one "$f" "$a"
    done < <(jq -r '.meta.accounts[].account' "$WORK/raw_report.json" | tr -d '\r')
}
win_path() {   # C:\x\y, C:/x/y -> /c/x/y when that exists (Git Bash / MSYS); otherwise unchanged
    local p="${1//\\//}" root="${RDS_PCR_DRIVE_ROOT:-/}"
    if [[ ! -e "$p" && "$p" =~ ^/([A-Za-z])/(.*)$ && "$root" != / ]] && ! compgen -G "$p" >/dev/null; then
        p="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
    fi
    if [[ ! -e "$p" && "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
        local alt; alt="${root%/}/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
        if [[ -e "$alt" ]] || compgen -G "$alt" >/dev/null; then p="$alt"
        elif command -v cygpath >/dev/null 2>&1; then
            alt="$(cygpath -u -- "$p" 2>/dev/null | tr -d '\r')"
            if [[ -n "$alt" ]] && { [[ -e "$alt" ]] || compgen -G "$alt" >/dev/null; }; then p="$alt"; fi
        fi
    fi
    printf '%s' "$p"
}
is_data_file() { [[ "$(jq -r --arg s "$DATA_SCHEMA" 'if type == "object" and .schema == $s then "y" else "n" end' -- "$1" 2>/dev/null | tr -d '\r')" == y ]]; }
merge_files() {   # expand --merge arguments (files, globs, directories) into MERGE_FILES
    local a p x; local -a hits
    MERGE_FILES=()
    for a in "${MERGE_ARGS[@]}"; do
        p="$(win_path "$a")"
        if [[ -d "$p" ]]; then
            hits=()
            while IFS= read -r x; do if is_data_file "$x"; then hits+=("$x"); else log_info "Skipping $x (not a --save-data file)"; fi; done < <(compgen -G "${p%/}/*.json" | sort)
            (( ${#hits[@]} )) || die 3 "No --save-data JSON file in directory: $a"
            MERGE_FILES+=("${hits[@]}")
        elif [[ -e "$p" ]]; then MERGE_FILES+=("$p")
        elif [[ "$p" == *[*?[]* ]]; then
            mapfile -t hits < <(compgen -G "$p" | sort)
            (( ${#hits[@]} )) || die 3 "No file matches: $a"
            MERGE_FILES+=("${hits[@]}")
        else die 3 "File not found: $a"; fi
    done
}
check_data_file() {   # schema 1 from --save-data, or die 3 with the reason
    local f="$1" st
    [[ -r "$f" && -f "$f" ]] || die 3 "Cannot read $f"
    if head -c 300 -- "$f" | tr -d '\r' | grep -qi '<!doctype html\|<html'; then
        die 3 "$f is an HTML report, not a data file. Re-run the report in that account with --save-data and merge the rds_patch_<account>_<date>.json file"
    fi
    st="$(jq -r --arg s "$DATA_SCHEMA" 'if type != "object" then "not-object"
        elif .schema != $s then (if (.meta and .summary and .rows) then "report-json" else "no-schema" end)
        elif (.schema_version | type) != "number" then "no-version"
        elif (.rows | type) != "array" or (.accounts | type) != "array" or (.accounts | length) == 0 or (.collected_epoch | type) != "number" then "v\(.schema_version)-incomplete"
        else "v\(.schema_version)" end' -- "$f" 2>/dev/null | tr -d '\r')" || st="bad-json"
    case "$st" in
        "v$DATA_SCHEMA_VERSION") return 0 ;;
        bad-json|"")  die 3 "$f is not valid JSON (truncated or not a --save-data file)" ;;
        report-json)  die 3 "$f is a -F json report, not a --save-data file; re-run with --save-data" ;;
        not-object|no-schema) die 3 "$f is not a patch compliance data file (schema \"$DATA_SCHEMA\" expected; write one with --save-data)" ;;
        no-version)   die 3 "$f has no schema_version; re-run the report with --save-data" ;;
        *-incomplete) die 3 "$f is missing accounts / rows / collected_epoch (schema ${st%-incomplete}); re-run the report with --save-data" ;;
        v*)           if (( ${st#v} < DATA_SCHEMA_VERSION )); then die 3 "$f uses old data schema ${st#v}; re-run v$SCRIPT_VERSION with --save-data"
                      else die 3 "$f uses newer data schema ${st#v} (this script reads $DATA_SCHEMA_VERSION); update rds_patch_compliance_report.sh"; fi ;;
    esac
}
merge_main() {
    precheck_jq
    detect_jq_eol
    local -a MERGE_FILES=(); local f i=0 l tz abbr off mb
    merge_files
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_pcr.XXXXXX" 2>/dev/null)" || { WORK="${TMPDIR:-/tmp}/rds_pcr.$$.$RANDOM"; mkdir -m 700 -- "$WORK"; } || die 4 "Cannot create a temporary directory"
    : >"$WORK/inputs.jsonl"
    for f in "${MERGE_FILES[@]}"; do
        check_data_file "$f"
        jq -c --argjson i "$i" --arg label "${f##*/}" '{i: $i, label: $label, d: .}' -- "$f" | tr -d '\r' >>"$WORK/inputs.jsonl" || die 3 "Cannot read $f"
        log_info "Input $(( i + 1 )): $f ($(jq -r '"collected \(.collected_at), account(s) \([.accounts[] | "\(.account) (\(.profile))"] | join(", "))"' -- "$f" | tr -d '\r'))"
        i=$(( i + 1 ))
    done
    mb="null"; (( MAX_BEHIND_SET )) && mb="$MAX_BEHIND"
    jq -c -s --argjson mb "$mb" --argjson oal "$( (( ORACLE_ANY_LINE )) && echo true || echo null)" -f "$MERGE_LIB" "$WORK/inputs.jsonl" | tr -d '\r' >"$WORK/merged.json" || die 4 "Merging the data files failed"
    while IFS= read -r l; do log_info "$l"; done < <(jq -r '.superseded[] | if .same_time
        then "Account \(.account): in \(.dropped) and \(.kept) with the same collection time; using \(.kept) (given later)"
        else "Account \(.account): using newer \(.kept) (\(.kept_utc)); ignoring older \(.dropped) (\(.dropped_utc))" end' "$WORK/merged.json" | tr -d '\r')
    if (( TZ_SET )); then
        tz="$DISPLAY_TZ"; abbr="$(TZ="$DISPLAY_TZ" date '+%Z')"; off="$(TZ="$DISPLAY_TZ" date '+%z')"
        off=$(( (${off:0:1}1) * (10#${off:1:2} * 3600 + 10#${off:3:2} * 60) ))
    else
        tz="$(jq -r '.tz.tz' "$WORK/merged.json" | tr -d '\r')"; abbr="$(jq -r '.tz.tz_abbr' "$WORK/merged.json" | tr -d '\r')"
        off="$(jq -r '.tz.tz_offset' "$WORK/merged.json" | tr -d '\r')"; DISPLAY_TZ="$tz"
    fi
    MAX_BEHIND="$(jq -r '.max_behind' "$WORK/merged.json" | tr -d '\r')"
    STAMP="$(jq -rn --argjson n "$NOW" --argjson o "$off" '($n + $o) | strftime("%Y%m%d_%H%M%S")' | tr -d '\r')"
    jq -c --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" --argjson now "$NOW" --arg tz "$tz" --arg abbr "$abbr" --argjson off "$off" \
        --argjson n "$i" --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}" | tr -d '\r')" --argjson warn "$WARN_DAYS" --arg ft "$(filters_text)" --argjson f "$FILTERS_JSON" \
        --arg host "$(hostname 2>/dev/null | tr -d '\r' || echo unknown)" '
        def loc: ((. + $off) | strftime("%Y-%m-%d %H:%M")) + " " + $abbr;
        {meta: {script: $script, version: $version, generated_utc: ($now | strftime("%Y-%m-%d %H:%M UTC")), generated_local: ($now | loc),
                tz: $tz, host: $host,
                accounts: [.accounts[] | . + {collected_local: (.collected_epoch | loc)}], regions: .regions, tag_columns: $tagcols,
                max_behind: .max_behind, warn_days: $warn, filters: $f, filters_text: $ft,
                region_discovery: {mode: "merge", probe_parallel: null}, region_status: .region_status, aws_calls: 0, aws_failures: 0,
                lifecycle_api: .lifecycle_api, oracle_any_patch_line: .oracle_any_patch_line,
                merge: {files: $n, basis: "merge time", sources: [.sources[] | . + {collected_local: (.collected_epoch | loc)}]}},
         rows: .rows, errors: .errors}' "$WORK/merged.json" | tr -d '\r' >"$WORK/raw_report.json" || die 4 "Assembling the merged report failed"
    # identifier / engine filters (-e / -i) apply to merged rows too
    REPORT="$WORK/report.json"
    rjq finalize "$WORK/raw_report.json" | tr -d '\r' >"$REPORT" || die 4 "Finalizing the merged report failed"
    write_outputs
    local rc=0 nc; nc="$(jq -r '.summary.non_compliant' "$REPORT" | tr -d '\r')"
    (( FAIL_ON_NC && nc > 0 )) && rc=5
    log_info "$(jq -r '"Merged \(.meta.accounts | length) account(s) from '"$i"' file(s): \(.summary.total) server(s)/cluster(s): COMPLIANT \(.summary.compliant), NON-COMPLIANT \(.summary.non_compliant), UNKNOWN \(.summary.unknown) (\(.summary.pct_compliant)% compliant); \(.summary.errors) error(s)"' "$REPORT" | tr -d '\r'); 0 AWS calls; exit $rc"
    exit "$rc"
}

main() {
    trap on_exit EXIT
    trap on_signal INT TERM
    parse_args "$@"
    validate
    NOW="$(date +%s)"
    [[ -n "${RDS_PCR_NOW:-}" ]] && NOW="$RDS_PCR_NOW"   # tests: fixed clock
    FILTERS_JSON="$(filters_json | tr -d '\r')"
    if (( MERGE )); then merge_main; fi
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
    detect_jq_eol
    build_report
    write_outputs
    (( SAVE_DATA )) && save_data
    local rc=0 nc
    nc="$(jq -r '.summary.non_compliant' "$REPORT")"
    (( FAIL_ON_NC && nc > 0 )) && rc=5
    log_info "$(jq -r '"Result: \(.summary.total) server(s)/cluster(s): COMPLIANT \(.summary.compliant), NON-COMPLIANT \(.summary.non_compliant), UNKNOWN \(.summary.unknown) (\(.summary.pct_compliant)% compliant); \(.summary.errors) error(s)"' "$REPORT"); $AWS_CALLS AWS call(s); exit $rc"
    send_alerts "$rc"
    exit "$rc"
}

main "$@"
