# rds_patch_compliance_report.sh --merge: combine --save-data files (input: array of {i, label, d}).
# Per account the newest collection wins (collected_epoch; same time -> the file given later).
# $mb: --max-behind or null (= largest in the files); $oal: true with --oracle-any-patch-line, else null (= any file saved with it).
include "versions" {search: "./"};
# Oracle rows: recount the valid targets for the patch-line rule of the merge (saved newer_versions + targets
# excluded for "different patch line" are the pool; same rule as minor_select in lib/versions.jq).
def ora_recount($any):
  if (.engine | test("^oracle")) and .versions_behind != null and (.current_version | ora_parse) != null then
    . as $row | (.current_version | ora_parse) as $cp | (.current_version | ora_key) as $ck
    | ([.newer_versions[]?] + [(.excluded_targets // [])[] | select(.reason | test("different patch line")) | .version] | unique) as $pool
    | [ $pool[] | . as $v | ($v | ora_parse) as $tp | ($v | ora_key) as $k
        | if $tp == null then {v: $v, inc: (($row.newer_versions | index([$v])) != null)}
          elif $tp.line == $cp.line then {v: $v, inc: ($k > $ck)}
          elif $any then {v: $v, inc: ($k >= $ck)}
          else {v: $v, inc: false, x: "excluded \($v) (different patch line \($tp.line | line_label); current is \($cp.line | line_label))"} end ] as $d
    | ([ $d[] | select(.inc) ] | sort_by([((.v | ora_key) // []), .v]) | map(.v)) as $newer
    | .newer_versions = $newer | .versions_behind = ($newer | length) | .latest_minor_version = ($newer[-1] // .current_version)
    | .excluded_targets = ([(.excluded_targets // [])[] | select(.reason | test("different patch line") | not)] + [ $d[] | select(.x) | {version: .v, reason: .x} ])
    | (if .default_auto_upgrade_target != null and ($newer | index([$row.default_auto_upgrade_target])) == null then .default_auto_upgrade_target = null else . end)
  else . end;
. as $F
| def utc: strftime("%Y-%m-%d %H:%M UTC");
  [ $F[] | . as $f | $f.d.accounts[]
    | {account, profile, collected_epoch: (.collected_epoch // $f.d.collected_epoch), i: $f.i, label: $f.label} ] as $ALL
| ($ALL | group_by(.account) | map(sort_by(.collected_epoch, .i))) as $G
| ([ $G[] | last | {key: "\(.account)|\(.i)", value: true} ] | from_entries) as $USE
| ([ $ALL[].account ] | unique) as $KNOWN
| def used($f): (. as $a | $USE["\($a)|\($f.i)"]) // false;
  ([ $G[] | last ]) as $KEEP
| ([ $F[] | . as $f | $f.d.rows[] | select(.account_id | used($f)) ]) as $rows
| ($mb // ([ $F[].d.settings.max_behind // 2 ] | max)) as $M
| ($oal // any($F[]; .d.settings.oracle_any_patch_line // false)) as $OAL
| {
    accounts: [ $KEEP[] | {account, profile, collected_epoch, collected_utc: (.collected_epoch | utc), source: .label} ],
    rows: [ $rows[] | ora_recount($OAL) | if .versions_behind == null or .compliance_status == "UNKNOWN" then .
                      else .compliance_status = (if .versions_behind > $M then "NON-COMPLIANT" else "COMPLIANT" end) end ],
    region_status: [ $F[] | . as $f | ($f.d.region_status // [])[] | select(.account | used($f)) ],
    errors: ([ $F[] | . as $f | ($f.d.errors // [])[] | select((.account | used($f)) or ((.account as $a | $KNOWN | index([$a])) == null)) ]
             | unique_by([.account, .profile, .region, .call, .message])),
    regions: ([ $rows[].region ] + [ $F[] | . as $f | ($f.d.region_status // [])[] | select(.account | used($f)) | .region ] | unique),
    max_behind: $M,
    lifecycle_api: all($F[]; .d.settings.lifecycle_api // true),
    oracle_any_patch_line: $OAL,
    tz: ($F | max_by([.d.collected_epoch, .i]).d | {tz: (.tz // "UTC"), tz_abbr: (.tz_abbr // "UTC"), tz_offset: (.tz_offset // 0)}),
    sources: [ $F[] | . as $f | {file: .label, collected_epoch: .d.collected_epoch, collected_utc: (.d.collected_epoch | utc), script_version: .d.script_version,
                                 used: [ .d.accounts[].account | select(used($f)) ], superseded: [ .d.accounts[].account | select(used($f) | not) ]} ],
    superseded: [ $G[] | last as $k | .[:-1][]
                  | {account, kept: $k.label, kept_utc: ($k.collected_epoch | utc), dropped: .label, dropped_utc: (.collected_epoch | utc),
                     same_time: (.collected_epoch == $k.collected_epoch)} ]
  }
