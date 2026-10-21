-- Read-only catalog query for pg_permissions_audit.sh. Returns ONE json document for the current database.
-- Uses only pg_catalog views/functions readable by any role (no pg_authid, no option values of user mappings).
-- psql variable :incsys = on|off  (include pg_catalog / information_schema / pg_toast / temp schemas)
WITH ns AS (
  SELECT n.oid, n.nspname, n.nspowner, n.nspacl FROM pg_namespace n
  WHERE :'incsys' = 'on'
     OR NOT (n.nspname IN ('pg_catalog', 'information_schema') OR n.nspname LIKE 'pg\_toast%' OR n.nspname LIKE 'pg\_temp\_%')
),
ext AS (SELECT classid, objid FROM pg_depend WHERE deptype = 'e'),
rel AS (
  SELECT n.nspname AS schema, c.relname AS name,
         CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'matview'
                        WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'foreign table' END AS type,
         pg_get_userbyid(c.relowner) AS owner, c.relacl IS NULL AS acl_default, false AS secdef,
         EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_class'::regclass AND ext.objid = c.oid) AS ext,
         c.relispartition AS partition,
         coalesce(c.relacl, acldefault(CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END::"char", c.relowner)) AS acl
  FROM pg_class c JOIN ns n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  UNION ALL
  SELECT n.nspname, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'a' THEN 'aggregate' WHEN 'w' THEN 'window function' ELSE 'function' END,
         pg_get_userbyid(p.proowner), p.proacl IS NULL, p.prosecdef,
         EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_proc'::regclass AND ext.objid = p.oid), false,
         coalesce(p.proacl, acldefault('f', p.proowner))
  FROM pg_proc p JOIN ns n ON n.oid = p.pronamespace
)
SELECT json_build_object(
  'server_version', current_setting('server_version'),
  'server_version_num', current_setting('server_version_num')::int,
  'connected_as', current_user,
  'database', (
    SELECT json_build_object('name', d.datname, 'owner', pg_get_userbyid(d.datdba), 'conn_limit', d.datconnlimit,
             'allow_conn', d.datallowconn, 'acl_default', d.datacl IS NULL,
             'grants', (SELECT coalesce(json_agg(json_build_object(
                           'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
                           'grantor', pg_get_userbyid(a.grantor), 'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]')
                        FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a))
    FROM pg_database d WHERE d.datname = current_database()),
  'schemas', (
    SELECT coalesce(json_agg(json_build_object('name', n.nspname, 'owner', pg_get_userbyid(n.nspowner),
             'acl_default', n.nspacl IS NULL,
             'ext', EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_namespace'::regclass AND ext.objid = n.oid),
             'grants', (SELECT coalesce(json_agg(json_build_object(
                           'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
                           'grantor', pg_get_userbyid(a.grantor), 'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]')
                        FROM aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a))
           ORDER BY n.nspname), '[]')
    FROM ns n),
  'objects', (
    SELECT coalesce(json_agg(json_build_object('schema', r.schema, 'name', r.name, 'type', r.type, 'owner', r.owner,
             'acl_default', r.acl_default, 'secdef', r.secdef, 'ext', r.ext, 'partition', r.partition,
             'grants', (SELECT coalesce(json_agg(json_build_object(
                           'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
                           'grantor', pg_get_userbyid(a.grantor), 'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]')
                        FROM aclexplode(r.acl) a))
           ORDER BY r.schema, r.type, r.name), '[]')
    FROM rel r),
  'column_grants', (
    SELECT coalesce(json_agg(json_build_object('schema', n.nspname, 'table', c.relname, 'column', at.attname,
             'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
             'grantor', pg_get_userbyid(a.grantor), 'priv', a.privilege_type, 'grantable', a.is_grantable)
           ORDER BY n.nspname, c.relname, at.attnum), '[]')
    FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid JOIN ns n ON n.oid = c.relnamespace
         CROSS JOIN LATERAL aclexplode(at.attacl) a
    WHERE at.attacl IS NOT NULL AND at.attnum > 0 AND NOT at.attisdropped),
  'default_privileges', (
    SELECT coalesce(json_agg(json_build_object('for_role', pg_get_userbyid(d.defaclrole),
             'schema', coalesce(n.nspname, '*'),
             'objtype', CASE d.defaclobjtype WHEN 'r' THEN 'tables' WHEN 'S' THEN 'sequences' WHEN 'f' THEN 'functions'
                                             WHEN 'T' THEN 'types' WHEN 'n' THEN 'schemas' ELSE d.defaclobjtype::text END,
             'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
             'priv', a.privilege_type, 'grantable', a.is_grantable)
           ORDER BY pg_get_userbyid(d.defaclrole), n.nspname, d.defaclobjtype), '[]')
    FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
         CROSS JOIN LATERAL aclexplode(d.defaclacl) a),
  'fdw_servers', (
    SELECT coalesce(json_agg(json_build_object('name', s.srvname, 'fdw', w.fdwname, 'owner', pg_get_userbyid(s.srvowner),
             'grants', (SELECT coalesce(json_agg(json_build_object(
                           'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
                           'grantor', pg_get_userbyid(a.grantor), 'priv', a.privilege_type, 'grantable', a.is_grantable)), '[]')
                        FROM aclexplode(coalesce(s.srvacl, acldefault('S', s.srvowner))) a),
             'user_mappings', (SELECT coalesce(json_agg(CASE WHEN um.umuser = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(um.umuser) END
                                                       ORDER BY 1), '[]')
                               FROM pg_user_mappings um WHERE um.srvid = s.oid))
           ORDER BY s.srvname), '[]')
    FROM pg_foreign_server s JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw),
  'roles', (
    SELECT coalesce(json_agg(json_build_object('name', r.rolname, 'login', r.rolcanlogin, 'superuser', r.rolsuper,
             'createrole', r.rolcreaterole, 'createdb', r.rolcreatedb, 'replication', r.rolreplication,
             'bypassrls', r.rolbypassrls, 'inherit', r.rolinherit, 'conn_limit', r.rolconnlimit,
             'valid_until', r.rolvaliduntil,
             'valid_until_past', coalesce(r.rolvaliduntil < now(), false),
             'system', r.oid < 16384 OR r.rolname ~ '^(pg_|rds_|rdsadmin$|rdsrepladmin$|rdstopmgr$|rdsproxyadmin$)',
             'rds_superuser', EXISTS (SELECT 1 FROM pg_roles s WHERE s.rolname = 'rds_superuser' AND s.oid <> r.oid
                                      AND pg_has_role(r.oid, s.oid, 'MEMBER')),
             'member_of', (SELECT coalesce(json_agg(DISTINCT g.rolname), '[]') FROM pg_auth_members m
                           JOIN pg_roles g ON g.oid = m.roleid WHERE m.member = r.oid),
             'members', (SELECT coalesce(json_agg(DISTINCT u.rolname), '[]') FROM pg_auth_members m
                         JOIN pg_roles u ON u.oid = m.member WHERE m.roleid = r.oid),
             'effective', (SELECT coalesce(json_agg(g.rolname ORDER BY g.rolname), '[]') FROM pg_roles g
                           WHERE g.oid <> r.oid AND NOT r.rolsuper AND pg_has_role(r.oid, g.oid, 'USAGE')),
             'can_set', (SELECT coalesce(json_agg(g.rolname ORDER BY g.rolname), '[]') FROM pg_roles g
                         WHERE g.oid <> r.oid AND NOT r.rolsuper AND pg_has_role(r.oid, g.oid, 'MEMBER')
                           AND NOT pg_has_role(r.oid, g.oid, 'USAGE')))
           ORDER BY r.rolname), '[]')
    FROM pg_roles r),
  'chains', (
    WITH RECURSIVE ch(member, roleid, path) AS (
      SELECT m.member, m.roleid, ARRAY[m.member, m.roleid]::oid[] FROM pg_auth_members m
      UNION
      SELECT ch.member, m.roleid, ch.path || m.roleid FROM ch JOIN pg_auth_members m ON m.member = ch.roleid
      WHERE NOT m.roleid = ANY (ch.path) AND cardinality(ch.path) < 20)
    SELECT coalesce(json_agg(json_build_object('role', pg_get_userbyid(ch.member), 'reaches', pg_get_userbyid(ch.roleid),
             'depth', cardinality(ch.path) - 1,
             'path', (SELECT string_agg(pg_get_userbyid(x), ' -> ' ORDER BY i) FROM unnest(ch.path) WITH ORDINALITY u(x, i)))
           ORDER BY pg_get_userbyid(ch.member), cardinality(ch.path)), '[]')
    FROM ch)
);
