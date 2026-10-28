#!/usr/bin/env bash
#
# rds_inventory_explorer.sh - one self-contained, offline HTML "explorer" for an RDS / Aurora fleet:
# Aurora global clusters, regional Aurora / Multi-AZ DB clusters and RDS instances across profiles (accounts) and regions.
# The page has a type-ahead search and account / region / type / engine dropdowns; picking a resource shows only its
# detail card (endpoints, members, master user / secret, KMS keys, backups, maintenance, CA, tags) plus "Copy JSON".
#
# READ-ONLY: rds describe-* only (+ sts get-caller-identity, ec2 describe-regions). NO CloudWatch, never a secret value.
# Exit: 0 report written, 1 usage, 2 pre-check / no usable profile, 4 output/internal error, 130 interrupted.
# Data model: lib/explorer.jq. Page (HTML/CSS/JS): lib/explorer_template.html.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
LIB_DIR="${RDS_EXPLORER_LIB:-$SCRIPT_DIR/lib}"
LIB="$LIB_DIR/explorer.jq"
TEMPLATE="$LIB_DIR/explorer_template.html"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

PROFILES=()
REGIONS=()
ALL_REGIONS=0
DISCOVER=1
PROBE_PARALLEL=8
OUTPUT_DIR="."
PREFIX="rds_inventory_explorer"
DISPLAY_TZ="Asia/Kolkata"
INCLUDE_DOCDB=0
AWS_TIMEOUT=30
MAX_ATTEMPTS=5
KEEP_WORKDIR=0
DRY_RUN=0
VERBOSE=0

WORK=""
AWS_CALLS=0
AWS_FAILS=0
NOW=0
OUTFILE=""
declare -a ACCOUNTS_JSON=()

_log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}" >&2; }
log_info()  { _log INFO "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }
die() { local code="$1"; shift; log_error "$@"; exit "$code"; }

usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - single-file HTML RDS / Aurora inventory explorer (read-only, no CloudWatch)

Usage: $SCRIPT_NAME [options]

Scope:
  -P, --profile NAME        AWS CLI profile / account; repeatable or comma-separated (default: default chain)
  -r, --region REGION       Region(s); repeatable or comma-separated (default: env / profile region)
  -A, --all-regions         Every region enabled in each account (ec2 describe-regions). Each region is first
                            probed (2 one-page calls, in parallel); only regions with a DB instance or cluster
                            are read in full. A probe that fails (AccessDenied / SCP / timeout) is reported
                            and that region is still read in full - a failed probe never counts as empty.
      --no-discover         With -A: no probe, read every enabled region in full
      --probe-parallel N    Regions probed at the same time (default: 8, 1-32)
      --include-docdb       Also list DocumentDB and Neptune clusters (default: skipped)

Output:
  -o, --output-dir DIR      Directory for <prefix>_YYYYmmdd_HHMMSS.html (default: current directory)
      --prefix NAME         File name prefix (default: rds_inventory_explorer)
      --tz ZONE             Second time zone shown next to UTC (default: Asia/Kolkata)

Behaviour:
      --aws-timeout SEC     AWS CLI connect/read timeout (default: 30)
      --max-attempts N      AWS CLI retry attempts (default: 5)
      --keep-workdir        Keep raw AWS responses for debugging
      --dry-run             Print the AWS calls that would run; call nothing
  -v, --verbose             Debug logging
  -h, --help / -V, --version

Example:  $SCRIPT_NAME -P prod,dev -A -o ~/rds_inventory
Exit codes: 0 report written, 1 usage, 2 pre-check (aws/jq missing, no profile has valid credentials),
            4 output error, 130 interrupted. Errors in one account / region are shown in the page, not fatal.
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
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }

parse_args() {
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
            --probe-parallel)   need_arg "$opt" $#; PROBE_PARALLEL="$2"; shift 2 ;;
            --include-docdb)    INCLUDE_DOCDB=1; shift ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix)           need_arg "$opt" $#; PREFIX="$2"; shift 2 ;;
            --tz)               need_arg "$opt" $#; DISPLAY_TZ="$2"; shift 2 ;;
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

posint() {   # posint <var> <option>
    local -n _v="$1"
    if ! [[ "$_v" =~ ^[0-9]+$ ]] || (( 10#$_v == 0 )); then die 1 "$2 must be a positive whole number"; fi
    _v=$(( 10#$_v ))
}

validate() {
    local x
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--prefix may contain only letters, digits, . _ -"
    (( ALL_REGIONS && ${#REGIONS[@]} )) && die 1 "Use either --region or --all-regions, not both"
    (( ! DISCOVER && ! ALL_REGIONS )) && die 1 "--no-discover only applies with --all-regions"
    for x in "${REGIONS[@]}"; do [[ "$x" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || die 1 "Invalid region: $x"; done
    for x in "${PROFILES[@]}"; do [[ "$x" =~ ^[A-Za-z0-9_.+@-]+$ ]] || die 1 "Invalid profile name: $x"; done
    posint AWS_TIMEOUT --aws-timeout; posint MAX_ATTEMPTS --max-attempts
    if [[ ! "$PROBE_PARALLEL" =~ ^[0-9]+$ ]] || (( 10#$PROBE_PARALLEL < 1 || 10#$PROBE_PARALLEL > 32 )); then die 1 "--probe-parallel must be 1-32"; fi
    PROBE_PARALLEL=$(( 10#$PROBE_PARALLEL ))
    [[ -e "/usr/share/zoneinfo/$DISPLAY_TZ" || "$DISPLAY_TZ" == UTC ]] || die 1 "Unknown time zone: $DISPLAY_TZ"
    OUTPUT_DIR="${OUTPUT_DIR/#\~/$HOME}"
    if (( ! DRY_RUN )); then
        if ! mkdir -p -- "$OUTPUT_DIR" 2>/dev/null || [[ ! -w "$OUTPUT_DIR" ]]; then die 1 "Output directory not writable: $OUTPUT_DIR"; fi
    fi
    (( ${#PROFILES[@]} )) || PROFILES=("")
}

precheck() {
    command -v jq >/dev/null 2>&1 || die 2 "jq not found in PATH (install jq 1.6+)"
    command -v aws >/dev/null 2>&1 || die 2 "AWS CLI not found in PATH (install AWS CLI v2)"
    local v; v="$(aws --version 2>&1 || true)"
    [[ "$v" =~ aws-cli/([0-9]+) ]] || die 2 "Cannot determine AWS CLI version: ${v%%$'\n'*}"
    (( BASH_REMATCH[1] >= 2 )) || die 2 "AWS CLI v2 required (found ${v%% *})"
    v="$(jq --version 2>/dev/null || true)"
    [[ "$v" =~ ^jq-1\.([6-9]|[1-9][0-9]) ]] || die 2 "jq 1.6 or newer required (found ${v:-unknown})"
    [[ -r "$LIB" ]] || die 2 "Library missing: $LIB"
    [[ -r "$TEMPLATE" ]] || die 2 "Page template missing: $TEMPLATE"
}

# ----------------------------------------------------------------------------
# AWS access (read-only allowlist; never CloudWatch; AWS CLI v2 paginates every list call automatically)
# ----------------------------------------------------------------------------
aws_base() {   # aws_base <profile> <region>
    AWS_CMD=(aws --output json --no-cli-pager --cli-connect-timeout "$AWS_TIMEOUT" --cli-read-timeout "$AWS_TIMEOUT")
    [[ -n "$1" ]] && AWS_CMD+=(--profile "$1")
    [[ -n "$2" ]] && AWS_CMD+=(--region "$2")
    return 0
}
read_only_guard() {   # read_only_guard <service> <operation>
    case "$1:$2" in
        cloudwatch:*|logs:*|secretsmanager:*|kms:*) die 4 "internal: refusing call to $1 (not part of this report)" ;;
        sts:get-caller-identity|ec2:describe-regions|rds:describe-*) return 0 ;;
        *) die 4 "internal: refusing non-read-only call aws $1 $2" ;;
    esac
}
LAST_ERR=""
aws_call() {   # aws_call <outfile> <profile> <region> <service> <operation> [args...]
    local out="$1" profile="$2" region="$3"; shift 3
    local rc=0
    read_only_guard "$1" "$2"
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
default_region() {   # default_region <profile>
    local r="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    if [[ -z "$r" ]]; then
        local -a p=(); [[ -n "$1" ]] && p=(--profile "$1")
        r="$(aws configure get region "${p[@]}" 2>/dev/null || true)"
    fi
    printf '%s' "$r"
}

# soft <out> <key> <account> <profile> <region> <op> [args...]  -> list in <out> ([] + error recorded on failure)
soft() {
    local out="$1" key="$2" account="$3" profile="$4" region="$5"; shift 5
    if aws_call "$out.raw" "$profile" "$region" rds "$@"; then
        jq -c --arg k "$key" '.[$k] // []' "$out.raw" >"$out"; return 0
    fi
    add_error "$account" "$profile" "$region" "rds $1" "$LAST_ERR"
    printf '[]' >"$out"; return 1
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
    soft "$d/globals.json" GlobalClusters "$account" "$profile" "$region" describe-global-clusters || true
    if [[ "$(jq length "$d/clusters.json")" -gt 0 ]]; then
        soft "$d/endpoints.json" DBClusterEndpoints "$account" "$profile" "$region" describe-db-cluster-endpoints || true
    else printf '[]' >"$d/endpoints.json"; fi
    soft "$d/pma.json" PendingMaintenanceActions "$account" "$profile" "$region" describe-pending-maintenance-actions || true
    soft "$d/certs.json" Certificates "$account" "$profile" "$region" describe-certificates || true
    jq -cn --arg a "$account" --arg p "${profile:-default}" --arg r "$region" \
        --slurpfile clusters "$d/clusters.json" --slurpfile instances "$d/instances.json" --slurpfile globals "$d/globals.json" \
        --slurpfile endpoints "$d/endpoints.json" --slurpfile pma "$d/pma.json" --slurpfile certs "$d/certs.json" \
        '{account: $a, profile: $p, region: $r, clusters: $clusters[0], instances: $instances[0], globals: $globals[0],
          endpoints: $endpoints[0], pma: $pma[0], certs: $certs[0]}' >"$d/region.json" || die 4 "Assembling region data failed"
    log_info "[${profile:-default}/$region] $(jq length "$d/clusters.json") cluster(s), $(jq length "$d/instances.json") instance(s), $(jq length "$d/globals.json") global cluster(s)"
}

# Region discovery (-A): two read-only, one-page calls per region tell whether it has any DB instance / cluster.
# --no-paginate + --max-records 20 = exactly one API call each; --query length(...) prints a number.
PROBE_ARGS_I=(rds describe-db-instances --max-records 20 --query 'length(DBInstances)' --no-paginate)
PROBE_ARGS_C=(rds describe-db-clusters --max-records 20 --query 'length(DBClusters)' --no-paginate)
probe_region() {   # probe_region <profile> <region> <outfile>   (background subshell: results go to the file)
    local profile="$1" region="$2" out="$3" kind n rc ni="" nc="" ei="" ec="" e
    local -a args
    for kind in i c; do
        if [[ "$kind" == i ]]; then args=("${PROBE_ARGS_I[@]}"); else args=("${PROBE_ARGS_C[@]}"); fi
        read_only_guard "${args[0]}" "${args[1]}"
        aws_base "$profile" "$region"
        rc=0; n="$("${AWS_CMD[@]}" "${args[@]}" 2>"$out.$kind.err")" || rc=$?
        n="${n//[[:space:]]/}"
        if (( rc == 0 )) && [[ "$n" =~ ^[0-9]+$ ]]; then e=""
        else
            e="$(tr -s '\n' ' ' <"$out.$kind.err" | sed -E 's/aws: \[ERROR\]: //g; s/^ +//; s/ +$//')"
            [[ -n "$e" ]] || e="exit $rc, not a number: ${n:0:80}"
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
    for region in "$@"; do
        f="$dir/probe/$region.json"
        AWS_CALLS=$(( AWS_CALLS + 2 ))
        if [[ ! -s "$f" ]]; then   # the subshell died before writing: an error, never "empty"
            jq -cn --arg r "$region" '{region: $r, instances: null, clusters: null, errors: [{call: "rds discovery probe", message: "probe produced no result"}]}' >"$f"
        fi
        while IFS=$'\t' read -r c m; do
            AWS_FAILS=$(( AWS_FAILS + 1 ))
            log_error "[${profile:-default}/$region] discovery probe '$c' failed: $m"
            add_error "$account" "$profile" "$region" "$c" "$m (region read in full anyway)"
        done < <(jq -r '.errors[] | [.call, .message] | @tsv' "$f")
    done
}

collect_profile() {   # collect_profile <index> <profile>
    local idx="$1" profile="$2" account region base st
    local -a regions=()
    base="${REGIONS[0]:-$(default_region "$profile")}"
    if [[ -z "$base" ]]; then
        if (( ALL_REGIONS )); then base="us-east-1"
        else add_error "-" "$profile" "-" "region" "no region given and profile has none (use -r or -A)"; return 1; fi
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
    (( ALL_REGIONS && DISCOVER && ${#regions[@]} )) && discover_regions "$profile" "$account" "$WORK/p$idx" "${regions[@]}"
    for region in "${regions[@]}"; do
        if (( ALL_REGIONS && DISCOVER )); then
            st="$(jq -r 'if (.errors | length) > 0 then "probe-error" elif (.instances + .clusters) > 0 then "databases" else "empty" end' "$WORK/p$idx/probe/$region.json")"
            if [[ "$st" == empty ]]; then log_debug "[${profile:-default}/$region] discovery: no DB instance or cluster; skipped"; continue; fi
        fi
        collect_region "$profile" "$account" "$region" "$WORK/p$idx/$region"
    done
    return 0
}

# ----------------------------------------------------------------------------
# Model + page
# ----------------------------------------------------------------------------
tz_offset_sec() {   # offset of DISPLAY_TZ at NOW in seconds (e.g. +19800 for IST)
    local z; z="$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%z')"
    local s="${z:0:1}" h="${z:1:2}" m="${z:3:2}"
    local v=$(( 10#$h * 3600 + 10#$m * 60 ))
    [[ "$s" == - ]] && v=$(( -v ))
    printf '%s' "$v"
}

build_model() {
    local -a rf=()
    mapfile -t rf < <(find "$WORK" -name region.json -type f | sort)
    # large data goes to jq only as FILES, never as arguments (ARG_MAX)
    if (( ${#rf[@]} )); then jq -cs . -- "${rf[@]}" >"$WORK/regions.json"; else printf '[]' >"$WORK/regions.json"; fi
    if [[ -s "$WORK/errors.jsonl" ]]; then jq -cs . "$WORK/errors.jsonl" >"$WORK/all_errors.json"; else printf '[]' >"$WORK/all_errors.json"; fi
    : >"$WORK/accounts.jsonl"
    if (( ${#ACCOUNTS_JSON[@]} )); then printf '%s\n' "${ACCOUNTS_JSON[@]}" >"$WORK/accounts.jsonl"; fi
    local mode="explicit"; (( ALL_REGIONS )) && { if (( DISCOVER )); then mode="discover"; else mode="full"; fi; }
    jq -n --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" --argjson now "$NOW" \
        --arg gu "$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M UTC')" --arg gl "$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Y-%m-%d %H:%M %Z')" \
        --arg tz "$DISPLAY_TZ" --arg tzabbr "$(TZ="$DISPLAY_TZ" date -d "@$NOW" '+%Z')" --argjson tzoff "$(tz_offset_sec)" \
        --slurpfile accounts "$WORK/accounts.jsonl" --argjson profiles "${#PROFILES[@]}" --arg rmode "$mode" \
        --argjson docdb "$INCLUDE_DOCDB" --argjson calls "$AWS_CALLS" --argjson fails "$AWS_FAILS" \
        '{script: $script, version: $version, now: $now, generated_utc: $gu, generated_local: $gl, tz: $tz, tz_abbr: $tzabbr, tz_offset: $tzoff,
          accounts: $accounts, profiles_requested: $profiles, region_mode: $rmode, include_docdb: ($docdb == 1),
          aws_calls: $calls, aws_failures: $fails, cloudwatch_calls: 0}' >"$WORK/meta.json" || die 4 "Building report metadata failed"
    jq -n --slurpfile meta "$WORK/meta.json" --slurpfile regions "$WORK/regions.json" --slurpfile errors "$WORK/all_errors.json" \
        '{meta: $meta[0], regions: $regions[0], errors: $errors[0]}' >"$WORK/raw.json" || die 4 "Assembling the report failed"
    jq -c -f "$LIB" "$WORK/raw.json" >"$WORK/model.json" || die 4 "Building the data model failed"
}

write_html() {
    local stamp; stamp="$(date -d "@$NOW" '+%Y%m%d_%H%M%S')"
    OUTFILE="${OUTPUT_DIR%/}/${PREFIX}_${stamp}.html"
    # embed the model as JSON inside <script type="application/json">: every "<" becomes \u003c, so no "</script"
    # (or "<!--") in any AWS value can end the block; JSON.parse turns it back into "<".
    jq -r --rawfile tpl "$TEMPLATE" '
        (tojson | gsub("<"; "\\u003c") | gsub("\u2028"; "\\u2028") | gsub("\u2029"; "\\u2029")) as $data
        | ($tpl | split("/*__EXPLORER_DATA__*/")) as $p
        | if ($p | length) != 2 then error("template placeholder missing") else $p[0] + $data + $p[1] end' \
        "$WORK/model.json" >"$WORK/out.html" || die 4 "Rendering HTML failed"
    if ! { cp -- "$WORK/out.html" "$OUTFILE.tmp.$$" && mv -f -- "$OUTFILE.tmp.$$" "$OUTFILE"; }; then die 4 "Cannot write $OUTFILE"; fi
    chmod 0640 -- "$OUTFILE" 2>/dev/null || true
    OUTFILE="$(cd -- "$(dirname -- "$OUTFILE")" && pwd -P)/${OUTFILE##*/}"
    log_info "Wrote $OUTFILE"
}

dry_run_plan() {
    local p r c
    echo "$SCRIPT_NAME v$SCRIPT_VERSION dry run - no AWS calls are made (and never any CloudWatch call)"
    echo "  profiles : $(for p in "${PROFILES[@]}"; do printf '%s ' "${p:-default}"; done)"
    if (( ALL_REGIONS && DISCOVER )); then echo "  regions  : all enabled per account; discovery probe ($PROBE_PARALLEL in parallel), full read only where databases (or a probe error) are found"
    elif (( ALL_REGIONS )); then echo "  regions  : all enabled per account; every region read in full (--no-discover)"
    else echo "  regions  : ${REGIONS[*]:-profile default}"; fi
    echo "  docdb    : $( (( INCLUDE_DOCDB )) && echo included || echo skipped)"
    echo "  output   : ${OUTPUT_DIR%/}/${PREFIX}_YYYYmmdd_HHMMSS.html"
    for p in "${PROFILES[@]}"; do
        r="${REGIONS[0]:-<region>}"
        echo "Profile ${p:-default}:"
        aws_base "$p" "$r"; printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" sts get-caller-identity)"
        if (( ALL_REGIONS )); then
            printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" ec2 describe-regions)"
            if (( DISCOVER )); then
                echo "  discovery probe, every enabled region, $PROBE_PARALLEL at a time:"
                aws_base "$p" "<each-region>"
                printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" "${PROBE_ARGS_I[@]}")" "$(printf '%q ' "${AWS_CMD[@]}" "${PROBE_ARGS_C[@]}")"
                echo "  full read, only regions where a probe found a DB instance / cluster or failed:"
            fi
        fi
        for r in "${REGIONS[@]:-<each-region>}"; do
            aws_base "$p" "$r"
            for c in describe-db-clusters describe-db-instances describe-global-clusters describe-db-cluster-endpoints describe-pending-maintenance-actions describe-certificates; do
                printf '    %s\n' "$(printf '%q ' "${AWS_CMD[@]}" rds "$c")"
            done
        done
    done
}

# shellcheck disable=SC2317  # invoked via trap
on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    local j; for j in $(jobs -pr); do kill "$j" 2>/dev/null || true; done
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
    [[ -n "${RDS_EXPLORER_NOW:-}" ]] && NOW="$RDS_EXPLORER_NOW"   # tests: fixed clock
    export AWS_PAGER="" AWS_MAX_ATTEMPTS="$MAX_ATTEMPTS" AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
    if (( DRY_RUN )); then dry_run_plan; exit 0; fi
    precheck
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_explorer.XXXXXX")"
    : >"$WORK/errors.jsonl"
    local i ok=0
    for i in "${!PROFILES[@]}"; do
        if collect_profile "$i" "${PROFILES[$i]}"; then ok=$(( ok + 1 )); fi
    done
    if (( ok == 0 )); then
        jq -r '"\(.profile): \(.message)"' "$WORK/errors.jsonl" | while IFS= read -r l; do log_error "$l"; done
        die 2 "No profile could be used (credentials / region); nothing to report"
    fi
    build_model
    write_html
    log_info "$(jq -r '.meta.counts | "Result: \(.global_clusters) global cluster(s), \(.clusters) cluster(s), \(.instances) instance(s) (\(.standalone_instances) standalone) in \(.accounts) account(s) / \(.regions_with_databases) region(s) with databases; \(.errors) error(s)"' "$WORK/model.json"); $AWS_CALLS AWS call(s), 0 CloudWatch"
    exit 0
}

main "$@"
