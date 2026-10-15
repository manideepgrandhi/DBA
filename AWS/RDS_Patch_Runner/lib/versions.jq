# lib/versions.jq - engine-version parsing and minor-upgrade candidate selection.
# SHARED, byte-identical copy in RDS_Patch_Compliance, RDS_Pending_Maintenance and RDS_Patch_Runner (lib/versions.jq).
# Loaded with: include "versions" {search: "./"};  (resolved relative to the including file)

# Generic key: digit runs compare as numbers (15.10 > 15.9, 3.05.2 = 3.5.2), letter runs as lower-case text.
def vkey: [scan("[0-9]+|[A-Za-z]+") | (tonumber? // ascii_downcase)];

# ---- Oracle: <major>.0.0.0.ru-<YYYY-MM>[.<line>-<YYYY-MM | N>].r<N>
# line: none (plain RU), rur (release update revision), mrp (monthly recommended patches), spb (spatial patch
# bundle) or any other lower-case word ("other:<word>" is kept as its own line). null when the format is unknown.
def ora_parse:
  (capture("^(?<maj>[0-9]+)\\.0\\.0\\.0\\.ru-(?<ry>[0-9]{4})-(?<rm>[0-9]{2})(\\.(?<lt>[a-z]+)-(?<ld>[0-9]+(-[0-9]+)?))?\\.r(?<rev>[0-9]+)$"; "i") // null)
  | if . == null then null else
      {major: .maj, ru: [(.ry | tonumber), (.rm | tonumber)],
       line: (if .lt == null then "none" else (.lt | ascii_downcase) end),
       line_key: (if .ld == null then [] else [.ld | scan("[0-9]+") | tonumber] end),
       rev: (.rev | tonumber)} end;
def line_label: if . == "none" then "plain RU" else . end;
def ora_key: ora_parse | if . == null then null else [.ru[0], .ru[1]] + .line_key + [.rev] end;

# ---- major line of a version string (used when MajorEngineVersion is missing, and for every target)
# postgres / aurora-postgresql: first part (>= 10) else first two; oracle / sqlserver: first part;
# aurora-mysql: the Aurora major (8.0.mysql_aurora.3.05.2 -> "3", 5.7.mysql_aurora.2.11.6 -> "2", 3.05.2 -> "3");
# mysql / mariadb / docdb / neptune / other: first two parts.
def major_of($engine):
  tostring | split(".") as $k
  | if ($engine | test("postgres")) then (if (($k[0] | tonumber? // 0)) >= 10 then $k[0] else $k[0] + "." + ($k[1] // "0") end)
    elif ($engine | test("^oracle")) or ($engine | test("^sqlserver")) then ($k[0] | tonumber? | tostring) // $k[0]
    elif $engine == "aurora-mysql" then
      (capture("mysql_aurora\\.(?<a>[0-9]+)") .a // (if ($k | length) == 3 then $k[0] else $k[0] + "." + ($k[1] // "0") end))
    else $k[0] + "." + ($k[1] // "0") end;

# ---- ordering key within one major / patch line (all numeric). Oracle with an unknown format falls back to vkey.
def ver_key($engine):
  if ($engine | test("^oracle")) then (ora_key // vkey) else vkey end;

# ---- choose the minor upgrade candidates
# input: ValidUpgradeTarget[] objects (Engine, EngineVersion, IsMajorVersionUpgrade, MajorEngineVersion?)
# $cur_major: MajorEngineVersion of the current version when AWS returned it (else null -> parsed)
# $any_line : true = Oracle may move to another patch line (--oracle-any-patch-line); a target on another line
#             with the same RU / line date / revision as the current version then counts as newer too
# -> {targets: [objects, oldest first], versions: [...], excluded: [{version, reason}], warnings: [...]}
def minor_select($engine; $cur; $cur_major; $any_line):
  ($engine | test("^oracle")) as $ora
  | ($cur | major_of($engine)) as $cmaj_p
  | ($cur | if $ora then ora_parse else null end) as $cp
  | [ .[]? | select(type == "object") | select((.IsMajorVersionUpgrade // false) == false and ((.Engine // $engine) == $engine) and ((.EngineVersion // "") != "")) ]
  | unique_by(.EngineVersion)
  | map(. as $t | .EngineVersion as $v | ($v | major_of($engine)) as $tmaj
        | ($v | if $ora then ora_parse else null end) as $tp
        | ( if $tmaj != $cmaj_p then {x: "excluded \($v) (different major version \($tmaj); current is \($cmaj_p))"}
            elif $cur_major != null and ($t.MajorEngineVersion // null) != null and $t.MajorEngineVersion != $cur_major
              then {x: "excluded \($v) (different major version \($t.MajorEngineVersion); current is \($cur_major))"}
            elif $ora and ($cp == null or $tp == null) then
              {w: "oracle version format not recognised (\(if $cp == null then $cur else $v end)); generic compare used",
               k: ($v | vkey), ck: ($cur | vkey)}
            elif $ora and ($any_line | not) and $tp.line != $cp.line
              then {x: "excluded \($v) (different patch line \($tp.line | line_label); current is \($cp.line | line_label))"}
            elif $ora then {k: ($v | ora_key), ck: ($cur | ora_key), xl: ($tp.line != $cp.line)}
            else {k: ($v | vkey), ck: ($cur | vkey)} end ) as $d
        | $t + {_d: $d})
  | { targets: [ .[] | select(._d.x == null and (._d.k > ._d.ck or (._d.k == ._d.ck and ._d.xl == true))) | {k: ._d.k, t: (del(._d))} ] | sort_by(.k, .t.EngineVersion) | map(.t),
      excluded: [ .[] | select(._d.x != null) | {version: .EngineVersion, reason: ._d.x} ],
      warnings: [ .[] | ._d.w // empty ] | unique }
  | . + {versions: (.targets | map(.EngineVersion))};

# compare two versions of one engine: -1 / 0 / 1 (Oracle numeric within the format, else generic)
def vcmp_e($engine; $a; $b):
  ($a | ver_key($engine)) as $x | ($b | ver_key($engine)) as $y
  | if ($engine | test("^oracle")) and (($a | ora_key) == null or ($b | ora_key) == null) then
      (($a | vkey) as $p | ($b | vkey) as $q | if $p < $q then -1 elif $p > $q then 1 else 0 end)
    elif $x < $y then -1 elif $x > $y then 1 else 0 end;

# highest version of a list for one engine; Oracle: one per patch line, joined ("mrp: <v>; plain RU: <v>")
def latest_of($engine):
  map(select(. != null)) | unique
  | if length == 0 then null
    elif ($engine | test("^oracle")) then
      group_by(ora_parse | if . == null then "?" else .line end)
      | map(sort_by(ver_key($engine)) | .[-1]) as $tops
      | if ($tops | length) == 1 then $tops[0]
        else $tops | map(((ora_parse | if . == null then "unrecognised format" else (.line | line_label) end) + ": " + .)) | join("; ") end
    else sort_by(vkey) | .[-1] end;
