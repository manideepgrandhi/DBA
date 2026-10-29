#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose
# rds_patch_compliance_summary.sh - high-level RDS patch compliance summary + the NON-COMPLIANT servers only.
#
# READ-ONLY. The scan and every counting rule come from rds_patch_compliance_report.sh in this folder (it is run
# with -F json and its lib/compliance.jq + lib/versions.jq do the work), so the numbers are identical to the full
# report: valid RDS minor upgrade targets only, same major line, Oracle same patch line, deprecated -> UNKNOWN.
# This script only renders a short summary (lib/summary.jq) and optionally alerts.
# --save-data and --merge are passed to the full report too, so the data files are the same format
# (rds_patch_<ACCOUNTID>_<YYYYMMDD>.json) and files saved by either script can be merged by either script.
#
# Exit codes: 0 ok, 1 usage, 2 pre-check / collection failed, 3 bad --merge input file, 4 output error, 5 NON-COMPLIANT found with
#             --fail-on-noncompliant, 130 interrupted.
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="rds_patch_compliance_summary.sh"
readonly SCRIPT_VERSION="1.3.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
FULL="${RDS_PCS_FULL:-$SCRIPT_DIR/rds_patch_compliance_report.sh}"
[[ "$FULL" == /* ]] || FULL="$PWD/$FULL"
LIB="$SCRIPT_DIR/lib/summary.jq"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

PROFILES=(); REGIONS=(); ALL_REGIONS=0; NO_DISCOVER=0; PROBE_PARALLEL=""; ENGINES=(); IDENTIFIERS=()
FORMATS=(); OUTPUT_DIR=""; PREFIX="rds_patch_compliance_summary"
MAX_BEHIND=2; MAX_BEHIND_SET=0; WARN_DAYS=180; SAVE_DATA=0; SAVE_DATA_FILE=""; MERGE=0; MERGE_ARGS=(); ORACLE_ANY_LINE=0; FAIL_ON_NC=0; VERBOSE=0
ALERT_EMAILS=(); ALERT_WEBHOOKS=(); ALERT_ON="noncompliant"; ALERT_WEBHOOK_FORMAT="slack"; ALERT_FROM=""
readonly SLACK_MAX_CHARS=35000
WORK=""; WRITTEN=()

_log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}" >&2; }
log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
die() { local code="$1"; shift; _log ERROR "$@"; exit "$code"; }
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
add_list() {
    local -n _arr="$1"; local _item; local -a _parts
    IFS=',' read -r -a _parts <<<"$2"
    for _item in "${_parts[@]}"; do
        _item="${_item#"${_item%%[![:space:]]*}"}"; _item="${_item%"${_item##*[![:space:]]}"}"
        [[ -n "$_item" ]] && _arr+=("$_item")
    done
    return 0
}
redact_url() { if [[ "$1" =~ ^([a-zA-Z]+://[^/]+) ]]; then printf '%s/...' "${BASH_REMATCH[1]}"; else printf '<webhook>'; fi; }

usage() {
    cat <<USAGE
$SCRIPT_NAME $SCRIPT_VERSION - RDS patch compliance SUMMARY (read-only)

Shows only the high-level picture and the NON-COMPLIANT servers. The rule (same as the full report):
NON-COMPLIANT when versions_behind > --max-behind (default 2, i.e. 3 or more valid minor versions behind).

Usage: $SCRIPT_NAME [options]
  -P, --profile P[,P]       AWS CLI profile(s)                                   [repeatable]
  -r, --region R[,R]        Region(s)                                            [repeatable]
  -A, --all-regions         Every enabled region; a quick discovery probe per region (in parallel) skips
                            regions with no DB instance / cluster
      --no-discover         With -A: scan every enabled region in full (no probe)
      --probe-parallel N    With -A: regions probed at a time (1-32, default 8)
  -e, --engine GLOB         Engine filter, e.g. 'aurora-*', oracle-ee            [repeatable]
  -i, --identifier GLOB     Cluster / instance filter                            [repeatable]
      --max-behind N        Allowed minor versions behind (default 2)
      --warn-days N         "Support ending" window in days (default 180)
      --oracle-any-patch-line  Oracle: count targets on other patch lines too (default: same line only)
  -F, --format F[,F]        txt | html | csv  (default txt to the screen; csv = non-compliant rows + summary CSV)
  -o, --output-dir DIR      Write files there (needed for html / csv / several formats)
      --prefix NAME         File name prefix (default $PREFIX)
      --save-data [FILE.json]  Also save the raw data (same format as rds_patch_compliance_report.sh --save-data):
                            default rds_patch_<ACCOUNTID>_<YYYYMMDD>.json per account in -o DIR (or the current folder)
      --merge FILE|DIR...   Offline: summarise --save-data files of either script (a DIR = its *.json data files).
                            0 AWS calls, jq only; the newer collection wins per account; days recomputed now.
                            -P / -r / -A / --no-discover / --probe-parallel / -e / -i / --save-data do not apply.
      --fail-on-noncompliant  Exit 5 when any NON-COMPLIANT server is found
      --alert-email ADDR    E-mail the text summary (mail/mailx/sendmail)        [repeatable]
      --alert-webhook URL   POST the summary to a webhook (curl)                 [repeatable]
      --alert-webhook-format F  slack | json (default slack)
      --alert-on WHEN       noncompliant (NON-COMPLIANT found or AWS errors) | always (default noncompliant)
      --alert-from ADDR     From address for e-mail
  -v, --verbose             Debug log of the scan
  -h, --help | -V, --version
Merge example (Git Bash):  $SCRIPT_NAME --merge "C:\\Users\\me\\Downloads\\patch data" -F txt,html,csv -o out
Exit codes: 0 ok, 1 usage, 2 pre-check / collection failed, 3 bad --merge input, 4 output error, 5 non-compliant (--fail-on-noncompliant), 130 interrupted.
Needs: aws CLI v2 (not for --merge), jq 1.6+, and rds_patch_compliance_report.sh + lib/ next to this script.
USAGE
}

parse_args() {
    local opt
    while (( $# )); do
        opt="$1"
        if [[ "$opt" == --*=* ]]; then set -- "${opt%%=*}" "${opt#*=}" "${@:2}"; opt="$1"; fi
        case "$opt" in
            -P|--profile)       need_arg "$opt" $#; add_list PROFILES "$2"; shift 2 ;;
            -r|--region)        need_arg "$opt" $#; add_list REGIONS "$2"; shift 2 ;;
            -A|--all-regions)   ALL_REGIONS=1; shift ;;
            --no-discover)      NO_DISCOVER=1; shift ;;
            --probe-parallel)   need_arg "$opt" $#; PROBE_PARALLEL="$2"; shift 2 ;;
            -e|--engine)        need_arg "$opt" $#; add_list ENGINES "$2"; shift 2 ;;
            -i|--identifier)    need_arg "$opt" $#; add_list IDENTIFIERS "$2"; shift 2 ;;
            --max-behind)       need_arg "$opt" $#; MAX_BEHIND="$2"; MAX_BEHIND_SET=1; shift 2 ;;
            --save-data)        SAVE_DATA=1; if [[ $# -ge 2 && "$2" != -* ]]; then SAVE_DATA_FILE="$2"; shift; fi; shift ;;
            --merge)            MERGE=1; shift; while (( $# )) && [[ "$1" != -* ]]; do MERGE_ARGS+=("$1"); shift; done ;;
            --warn-days)        need_arg "$opt" $#; WARN_DAYS="$2"; shift 2 ;;
            --oracle-any-patch-line) ORACLE_ANY_LINE=1; shift ;;
            -F|--format)        need_arg "$opt" $#; add_list FORMATS "$2"; shift 2 ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix)           need_arg "$opt" $#; PREFIX="$2"; shift 2 ;;
            --fail-on-noncompliant) FAIL_ON_NC=1; shift ;;
            --alert-email)      need_arg "$opt" $#; add_list ALERT_EMAILS "$2"; shift 2 ;;
            --alert-webhook)    need_arg "$opt" $#; add_list ALERT_WEBHOOKS "$2"; shift 2 ;;
            --alert-webhook-format) need_arg "$opt" $#; ALERT_WEBHOOK_FORMAT="$2"; shift 2 ;;
            --alert-on)         need_arg "$opt" $#; ALERT_ON="$2"; shift 2 ;;
            --alert-from)       need_arg "$opt" $#; ALERT_FROM="$2"; shift 2 ;;
            -v|--verbose)       VERBOSE=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            -V|--version)       echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *)                  die 1 "Unknown option: $opt (see --help)" ;;
        esac
    done
}

validate() {
    local f x
    (( ${#FORMATS[@]} )) || FORMATS=(txt)
    for f in "${FORMATS[@]}"; do case "$f" in txt|text|html|csv) ;; *) die 1 "Unknown format '$f' (txt, html, csv)" ;; esac; done
    if [[ -z "$OUTPUT_DIR" ]] && { (( ${#FORMATS[@]} > 1 )) || [[ "${FORMATS[0]}" != txt && "${FORMATS[0]}" != text ]]; }; then
        die 1 "html / csv / several formats need -o DIR"
    fi
    [[ "$MAX_BEHIND" =~ ^[0-9]+$ ]] || die 1 "--max-behind must be a whole number >= 0"
    [[ "$WARN_DAYS" =~ ^[0-9]+$ ]] || die 1 "--warn-days must be a whole number >= 0"
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ && "$PREFIX" != .* ]] || die 1 "--prefix may contain only letters, digits, . _ -"
    (( ALL_REGIONS && ${#REGIONS[@]} )) && die 1 "Use either -r or --all-regions, not both"
    [[ -z "$PROBE_PARALLEL" ]] || { [[ "$PROBE_PARALLEL" =~ ^[0-9]+$ ]] && (( 10#$PROBE_PARALLEL >= 1 && 10#$PROBE_PARALLEL <= 32 )); } \
        || die 1 "--probe-parallel must be a whole number from 1 to 32"
    case "${ALERT_ON,,}" in noncompliant|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be noncompliant or always" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be slack or json" ;; esac
    for x in "${ALERT_EMAILS[@]}"; do
        [[ "$x" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $x"
    done
    for x in "${ALERT_WEBHOOKS[@]}"; do [[ "$x" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$x")"; done
    if (( MERGE )); then
        (( ${#MERGE_ARGS[@]} )) || die 1 "--merge needs at least one --save-data file or directory"
        (( ${#PROFILES[@]} || ${#REGIONS[@]} || ALL_REGIONS || NO_DISCOVER )) && die 1 "--merge works offline on saved data: -P / -r / -A / --no-discover do not apply"
        [[ -n "$PROBE_PARALLEL" ]] && die 1 "--merge: --probe-parallel does not apply"
        (( ${#ENGINES[@]} || ${#IDENTIFIERS[@]} )) && die 1 "--merge: -e / -i do not apply"
        (( SAVE_DATA )) && die 1 "--merge cannot be combined with --save-data"
    fi
    if [[ -n "$SAVE_DATA_FILE" ]]; then
        [[ "$SAVE_DATA_FILE" == *.json ]] || die 1 "--save-data FILE must end in .json"
        [[ "$SAVE_DATA_FILE" == /* ]] || SAVE_DATA_FILE="$PWD/$SAVE_DATA_FILE"
    fi
    command -v jq >/dev/null 2>&1 || die 2 "jq not found in PATH"
    [[ -x "$FULL" ]] || die 2 "Full report script not found or not executable: $FULL"
    [[ -r "$LIB" && -r "$SCRIPT_DIR/lib/versions.jq" ]] || die 2 "lib/summary.jq or lib/versions.jq missing next to $SCRIPT_NAME"
}

# the full report does the read-only scan; its JSON is the single source of the numbers
collect() {
    local -a a=(-F json --warn-days "$WARN_DAYS")
    local x rc=0 dir=.
    if (( MERGE )); then
        # offline: the full report merges (0 AWS calls, exit 3 on a bad file); --max-behind only when given (default: from the files)
        a=(--merge "${MERGE_ARGS[@]}" "${a[@]}")
        (( MAX_BEHIND_SET )) && a+=(--max-behind "$MAX_BEHIND")
        (( ORACLE_ANY_LINE )) && a+=(--oracle-any-patch-line)
        (( VERBOSE )) && a+=(-v)
        REPORT="$WORK/report.json"
        "$FULL" "${a[@]}" >"$REPORT" || rc=$?
        (( rc == 0 )) || die "$rc" "Merge failed (rds_patch_compliance_report.sh --merge exit $rc)"
        jq -e '.summary.total != null' "$REPORT" >/dev/null 2>&1 || die 2 "Merge returned no report"
        return 0
    fi
    a+=(--max-behind "$MAX_BEHIND")
    for x in "${PROFILES[@]}"; do a+=(-P "$x"); done
    for x in "${REGIONS[@]}"; do a+=(-r "$x"); done
    for x in "${ENGINES[@]}"; do a+=(-e "$x"); done
    for x in "${IDENTIFIERS[@]}"; do a+=(-i "$x"); done
    (( ALL_REGIONS )) && a+=(--all-regions)
    (( NO_DISCOVER )) && a+=(--no-discover)
    [[ -n "$PROBE_PARALLEL" ]] && a+=(--probe-parallel "$PROBE_PARALLEL")
    (( ORACLE_ANY_LINE )) && a+=(--oracle-any-patch-line)
    (( VERBOSE )) && a+=(-v)
    if (( SAVE_DATA )); then
        # the full report writes the data file(s); default names go to -o DIR (or the current folder)
        if [[ -n "$SAVE_DATA_FILE" ]]; then a+=(--save-data "$SAVE_DATA_FILE")
        else a+=(--save-data); [[ -n "$OUTPUT_DIR" ]] && { mkdir -p -- "$OUTPUT_DIR" || die 4 "Cannot create $OUTPUT_DIR"; dir="$OUTPUT_DIR"; }; fi
    fi
    REPORT="$WORK/report.json"
    ( cd -- "$dir" && exec "$FULL" "${a[@]}" ) >"$REPORT" || rc=$?
    (( rc == 0 )) || die "$rc" "Scan failed (rds_patch_compliance_report.sh exit $rc)"
    jq -e '.summary.total != null' "$REPORT" >/dev/null 2>&1 || die 2 "Scan returned no report"
}

# jq.exe (Git Bash on Windows) writes CRLF: every jq output used here is made LF-only
JQ_CRLF=0
detect_jq_eol() { if [[ "$(jq -jn '"x\n"' | wc -c | tr -d ' \r')" != 2 ]]; then JQ_CRLF=1; fi; }
unix_eol() { if (( JQ_CRLF )); then tr -d '\r'; else cat; fi; }
jqr() { jq "$@" | unix_eol; }
render() { jqr -r --arg mode "$1" --arg version "$SCRIPT_VERSION" -f "$LIB" "$REPORT"; }

write_outputs() {
    local f stamp file acct
    if [[ -z "$OUTPUT_DIR" ]]; then render text || die 4 "Rendering failed"; return 0; fi
    mkdir -p -- "$OUTPUT_DIR" || die 4 "Cannot create $OUTPUT_DIR"
    stamp="$(date -u +%Y%m%d_%H%M%S)"
    # one account: its number goes into the file names
    acct="$(jqr -r 'if (.meta.accounts | length) == 1 then .meta.accounts[0].account else "" end' "$REPORT")"
    [[ "$acct" =~ ^[0-9]{12}$ ]] && stamp="${acct}_$stamp"
    for f in "${FORMATS[@]}"; do
        case "$f" in
            txt|text) file="$OUTPUT_DIR/${PREFIX}_$stamp.txt"; render text >"$file" || die 4 "Writing $file failed" ;;
            html)     file="$OUTPUT_DIR/${PREFIX}_$stamp.html"; render html >"$file" || die 4 "Writing $file failed" ;;
            csv)      file="$OUTPUT_DIR/${PREFIX}_${stamp}_summary.csv"; render csv_summary >"$file" || die 4 "Writing $file failed"
                      WRITTEN+=("$(cd -- "$OUTPUT_DIR" && pwd -P)/${file##*/}")
                      file="$OUTPUT_DIR/${PREFIX}_${stamp}_noncompliant.csv"; render csv_nc >"$file" || die 4 "Writing $file failed"
                      WRITTEN+=("$(cd -- "$OUTPUT_DIR" && pwd -P)/${file##*/}")
                      file="$OUTPUT_DIR/${PREFIX}_${stamp}_accounts.csv"; render csv_accounts >"$file" || die 4 "Writing $file failed"
                      WRITTEN+=("$(cd -- "$OUTPUT_DIR" && pwd -P)/${file##*/}")
                      file="$OUTPUT_DIR/${PREFIX}_${stamp}_regions.csv"; render csv_regions >"$file" || die 4 "Writing $file failed" ;;
        esac
        WRITTEN+=("$(cd -- "$OUTPUT_DIR" && pwd -P)/${file##*/}")
    done
    printf '%s\n' "${WRITTEN[@]}" | while IFS= read -r f; do log_info "Wrote $f"; done
    # the screen still gets the text summary when txt is requested
    case " ${FORMATS[*]} " in *" txt "*|*" text "*) render text ;; esac
}

send_email_alert() {   # <subject> <body-file>
    local subject="$1" bodyfile="$2" mailer="" to
    local -a tmo=(); command -v timeout >/dev/null 2>&1 && tmo=(timeout 60)
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
send_webhook_alert() {   # <url> <payload-file>
    local url="$1" payload="$2" out
    command -v curl >/dev/null 2>&1 || { log_warn "Alert: curl not installed; webhook skipped"; return 1; }
    out="$(printf 'url = "%s"\n' "${url//\"/\\\"}" | curl -sS --fail --max-time 20 --retry 2 \
            -H 'Content-Type: application/json' --data-binary "@$payload" -o /dev/null -w '%{http_code}' -K - 2>&1)" \
        || { log_warn "Alert: webhook $(redact_url "$url") failed: ${out%%$'\n'*}"; return 1; }
    log_info "Alert: webhook $(redact_url "$url") -> HTTP $out"
}
send_alerts() {
    (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || return 0
    local body="$WORK/alert_body.txt" payload="$WORK/alert_payload.json" status subject url
    if [[ "$ALERT_ON" == noncompliant ]] && [[ "$(jqr -r '.summary.non_compliant + .summary.errors' "$REPORT")" == 0 ]]; then return 0; fi
    status="$(jqr -r 'if .summary.non_compliant > 0 then "NON-COMPLIANT" elif .summary.errors > 0 then "ERRORS" else "COMPLIANT" end' "$REPORT")"
    subject="[rds_patch_compliance_summary] $status: $(jqr -r '"\(.summary.non_compliant) non-compliant of \(.summary.total), \(.summary.pct_compliant)% compliant"' "$REPORT")"
    render text >"$body" || { log_warn "Alert: rendering failed"; return 0; }
    if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
        jqr -cn --arg h "$subject" --rawfile b "$body" --argjson max "$SLACK_MAX_CHARS" \
            '{text: ("*" + $h + "*\n```" + (if ($b | length) > $max then $b[0:$max] + "\n... (truncated)" else $b end) + "```")}' >"$payload"
    else
        render alert | jqr -c --arg s "$subject" --arg st "$status" --rawfile b "$body" '. + {status: $st, text: ($s + "\n\n" + $b)}' >"$payload" \
            || { log_warn "Alert: building the payload failed"; return 0; }
    fi
    if (( ${#ALERT_EMAILS[@]} )); then
        if send_email_alert "$subject" "$body"; then log_info "Alert: e-mail ($status) sent to ${ALERT_EMAILS[*]}"
        else log_warn "Alert: e-mail to ${ALERT_EMAILS[*]} failed"; fi
    fi
    for url in "${ALERT_WEBHOOKS[@]}"; do send_webhook_alert "$url" "$payload" || true; done
    return 0
}

# shellcheck disable=SC2317  # invoked via trap
on_exit() { local rc=$?; trap - EXIT INT TERM; [[ -n "$WORK" && -d "$WORK" ]] && rm -rf -- "$WORK"; exit "$rc"; }
# shellcheck disable=SC2317
on_signal() { _log ERROR "Interrupted"; exit 130; }

main() {
    trap on_exit EXIT
    trap on_signal INT TERM
    parse_args "$@"
    validate
    detect_jq_eol
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_pcs.XXXXXX")"
    collect
    write_outputs
    local rc=0
    (( FAIL_ON_NC )) && [[ "$(jqr -r '.summary.non_compliant' "$REPORT")" != 0 ]] && rc=5
    log_info "$(jqr -r '"\(if .meta.merge then "Merged \(.meta.accounts | length) account(s) from \(.meta.merge.files) file(s), 0 AWS calls. " else "" end)Summary: \(.summary.total) server(s)/cluster(s): COMPLIANT \(.summary.compliant), NON-COMPLIANT \(.summary.non_compliant), UNKNOWN \(.summary.unknown) (\(.summary.pct_compliant)% compliant)"' "$REPORT"); exit $rc"
    send_alerts
    exit "$rc"
}

main "$@"
