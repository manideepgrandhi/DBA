-- pg_permissions_audit.sql - standalone READ-ONLY permissions audit of ONE PostgreSQL / Aurora PostgreSQL database.
-- Plain psql (10+ client), no bash/jq. Server PG 11+ (tested 13, 16, 17). Catalog SELECTs only, inside BEGIN READ ONLY.
--
--   psql -X -h HOST -U USER -d DB -f pg_permissions_audit.sql                       > audit.txt
--   psql -X -h HOST -U USER -d DB -f pg_permissions_audit.sql -v role=app_user      > audit.txt   (+ per-role view)
--   psql -X -h HOST -U USER -d DB -f pg_permissions_audit.sql -v schema='sales*'    > audit.txt   (schema filter)
--
-- Optional psql variables:
--   role    = role name for the "effective access" section (direct + inherited group roles + PUBLIC)
--   schema  = schema name or pattern (* or % wildcards). Default: all non-system schemas
--   showall = on -> also list owners' implicit self-grants and extension-owned objects (default off)
--   csv     = on -> CSV tables instead of aligned text (psql 12+ client); section headers stay as text lines
-- Notes: priv* in output = WITH GRANT OPTION. Never reads pg_authid, password hashes or user-mapping options.

\set ON_ERROR_STOP on
\set QUIET on
\if :{?schema}
\else
  \set schema ''
\endif
\if :{?role}
\else
  \set role ''
\endif
\if :{?showall}
\else
  \set showall off
\endif
\pset pager off
\if :{?csv}
  \pset format csv
\else
  \pset format aligned
  \pset border 1
\endif
\pset null ''
\pset footer on
\timing off

BEGIN READ ONLY;
SET LOCAL statement_timeout = '120s';
SET LOCAL lock_timeout = '5s';
SET LOCAL search_path = pg_catalog;

-- reusable SQL fragments (psql interpolates :name before sending)
\set G 'CASE WHEN a.grantee = 0 THEN ''PUBLIC'' ELSE pg_get_userbyid(a.grantee) END'
\set SYS '(n.nspname IN (''pg_catalog'', ''information_schema'') OR n.nspname LIKE ''pg\\_toast%'' OR n.nspname LIKE ''pg\\_temp\\_%'')'
\set PRIVS 'string_agg(a.privilege_type || CASE WHEN a.is_grantable THEN ''*'' ELSE '''' END, '','' ORDER BY a.privilege_type)'

SELECT replace(:'schema', '*', '%') AS schema_like,
       (:'role' <> '') AS role_given,
       EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') AS role_exists,
       (:'showall'::boolean) AS show_all
\gset

\echo
\echo '================================================================================'
\echo ' PostgreSQL permissions audit (read-only)   priv* = WITH GRANT OPTION'
\echo '================================================================================'
SELECT current_setting('server_version') AS server_version, current_database() AS database, current_user AS connected_as,
       to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"') AS generated_utc,
       to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI "IST"') AS generated_ist,
       CASE WHEN :'schema' = '' THEN 'all non-system' ELSE :'schema' END AS schema_filter,
       CASE WHEN :'role' = '' THEN '-' ELSE :'role' END AS role_view,
       (SELECT CASE WHEN rolsuper THEN 'superuser'
                    WHEN EXISTS (SELECT 1 FROM pg_roles s WHERE s.rolname = 'rds_superuser' AND pg_has_role(current_user, s.oid, 'MEMBER')) THEN 'rds_superuser member'
                    ELSE 'regular role' END FROM pg_roles WHERE rolname = current_user) AS privilege_level;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 1. RISK FLAGS (HIGH / MEDIUM / LOW) ======================================='
WITH ns AS (SELECT n.oid, n.nspname, n.nspowner, n.nspacl FROM pg_namespace n
            WHERE NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')),
ext AS (SELECT classid, objid FROM pg_depend WHERE deptype = 'e'),
rl AS (SELECT r.*, (r.oid < 16384 OR r.rolname ~ '^(pg_|rds_|rdsadmin$|rdsrepladmin$|rdstopmgr$|rdsproxyadmin$)') AS sys FROM pg_roles r),
obj AS (
  SELECT n.nspname AS schema, c.relname AS name,
         CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview'
                        WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'foreign table' END AS type,
         c.relowner AS owner, c.relacl IS NULL AS acl_default, false AS secdef,
         coalesce(c.relacl, acldefault(CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END::"char", c.relowner)) AS acl
  FROM pg_class c JOIN ns n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
    AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_class'::regclass AND ext.objid = c.oid)
  UNION ALL
  SELECT n.nspname, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'a' THEN 'aggregate' ELSE 'function' END,
         p.proowner, p.proacl IS NULL, p.prosecdef, coalesce(p.proacl, acldefault('f', p.proowner))
  FROM pg_proc p JOIN ns n ON n.oid = p.pronamespace
  WHERE NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_proc'::regclass AND ext.objid = p.oid)),
grants AS (   -- every non-owner grant in scope: (kind, object, grantee oid, grantable)
  SELECT 'database' AS kind, d.datname::text AS object, a.grantee, a.is_grantable, a.privilege_type
  FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
  WHERE d.datname = current_database() AND a.grantee <> d.datdba
  UNION ALL SELECT 'schema', n.nspname, a.grantee, a.is_grantable, a.privilege_type
  FROM ns n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a WHERE a.grantee <> n.nspowner
  UNION ALL SELECT o.type, o.schema || '.' || o.name, a.grantee, a.is_grantable, a.privilege_type
  FROM obj o, aclexplode(o.acl) a WHERE a.grantee <> o.owner
  UNION ALL SELECT 'column', n.nspname || '.' || c.relname || '.' || at.attname, a.grantee, a.is_grantable, a.privilege_type
  FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid JOIN ns n ON n.oid = c.relnamespace, aclexplode(at.attacl) a
  WHERE at.attacl IS NOT NULL AND at.attnum > 0 AND NOT at.attisdropped
  UNION ALL SELECT 'default privs', pg_get_userbyid(d.defaclrole) || ' in ' || coalesce(n.nspname, '*'), a.grantee, a.is_grantable, a.privilege_type
  FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace, aclexplode(d.defaclacl) a),
flags AS (
  SELECT 'HIGH' AS severity, 'PUBLIC_CREATE_PUBLIC_SCHEMA' AS flag, 'public' AS object,
         'PUBLIC can CREATE in schema public (REVOKE CREATE ON SCHEMA public FROM PUBLIC)' AS detail
  FROM ns n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
  WHERE n.nspname = 'public' AND a.grantee = 0 AND a.privilege_type = 'CREATE'
  UNION ALL SELECT 'HIGH', 'PUBLIC_OBJECT_PRIV', o.schema || '.' || o.name, o.type || ': PUBLIC has ' || :PRIVS
  FROM obj o, aclexplode(o.acl) a WHERE a.grantee = 0 AND o.type NOT IN ('function', 'procedure', 'aggregate')
  GROUP BY o.schema, o.name, o.type
  UNION ALL SELECT 'HIGH', 'PUBLIC_EXEC_SECDEF', o.schema || '.' || o.name, 'SECURITY DEFINER ' || o.type || ' executable by PUBLIC'
  FROM obj o, aclexplode(o.acl) a WHERE o.secdef AND a.grantee = 0
  UNION ALL SELECT 'HIGH', 'RDS_SUPERUSER_MEMBER', r.rolname, 'member of rds_superuser' || CASE WHEN r.rolcanlogin THEN ' (login)' ELSE ' (group)' END
  FROM rl r JOIN pg_roles s ON s.rolname = 'rds_superuser' AND s.oid <> r.oid
  WHERE NOT r.sys AND pg_has_role(r.oid, s.oid, 'MEMBER')
  UNION ALL SELECT 'HIGH', 'SUPERUSER', r.rolname, 'role is SUPERUSER' FROM rl r WHERE r.rolsuper AND NOT r.sys
  UNION ALL SELECT 'MEDIUM', 'PUBLIC_SCHEMA_PRIV', n.nspname, 'PUBLIC has ' || a.privilege_type || ' on schema'
  FROM ns n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a WHERE n.nspname <> 'public' AND a.grantee = 0
  UNION ALL SELECT 'MEDIUM', 'PUBLIC_DB_CREATE', current_database(), 'PUBLIC can CREATE schemas in this database'
  FROM grants g WHERE g.kind = 'database' AND g.grantee = 0 AND g.privilege_type = 'CREATE'
  UNION ALL SELECT 'MEDIUM', 'DIRECT_GRANT_TO_LOGIN', r.rolname,
         count(*) || ' grant(s) made directly to a login user, e.g. ' || string_agg(DISTINCT g.kind || ' ' || g.object, '; ')
  FROM grants g JOIN rl r ON r.oid = g.grantee WHERE r.rolcanlogin AND NOT r.sys GROUP BY r.rolname
  UNION ALL SELECT 'MEDIUM', 'GRANT_OPTION', r.rolname, 'WITH GRANT OPTION on: ' || string_agg(DISTINCT g.kind || ' ' || g.object, '; ')
  FROM grants g JOIN rl r ON r.oid = g.grantee WHERE g.is_grantable AND NOT r.sys GROUP BY r.rolname
  UNION ALL SELECT 'MEDIUM', 'PASSWORD_EXPIRED', r.rolname, 'VALID UNTIL ' || r.rolvaliduntil || ' is in the past'
  FROM rl r WHERE r.rolcanlogin AND NOT r.sys AND r.rolvaliduntil < now()
  UNION ALL SELECT 'MEDIUM', 'LOGIN_WITH_CREATEROLE_DB', r.rolname,
         concat_ws(' ', CASE WHEN r.rolcreaterole THEN 'CREATEROLE' END, CASE WHEN r.rolcreatedb THEN 'CREATEDB' END)
  FROM rl r WHERE r.rolcanlogin AND NOT r.sys AND (r.rolcreaterole OR r.rolcreatedb) AND NOT r.rolsuper
    AND NOT EXISTS (SELECT 1 FROM pg_roles s WHERE s.rolname = 'rds_superuser' AND s.oid <> r.oid AND pg_has_role(r.oid, s.oid, 'MEMBER'))
  UNION ALL SELECT 'LOW', 'OWNED_BY_LOGIN_USER', r.rolname, 'owns ' || count(*) || ' object(s), e.g. ' || string_agg(o.schema || '.' || o.name, ', ' ORDER BY o.schema, o.name)
  FROM obj o JOIN rl r ON r.oid = o.owner WHERE r.rolcanlogin AND NOT r.sys GROUP BY r.rolname
  UNION ALL SELECT 'LOW', 'SCHEMA_OWNED_BY_LOGIN_USER', n.nspname, 'schema owned by login user ' || r.rolname
  FROM ns n JOIN rl r ON r.oid = n.nspowner WHERE r.rolcanlogin AND NOT r.sys
  UNION ALL SELECT 'LOW', 'UNUSED_GROUP_ROLE', r.rolname, 'NOLOGIN role with no members'
  FROM rl r WHERE NOT r.rolcanlogin AND NOT r.sys AND NOT EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = r.oid)
  UNION ALL SELECT 'LOW', 'PASSWORD_NO_EXPIRY', r.rolname, 'login role without VALID UNTIL (fine for IAM-only users)'
  FROM rl r WHERE r.rolcanlogin AND NOT r.sys AND (r.rolvaliduntil IS NULL OR r.rolvaliduntil = 'infinity')
  UNION ALL SELECT 'LOW', 'PUBLIC_EXECUTE', o.schema || '.' || o.name, 'explicit EXECUTE grant to PUBLIC'
  FROM obj o, aclexplode(o.acl) a WHERE NOT o.acl_default AND NOT o.secdef AND a.grantee = 0 AND o.type IN ('function', 'procedure', 'aggregate'))
SELECT severity, flag, object, left(detail, 160) AS detail FROM flags
ORDER BY CASE severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END, flag, object;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 2. DATABASE: owner and ACL ================================================'
SELECT d.datname AS database, pg_get_userbyid(d.datdba) AS owner, d.datconnlimit AS conn_limit,
       CASE WHEN d.datacl IS NULL THEN 'default' ELSE 'explicit' END AS acl,
       :G AS grantee, :PRIVS AS privileges, string_agg(DISTINCT pg_get_userbyid(a.grantor), ',') AS grantor
FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
WHERE d.datname = current_database() AND (:'show_all'::boolean OR a.grantee <> d.datdba)
GROUP BY d.datname, d.datdba, d.datconnlimit, (d.datacl IS NULL), a.grantee ORDER BY 5;

\echo
\echo '--- other databases on this server (CONNECT for PUBLIC?) ---'
SELECT d.datname AS database, pg_get_userbyid(d.datdba) AS owner,
       has_database_privilege('public', d.datname, 'CONNECT') AS public_connect,
       array_to_string(d.datacl, ' ') AS raw_acl
FROM pg_database d WHERE NOT d.datistemplate AND d.datname NOT IN ('rdsadmin') ORDER BY 1;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 3. SCHEMAS: owner and USAGE / CREATE ======================================'
SELECT n.nspname AS schema, pg_get_userbyid(n.nspowner) AS owner,
       CASE WHEN n.nspacl IS NULL THEN 'default' ELSE 'explicit' END AS acl,
       :G AS grantee, :PRIVS AS privileges, string_agg(DISTINCT pg_get_userbyid(a.grantor), ',') AS grantor
FROM pg_namespace n LEFT JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
     ON (:'show_all'::boolean OR a.grantee <> n.nspowner)
WHERE NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
GROUP BY n.nspname, n.nspowner, (n.nspacl IS NULL), a.grantee ORDER BY 1, 4 NULLS FIRST;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 4. OBJECT GRANTS (tables, views, matviews, sequences, foreign tables, functions, procedures) ==='
\echo '    (objects with no non-owner grants are listed once with an empty grantee)'
WITH ext AS (SELECT classid, objid FROM pg_depend WHERE deptype = 'e'),
obj AS (
  SELECT n.nspname AS schema, c.relname::text AS name,
         CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview'
                        WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'foreign table' END AS type,
         c.relowner AS owner, c.relacl IS NULL AS acl_default, false AS secdef,
         coalesce(c.relacl, acldefault(CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END::"char", c.relowner)) AS acl,
         EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_class'::regclass AND ext.objid = c.oid) AS is_ext
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f') AND NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
  UNION ALL
  SELECT n.nspname, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'a' THEN 'aggregate' WHEN 'w' THEN 'window function' ELSE 'function' END,
         p.proowner, p.proacl IS NULL, p.prosecdef, coalesce(p.proacl, acldefault('f', p.proowner)),
         EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_proc'::regclass AND ext.objid = p.oid)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like'))
SELECT o.schema, o.type, o.name AS object, pg_get_userbyid(o.owner) AS owner,
       concat_ws(' ', CASE WHEN o.secdef THEN 'SECURITY DEFINER' END, CASE WHEN o.acl_default THEN 'default-acl' END) AS notes,
       :G AS grantee, :PRIVS AS privileges
FROM obj o LEFT JOIN LATERAL aclexplode(o.acl) a ON (:'show_all'::boolean OR a.grantee <> o.owner)
WHERE :'show_all'::boolean OR NOT o.is_ext
GROUP BY o.schema, o.type, o.name, o.owner, o.secdef, o.acl_default, a.grantee
ORDER BY 1, 2, 3, 6 NULLS FIRST;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 5. COLUMN-LEVEL GRANTS ===================================================='
SELECT n.nspname AS schema, c.relname AS "table", at.attname AS "column", :G AS grantee, :PRIVS AS privileges,
       string_agg(DISTINCT pg_get_userbyid(a.grantor), ',') AS grantor
FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace,
     aclexplode(at.attacl) a
WHERE at.attacl IS NOT NULL AND at.attnum > 0 AND NOT at.attisdropped
  AND NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
GROUP BY n.nspname, c.relname, at.attnum, at.attname, a.grantee ORDER BY 1, 2, at.attnum, 4;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 6. DEFAULT PRIVILEGES (ALTER DEFAULT PRIVILEGES - applies to FUTURE objects) ==='
\echo '    for_role = role whose newly created objects get these grants; schema * = all schemas'
SELECT pg_get_userbyid(d.defaclrole) AS for_role, coalesce(n.nspname, '*') AS schema,
       CASE d.defaclobjtype WHEN 'r' THEN 'tables' WHEN 'S' THEN 'sequences' WHEN 'f' THEN 'functions'
                            WHEN 'T' THEN 'types' WHEN 'n' THEN 'schemas' ELSE d.defaclobjtype::text END AS object_type,
       :G AS grantee, :PRIVS AS privileges
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace, aclexplode(d.defaclacl) a
WHERE n.nspname IS NULL OR :'schema_like' = '' OR n.nspname LIKE :'schema_like'
GROUP BY d.defaclrole, n.nspname, d.defaclobjtype, a.grantee ORDER BY 1, 2, 3, 4;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 7. FOREIGN SERVERS and USER MAPPINGS (user names only, options never shown) ==='
SELECT s.srvname AS foreign_server, w.fdwname AS fdw, pg_get_userbyid(s.srvowner) AS owner,
       (SELECT string_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END || '=' || a.privilege_type
                          || CASE WHEN a.is_grantable THEN '*' ELSE '' END, ', ')
        FROM aclexplode(coalesce(s.srvacl, acldefault('S', s.srvowner))) a WHERE a.grantee <> s.srvowner) AS usage_grants,
       (SELECT string_agg(CASE WHEN um.umuser = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(um.umuser) END, ', ' ORDER BY 1)
        FROM pg_user_mappings um WHERE um.srvid = s.oid) AS user_mappings
FROM pg_foreign_server s JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw ORDER BY 1;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 8. ROLES and attributes (non-system; cluster-wide) ========================'
SELECT r.rolname AS role, r.rolcanlogin AS login,
       EXISTS (SELECT 1 FROM pg_roles s WHERE s.rolname = 'rds_superuser' AND s.oid <> r.oid AND pg_has_role(r.oid, s.oid, 'MEMBER')) AS rds_superuser,
       r.rolsuper AS superuser, r.rolcreaterole AS createrole, r.rolcreatedb AS createdb, r.rolinherit AS inherit,
       r.rolbypassrls AS bypassrls, r.rolconnlimit AS conn_limit,
       CASE WHEN r.rolvaliduntil IS NULL THEN 'never' WHEN r.rolvaliduntil < now() THEN 'EXPIRED ' || r.rolvaliduntil::date
            ELSE r.rolvaliduntil::date::text END AS valid_until,
       (SELECT string_agg(DISTINCT g.rolname, ',') FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid WHERE m.member = r.oid) AS member_of,
       (SELECT string_agg(DISTINCT u.rolname, ',') FROM pg_auth_members m JOIN pg_roles u ON u.oid = m.member WHERE m.roleid = r.oid) AS members
FROM pg_roles r
WHERE NOT (r.oid < 16384 OR r.rolname ~ '^(pg_|rds_|rdsadmin$|rdsrepladmin$|rdstopmgr$|rdsproxyadmin$)')
ORDER BY 1;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 9. MEMBERSHIP CHAINS (recursive; inherited = privileges flow automatically) ==='
WITH RECURSIVE ch(member, roleid, path) AS (
  SELECT m.member, m.roleid, ARRAY[m.member, m.roleid]::oid[] FROM pg_auth_members m
  UNION
  SELECT ch.member, m.roleid, ch.path || m.roleid FROM ch JOIN pg_auth_members m ON m.member = ch.roleid
  WHERE NOT m.roleid = ANY (ch.path) AND cardinality(ch.path) < 20)
SELECT pg_get_userbyid(ch.member) AS role, pg_get_userbyid(ch.roleid) AS reaches, cardinality(ch.path) - 1 AS depth,
       CASE WHEN pg_has_role(ch.member, ch.roleid, 'USAGE') THEN 'inherited' ELSE 'SET ROLE only' END AS how,
       (SELECT string_agg(pg_get_userbyid(x), ' -> ' ORDER BY i) FROM unnest(ch.path) WITH ORDINALITY u(x, i)) AS path
FROM ch
WHERE pg_get_userbyid(ch.member) !~ '^(pg_|rds_|rdsadmin$)' OR :'show_all'::boolean
ORDER BY 1, 3, 5;

-- ---------------------------------------------------------------------------------------------
\echo
\echo '=== 10. OBJECTS / SCHEMAS OWNED BY LOGIN USERS (prefer NOLOGIN owner roles) ===='
SELECT r.rolname AS owner, x.kind, x.schema, x.object
FROM (SELECT c.relowner AS owner, CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view'
                    WHEN 'm' THEN 'matview' WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'foreign table' END AS kind,
             n.nspname AS schema, c.relname::text AS object
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f') AND NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
      UNION ALL
      SELECT p.proowner, CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END, n.nspname,
             p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
      UNION ALL
      SELECT n.nspowner, 'schema', n.nspname, n.nspname FROM pg_namespace n
      WHERE NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')) x
JOIN pg_roles r ON r.oid = x.owner
WHERE r.rolcanlogin AND NOT (r.oid < 16384 OR r.rolname ~ '^(pg_|rds_|rdsadmin$)')
ORDER BY 1, 2, 3, 4;

-- ---------------------------------------------------------------------------------------------
\if :role_given
\echo
\echo '=== 11. EFFECTIVE ACCESS for role' :'role' '(direct + inherited group roles + PUBLIC) ==='
\if :role_exists
SELECT :'role' AS role,
       (SELECT string_agg(g.rolname, ', ' ORDER BY g.rolname) FROM pg_roles g, pg_roles r
        WHERE r.rolname = :'role' AND g.oid <> r.oid AND pg_has_role(r.oid, g.oid, 'USAGE')) AS inherits_from,
       (SELECT string_agg(g.rolname, ', ' ORDER BY g.rolname) FROM pg_roles g, pg_roles r
        WHERE r.rolname = :'role' AND g.oid <> r.oid AND pg_has_role(r.oid, g.oid, 'MEMBER') AND NOT pg_has_role(r.oid, g.oid, 'USAGE')) AS set_role_only,
       (SELECT rolsuper FROM pg_roles WHERE rolname = :'role') AS superuser;
WITH me AS (SELECT oid FROM pg_roles WHERE rolname = :'role'),
via AS (SELECT 0::oid AS oid, 'PUBLIC'::text AS name
        UNION ALL SELECT g.oid, g.rolname::text FROM pg_roles g, me WHERE pg_has_role(me.oid, g.oid, 'USAGE')),
ext AS (SELECT classid, objid FROM pg_depend WHERE deptype = 'e'),
acc AS (
  SELECT 1 AS ord, 'database' AS level, current_database()::text AS object, NULL::oid AS owner, a.grantee, a.privilege_type, a.is_grantable
  FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname = current_database()
  UNION ALL
  SELECT 2, 'schema', n.nspname, n.nspowner, a.grantee, a.privilege_type, a.is_grantable
  FROM pg_namespace n, aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
  WHERE NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
  UNION ALL
  SELECT 3, CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview'
                           WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'foreign table' END,
         n.nspname || '.' || c.relname, c.relowner, a.grantee, a.privilege_type, a.is_grantable
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
       aclexplode(coalesce(c.relacl, acldefault(CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END::"char", c.relowner))) a
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f') AND NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
    AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_class'::regclass AND ext.objid = c.oid)
  UNION ALL
  SELECT 4, CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END,
         n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', p.proowner,
         a.grantee, a.privilege_type, a.is_grantable
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  WHERE NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
    AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_proc'::regclass AND ext.objid = p.oid)
    AND NOT (a.grantee = 0 AND p.proacl IS NULL)          -- skip PostgreSQL's built-in EXECUTE-to-PUBLIC noise
  UNION ALL
  SELECT 5, 'column', n.nspname || '.' || c.relname || '.' || at.attname, c.relowner, a.grantee, a.privilege_type, a.is_grantable
  FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(at.attacl) a
  WHERE at.attacl IS NOT NULL AND at.attnum > 0 AND NOT at.attisdropped AND NOT :SYS AND (:'schema_like' = '' OR n.nspname LIKE :'schema_like')
  UNION ALL
  SELECT 6, 'future ' || CASE d.defaclobjtype WHEN 'r' THEN 'tables' WHEN 'S' THEN 'sequences' WHEN 'f' THEN 'functions'
                                              WHEN 'T' THEN 'types' WHEN 'n' THEN 'schemas' END,
         'created by ' || pg_get_userbyid(d.defaclrole) || ' in ' || coalesce(n.nspname, '*'), NULL, a.grantee, a.privilege_type, a.is_grantable
  FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace, aclexplode(d.defaclacl) a
  UNION ALL
  SELECT 7, 'user mapping', s.srvname, NULL, um.umuser, 'USER MAPPING', false
  FROM pg_user_mappings um JOIN pg_foreign_server s ON s.oid = um.srvid),
per_via AS (
  SELECT acc.ord, acc.level, acc.object, acc.owner, via.name AS via,
         string_agg(acc.privilege_type || CASE WHEN acc.is_grantable THEN '*' ELSE '' END, ',' ORDER BY acc.privilege_type) AS privs
  FROM acc JOIN via ON via.oid = acc.grantee
  GROUP BY acc.ord, acc.level, acc.object, acc.owner, via.name)
SELECT level, object,
       CASE WHEN owner IS NOT NULL AND (owner = (SELECT oid FROM me) OR pg_has_role((SELECT oid FROM me), owner, 'USAGE'))
            THEN 'OWNER (' || pg_get_userbyid(owner) || ')' ELSE '' END AS owned,
       string_agg(privs || ' via ' || via, '; ' ORDER BY via) AS privileges
FROM per_via
GROUP BY ord, level, object, owner
ORDER BY ord, object, level;
\else
\echo '    role' :'role' 'does not exist on this server'
\endif
\endif

COMMIT;
\echo
\echo '=== end of audit (read-only; nothing was changed) ==='
