# merge.jq - combines several --save-data files (schema 1) into one raw input for explorer.jq.
# Usage: jq -s -f merge.jq inputs.jsonl, where each line is {i: <arg order>, label: <file name>, d: <data file>}.
# Per account the copy with the newest collection time wins (ties: the file given later). Each file's raw describe-*
# output (.d.source.regions) is re-used, so explorer.jq recomputes every derived value (days left, urgency, counts, CSV)
# at merge time. DocumentDB / Neptune are dropped from files collected without --include-docdb.
def keepeng($docdb): (.Engine // "") as $e | $docdb or ($e | test("^(docdb|neptune)") | not);
def utc: if . == null then null else strftime("%Y-%m-%d %H:%M UTC") end;

. as $F
| [$F[] | . as $f | .d.accounts[] | {account, profile, alias: (.alias // null),
     collected_epoch: (.collected_epoch // $f.d.generated_epoch), i: $f.i, label: $f.label}] as $ALL
| ($ALL | group_by(.account) | map(sort_by(.collected_epoch, .i) | {key: .[0].account, value: {keep: last, drop: .[:-1]}}) | from_entries) as $PICK
| ([$PICK[] | .keep | {key: "\(.account)|\(.i)", value: true}] | from_entries) as $USE
| ([$ALL[] | .account] | unique) as $KNOWN
| {accounts: [$PICK[] | .keep | {account, profile, alias, collected_epoch, source: .label}],
   regions: [$F[] | . as $f | (.d.source.include_docdb // false) as $dd | .d.source.regions[]
             | select($USE["\(.account)|\($f.i)"])
             | .clusters |= map(select(keepeng($dd))) | .instances |= map(select(keepeng($dd))) | .globals |= map(select(keepeng($dd)))],
   regions_scanned: [$F[] | . as $f | (.d.regions_scanned // [])[] | select($USE["\(.account)|\($f.i)"])],
   # errors of a kept account come from the kept file; errors without a known account (a profile with bad credentials) from every file
   errors: ([$F[] | . as $f | (.d.errors // [])[]
             | select($USE["\(.account)|\($f.i)"] or ((.account as $a | $KNOWN | index([$a])) == null))] | unique_by([.account, .profile, .region, .call, .message])),
   sources: [$F[] | . as $f | {file: .label, generated_epoch: .d.generated_epoch, generated_utc: (.d.generated_epoch | utc),
             generated_local: .d.generated_local, script_version: .d.script_version, merged: (.d.merged // false),
             accounts: [.d.accounts[].account],
             used: [.d.accounts[] | .account | select($USE["\(.)|\($f.i)"])],
             superseded: [.d.accounts[] | .account | select($USE["\(.)|\($f.i)"] | not)]}],
   superseded: [$PICK[] | .keep as $k | .drop[] | {account, kept: $k.label, kept_utc: ($k.collected_epoch | utc),
                dropped: .label, dropped_utc: (.collected_epoch | utc), same_time: (.collected_epoch == $k.collected_epoch)}],
   tz: ($F | max_by(.d.generated_epoch) | .d.meta | {tz, tz_abbr, tz_offset})}
