-- =============================================================================
-- pg_session_history : functions.sql   (run after schema.sql, same owner role)
--   monitoring.create_partitions(days_ahead, from_day)  -> partitions created
--   monitoring.collect_sessions(...)                    -> rows inserted
--   monitoring.purge_sessions(retention, dry_run)       -> what was removed
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Daily partitions (UTC days). Idempotent and safe to call concurrently.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION monitoring.create_partitions(
    p_days_ahead integer DEFAULT 7,
    p_from_day   date    DEFAULT (now() AT TIME ZONE 'UTC')::date
) RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    d       date;
    v_name  text;
    v_count integer := 0;
BEGIN
    IF p_days_ahead < 0 THEN
        RAISE EXCEPTION 'p_days_ahead must be >= 0';
    END IF;
    FOR d IN SELECT generate_series(p_from_day, p_from_day + p_days_ahead, interval '1 day')::date LOOP
        v_name := 'session_history_p' || to_char(d, 'YYYYMMDD');
        CONTINUE WHEN to_regclass('monitoring.' || v_name) IS NOT NULL;
        -- serialise concurrent creators, then re-check
        PERFORM pg_advisory_xact_lock(hashtext('monitoring.create_partitions'));
        CONTINUE WHEN to_regclass('monitoring.' || v_name) IS NOT NULL;
        EXECUTE format(
            'CREATE TABLE monitoring.%I PARTITION OF monitoring.session_history FOR VALUES FROM (%L) TO (%L)',
            v_name,
            (d::timestamp AT TIME ZONE 'UTC'),
            ((d + 1)::timestamp AT TIME ZONE 'UTC'));
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$fn$;

COMMENT ON FUNCTION monitoring.create_partitions(integer, date) IS
    'Create the daily (UTC) partitions of monitoring.session_history from p_from_day to p_from_day + p_days_ahead if missing; returns how many were created';

-- -----------------------------------------------------------------------------
-- Take one snapshot of pg_stat_activity
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION monitoring.collect_sessions(
    p_server_id             text      DEFAULT NULL,   -- NULL: cluster_name, else server addr:port
    p_include_idle          boolean   DEFAULT true,   -- false: skip state = 'idle'
    p_min_duration          interval  DEFAULT NULL,   -- keep active / idle-in-xact rows only if running at least this long
    p_exclude_backend_types text[]    DEFAULT '{}',   -- e.g. '{walwriter,checkpointer,background writer}'
    p_max_query_length      integer   DEFAULT NULL    -- truncate stored query text (NULL: keep as is)
) RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_ts      timestamptz := clock_timestamp();   -- captured ONCE: same value for every row
    v_id      bigint;
    v_server  text;
    v_rows    integer;
    v_total   integer;
    v_client  integer;
    v_excl    text[] := coalesce(p_exclude_backend_types, '{}');
BEGIN
    v_server := coalesce(nullif(p_server_id, ''),
                         nullif(current_setting('cluster_name'), ''),
                         coalesce(host(inet_server_addr()), 'local') || ':' || current_setting('port'));

    -- make sure today's (and tomorrow's) partition exists; never fail the snapshot for it
    BEGIN
        PERFORM monitoring.create_partitions(1, (v_ts AT TIME ZONE 'UTC')::date);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'collect_sessions: could not create partition (%), rows outside existing partitions go to the default partition', SQLERRM;
    END;

    v_id := nextval('monitoring.session_snapshot_id_seq');

    -- pg_stat_activity is read once per transaction, so totals and rows are consistent
    SELECT count(*), count(*) FILTER (WHERE backend_type = 'client backend')
      INTO v_total, v_client
      FROM pg_stat_activity;

    WITH a AS (
        SELECT s.*,
               CASE WHEN s.wait_event_type = 'Lock' THEN pg_blocking_pids(s.pid) END AS bpids
          FROM pg_stat_activity s
         WHERE s.pid <> pg_backend_pid()
    ), blockers AS (
        SELECT DISTINCT unnest(bpids) AS pid FROM a WHERE bpids IS NOT NULL
    ), ins AS (
        INSERT INTO monitoring.session_history (
            collected_at, snapshot_id, server_id, datname, pid, leader_pid, usename,
            application_name, client_addr, client_hostname, client_port, backend_type,
            backend_start, xact_start, query_start, state_change, state,
            wait_event_type, wait_event, backend_xid, backend_xmin, query_id, query,
            query_duration, xact_duration, state_duration, backend_age, blocking_pids)
        SELECT v_ts, v_id, v_server, a.datname, a.pid, a.leader_pid, a.usename,
               a.application_name, a.client_addr, a.client_hostname, a.client_port, a.backend_type,
               a.backend_start, a.xact_start, a.query_start, a.state_change, a.state,
               a.wait_event_type, a.wait_event, a.backend_xid, a.backend_xmin, a.query_id,
               CASE WHEN p_max_query_length IS NULL THEN a.query ELSE left(a.query, p_max_query_length) END,
               v_ts - a.query_start, v_ts - a.xact_start, v_ts - a.state_change, v_ts - a.backend_start,
               a.bpids
          FROM a
         WHERE (p_include_idle OR a.state IS DISTINCT FROM 'idle')
           AND NOT (a.backend_type = ANY (v_excl))
           AND (p_min_duration IS NULL
                OR a.state IS NULL                         -- background processes
                OR a.state = 'idle'                        -- governed by p_include_idle
                OR a.bpids IS NOT NULL                     -- always keep lock waiters ...
                OR a.pid IN (SELECT pid FROM blockers)     -- ... and their blockers
                OR greatest(v_ts - a.xact_start,
                            CASE WHEN a.state = 'active' THEN v_ts - a.query_start END) >= p_min_duration)
        RETURNING 1
    )
    SELECT count(*) INTO v_rows FROM ins;

    INSERT INTO monitoring.session_snapshots
        (snapshot_id, collected_at, server_id, total_backends, client_backends, rows_stored,
         max_connections, filters, collect_ms)
    VALUES
        (v_id, v_ts, v_server, v_total, v_client, v_rows,
         current_setting('max_connections')::integer,
         jsonb_build_object('include_idle', p_include_idle,
                            'min_duration', p_min_duration::text,
                            'exclude_backend_types', to_jsonb(v_excl),
                            'max_query_length', p_max_query_length),
         round((extract(epoch FROM clock_timestamp() - v_ts) * 1000)::numeric, 3));

    RETURN v_rows;
END;
$fn$;

COMMENT ON FUNCTION monitoring.collect_sessions(text, boolean, interval, text[], integer) IS
    'Insert one pg_stat_activity snapshot (excluding the calling backend) into monitoring.session_history; returns rows inserted';

-- -----------------------------------------------------------------------------
-- Retention: drop whole daily partitions older than the cutoff, delete the rest
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION monitoring.purge_sessions(
    p_retention interval,
    p_dry_run   boolean DEFAULT false
) RETURNS TABLE (action text, object text, row_count bigint)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_cutoff timestamptz;
    r        record;
    v_n      bigint;
BEGIN
    IF p_retention IS NULL OR p_retention < interval '1 hour' THEN
        RAISE EXCEPTION 'retention must be at least 1 hour (got %)', p_retention;
    END IF;
    v_cutoff := now() - p_retention;

    FOR r IN
        SELECT c.oid, c.relname,
               (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz AS upper_bound
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE i.inhparent = 'monitoring.session_history'::regclass
           AND pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT'
         ORDER BY 3
    LOOP
        CONTINUE WHEN r.upper_bound > v_cutoff;
        EXECUTE format('SELECT count(*) FROM monitoring.%I', r.relname) INTO v_n;
        IF NOT p_dry_run THEN
            EXECUTE format('DROP TABLE monitoring.%I', r.relname);
        END IF;
        action := CASE WHEN p_dry_run THEN 'would drop partition' ELSE 'dropped partition' END;
        object := 'monitoring.' || r.relname; row_count := v_n;
        RETURN NEXT;
    END LOOP;

    IF p_dry_run THEN
        SELECT count(*) INTO v_n FROM monitoring.session_history_default WHERE collected_at < v_cutoff;
    ELSE
        DELETE FROM monitoring.session_history_default WHERE collected_at < v_cutoff;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    action := CASE WHEN p_dry_run THEN 'would delete rows' ELSE 'deleted rows' END;
    object := 'monitoring.session_history_default'; row_count := v_n;
    RETURN NEXT;

    IF p_dry_run THEN
        SELECT count(*) INTO v_n FROM monitoring.session_snapshots WHERE collected_at < v_cutoff;
    ELSE
        DELETE FROM monitoring.session_snapshots WHERE collected_at < v_cutoff;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    action := CASE WHEN p_dry_run THEN 'would delete rows' ELSE 'deleted rows' END;
    object := 'monitoring.session_snapshots'; row_count := v_n;
    RETURN NEXT;
END;
$fn$;

COMMENT ON FUNCTION monitoring.purge_sessions(interval, boolean) IS
    'Drop daily partitions whose whole range is older than now() - p_retention, delete older rows from the default partition and session_snapshots';
