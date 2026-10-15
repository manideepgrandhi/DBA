#!/usr/bin/env bash
#
# rds_pending_maintenance_report.sh - report RDS / Aurora / DocumentDB / Neptune resources with
# pending maintenance actions, across profiles (accounts) and regions. READ-ONLY: describe-* only.
#
# Output: text | csv | json | html (several at once with -F csv,html -o DIR).
# Exit:   0 nothing pending, 10 pending (none urgent), 11 CRIT/OVERDUE, 1 usage, 2 pre-check,
#         3 AWS call failure(s) and nothing CRIT, 4 output/internal error, 130 interrupted.
# Logic and rendering live in lib/report.jq.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.4.1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIB="${RDS_PMR_LIB:-$SCRIPT_DIR/lib}/report.jq"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
PROFILES=()
REGIONS=()
ALL_REGIONS=0
INCLUDE_DOCDB=0
ENGINES=()
ACTIONS=()
IDENTIFIERS=()
TAG_FILTERS=()
URGENCY=()
TAG_COLUMNS=(Environment Owner Application)
FORMATS=()
OUTPUT_DIR=""
PREFIX="rds_pending_maintenance"
DISPLAY_TZ="Asia/Kolkata"
CRIT_DAYS=7
WARN_DAYS=30
VERSION_CHECK=1
ORACLE_ANY_LINE=0
SPLIT_BY_ENGINE=0
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
ALERT_ON="crit"
ALERT_WEBHOOK_FORMAT="slack"
ALERT_FROM=""
ALERT_TEST=0

WORK=""
AWS_CALLS=0
AWS_FAILS=0
NOW=0
REPORT=""
declare -a ACCOUNTS_JSON=() ALL_REGIONS_SEEN=() WRITTEN=()

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
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
$SCRIPT_NAME v$SCRIPT_VERSION - report pending RDS maintenance actions (read-only)

Usage: $SCRIPT_NAME [options]

Scope:
  -P, --profile NAME        AWS CLI profile / account; repeatable or comma-separated (default: default chain)
  -r, --region REGION       Region(s); repeatable or comma-separated (default: env / profile region)
  -A, --all-regions         Every region enabled in each account (ec2 describe-regions)
      --include-docdb       Also query 'aws docdb describe-pending-maintenance-actions' (merged, de-duplicated)

Filters (applied to the report and to the exit code; globs * ? allowed, case-insensitive):
  -e, --engine GLOB         e.g. aurora-postgresql, 'sqlserver-*', postgres          [repeatable]
  -a, --action GLOB         system-update | db-upgrade | os-upgrade | hardware-maintenance |
                            ca-certificate-rotation | ...                           [repeatable]
  -i, --identifier GLOB     instance or cluster identifier, e.g. 'prod-*'          [repeatable]
  -t, --tag KEY=GLOB        resource tag must match (all given tags must match)    [repeatable]
  -u, --urgency LIST        OVERDUE,CRIT,WARN,INFO,OPTIONAL

Report:
  -T, --tag-columns LIST    Tag keys shown as columns (default: Environment,Owner,Application; '' = none)
  -F, --format LIST         text,csv,json,html (default: text). Several formats need -o
  -o, --output-dir DIR      Write <prefix>_YYYYmmdd_HHMMSS.<ext> files into DIR
      --prefix NAME         File name prefix (default: rds_pending_maintenance)
      --tz ZONE             Second time zone shown next to UTC (default: Asia/Kolkata)
      --crit-days N         Apply date within N days = CRIT (default: 7; past date = OVERDUE)
      --warn-days N         Apply date within N days = WARN (default: 30; later = INFO, no date = OPTIONAL)
      --split-by-engine     With csv and -o: also write one CSV per engine (<prefix>_<stamp>_<engine>.csv)
      --oracle-any-patch-line
                            Oracle: also offer minor targets on OTHER patch lines (e.g. spb when the server is
                            on mrp). Default off: same line only (mrp->mrp, rur->rur, plain RU->plain RU), like the
                            RDS console Modify page. Every engine: targets of another major line are never offered.
      --no-version-check    Skip the minor-version lookup (describe-db-engine-versions); the columns
                            auto_minor_upgrade stays, next/latest_minor_version show 'not checked'
                            Printed per row (NEVER run): apply_immediate_command (--opt-in-type immediate,
                            may restart / fail over the DB), status_command, pending_actions_command,
                            minor_upgrade_command (--engine-version upgrade, in the next window),
                            backup_command + backup_wait_command (manual snapshot named
                            pre-maint-<id>-<UTC YYYYMMDD-HHMM at run time>; take it before patching)
                            Rows: grouped per engine, sorted by cluster / server, then patch_sequence
                            (replicas / readers 1, primary / writer 2), then instance
  -l, --log-file FILE       Append log lines to FILE

Alerts:
      --alert-email ADDR    E-mail the text report (mail/mailx/sendmail)        [repeatable]
      --alert-webhook URL   POST to a webhook via curl                         [repeatable]
      --alert-webhook-format F  slack | json                                    (default: slack)
      --alert-on WHEN       crit (CRIT/OVERDUE or AWS errors) | pending (anything) | always (default: crit)
      --alert-from ADDR     From address for e-mail
      --alert-test          Send a test alert and exit

Behaviour:
      --config FILE         key=value settings (CLI overrides)
      --aws-timeout SEC     AWS CLI connect/read timeout (default: 30)
      --max-attempts N      AWS CLI retry attempts (default: 5)
      --keep-workdir        Keep raw AWS responses for debugging
      --dry-run             Print the AWS calls that would run; call nothing
  -v, --verbose             Debug logging
  -h, --help / -V, --version

Exit codes: 0 nothing pending, 10 pending, 11 CRIT/OVERDUE pending, 1 usage, 2 pre-check
            (aws/jq missing, no profile has valid credentials), 3 AWS call failure(s) and nothing CRIT,
            4 output error, 130 interrupted.  Precedence: 11 > 3 > 10 > 0.
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
            include_docdb)          if is_true "$val"; then INCLUDE_DOCDB=1; else INCLUDE_DOCDB=0; fi ;;
            engine|engines)         ENGINES=(); add_list ENGINES "$val" ;;
            action|actions)         ACTIONS=(); add_list ACTIONS "$val" ;;
            identifier|identifiers) IDENTIFIERS=(); add_list IDENTIFIERS "$val" ;;
            tag|tags)               TAG_FILTERS=(); add_list TAG_FILTERS "$val" ;;
            urgency)                URGENCY=(); add_list URGENCY "$val" ;;
            tag_columns)            TAG_COLUMNS=(); add_list TAG_COLUMNS "$val" ;;
            format|formats)         FORMATS=(); add_list FORMATS "$val" ;;
            output_dir)             OUTPUT_DIR="$val" ;;
            prefix)                 PREFIX="$val" ;;
            tz)                     DISPLAY_TZ="$val" ;;
            crit_days)              CRIT_DAYS="$val" ;;
            warn_days)              WARN_DAYS="$val" ;;
            apply_opt_in)           log_warn "Config $file:$lineno: apply_opt_in is no longer used (removed in v1.3.0; only the immediate apply command is printed) - ignored" ;;
            split_by_engine)        if is_true "$val"; then SPLIT_BY_ENGINE=1; else SPLIT_BY_ENGINE=0; fi ;;
            version_check)          if is_true "$val"; then VERSION_CHECK=1; else VERSION_CHECK=0; fi ;;
            oracle_any_patch_line)  if is_true "$val"; then ORACLE_ANY_LINE=1; else ORACLE_ANY_LINE=0; fi ;;
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
            --include-docdb)    INCLUDE_DOCDB=1; shift ;;
            -e|--engine)        need_arg "$opt" $#; reset_once ENGINES; add_list ENGINES "$2"; shift 2 ;;
            -a|--action)        need_arg "$opt" $#; reset_once ACTIONS; add_list ACTIONS "$2"; shift 2 ;;
            -i|--identifier)    need_arg "$opt" $#; reset_once IDENTIFIERS; add_list IDENTIFIERS "$2"; shift 2 ;;
            -t|--tag)           need_arg "$opt" $#; reset_once TAG_FILTERS; TAG_FILTERS+=("$2"); shift 2 ;;
            -u|--urgency)       need_arg "$opt" $#; reset_once URGENCY; add_list URGENCY "$2"; shift 2 ;;
            -T|--tag-columns)   need_arg "$opt" $#; TAG_COLUMNS=(); add_list TAG_COLUMNS "$2"; shift 2 ;;
            -F|--format)        need_arg "$opt" $#; reset_once FORMATS; add_list FORMATS "$2"; shift 2 ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix)           need_arg "$opt" $#; PREFIX="$2"; shift 2 ;;
            --tz)               need_arg "$opt" $#; DISPLAY_TZ="$2"; shift 2 ;;
            --crit-days)        need_arg "$opt" $#; CRIT_DAYS="$2"; shift 2 ;;
            --warn-days)        need_arg "$opt" $#; WARN_DAYS="$2"; shift 2 ;;
            --apply-opt-in)     need_arg "$opt" $#; log_warn "--apply-opt-in is no longer used (removed in v1.3.0; only the immediate apply command is printed) - ignored"; shift 2 ;;
            --no-version-check) VERSION_CHECK=0; shift ;;
            --oracle-any-patch-line) ORACLE_ANY_LINE=1; shift ;;
            --split-by-engine)  SPLIT_BY_ENGINE=1; shift ;;
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
    for x in "${FORMATS[@]}"; do case "${x,,}" in text|csv|json|html) ;; *) die 1 "Unknown format '$x' (text,csv,json,html)" ;; esac; done
    mapfile -t FORMATS < <(printf '%s\n' "${FORMATS[@],,}" | awk '!s[$0]++')
    if (( ${#FORMATS[@]} > 1 )) && [[ -z "$OUTPUT_DIR" ]]; then die 1 "Several formats need --output-dir"; fi
    if (( SPLIT_BY_ENGINE )); then
        [[ -n "$OUTPUT_DIR" ]] || die 1 "--split-by-engine needs --output-dir"
        printf '%s\n' "${FORMATS[@]}" | grep -qx csv || die 1 "--split-by-engine needs csv in --format"
    fi
    if [[ -n "$OUTPUT_DIR" && "$DRY_RUN" -eq 0 ]]; then
        if ! mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || [[ ! -w "$OUTPUT_DIR" ]]; then die 1 "Output directory not writable: $OUTPUT_DIR"; fi
    fi
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--prefix may contain only letters, digits, . _ -"
    (( ALL_REGIONS && ${#REGIONS[@]} )) && die 1 "Use either --region or --all-regions, not both"
    for x in "${REGIONS[@]}"; do [[ "$x" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die 1 "Invalid region: $x"; done
    for x in "${PROFILES[@]}"; do [[ "$x" =~ ^[A-Za-z0-9_.+@-]+$ ]] || die 1 "Invalid profile name: $x"; done
    for x in "${TAG_FILTERS[@]}"; do [[ "$x" =~ ^[^=]+=.*$ ]] || die 1 "--tag must be KEY=VALUE (got '$x')"; done
    for x in "${URGENCY[@]}"; do case "${x^^}" in OVERDUE|CRIT|WARN|INFO|OPTIONAL) ;; *) die 1 "Unknown urgency '$x'" ;; esac; done
    mapfile -t URGENCY < <(for x in "${URGENCY[@]}"; do echo "${x^^}"; done)
    [[ "$CRIT_DAYS" =~ ^[0-9]+$ && "$WARN_DAYS" =~ ^[0-9]+$ ]] || die 1 "--crit-days/--warn-days must be whole numbers"
    (( CRIT_DAYS <= WARN_DAYS )) || die 1 "--crit-days must be <= --warn-days"
    [[ -e "/usr/share/zoneinfo/$DISPLAY_TZ" || "$DISPLAY_TZ" == UTC ]] || die 1 "Unknown time zone: $DISPLAY_TZ"
    if [[ ! "$AWS_TIMEOUT" =~ ^[0-9]+$ ]] || (( AWS_TIMEOUT == 0 )); then die 1 "--aws-timeout must be a positive integer"; fi
    if [[ ! "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || (( MAX_ATTEMPTS == 0 )); then die 1 "--max-attempts must be a positive integer"; fi
    case "${ALERT_ON,,}" in crit|pending|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be crit, pending or always" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be slack or json" ;; esac
    for x in "${ALERT_EMAILS[@]}"; do
        [[ "$x" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $x"
    done
    for x in "${ALERT_WEBHOOKS[@]}"; do [[ "$x" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$x")"; done
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then touch -- "$LOG_FILE" 2>/dev/null || die 1 "Cannot write log file: $LOG_FILE"; fi
    (( ${#PROFILES[@]} )) || PROFILES=("")
}

filters_json() {
    local t; local -a tj=()
    for t in "${TAG_FILTERS[@]}"; do tj+=("$(jq -cn --arg k "${t%%=*}" --arg v "${t#*=}" '{k: $k, v: $v}')"); done
    jq -cn --argjson e "$(json_array "${ENGINES[@]}")" --argjson a "$(json_array "${ACTIONS[@]}")" \
        --argjson i "$(json_array "${IDENTIFIERS[@]}")" --argjson u "$(json_array "${URGENCY[@]}")" \
        --argjson t "$(if (( ${#tj[@]} )); then printf '%s\n' "${tj[@]}" | jq -cs .; else echo '[]'; fi)" \
        '{engines: $e, actions: $a, identifiers: $i, urgency: $u, tags: $t}'
}
filters_text() {
    local -a p=()
    (( ${#ENGINES[@]} )) && p+=("engine=$(IFS=,; echo "${ENGINES[*]}")")
    (( ${#ACTIONS[@]} )) && p+=("action=$(IFS=,; echo "${ACTIONS[*]}")")
    (( ${#IDENTIFIERS[@]} )) && p+=("identifier=$(IFS=,; echo "${IDENTIFIERS[*]}")")
    (( ${#TAG_FILTERS[@]} )) && p+=("tag=$(IFS=,; echo "${TAG_FILTERS[*]}")")
    (( ${#URGENCY[@]} )) && p+=("urgency=$(IFS=,; echo "${URGENCY[*]}")")
    (( INCLUDE_DOCDB )) && p+=("include-docdb")
    local out="" x
    for x in "${p[@]}"; do out+="${out:+; }$x"; done
    echo "$out"
}

# report.jq needs every $variable defined in every mode
rjq() {   # rjq <mode> [extra jq args...]
    local mode="$1"; shift
    TZ="$DISPLAY_TZ" jq --arg mode "$mode" --argjson now "$NOW" --argjson crit_days "$CRIT_DAYS" --argjson warn_days "$WARN_DAYS" \
        --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}")" --argjson f "$FILTERS_JSON" \
        --argjson oracle_any "$( (( ORACLE_ANY_LINE )) && echo true || echo false)" -f "$LIB" "$@"
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

# Collect one (profile, region): pending actions + the resources they refer to
collect_region() {   # collect_region <profile> <account> <region> <dir>
    local profile="$1" account="$2" region="$3" d="$4" i chunk
    local -a arns=()
    mkdir -p "$d"
    printf '[]' >"$d/instances.json"; printf '[]' >"$d/clusters.json"; printf '[]' >"$d/pma.json"
    if ! aws_call "$d/r_pma.json" "$profile" "$region" rds describe-pending-maintenance-actions; then
        add_error "$account" "$profile" "$region" "rds describe-pending-maintenance-actions" "$LAST_ERR"; return 0
    fi
    jq '[.PendingMaintenanceActions[]? | . + {_source: "rds"}]' "$d/r_pma.json" >"$d/pma.json"
    if (( INCLUDE_DOCDB )); then
        if aws_call "$d/r_pma_docdb.json" "$profile" "$region" docdb describe-pending-maintenance-actions; then
            # merge and de-duplicate per (resource, action); the rds entry wins
            jq -s '[.[0][], (.[1].PendingMaintenanceActions[]? | . + {_source: "docdb"})]
                   | [.[] | . as $r | .PendingMaintenanceActionDetails[] | {ResourceIdentifier: $r.ResourceIdentifier, _source: $r._source, PendingMaintenanceActionDetails: [.]}]
                   | unique_by([.ResourceIdentifier, .PendingMaintenanceActionDetails[0].Action])' \
                "$d/pma.json" "$d/r_pma_docdb.json" >"$d/pma.tmp" && mv -f -- "$d/pma.tmp" "$d/pma.json"
        else
            add_error "$account" "$profile" "$region" "docdb describe-pending-maintenance-actions" "$LAST_ERR"
        fi
    fi
    log_info "[${profile:-default}/$region] $(jq '[.[].PendingMaintenanceActionDetails[]] | length' "$d/pma.json") pending action(s) on $(jq 'length' "$d/pma.json") resource(s)"

    # resolve ARNs in batches of 50 (one cache per region)
    local kind op flt key
    for kind in db cluster; do
        if [[ "$kind" == db ]]; then op=describe-db-instances; flt=db-instance-id; key=DBInstances
        else op=describe-db-clusters; flt=db-cluster-id; key=DBClusters; fi
        mapfile -t arns < <(jq -r --arg k ":$kind:" '[.[].ResourceIdentifier | select(contains($k))] | unique[]' "$d/pma.json")
        (( ${#arns[@]} )) || [[ "$kind" == cluster ]] || continue
        # 50 ARNs per call keeps --filters small (~4 KB) and within the API's filter-value limit
        local -a got=()
        for (( i = 0; i < ${#arns[@]}; i += 50 )); do
            chunk="$(IFS=,; echo "${arns[*]:i:50}")"
            if aws_call "$d/r_${kind}_$i.json" "$profile" "$region" rds "$op" --filters "Name=$flt,Values=$chunk"; then
                got+=("$d/r_${kind}_$i.json")
            else
                add_error "$account" "$profile" "$region" "rds $op" "$LAST_ERR"
            fi
        done
        # instances that belong to a cluster without a pending action of its own: describe that cluster
        # too (read-only) so DBClusterMembers.IsClusterWriter gives the writer / reader role
        if [[ "$kind" == cluster ]]; then
            local -a cids=()
            mapfile -t cids < <(jq -r -s '(.[1] | map(.DBClusterArn)) as $have
                | [.[0][] | select((.DBClusterIdentifier // "") != "")
                   | (.DBInstanceArn | sub(":db:[^:]+$"; ":cluster:")) + .DBClusterIdentifier | select(. as $a | $have | index($a) | not)]
                | unique[]' "$d/instances.json" <(jq -s 'map(.DBClusters // []) | add // []' -- "${got[@]}" /dev/null))
            for (( i = 0; i < ${#cids[@]}; i += 50 )); do
                chunk="$(IFS=,; echo "${cids[*]:i:50}")"
                if aws_call "$d/r_member_cluster_$i.json" "$profile" "$region" rds describe-db-clusters --filters "Name=db-cluster-id,Values=$chunk"; then
                    got+=("$d/r_member_cluster_$i.json")
                else
                    add_error "$account" "$profile" "$region" "rds describe-db-clusters (member roles)" "$LAST_ERR"
                fi
            done
        fi
        # one merge per region and kind (file inputs, no argv payload); unique in case pages overlap
        if (( ${#got[@]} )); then
            jq -s --arg key "$key" 'map(.[$key] // []) | add // [] | unique_by(.DBInstanceArn // .DBClusterArn)' -- "${got[@]}" \
                >"$d/${kind/db/instance}s.json" || die 4 "Merging $op output failed for ${profile:-default}/$region"
        fi
    done
    printf '[]' >"$d/versions.json"
    (( VERSION_CHECK )) && collect_versions "$profile" "$region" "$d"
    rjq rows -n --arg profile "${profile:-default}" --arg account "$account" --arg region "$region" \
        --slurpfile pma "$d/pma.json" --slurpfile instances "$d/instances.json" --slurpfile clusters "$d/clusters.json" \
        --slurpfile versions "$d/versions.json" --argjson vc "$VERSION_CHECK" \
        >"$d/rows.json" || die 4 "Building rows failed for ${profile:-default}/$region"
    local w
    while IFS= read -r w; do log_debug "[${profile:-default}/$region] $w"; done \
        < <(jq -r '[.[] | . as $x | ((.minor_version_warnings // [])[] | "\($x.identifier): \(.)"), (if (.minor_excluded // "") != "" then "\(.identifier): \(.minor_excluded)" else empty end)] | unique[]' "$d/rows.json")
}

# Engine versions of the resources found: one describe-db-engine-versions per (service, engine, version),
# cached per region in $WORK/ev/<region>/ (engine versions do not differ between accounts / profiles).
# A failed lookup is logged and shown as 'lookup failed' in the row; it does not make the report incomplete.
collect_versions() {   # collect_versions <profile> <region> <dir>
    local profile="$1" region="$2" d="$3" svc engine ver key cache
    local -a got=()
    mkdir -p "$WORK/ev/$region"
    while IFS=$'\t' read -r svc engine ver; do
        key="$(printf '%s_%s_%s' "$svc" "$engine" "$ver" | tr -c 'A-Za-z0-9._-' '_')"
        cache="$WORK/ev/$region/$key.json"
        if [[ ! -s "$cache" ]]; then
            if aws_call "$cache.raw" "$profile" "$region" "$svc" describe-db-engine-versions --engine "$engine" --engine-version "$ver"; then
                jq -c --arg s "$svc" --arg e "$engine" --arg v "$ver" \
                    '{svc: $s, engine: $e, version: $v, error: null, targets: [.DBEngineVersions[]? | .ValidUpgradeTarget[]?]}' \
                    "$cache.raw" >"$cache" || die 4 "Parsing describe-db-engine-versions failed for $engine $ver"
            else
                AWS_FAILS=$(( AWS_FAILS - 1 ))   # supplementary lookup: warn only
                log_warn "[${profile:-default}/$region] engine-version lookup for $engine $ver failed; minor-version columns show 'lookup failed'"
                jq -cn --arg s "$svc" --arg e "$engine" --arg v "$ver" --arg m "$LAST_ERR" \
                    '{svc: $s, engine: $e, version: $v, error: $m, targets: []}' >"$cache"
            fi
        fi
        got+=("$cache")
    done < <(jq -r -s '[.[0][], .[1][]] | map(select((.Engine // "") != "" and (.EngineVersion // "") != ""))
                       | map([(if .Engine == "docdb" then "docdb" elif .Engine == "neptune" then "neptune" else "rds" end), .Engine, .EngineVersion])
                       | unique[] | @tsv' "$d/instances.json" "$d/clusters.json")
    if (( ${#got[@]} )); then jq -cs . -- "${got[@]}" >"$d/versions.json" || die 4 "Merging engine versions failed for $region"; fi
    return 0
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
    # Large data (rows, errors, account list) is passed to jq only as FILES, never as arguments:
    # a single argv string is limited to 128 KiB (MAX_ARG_STRLEN) and all of argv+env to ARG_MAX.
    if (( ${#rowfiles[@]} )); then jq -cs 'add // []' -- "${rowfiles[@]}" >"$WORK/all_rows.json"; else printf '[]' >"$WORK/all_rows.json"; fi
    if [[ -s "$WORK/errors.jsonl" ]]; then jq -cs . "$WORK/errors.jsonl" >"$WORK/all_errors.json"; else printf '[]' >"$WORK/all_errors.json"; fi
    : >"$WORK/accounts.jsonl"
    if (( ${#ACCOUNTS_JSON[@]} )); then printf '%s\n' "${ACCOUNTS_JSON[@]}" >"$WORK/accounts.jsonl"; fi
    jq -n --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" \
        --arg gu "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M UTC')" --arg gl "$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Y-%m-%d %H:%M %Z')" \
        --arg tz "$DISPLAY_TZ" --arg tza "$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Z')" --arg host "$(hostname 2>/dev/null || echo unknown)" \
        --slurpfile accounts "$WORK/accounts.jsonl" \
        --argjson regions "$(json_array "${ALL_REGIONS_SEEN[@]}" | jq -c 'unique')" --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}")" \
        --argjson crit "$CRIT_DAYS" --argjson warn "$WARN_DAYS" --argjson vc "$VERSION_CHECK" --arg ft "$(filters_text)" --argjson f "$FILTERS_JSON" \
        --argjson calls "$AWS_CALLS" --argjson fails "$AWS_FAILS" \
        '{script: $script, version: $version, generated_utc: $gu, generated_local: $gl, tz: $tz, tz_abbr: $tza, host: $host,
          accounts: $accounts, regions: $regions, tag_columns: $tagcols, crit_days: $crit, warn_days: $warn, version_check: ($vc == 1),
          filters: $f, filters_text: $ft, aws_calls: $calls, aws_failures: $fails}' >"$WORK/meta.json" || die 4 "Building report metadata failed"
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
        WRITTEN+=("$file")
        log_info "Wrote $file"
    done
    if (( SPLIT_BY_ENGINE )); then
        local eng safe
        while IFS= read -r eng; do
            safe="$(printf '%s' "$eng" | tr -c 'A-Za-z0-9._-' '_')"
            file="${OUTPUT_DIR%/}/${PREFIX}_${stamp}_${safe}.csv"
            if ! { rjq csv -r --arg only_engine "$eng" "$REPORT" >"$file.tmp.$$" && mv -f -- "$file.tmp.$$" "$file"; }; then die 4 "Cannot write $file"; fi
            chmod 0640 -- "$file" 2>/dev/null || true
            WRITTEN+=("$file"); log_info "Wrote $file"
        done < <(jq -r '[.rows[].engine] | unique[]' "$REPORT")
    fi
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
    # body and payload can be megabytes for a big fleet: keep them in files, never in argv
    local body="$WORK/alert_body.txt" payload="$WORK/alert_payload.json"
    if [[ "$mode" == test ]]; then
        status="TEST"; subject="[rds_pending_maintenance] TEST alert from $(hostname 2>/dev/null || echo unknown)"
        printf 'Test alert from %s v%s at %s. No AWS calls were made.\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" "$(date '+%Y-%m-%d %H:%M:%S %Z')" >"$body"
        jq -cn --arg s "$subject" --rawfile b "$body" '{status: "TEST", exit_code: 0, text: ($s + "\n\n" + $b)}' >"$payload"
    else
        case "$ALERT_ON" in
            crit)    (( rc == 11 || rc == 3 )) || return 0 ;;
            pending) (( rc != 0 )) || return 0 ;;
        esac
        status="$(jq -r '.summary.overall' "$REPORT")"
        subject="[rds_pending_maintenance] $status: $(jq -r '"\(.summary.total) pending, \(.summary.by_urgency.OVERDUE // 0) overdue, \(.summary.by_urgency.CRIT // 0) due <= \(.meta.crit_days)d"' "$REPORT") (exit $rc)"
        render text >"$body" || { log_warn "Alert: rendering the body failed"; return 0; }
        if (( ${#WRITTEN[@]} )); then printf '\n\nReport files:\n' >>"$body"; printf '  %s\n' "${WRITTEN[@]}" >>"$body"; fi
        if ! { rjq alert -c "$REPORT" >"$payload.tmp" \
               && jq -c --arg s "$subject" --rawfile b "$body" '. + {text: ($s + "\n\n" + $b)}' "$payload.tmp" >"$payload"; }; then
            log_warn "Alert: building the webhook payload failed"; return 0
        fi
    fi
    if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
        # Slack rejects/truncates messages over ~40k characters
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
    echo "  formats  : ${FORMATS[*]} -> ${OUTPUT_DIR:-stdout}   tz: $DISPLAY_TZ   crit<=${CRIT_DAYS}d warn<=${WARN_DAYS}d   version check: $( (( VERSION_CHECK )) && echo on || echo off)"
    for p in "${PROFILES[@]}"; do
        r="${REGIONS[0]:-<region>}"
        echo "Profile ${p:-default}:"
        aws_base "$p" "$r"; printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" sts get-caller-identity)"
        (( ALL_REGIONS )) && printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" ec2 describe-regions)"
        for r in "${REGIONS[@]:-<each-region>}"; do
            aws_base "$p" "$r"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-pending-maintenance-actions)"
            (( INCLUDE_DOCDB )) && printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" docdb describe-pending-maintenance-actions)"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-instances --filters "Name=db-instance-id,Values=<pending-instance-arns>")"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-clusters --filters "Name=db-cluster-id,Values=<pending-cluster-arns>")"
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-clusters --filters "Name=db-cluster-id,Values=<clusters-of-pending-instances>") (writer / reader roles; only if needed)"
            (( VERSION_CHECK )) && printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-engine-versions --engine "<engine>" --engine-version "<version>") (once per engine+version; docdb/neptune for those engines)"
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
    FILTERS_JSON="$(filters_json)"
    export AWS_PAGER="" AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
    if (( ALERT_TEST )); then
        (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || die 1 "--alert-test needs --alert-email or --alert-webhook"
        WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_pmr.XXXXXX")"
        send_alerts 0 test; exit 0
    fi
    if (( DRY_RUN )); then dry_run_plan; exit 0; fi
    precheck
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_pmr.XXXXXX")"
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
    local rc; rc="$(jq -r '.summary.exit_code' "$REPORT")"
    log_info "$(jq -r '"Result: \(.summary.overall) - \(.summary.total) pending action(s) on \(.summary.resources) resource(s); \(.summary.behind_latest_minor) behind latest minor; urgency \(.summary.by_urgency | to_entries | map("\(.key)=\(.value)") | join(" ") | if . == "" then "none" else . end); \(.summary.errors) error(s)"' "$REPORT"); $AWS_CALLS AWS call(s); exit $rc"
    send_alerts "$rc"
    exit "$rc"
}

main "$@"
