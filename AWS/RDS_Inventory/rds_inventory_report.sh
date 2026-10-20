#!/usr/bin/env bash
#
# rds_inventory_report.sh - grouped inventory of Aurora global clusters, regional Aurora / Multi-AZ DB clusters and
# standalone RDS instances with their read replicas (incl. cross-region), across profiles (accounts) and regions.
# READ-ONLY: rds describe-* only (+ sts / ec2 describe-regions). NO CloudWatch calls (no metrics, no VolumeBytesUsed).
#
# Grouping: global cluster -> each regional cluster -> its member instances (writer first) stay in one block;
#           standalone primary -> its read replicas (same region, then cross-region).
# Output: text | csv | json | html (several at once with -F csv,html -o DIR). csv also writes _summary.csv.
# Exit:   0 report produced, 1 usage, 2 pre-check / no usable profile, 4 output/internal error, 130 interrupted.
# Logic and rendering live in lib/inventory.jq.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIB="${RDS_INV_LIB:-$SCRIPT_DIR/lib}/inventory.jq"

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
PREFIX="rds_inventory"
DISPLAY_TZ="Asia/Kolkata"
INCLUDE_DOCDB=0
FAST=0
PROD_TAG_KEY="Environment"
PROD_REGEX='(?i)^prod'
CA_DAYS=90
SUPPORT_WARN_DAYS=180
TOP_N=10
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
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local code="$1"; shift; log_error "$@"; exit "$code"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - grouped RDS / Aurora inventory (read-only, no CloudWatch)

Usage: $SCRIPT_NAME [options]

Scope:
  -P, --profile NAME        AWS CLI profile / account; repeatable or comma-separated (default: default chain)
  -r, --region REGION       Region(s); repeatable or comma-separated (default: env / profile region)
  -A, --all-regions         Every region enabled in each account (ec2 describe-regions)
  -e, --engine GLOB         postgres, mysql, 'aurora-*', 'sqlserver-*', 'oracle-*' ...        [repeatable]
  -i, --identifier GLOB     global / cluster / instance identifier (a group matches by any member) [repeatable]
      --include-docdb       Also list DocumentDB and Neptune clusters (default: skipped)
      --fast                Skip parameter group lookups (rds.force_ssl / require_secure_transport)

Risk flags:
      --prod-tag-key KEY    Tag that marks production (default: Environment)
      --prod-regex RE       Value regex for production (default: '(?i)^prod')
      --ca-days N           Flag CA certificates expiring within N days (default: 90)
      --support-warn-days N Flag majors whose standard support ends within N days (default: 180)

Report:
  -T, --tags LIST           Tag keys shown as columns (default: Environment,Owner,Application; '' = none).
                            All tags are always in the JSON / HTML.
  -F, --format LIST         text,csv,json,html (default: text). Several formats need -o
  -o, --output-dir DIR      Write <prefix>_YYYYmmdd_HHMMSS.<ext> files into DIR (csv also writes _summary.csv)
      --prefix NAME         File name prefix (default: rds_inventory)
      --top N               Examples per risk flag in the summary (default: 10)
      --tz ZONE             Second time zone for the generated time (default: Asia/Kolkata)
  -l, --log-file FILE       Append log lines to FILE

Behaviour:
      --config FILE         key=value settings (parsed, never sourced; CLI overrides)
      --aws-timeout SEC     AWS CLI connect/read timeout (default: 30)
      --max-attempts N      AWS CLI retry attempts (default: 5)
      --keep-workdir        Keep raw AWS responses for debugging
      --dry-run             Print the AWS calls that would run; call nothing
  -v, --verbose             Debug logging
  -h, --help / -V, --version

Exit codes: 0 report produced, 1 usage, 2 pre-check (aws/jq missing, no profile has valid credentials),
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
            include_docdb)          if is_true "$val"; then INCLUDE_DOCDB=1; else INCLUDE_DOCDB=0; fi ;;
            fast)                   if is_true "$val"; then FAST=1; else FAST=0; fi ;;
            prod_tag_key)           PROD_TAG_KEY="$val" ;;
            prod_regex)             PROD_REGEX="$val" ;;
            ca_days)                CA_DAYS="$val" ;;
            support_warn_days)      SUPPORT_WARN_DAYS="$val" ;;
            tags|tag_columns)       TAG_COLUMNS=(); add_list TAG_COLUMNS "$val" ;;
            format|formats)         FORMATS=(); add_list FORMATS "$val" ;;
            output_dir)             OUTPUT_DIR="${val/#\~/$HOME}" ;;
            prefix)                 PREFIX="$val" ;;
            tz)                     DISPLAY_TZ="$val" ;;
            top)                    TOP_N="$val" ;;
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
            --include-docdb)    INCLUDE_DOCDB=1; shift ;;
            --fast)             FAST=1; shift ;;
            --prod-tag-key)     need_arg "$opt" $#; PROD_TAG_KEY="$2"; shift 2 ;;
            --prod-regex)       need_arg "$opt" $#; PROD_REGEX="$2"; shift 2 ;;
            --ca-days)          need_arg "$opt" $#; CA_DAYS="$2"; shift 2 ;;
            --support-warn-days) need_arg "$opt" $#; SUPPORT_WARN_DAYS="$2"; shift 2 ;;
            -T|--tags|--tag-columns) need_arg "$opt" $#; TAG_COLUMNS=(); add_list TAG_COLUMNS "$2"; shift 2 ;;
            -F|--format)        need_arg "$opt" $#; reset_once FORMATS; add_list FORMATS "$2"; shift 2 ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix)           need_arg "$opt" $#; PREFIX="$2"; shift 2 ;;
            --tz)               need_arg "$opt" $#; DISPLAY_TZ="$2"; shift 2 ;;
            --top)              need_arg "$opt" $#; TOP_N="$2"; shift 2 ;;
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
    if [[ -n "$OUTPUT_DIR" && "$DRY_RUN" -eq 0 ]]; then
        if ! mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || [[ ! -w "$OUTPUT_DIR" ]]; then die 1 "Output directory not writable: $OUTPUT_DIR"; fi
    fi
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--prefix may contain only letters, digits, . _ -"
    (( ALL_REGIONS && ${#REGIONS[@]} )) && die 1 "Use either --region or --all-regions, not both"
    for x in "${REGIONS[@]}"; do [[ "$x" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die 1 "Invalid region: $x"; done
    for x in "${PROFILES[@]}"; do [[ "$x" =~ ^[A-Za-z0-9_.+@-]+$ ]] || die 1 "Invalid profile name: $x"; done
    for x in "${TAG_COLUMNS[@]}"; do [[ "$x" =~ ^[[:print:]]{1,128}$ ]] || die 1 "Invalid tag key: $x"; done
    posint CA_DAYS --ca-days 0; posint SUPPORT_WARN_DAYS --support-warn-days 0; posint TOP_N --top
    posint AWS_TIMEOUT --aws-timeout; posint MAX_ATTEMPTS --max-attempts
    jq -n --arg r "$PROD_REGEX" '"" | test($r)' >/dev/null 2>&1 || die 1 "Invalid --prod-regex: $PROD_REGEX"
    [[ -n "$PROD_TAG_KEY" ]] || die 1 "--prod-tag-key must not be empty"
    [[ -e "/usr/share/zoneinfo/$DISPLAY_TZ" || "$DISPLAY_TZ" == UTC ]] || die 1 "Unknown time zone: $DISPLAY_TZ"
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then touch -- "$LOG_FILE" 2>/dev/null || die 1 "Cannot write log file: $LOG_FILE"; fi
    (( ${#PROFILES[@]} )) || PROFILES=("")
}

filters_text() {
    local -a p=()
    (( ${#ENGINES[@]} )) && p+=("engine=$(IFS=,; echo "${ENGINES[*]}")")
    (( ${#IDENTIFIERS[@]} )) && p+=("identifier=$(IFS=,; echo "${IDENTIFIERS[*]}")")
    (( INCLUDE_DOCDB )) && p+=("DocumentDB/Neptune included")
    (( FAST )) && p+=("fast: parameter groups not read")
    local out="" x
    for x in "${p[@]}"; do out+="${out:+; }$x"; done
    echo "$out"
}

build_cfg() {
    CFG_JSON="$(jq -cn \
        --argjson engines "$(json_array "${ENGINES[@]}")" --argjson identifiers "$(json_array "${IDENTIFIERS[@]}")" \
        --argjson tagcols "$(json_array "${TAG_COLUMNS[@]}")" --argjson docdb "$INCLUDE_DOCDB" --argjson fast "$FAST" \
        --arg ptk "$PROD_TAG_KEY" --arg pre "$PROD_REGEX" --argjson ca "$CA_DAYS" --argjson sw "$SUPPORT_WARN_DAYS" --argjson top "$TOP_N" \
        '{engines: $engines, identifiers: $identifiers, tagcols: $tagcols, include_docdb: ($docdb == 1), fast: ($fast == 1),
          prod_tag_key: $ptk, prod_regex: $pre, ca_days: $ca, support_warn_days: $sw, top_n: $top}')"
}

rjq() {   # rjq <mode> [extra jq args...]
    local mode="$1"; shift
    TZ="$DISPLAY_TZ" jq --arg mode "$mode" --argjson now "$NOW" --argjson cfg "$CFG_JSON" -f "$LIB" "$@"
}

# ----------------------------------------------------------------------------
# AWS access (read-only; never cloudwatch)
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
    case "$1:$2" in cloudwatch:*) die 4 "internal: CloudWatch calls are not allowed" ;; *:describe-*|*:list-*|*:get-*) ;; *) die 4 "internal: refusing non-read-only call aws $1 $2" ;; esac
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


# soft <out> <key> <default> <account> <profile> <region> <op> [args...]  -> list extracted to <out>, error recorded
soft() {
    local out="$1" key="$2" dflt="$3" account="$4" profile="$5" region="$6"; shift 6
    if aws_call "$out.raw" "$profile" "$region" rds "$@"; then
        jq -c --arg k "$key" --argjson d "$dflt" '.[$k] // $d' "$out.raw" >"$out"; return 0
    fi
    add_error "$account" "$profile" "$region" "rds $1" "$LAST_ERR"
    printf '%s' "$dflt" >"$out"; return 1
}

# SSL-enforcement parameters of one parameter group, cached per region + kind + name
collect_params() {   # collect_params <account> <profile> <region> <dir> <kind db|cluster> <groups...>
    local account="$1" profile="$2" region="$3" d="$4" kind="$5" grp key f; shift 5
    mkdir -p "$WORK/pg/$region"
    for grp in "$@"; do
        key="$(printf '%s_%s' "$kind" "$grp" | tr -c 'A-Za-z0-9._-' '_')"
        f="$WORK/pg/$region/$key.json"
        if [[ ! -s "$f" ]]; then
            local -a op=(describe-db-parameters --db-parameter-group-name "$grp")
            [[ "$kind" == cluster ]] && op=(describe-db-cluster-parameters --db-cluster-parameter-group-name "$grp")
            if aws_call "$f.raw" "$profile" "$region" rds "${op[@]}"; then
                jq -c --arg k "$kind:$grp" '{key: $k, value: {error: false, params: [.Parameters[]? | select(.ParameterName | IN("rds.force_ssl", "require_secure_transport"))
                                                                  | {name: .ParameterName, value: (.ParameterValue // null), source: (.Source // "")}]}}' "$f.raw" >"$f"
            else
                add_error "$account" "$profile" "$region" "rds ${op[0]} ($grp)" "$LAST_ERR (SSL enforcement shown as 'lookup failed')"
                jq -cn --arg k "$kind:$grp" '{key: $k, value: {error: true, params: []}}' >"$f"
            fi
        fi
        printf '%s\n' "$f" >>"$d/params.list"
    done
}

collect_region() {   # collect_region <profile> <account> <region> <dir>
    local profile="$1" account="$2" region="$3" d="$4" e
    mkdir -p "$d"
    if ! aws_call "$d/r_clusters.json" "$profile" "$region" rds describe-db-clusters; then
        add_error "$account" "$profile" "$region" "rds describe-db-clusters" "$LAST_ERR"; return 0
    fi
    if ! aws_call "$d/r_instances.json" "$profile" "$region" rds describe-db-instances; then
        add_error "$account" "$profile" "$region" "rds describe-db-instances" "$LAST_ERR"; return 0
    fi
    jq -c '.DBClusters // []' "$d/r_clusters.json" >"$d/clusters.json"
    jq -c '.DBInstances // []' "$d/r_instances.json" >"$d/instances.json"
    soft "$d/globals.json" GlobalClusters '[]' "$account" "$profile" "$region" describe-global-clusters || true
    if [[ "$(jq length "$d/clusters.json")" -gt 0 ]]; then
        soft "$d/endpoints.json" DBClusterEndpoints '[]' "$account" "$profile" "$region" describe-db-cluster-endpoints || true
    else printf '[]' >"$d/endpoints.json"; fi
    soft "$d/pma.json" PendingMaintenanceActions '[]' "$account" "$profile" "$region" describe-pending-maintenance-actions || true
    soft "$d/certs.json" Certificates '[]' "$account" "$profile" "$region" describe-certificates || true
    # engine lifecycle (standard / extended support dates), once per engine + region
    : >"$d/lc.list"
    mkdir -p "$WORK/lc/$region"
    while IFS= read -r e; do
        local f="$WORK/lc/$region/$e.json"
        if [[ ! -s "$f" ]] && (( ! LC_UNSUPPORTED )); then
            if aws_call "$f.raw" "$profile" "$region" rds describe-db-major-engine-versions --engine "$e"; then
                jq -c --arg e "$e" '{key: $e, value: ([.DBMajorEngineVersions[]? | {key: .MajorEngineVersion, value:
                    {std_end: ([.SupportedEngineLifecycles[]? | select(.LifecycleSupportName | test("standard")) | .LifecycleSupportEndDate][0]),
                     ext_end: ([.SupportedEngineLifecycles[]? | select(.LifecycleSupportName | test("extended")) | .LifecycleSupportEndDate][0])}}] | from_entries)}' \
                    "$f.raw" >"$f"
            else
                if [[ "$LAST_ERR" == *"nvalid choice"* ]]; then
                    LC_UNSUPPORTED=1; log_info "This AWS CLI has no 'rds describe-db-major-engine-versions'; support dates show as unknown (upgrade the CLI)"
                else
                    add_error "$account" "$profile" "$region" "rds describe-db-major-engine-versions ($e)" "$LAST_ERR (support dates unknown)"
                fi
                jq -cn --arg e "$e" '{key: $e, value: {}}' >"$f"
            fi
        fi
        [[ -s "$f" ]] && printf '%s\n' "$f" >>"$d/lc.list"
    done < <(jq -r -s '[.[0][], .[1][]] | map(.Engine // empty) | unique[] | select(test("^(docdb|neptune)") | not)' "$d/clusters.json" "$d/instances.json")
    # SSL enforcement from parameter groups (cluster groups for clusters, instance groups for standalone instances)
    : >"$d/params.list"
    if (( ! FAST )); then
        local -a cg=() ig=()
        mapfile -t cg < <(jq -r --argjson dd "$INCLUDE_DOCDB" '.[] | select($dd == 1 or (.Engine | test("^(docdb|neptune)") | not)) | .DBClusterParameterGroup // empty' "$d/clusters.json" | sort -u)
        mapfile -t ig < <(jq -r '.[] | select((.DBClusterIdentifier // "") == "") | .DBParameterGroups[0].DBParameterGroupName // empty' "$d/instances.json" | sort -u)
        (( ${#cg[@]} )) && collect_params "$account" "$profile" "$region" "$d" cluster "${cg[@]}"
        (( ${#ig[@]} )) && collect_params "$account" "$profile" "$region" "$d" db "${ig[@]}"
    fi
    local -a pf=() lf=()
    mapfile -t pf <"$d/params.list"; mapfile -t lf <"$d/lc.list"
    if (( ${#pf[@]} )); then jq -cs 'from_entries' -- "${pf[@]}" >"$d/params.json"; else printf '{}' >"$d/params.json"; fi
    if (( ${#lf[@]} )); then jq -cs 'from_entries' -- "${lf[@]}" >"$d/lc.json"; else printf '{}' >"$d/lc.json"; fi
    jq -cn --arg a "$account" --arg p "${profile:-default}" --arg r "$region" \
        --slurpfile clusters "$d/clusters.json" --slurpfile instances "$d/instances.json" --slurpfile globals "$d/globals.json" \
        --slurpfile endpoints "$d/endpoints.json" --slurpfile pma "$d/pma.json" --slurpfile certs "$d/certs.json" \
        --slurpfile params "$d/params.json" --slurpfile lc "$d/lc.json" \
        '{account: $a, profile: $p, region: $r, clusters: $clusters[0], instances: $instances[0], globals: $globals[0], endpoints: $endpoints[0],
          pma: $pma[0], certs: $certs[0], params: $params[0], lifecycle: $lc[0]}' >"$d/region.json" || die 4 "Assembling region data failed"
    log_info "[${profile:-default}/$region] $(jq length "$d/clusters.json") cluster(s), $(jq length "$d/instances.json") instance(s), $(jq length "$d/globals.json") global cluster(s), ${#pf[@]} parameter group(s)"
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
    local -a rf=()
    mapfile -t rf < <(find "$WORK" -name region.json -type f | sort)
    # large data goes to jq only as FILES, never as arguments (ARG_MAX)
    if (( ${#rf[@]} )); then jq -cs . -- "${rf[@]}" >"$WORK/regions.json"; else printf '[]' >"$WORK/regions.json"; fi
    if [[ -s "$WORK/errors.jsonl" ]]; then jq -cs . "$WORK/errors.jsonl" >"$WORK/all_errors.json"; else printf '[]' >"$WORK/all_errors.json"; fi
    : >"$WORK/accounts.jsonl"
    if (( ${#ACCOUNTS_JSON[@]} )); then printf '%s\n' "${ACCOUNTS_JSON[@]}" >"$WORK/accounts.jsonl"; fi
    jq -n --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" \
        --arg gu "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M UTC')" --arg gl "$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Y-%m-%d %H:%M %Z')" \
        --arg tz "$DISPLAY_TZ" --slurpfile accounts "$WORK/accounts.jsonl" \
        --argjson regions "$(json_array "${ALL_REGIONS_SEEN[@]}" | jq -c 'unique')" \
        --arg ft "$(filters_text)" --argjson cfg "$CFG_JSON" --argjson calls "$AWS_CALLS" --argjson fails "$AWS_FAILS" --argjson lcu "$LC_UNSUPPORTED" \
        '{script: $script, version: $version, generated_utc: $gu, generated_local: $gl, tz: $tz, accounts: $accounts, regions: $regions,
          filters_text: $ft, options: $cfg, aws_calls: $calls, aws_failures: $fails, lifecycle_api: ($lcu == 0), cloudwatch_calls: 0}' >"$WORK/meta.json" \
        || die 4 "Building report metadata failed"
    jq -n --slurpfile meta "$WORK/meta.json" --slurpfile regions "$WORK/regions.json" --slurpfile errors "$WORK/all_errors.json" \
        '{meta: $meta[0], regions: $regions[0], errors: $errors[0]}' >"$WORK/raw.json" || die 4 "Assembling the report failed"
    rjq build "$WORK/raw.json" >"$WORK/built.json" || die 4 "Building groups failed"
    REPORT="$WORK/report.json"
    rjq finalize "$WORK/built.json" >"$REPORT" || die 4 "Finalizing the report failed"
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
        [[ "$fmt" == csv ]] && write_file csv_summary "${base}_summary.csv"
    done
    return 0
}

dry_run_plan() {
    local p r c
    echo "$SCRIPT_NAME v$SCRIPT_VERSION dry run - no AWS calls are made (and never any CloudWatch call)"
    echo "  profiles : $(for p in "${PROFILES[@]}"; do printf '%s ' "${p:-default}"; done)"
    echo "  regions  : $( (( ALL_REGIONS )) && echo "all enabled per account" || echo "${REGIONS[*]:-profile default}")"
    echo "  filters  : $(filters_text)"
    echo "  formats  : ${FORMATS[*]} -> ${OUTPUT_DIR:-stdout}"
    for p in "${PROFILES[@]}"; do
        r="${REGIONS[0]:-<region>}"
        echo "Profile ${p:-default}:"
        aws_base "$p" "$r"; printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" sts get-caller-identity)"
        (( ALL_REGIONS )) && printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" ec2 describe-regions)"
        for r in "${REGIONS[@]:-<each-region>}"; do
            aws_base "$p" "$r"
            for c in describe-db-clusters describe-db-instances describe-global-clusters describe-db-cluster-endpoints describe-pending-maintenance-actions describe-certificates; do
                printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds "$c")"
            done
            printf '    %s (once per engine + region)\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-major-engine-versions --engine "<engine>")"
            if (( ! FAST )); then
                printf '    %s (once per group + region)\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-cluster-parameters --db-cluster-parameter-group-name "<group>")"
                printf '    %s (once per group + region)\n' "$(printf '%q ' "${AWS_CMD[@]}" rds describe-db-parameters --db-parameter-group-name "<group>")"
            fi
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
    [[ -n "${RDS_INV_NOW:-}" ]] && NOW="$RDS_INV_NOW"   # tests: fixed clock
    build_cfg
    export AWS_PAGER="" AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
    if (( DRY_RUN )); then dry_run_plan; exit 0; fi
    precheck
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_inv.XXXXXX")"
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
    log_info "$(jq -r '"Result: \(.summary.groups) group(s): \(.summary.global_clusters) global, \(.summary.clusters) cluster(s), \(.summary.instances) instance(s), \(.summary.allocated_gb) GB allocated; risk flags: \(.summary.flags | map("\(.flag)=\(.count)") | join(" ") | if . == "" then "none" else . end); \(.summary.errors) error(s)"' "$REPORT"); $AWS_CALLS AWS call(s), 0 CloudWatch"
    exit 0
}

main "$@"
