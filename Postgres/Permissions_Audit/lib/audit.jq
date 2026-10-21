# Rendering + risk logic for pg_permissions_audit.sh.
# Inputs: $mode (text|json|html|csv_grants|csv_roles|csv_flags|csv_summary), $S[0] = servers array, $cfg[0] = settings.
def C: $cfg[0];
def ts($e): ($e | strftime("%Y-%m-%d %H:%M UTC")) + " / " + ($e + 19800 | strftime("%Y-%m-%d %H:%M IST"));
def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("'"; "&#39;");
def glob2re: "^" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
def globmatch($globs): . as $s | ($globs | length) == 0 or any($globs[]; . as $g | $s | test($g | glob2re));
def pad($n): tostring | . + (" " * ([($n - length), 0] | max));
def qi: if test("^[a-z_][a-z0-9_$]*$") then . else "\"" + gsub("\""; "\"\"") + "\"" end;   # quote ident like PG
def sevrank: {"HIGH": 0, "MEDIUM": 1, "LOW": 2, "INFO": 3}[.] // 9;

# ---------------------------------------------------------------- preparation
def roles_of($s): ([$s.dbs[] | select(.status == "ok") | .data.roles][0] // []);
def chains_of($s): ([$s.dbs[] | select(.status == "ok") | .data.chains][0] // []);
def rmap($roles): $roles | map({key: .name, value: .}) | from_entries;
def reach($rm; $r): [$r] + ($rm[$r].effective // []) + ["PUBLIC"];
# grants worth displaying: drop the owner's implicit self-grant unless --show-owner-grants, apply --role filter
def shown($owner; $rf): map(select((C.show_owner or (.grantee != $owner or .grantor != $owner))
                                   and (($rf | length) == 0 or (.grantee as $g | $rf | index($g)))));
def privs: map(.priv + (if .grantable then "*" else "" end)) | unique | join(",");
def bygrantee: group_by(.grantee) | map({grantee: .[0].grantee, privs: privs, grantor: (map(.grantor) | unique | join(","))});

def prep_db($rf):
  .data as $d
  | .data.schemas |= map(select(.name | globmatch(C.schemas)))
  | .data.objects |= map(select(.schema | globmatch(C.schemas)))
  | .data.column_grants |= map(select(.schema | globmatch(C.schemas)))
  | .data.default_privileges |= map(select(.schema == "*" or (.schema | globmatch(C.schemas))));

def servers:
  $S[0] | map(. as $s | roles_of($s) as $roles | rmap($roles) as $rm
    | (if (C.roles | length) > 0 then [C.roles[] as $r | reach($rm; $r)[]] | unique else [] end) as $rf
    | . + {roles: $roles, rm: $rm, chains: chains_of($s), rf: $rf,
           status: (if .error then "error" elif any(.dbs[]; .status == "error") then "partial" else "ok" end),
           version: ([.dbs[] | select(.status == "ok") | .data.server_version][0] // null)}
    | .dbs |= map(if .status == "ok" then prep_db($rf) else . end));

# ---------------------------------------------------------------- risk flags
def F($sev; $code; $s; $db; $obj; $detail): {sev: $sev, code: $code, server: $s, db: $db, object: $obj, detail: $detail};
def login($rm; $r): ($rm[$r].login // false) and (($rm[$r].system // false) | not);
def flags_db($s; $rm):
  .name as $db | .data as $d
  | ( ($d.database.grants | map(select(.grantee == "PUBLIC" and .priv == "CREATE")) | if length > 0 then
        F("MEDIUM"; "PUBLIC_DB_CREATE"; $s; $db; $db; "PUBLIC can CREATE schemas in the database") else empty end),
      ($d.schemas[] | select(.name == "public") | select(any(.grants[]; .grantee == "PUBLIC" and .priv == "CREATE"))
        | F("HIGH"; "PUBLIC_CREATE_PUBLIC_SCHEMA"; $s; $db; "public"; "PUBLIC has CREATE on schema public (REVOKE CREATE ON SCHEMA public FROM PUBLIC)")),
      ($d.schemas[] | select(.name != "public" and (.ext | not)) | . as $n | .grants[] | select(.grantee == "PUBLIC")
        | F("MEDIUM"; "PUBLIC_SCHEMA_PRIV"; $s; $db; $n.name; "PUBLIC has \(.priv) on schema")),
      ($d.objects[] | select(.ext | not) | . as $o | (($o.schema | qi) + "." + $o.name) as $on
        | ([.grants[] | select(.grantee == "PUBLIC")] | privs) as $p
        | if $p == "" then empty
          elif ($o.type | test("function|procedure|aggregate")) then
            (if $o.secdef then F("HIGH"; "PUBLIC_EXEC_SECDEF"; $s; $db; $on; "SECURITY DEFINER \($o.type) executable by PUBLIC")
             elif ($o.acl_default | not) then F("LOW"; "PUBLIC_EXECUTE"; $s; $db; $on; "PUBLIC: \($p) (explicit grant)") else empty end)
          else F("HIGH"; "PUBLIC_OBJECT_PRIV"; $s; $db; $on; "\($o.type): PUBLIC has \($p)") end),
      ( [ ($d.database.grants[] | select(.grantee != $d.database.owner) | {g: .grantee, o: "database \($db)", gr: .grantable}),
          ($d.schemas[] | . as $n | .grants[] | select(.grantee != $n.owner) | {g: .grantee, o: "schema \($n.name)", gr: .grantable}),
          ($d.objects[] | select(.ext | not) | . as $o | .grants[] | select(.grantee != $o.owner) | {g: .grantee, o: "\($o.type) \($o.schema).\($o.name)", gr: .grantable}),
          ($d.column_grants[] | {g: .grantee, o: "column \(.schema).\(.table).\(.column)", gr: .grantable}),
          ($d.default_privileges[] | {g: .grantee, o: "default privs (\(.for_role) in \(.schema)) on \(.objtype)", gr: .grantable})
        ] as $all
        | ($all | map(select(login($rm; .g))) | group_by(.g)[]
             | F("MEDIUM"; "DIRECT_GRANT_TO_LOGIN"; $s; $db; .[0].g; "\(length) grant(s) made directly to login user: " + (map(.o) | unique | .[:3] | join("; ")) + (if (map(.o) | unique | length) > 3 then " ..." else "" end))),
          ($all | map(select(.gr and .g != "PUBLIC" and (($rm[.g].system // false) | not))) | group_by(.g)[]
             | F("MEDIUM"; "GRANT_OPTION"; $s; $db; .[0].g; "WITH GRANT OPTION on \(length) privilege(s): " + (map(.o) | unique | .[:3] | join("; "))))),
      ($d.objects | map(select((.ext | not) and login($rm; .owner))) | group_by(.owner)[]
        | F("LOW"; "OWNED_BY_LOGIN_USER"; $s; $db; .[0].owner; "owns \(length) object(s), e.g. " + (map("\(.schema).\(.name)") | .[:3] | join(", ")))),
      ($d.schemas | map(select(login($rm; .owner))) | .[] | F("LOW"; "SCHEMA_OWNED_BY_LOGIN_USER"; $s; $db; .name; "schema owned by login user \(.owner)")) );

def flags_server:
  . as $s | .name as $sn | .rm as $rm
  | ( (if .error then F("HIGH"; "SERVER_ERROR"; $sn; ""; .host; .error) else empty end),
      (.dbs[] | select(.status == "error") | F("HIGH"; "DB_ERROR"; $sn; .name; .name; .error)),
      (.roles[] | select(.system | not)
        | if .superuser then F("HIGH"; "SUPERUSER"; $sn; ""; .name; "role is SUPERUSER") else empty end,
          if .rds_superuser then F("HIGH"; "RDS_SUPERUSER_MEMBER"; $sn; ""; .name; "member of rds_superuser" + (if .login then " (login)" else " (group)" end)) else empty end,
          if (.login | not) and (.members | length) == 0 then F("LOW"; "UNUSED_GROUP_ROLE"; $sn; ""; .name; "NOLOGIN role with no members") else empty end,
          if .login and .valid_until_past then F("MEDIUM"; "PASSWORD_EXPIRED"; $sn; ""; .name; "VALID UNTIL \(.valid_until) is in the past") else empty end,
          if .login and (.valid_until == null or .valid_until == "infinity") then F("LOW"; "PASSWORD_NO_EXPIRY"; $sn; ""; .name; "no VALID UNTIL (fine for IAM-only users)") else empty end,
          if .login and (.createrole or .createdb) and (.rds_superuser | not) then F("MEDIUM"; "LOGIN_WITH_CREATEROLE_DB"; $sn; ""; .name; ([if .createrole then "CREATEROLE" else empty end, if .createdb then "CREATEDB" else empty end] | join(" "))) else empty end),
      (.dbs[] | select(.status == "ok") | flags_db($sn; $rm)) );

def allflags: [servers[] | flags_server] | sort_by((.sev | sevrank), .code, .server, .db, .object);

# ---------------------------------------------------------------- per-role access
def role_access($s; $r):
  reach($s.rm; $r) as $via | ([$r] + ($s.rm[$r].effective // [])) as $own
  | [$s.dbs[] | select(.status == "ok") | .name as $db | .data as $d
     | {db: $db,
        database: ($d.database.grants | map(select(.grantee as $g | $via | index($g)))),
        schemas: [$d.schemas[] | . as $n | {schema: .name, owner: .owner, owned: (.owner as $o | $own | index($o) != null),
                    grants: (.grants | map(select(.grantee as $g | $via | index($g))))} | select(.owned or (.grants | length) > 0)],
        objects: [$d.objects[] | select(.ext | not) | {schema, name, type, owner, owned: (.owner as $o | $own | index($o) != null),
                    grants: (.grants | map(select(.grantee as $g | $via | index($g))))}
                  | select(.owned or ((.grants | length) > 0 and ((.type | test("function|procedure|aggregate")) and (.grants | all(.grantee == "PUBLIC")) | not)))],
        columns: ($d.column_grants | map(select(.grantee as $g | $via | index($g)))),
        default_privileges: ($d.default_privileges | map(select(.grantee as $g | $via | index($g)))),
        user_mappings: [$d.fdw_servers[] | . as $f | select(.user_mappings | any(. as $u | $via | index($u))) | .name]}];

def role_targets($s): if (C.roles | length) > 0 then C.roles else [$s.roles[] | select(.login and (.system | not)) | .name] end;

# ---------------------------------------------------------------- summary
def summary($sv; $fl):
  [$sv[] | .name as $n | {server: .name, host: .host, port: .port, user: .user, auth: .auth, status, version, error: (.error // null),
     dbs_ok: ([.dbs[] | select(.status == "ok")] | length), dbs_failed: ([.dbs[] | select(.status == "error")] | length),
     roles: ([.roles[] | select(.system | not)] | length), login_roles: ([.roles[] | select(.login and (.system | not))] | length),
     objects: ([.dbs[] | select(.status == "ok") | .data.objects[] | select(.ext | not)] | length),
     high: ([$fl[] | select(.server == $n and .sev == "HIGH")] | length), medium: ([$fl[] | select(.server == $n and .sev == "MEDIUM")] | length),
     low: ([$fl[] | select(.server == $n and .sev == "LOW")] | length)}];

# ---------------------------------------------------------------- csv
def grant_rows:
  servers[] | . as $s | .rf as $rf | .dbs[] | select(.status == "ok") | .name as $db | .data as $d
  | ( ($d.database | . as $x | .grants | shown($x.owner; $rf)[] | [$s.name, $db, "database", "", $db, "database", $x.owner, .grantee, .grantor, .priv, .grantable]),
      ($d.schemas[] | . as $x | .grants | shown($x.owner; $rf)[] | [$s.name, $db, "schema", $x.name, $x.name, "schema", $x.owner, .grantee, .grantor, .priv, .grantable]),
      ($d.objects[] | select(.ext | not) | . as $x | .grants | shown($x.owner; $rf)[] | [$s.name, $db, "object", $x.schema, $x.name, $x.type, $x.owner, .grantee, .grantor, .priv, .grantable]),
      ($d.column_grants | shown(""; $rf)[] | [$s.name, $db, "column", .schema, "\(.table).\(.column)", "column", "", .grantee, .grantor, .priv, .grantable]),
      ($d.default_privileges | shown(""; $rf)[] | [$s.name, $db, "default", .schema, "for role " + .for_role, .objtype, .for_role, .grantee, "", .priv, .grantable]),
      ($d.fdw_servers[] | . as $x | (.grants | shown($x.owner; $rf)[] | [$s.name, $db, "foreign server", "", $x.name, "foreign server", $x.owner, .grantee, .grantor, .priv, .grantable]),
                                     (.user_mappings[] | [$s.name, $db, "user mapping", "", $x.name, "user mapping", $x.owner, ., "", "USER MAPPING", false])) );

# ---------------------------------------------------------------- text
def gline: "\(.grantee): \(.privs)";
def text_report:
  servers as $sv | allflags as $fl | summary($sv; $fl) as $sum
  | "PostgreSQL permissions audit  v\(C.version)   generated \(ts(C.now))",
    "Filters: db=\(C.dbs | join(",") | if . == "" then "*" else . end)  schema=\(C.schemas | join(",") | if . == "" then "*" else . end)  role=\(C.roles | join(",") | if . == "" then "-" else . end)  system schemas=\(if C.include_system then "included" else "excluded" end)",
    "Legend: priv* = WITH GRANT OPTION. Owners' implicit self-grants are \(if C.show_owner then "shown" else "hidden (--show-owner-grants)" end). Extension-owned objects are skipped.",
    "",
    "== SUMMARY (\($sum | length) server(s))",
    ("SERVER" | pad(18)) + ("STATUS" | pad(8)) + ("VERSION" | pad(9)) + ("DBS ok/fail" | pad(12)) + ("ROLES(login)" | pad(13)) + ("OBJECTS" | pad(8)) + "FLAGS H/M/L",
    ($sum[] | (.server | pad(18)) + (.status | pad(8)) + ((.version // "-") | split(" ")[0] | pad(9)) + ("\(.dbs_ok)/\(.dbs_failed)" | pad(12)) + ("\(.roles)(\(.login_roles))" | pad(13)) + (.objects | pad(8)) + "\(.high)/\(.medium)/\(.low)"
              + (if .error then "   ERROR: " + (.error | gsub("\n"; " ") | .[:160]) else "" end)),
    "",
    "== RISK FLAGS (\($fl | length): \([$fl[] | select(.sev == "HIGH")] | length) high, \([$fl[] | select(.sev == "MEDIUM")] | length) medium, \([$fl[] | select(.sev == "LOW")] | length) low)",
    ($fl | group_by(.code) | sort_by(.[0].sev | sevrank) | .[] | "  [\(.[0].sev)] \(.[0].code) (\(length))",
       (.[:C.top][] | "      \(.server)\(if .db != "" then "/" + .db else "" end)  \(.object): \(.detail | gsub("\n"; " ") | .[:200])"),
       (if length > C.top then "      ... \(length - C.top) more (see csv/json/html)" else empty end)),
    "",
    ($sv[] | . as $s | .rf as $rf
     | "################ SERVER \(.name)  \(.user)@\(.host):\(.port)  \(.version // "")  [\(.status)]",
       (if .error then "  ERROR: \(.error)" else empty end),
       (.dbs[] | select(.status == "error") | "  DB \(.name): ERROR \(.error | gsub("\n"; " "))"),
       (.dbs[] | select(.status == "ok") | .name as $db | .data as $d
        | "", "=== DATABASE \($db)   owner=\($d.database.owner)   conn_limit=\($d.database.conn_limit)\(if $d.database.acl_default then "   (default ACL)" else "" end)",
          "    grants: " + ($d.database.grants | shown($d.database.owner; $rf) | bygrantee | map(gline) | join("; ") | if . == "" then "(none)" else . end),
          ($d.fdw_servers[] | . as $f | "    foreign server \(.name) (\(.fdw)) owner=\(.owner)  usage: " + (.grants | shown($f.owner; $rf) | bygrantee | map(gline) | join("; ")) + "  user mappings: " + (.user_mappings | join(", "))),
          ($d.default_privileges | select(length > 0) | "    default privileges (ALTER DEFAULT PRIVILEGES):",
             (shown(""; $rf) | group_by(.for_role, .schema, .objtype)[] | "      for role \(.[0].for_role) in schema \(.[0].schema) on \(.[0].objtype): " + (bygrantee | map(gline) | join("; ")))),
          ($d.schemas[] | . as $n
           | "  --- schema \(.name | qi)  owner=\(.owner)\(if .ext then " (extension)" else "" end)  " + (.grants | shown($n.owner; $rf) | bygrantee | map(gline) | join("; ") | if . == "" then "(no grants)" else . end),
             ($d.objects[] | select(.schema == $n.name and (.ext | not)) | . as $o
              | (.grants | shown($o.owner; $rf) | bygrantee) as $g
              | select(($rf | length) == 0 or ($g | length) > 0)
              | "      " + (.type | pad(15)) + (.name | pad(34)) + " owner=" + (.owner | pad(14)) + (if .secdef then " SECDEF" else "" end)
                + (if .acl_default then " (default ACL)" else "" end) + "  " + ($g | map(gline) | join("; "))),
             ($d.column_grants | map(select(.schema == $n.name)) | shown(""; $rf) | group_by(.table, .column)[]
              | "      " + ("column" | pad(15)) + ("\(.[0].table).\(.[0].column)" | pad(34)) + "  " + (bygrantee | map(gline) | join("; ")))) ),
       (if .error then empty else "", "=== ROLES on \(.name)  (non-system; L=login S=rds_superuser R=createrole D=createdb I=inherit)",
       (.roles[] | select(.system | not) | select(($rf | length) == 0 or (.name as $n | $rf | index($n)))
        | "  " + (.name | pad(20)) + ([if .login then "L" else "-" end, if .rds_superuser or .superuser then "S" else "-" end, if .createrole then "R" else "-" end, if .createdb then "D" else "-" end, if .inherit then "I" else "-" end] | join(""))
          + "  conn_limit=\(.conn_limit)  valid_until=\(.valid_until // "never")"
          + "  member_of=[\(.member_of | join(","))]  members=[\(.members | join(","))]"
          + (if (.effective | length) > 0 then "  inherits=[\(.effective | join(","))]" else "" end)
          + (if (.can_set | length) > 0 then "  SET ROLE only=[\(.can_set | join(","))]" else "" end)),
       (.chains | map(select(.depth > 1)) | select(length > 0) | "  membership chains (depth > 1):", (.[] | "    \(.path)")) end),
       (if (C.roles | length) > 0 then
          (role_targets($s)[] as $r | select($s.rm[$r] != null) | "", "=== EFFECTIVE ACCESS for role \($r) on \($s.name)  (via: \(reach($s.rm; $r) | join(", ")))",
             (role_access($s; $r)[] | "  db \(.db): " + (.database | bygrantee | map("\(.privs) via \(.grantee)") | join(", ") | if . == "" then "(no database privileges - cannot CONNECT)" else . end),
               (.schemas[] | "    schema \(.schema)\(if .owned then " (OWNER)" else "" end): " + (.grants | map("\(.priv) via \(.grantee)") | join(", "))),
               (.objects[] | "    \(.type) \(.schema).\(.name)\(if .owned then " (OWNER)" else "" end): " + (.grants | bygrantee | map("\(.privs) via \(.grantee)") | join(", "))),
               (.columns | group_by(.table, .column)[] | "    column \(.[0].schema).\(.[0].table).\(.[0].column): " + (bygrantee | map("\(.privs) via \(.grantee)") | join(", "))),
               (.default_privileges | group_by(.for_role, .schema, .objtype)[] | "    future \(.[0].objtype) created by \(.[0].for_role) in schema \(.[0].schema): " + (bygrantee | map("\(.privs) via \(.grantee)") | join(", "))),
               (.user_mappings[] | "    user mapping on foreign server \(.)"))),
          (C.roles - [$s.rm | keys[]] | select(length > 0 and ($s.error | not)) | "", "  (role(s) not on \($s.name): \(join(", ")))")
        else empty end), "");

# ---------------------------------------------------------------- html
def chips: map("<span class=\"g\"><b>\(.grantee | esc)</b> \(.privs | esc)</span>") | join(" ");
def html_report:
  servers as $sv | allflags as $fl | summary($sv; $fl) as $sum
  | ($fl | map(.code) | unique) as $codes
  | "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>PostgreSQL permissions audit</title><style>
body{font:13px/1.4 system-ui,Segoe UI,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1d2330}
header{background:#1f3b5b;color:#fff;padding:12px 20px}header h1{margin:0;font-size:18px}header .m{opacity:.8;font-size:12px}
.bar{position:sticky;top:0;z-index:5;background:#fff;border-bottom:1px solid #d8dce3;padding:8px 20px;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.bar input{flex:1;min-width:260px;padding:6px 8px;border:1px solid #b9c0cc;border-radius:4px}.bar select,.bar button{padding:5px 8px}
main{padding:12px 20px}table{border-collapse:collapse;width:100%;background:#fff;margin:6px 0}th,td{border:1px solid #e1e4ea;padding:3px 6px;text-align:left;vertical-align:top}
th{background:#eef1f5;position:relative}details.card{background:#fff;border:1px solid #d8dce3;border-radius:6px;margin:8px 0}
details.card>summary{cursor:pointer;padding:8px 12px;font-size:14px}details.card[open]>summary{border-bottom:1px solid #e1e4ea;background:#f0f4fa}
.cb{padding:6px 12px 12px}details.sch{margin:6px 0 6px 6px;border-left:3px solid #9db4d0;padding-left:8px}details.sch>summary{cursor:pointer;font-weight:600}
.hidden{display:none!important}.g{display:inline-block;background:#eef3fb;border:1px solid #cfdbee;border-radius:3px;padding:0 4px;margin:1px}
.HIGH{color:#fff;background:#c0392b}.MEDIUM{background:#f0b429}.LOW{background:#d9e2ec}.INFO{background:#eee}.sev{padding:0 5px;border-radius:3px;font-size:11px;font-weight:700}
.err{color:#b00020;font-weight:600}.k{color:#56607a;font-size:12px}mark{background:#ffe066}.tag{font-size:11px;border:1px solid #b9c0cc;border-radius:3px;padding:0 4px;margin-left:6px;color:#56607a}
#none{padding:20px;color:#56607a}</style></head><body>
<header><h1>PostgreSQL permissions audit</h1><div class=\"m\">Generated \(ts(C.now) | esc) · v\(C.version | esc) · read-only catalog audit · owners' self-grants \(if C.show_owner then "shown" else "hidden" end) · priv* = WITH GRANT OPTION</div></header>
<div class=\"bar\"><input id=\"q\" placeholder=\"Search server, database, schema, object, role, privilege…  (press / to focus)\" autocomplete=\"off\">
<select id=\"fs\"><option value=\"\">All servers</option>\($sv | map("<option>\(.name | esc)</option>") | join(""))</select>
<select id=\"fk\"><option value=\"\">All sections</option><option value=\"db\">Databases</option><option value=\"roles\">Roles</option><option value=\"access\">Per-role access</option></select>
<select id=\"fsev\"><option value=\"\">Flags: all</option><option>HIGH</option><option>MEDIUM</option><option>LOW</option></select>
<button id=\"ex\">Expand all</button><button id=\"co\">Collapse all</button><button id=\"clear\">Clear</button><span id=\"count\" class=\"k\"></span></div><main>
<h2>Summary</h2><table><tr><th>Server</th><th>Endpoint</th><th>Status</th><th>Version</th><th>DBs ok/failed</th><th>Roles (login)</th><th>Objects</th><th>High</th><th>Medium</th><th>Low</th></tr>
\($sum | map("<tr><td>\(.server | esc)</td><td>\(.user | esc)@\(.host | esc):\(.port)</td><td class=\"\(if .status != "ok" then "err" else "" end)\">\(.status)\(if .error then ": " + (.error | esc) else "" end)</td><td>\(.version // "-" | esc)</td><td>\(.dbs_ok) / \(.dbs_failed)</td><td>\(.roles) (\(.login_roles))</td><td>\(.objects)</td><td>\(.high)</td><td>\(.medium)</td><td>\(.low)</td></tr>") | join(""))</table>
<h2>Risk flags (\($fl | length))</h2><table id=\"flags\"><tr><th>Severity</th><th>Flag</th><th>Server</th><th>Database</th><th>Object / role</th><th>Detail</th></tr>
\($fl | map("<tr class=\"fl\" data-sev=\"\(.sev)\" data-server=\"\(.server | esc)\"><td><span class=\"sev \(.sev)\">\(.sev)</span></td><td>\(.code)</td><td>\(.server | esc)</td><td>\(.db | esc)</td><td>\(.object | esc)</td><td>\(.detail | esc)</td></tr>") | join(""))</table>
<h2>Details</h2><div id=\"cards\">"
  + ([$sv[] | . as $s | .rf as $rf
      | (if .error then "<details class=\"card\" data-kind=\"db\" data-server=\"\(.name | esc)\"><summary><b>\(.name | esc)</b> <span class=\"err\">server error</span></summary><div class=\"cb err\">\(.error | esc)</div></details>" else "" end)
      + ([.dbs[] | select(.status == "error") | "<details class=\"card\" data-kind=\"db\" data-server=\"\($s.name | esc)\"><summary><b>\($s.name | esc) / \(.name | esc)</b> <span class=\"err\">database error</span></summary><div class=\"cb err\">\(.error | esc)</div></details>"] | join(""))
      + ([.dbs[] | select(.status == "ok") | .name as $db | .data as $d
          | "<details class=\"card\" data-kind=\"db\" data-server=\"\($s.name | esc)\"><summary><b>\($s.name | esc) / \($db | esc)</b><span class=\"tag\">database</span><span class=\"tag\">owner \($d.database.owner | esc)</span><span class=\"tag\">\($d.schemas | length) schemas</span><span class=\"tag\">\([$d.objects[] | select(.ext | not)] | length) objects</span></summary><div class=\"cb\">"
            + "<p><b>Database grants:</b> \($d.database.grants | shown($d.database.owner; $rf) | bygrantee | chips)\(if $d.database.acl_default then " <span class=\"k\">(default ACL)</span>" else "" end)</p>"
            + (if ($d.default_privileges | length) > 0 then "<p><b>Default privileges</b></p><table><tr><th>For role (creator)</th><th>Schema</th><th>Object type</th><th>Grantees</th></tr>"
                + ($d.default_privileges | shown(""; $rf) | group_by(.for_role, .schema, .objtype) | map("<tr><td>\(.[0].for_role | esc)</td><td>\(.[0].schema | esc)</td><td>\(.[0].objtype)</td><td>\(bygrantee | chips)</td></tr>") | join("")) + "</table>" else "" end)
            + (if ($d.fdw_servers | length) > 0 then "<p><b>Foreign servers</b></p><table><tr><th>Server</th><th>FDW</th><th>Owner</th><th>USAGE</th><th>User mappings</th></tr>"
                + ($d.fdw_servers | map(. as $f | "<tr><td>\(.name | esc)</td><td>\(.fdw | esc)</td><td>\(.owner | esc)</td><td>\(.grants | shown($f.owner; $rf) | bygrantee | chips)</td><td>\(.user_mappings | map(esc) | join(", "))</td></tr>") | join("")) + "</table>" else "" end)
            + ([$d.schemas[] | . as $n
                | ([$d.objects[] | select(.schema == $n.name and (.ext | not))]) as $objs
                | ($d.column_grants | map(select(.schema == $n.name)) | shown(""; $rf)) as $cols
                | "<details class=\"sch\"><summary>schema \(.name | esc) <span class=\"k\">owner \(.owner | esc) · \($objs | length) objects\(if .ext then " · extension" else "" end)</span></summary>"
                  + "<p>Schema grants: \(.grants | shown($n.owner; $rf) | bygrantee | chips)</p>"
                  + (if ($objs | length) > 0 then "<table><tr><th>Type</th><th>Object</th><th>Owner</th><th>Grants</th></tr>"
                      + ($objs | map(. as $o | (.grants | shown($o.owner; $rf) | bygrantee) as $g | select(($rf | length) == 0 or ($g | length) > 0)
                          | "<tr><td>\(.type)\(if .secdef then " <span class=\"sev HIGH\">SECDEF</span>" else "" end)</td><td>\(.name | esc)</td><td>\(.owner | esc)</td><td>\($g | chips)\(if .acl_default then " <span class=\"k\">(default ACL)</span>" else "" end)</td></tr>") | join(""))
                      + ($cols | group_by(.table, .column) | map("<tr><td>column</td><td>\(.[0].table | esc).\(.[0].column | esc)</td><td></td><td>\(bygrantee | chips)</td></tr>") | join(""))
                      + "</table>" else "" end) + "</details>"] | join(""))
            + "</div></details>"] | join(""))
      + (if .error then "" else "<details class=\"card\" data-kind=\"roles\" data-server=\"\(.name | esc)\"><summary><b>\(.name | esc) / roles</b><span class=\"tag\">roles</span><span class=\"tag\">\([.roles[] | select(.system | not)] | length) non-system</span></summary><div class=\"cb\"><table><tr><th>Role</th><th>Login</th><th>rds_superuser</th><th>CreateRole</th><th>CreateDB</th><th>Inherit</th><th>Conn limit</th><th>Valid until</th><th>Member of</th><th>Members</th><th>Inherits (effective)</th></tr>"
        + ([.roles[] | select(.system | not) | "<tr><td>\(.name | esc)</td><td>\(.login)</td><td>\(.rds_superuser or .superuser)</td><td>\(.createrole)</td><td>\(.createdb)</td><td>\(.inherit)</td><td>\(.conn_limit)</td><td>\(.valid_until // "never" | esc)</td><td>\(.member_of | map(esc) | join(", "))</td><td>\(.members | map(esc) | join(", "))</td><td>\(.effective | map(esc) | join(", "))\(if (.can_set | length) > 0 then " <span class=\"k\">SET ROLE only: \(.can_set | map(esc) | join(", "))</span>" else "" end)</td></tr>"] | join(""))
        + "</table>" + (.chains | map(select(.depth > 1)) | if length > 0 then "<p><b>Membership chains</b></p><ul>" + (map("<li>\(.path | esc)</li>") | join("")) + "</ul>" else "" end) + "</div></details>" end)
      + ([role_targets($s)[] as $r | select($s.rm[$r] != null)
          | "<details class=\"card\" data-kind=\"access\" data-server=\"\($s.name | esc)\"><summary><b>\($s.name | esc) / access: \($r | esc)</b><span class=\"tag\">per-role</span><span class=\"tag\">via \(reach($s.rm; $r) | map(esc) | join(", "))</span></summary><div class=\"cb\"><table><tr><th>Database</th><th>Level</th><th>Object</th><th>Privileges (via)</th></tr>"
            + ([role_access($s; $r)[] | .db as $db
                | (if (.database | length) > 0 then "<tr><td>\($db | esc)</td><td>database</td><td>\($db | esc)</td><td>\(.database | bygrantee | chips)</td></tr>" else "" end)
                  + (.schemas | map("<tr><td>\($db | esc)</td><td>schema</td><td>\(.schema | esc)\(if .owned then " <b>(owner)</b>" else "" end)</td><td>\(.grants | bygrantee | chips)</td></tr>") | join(""))
                  + (.objects | map("<tr><td>\($db | esc)</td><td>\(.type)</td><td>\(.schema | esc).\(.name | esc)\(if .owned then " <b>(owner)</b>" else "" end)</td><td>\(.grants | bygrantee | chips)</td></tr>") | join(""))
                  + (.columns | group_by(.table, .column) | map("<tr><td>\($db | esc)</td><td>column</td><td>\(.[0].schema | esc).\(.[0].table | esc).\(.[0].column | esc)</td><td>\(bygrantee | chips)</td></tr>") | join(""))
                  + (.default_privileges | map("<tr><td>\($db | esc)</td><td>future \(.objtype)</td><td>created by \(.for_role | esc) in \(.schema | esc)</td><td><span class=\"g\"><b>\(.grantee | esc)</b> \(.priv)</span></td></tr>") | join(""))
                  + (.user_mappings | map("<tr><td>\($db | esc)</td><td>user mapping</td><td>\(. | esc)</td><td></td></tr>") | join(""))] | join(""))
            + "</table></div></details>"] | join(""))] | join(""))
  + "</div><div id=\"none\" hidden>No matching cards.</div></main><script>
(function(){var q=document.getElementById('q'),fs=document.getElementById('fs'),fk=document.getElementById('fk'),fv=document.getElementById('fsev'),cnt=document.getElementById('count');
var cards=[].slice.call(document.querySelectorAll('details.card')),flags=[].slice.call(document.querySelectorAll('tr.fl'));
function unmark(){[].slice.call(document.querySelectorAll('mark')).forEach(function(m){var p=m.parentNode;p.replaceChild(document.createTextNode(m.textContent),m);p.normalize();});}
function mark(el,t){var w=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null),n,ns=[],c=0;while(n=w.nextNode())ns.push(n);
 ns.forEach(function(n){var s=n.nodeValue,l=s.toLowerCase(),i=l.indexOf(t);if(i<0)return;var f=document.createDocumentFragment(),p=0;
 while(i>=0){f.appendChild(document.createTextNode(s.slice(p,i)));var m=document.createElement('mark');m.textContent=s.slice(i,i+t.length);f.appendChild(m);c++;p=i+t.length;i=l.indexOf(t,p);}
 f.appendChild(document.createTextNode(s.slice(p)));n.parentNode.replaceChild(f,n);});return c;}
function run(){unmark();var t=q.value.trim().toLowerCase(),sv=fs.value,k=fk.value,vis=0,hits=0;
 cards.forEach(function(c){var ok=(!sv||c.dataset.server===sv)&&(!k||c.dataset.kind===k)&&(!t||c.textContent.toLowerCase().indexOf(t)>=0);
  c.classList.toggle('hidden',!ok);if(ok)vis++;
  if(ok&&t){hits+=mark(c,t);c.open=true;[].slice.call(c.querySelectorAll('details.sch')).forEach(function(s){s.open=s.textContent.toLowerCase().indexOf(t)>=0;});}
  else if(!t)c.open=false;});
 flags.forEach(function(r){var ok=(!sv||r.dataset.server===sv)&&(!fv.value||r.dataset.sev===fv.value)&&(!t||r.textContent.toLowerCase().indexOf(t)>=0);r.classList.toggle('hidden',!ok);if(ok&&t)hits+=mark(r,t);});
 document.getElementById('none').hidden=vis>0;cnt.textContent=vis+' of '+cards.length+' card(s)'+(t?' · '+hits+' match(es)':'');}
var tm;q.addEventListener('input',function(){clearTimeout(tm);tm=setTimeout(run,150);});[fs,fk,fv].forEach(function(e){e.addEventListener('change',run);});
document.getElementById('clear').onclick=function(){q.value='';fs.value='';fk.value='';fv.value='';run();};
document.getElementById('ex').onclick=function(){cards.forEach(function(c){if(!c.classList.contains('hidden')){c.open=true;[].slice.call(c.querySelectorAll('details.sch')).forEach(function(s){s.open=true;});}});};
document.getElementById('co').onclick=function(){[].slice.call(document.querySelectorAll('details')).forEach(function(c){c.open=false;});};
document.addEventListener('keydown',function(e){if(e.key==='/'&&document.activeElement!==q){e.preventDefault();q.focus();q.select();}else if(e.key==='Escape'&&document.activeElement===q){q.value='';run();}});
run();})();
</script></body></html>";

# ---------------------------------------------------------------- dispatch
if $mode == "text" then text_report
elif $mode == "json" then
  servers as $sv | allflags as $fl
  | {generated_utc: (C.now | todate), generated_ist: (C.now + 19800 | strftime("%Y-%m-%dT%H:%M:%S+05:30")), version: C.version,
     filters: {db: C.dbs, schema: C.schemas, role: C.roles, include_system: C.include_system},
     summary: summary($sv; $fl), flags: $fl,
     servers: [$sv[] | . as $s | del(.rm, .rf) | .per_role_access = [role_targets($s)[] as $r | select($s.rm[$r] != null) | {role: $r, via: reach($s.rm; $r), databases: role_access($s; $r)}]]}
elif $mode == "html" then html_report
elif $mode == "csv_grants" then (["server","database","level","schema","object","object_type","owner","grantee","grantor","privilege","grantable"] | @csv), (grant_rows | @csv)
elif $mode == "csv_roles" then (["server","role","login","rds_superuser","superuser","createrole","createdb","inherit","conn_limit","valid_until","member_of","members","effective_roles","system"] | @csv),
  (servers[] | .name as $n | .roles[] | [$n, .name, .login, .rds_superuser, .superuser, .createrole, .createdb, .inherit, .conn_limit, (.valid_until // ""), (.member_of | join(";")), (.members | join(";")), (.effective | join(";")), .system] | @csv)
elif $mode == "csv_flags" then (["severity","flag","server","database","object","detail"] | @csv), (allflags[] | [.sev, .code, .server, .db, .object, .detail] | @csv)
elif $mode == "csv_summary" then (["server","host","port","user","auth","status","version","dbs_ok","dbs_failed","roles","login_roles","objects","high","medium","low","error"] | @csv),
  (summary(servers; allflags)[] | [.server, .host, .port, .user, .auth, .status, .version, .dbs_ok, .dbs_failed, .roles, .login_roles, .objects, .high, .medium, .low, (.error // "")] | @csv)
else error("unknown mode " + $mode) end
