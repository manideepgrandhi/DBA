-- =============================================================================
-- pg_session_history : schema.sql
-- History of pg_stat_activity snapshots for later analysis.
--
-- Run as the role that should OWN the monitoring objects (ideally a dedicated
-- role such as "session_collector", see README.md), in the database where you
-- want to keep the history:
--     psql -d monitoring_db -v ON_ERROR_STOP=1 -f schema.sql
--     psql -d monitoring_db -v ON_ERROR_STOP=1 -f functions.sql
--
-- pg_stat_activity is cluster-wide: a collector connected to ANY database sees
-- the sessions of ALL databases, so one history database per cluster is enough.
--
-- Design: monitoring.session_history is RANGE-partitioned by collected_at with
-- one partition per UTC day (+ a DEFAULT partition as a safety net). Retention
-- is then a cheap DROP TABLE of old partitions instead of a huge DELETE + VACUUM.
-- monitoring.session_snapshots keeps one row per collection run (when, how many
-- backends in total, max_connections) so counts are correct even when the
-- collector filters out idle sessions. Requires PostgreSQL 14+ (query_id).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS monitoring;
COMMENT ON SCHEMA monitoring IS 'Session history (pg_stat_activity snapshots) and related helpers';

CREATE SEQUENCE IF NOT EXISTS monitoring.session_snapshot_id_seq AS bigint;

-- -----------------------------------------------------------------------------
-- One row per collection run
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS monitoring.session_snapshots (
    snapshot_id        bigint      PRIMARY KEY,
    collected_at       timestamptz NOT NULL,
    server_id          text        NOT NULL,
    total_backends     integer     NOT NULL,
    client_backends    integer     NOT NULL,
    rows_stored        integer     NOT NULL,
    max_connections    integer     NOT NULL,
    filters            jsonb       NOT NULL DEFAULT '{}'::jsonb,
    collect_ms         numeric(10,3)
);
CREATE INDEX IF NOT EXISTS session_snapshots_collected_at_idx ON monitoring.session_snapshots (collected_at);
CREATE INDEX IF NOT EXISTS session_snapshots_server_time_idx  ON monitoring.session_snapshots (server_id, collected_at);

COMMENT ON TABLE  monitoring.session_snapshots IS 'One row per monitoring.collect_sessions() call: snapshot header with unfiltered totals';
COMMENT ON COLUMN monitoring.session_snapshots.snapshot_id     IS 'Snapshot identifier; the same value is stored on every session_history row of the snapshot';
COMMENT ON COLUMN monitoring.session_snapshots.collected_at    IS 'Collection time (clock_timestamp() captured once per snapshot); identical for all rows of the snapshot';
COMMENT ON COLUMN monitoring.session_snapshots.server_id       IS 'Identifier of the monitored server (passed by the collector, e.g. host:port or cluster_name)';
COMMENT ON COLUMN monitoring.session_snapshots.total_backends  IS 'All rows in pg_stat_activity at collection time (all backend types, before filters)';
COMMENT ON COLUMN monitoring.session_snapshots.client_backends IS 'Rows with backend_type = client backend (these count against max_connections), before filters';
COMMENT ON COLUMN monitoring.session_snapshots.rows_stored     IS 'Rows written to session_history for this snapshot (after filters)';
COMMENT ON COLUMN monitoring.session_snapshots.max_connections IS 'Value of max_connections at collection time';
COMMENT ON COLUMN monitoring.session_snapshots.filters         IS 'Filters used by the collector for this snapshot (include_idle, min_duration, excluded backend types, ...)';
COMMENT ON COLUMN monitoring.session_snapshots.collect_ms      IS 'Time the collection took, in milliseconds';

-- -----------------------------------------------------------------------------
-- One row per session per snapshot (partitioned by collected_at, daily, UTC)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS monitoring.session_history (
    collected_at       timestamptz NOT NULL,
    snapshot_id        bigint      NOT NULL,
    server_id          text        NOT NULL,
    datname            name,
    pid                integer     NOT NULL,
    leader_pid         integer,
    usename            name,
    application_name   text,
    client_addr        inet,
    client_hostname    text,
    client_port        integer,
    backend_type       text,
    backend_start      timestamptz,
    xact_start         timestamptz,
    query_start        timestamptz,
    state_change       timestamptz,
    state              text,
    wait_event_type    text,
    wait_event         text,
    backend_xid        xid,
    backend_xmin       xid,
    query_id           bigint,
    query              text,
    query_duration     interval,
    xact_duration      interval,
    state_duration     interval,
    backend_age        interval,
    blocking_pids      integer[]
) PARTITION BY RANGE (collected_at);

CREATE TABLE IF NOT EXISTS monitoring.session_history_default
    PARTITION OF monitoring.session_history DEFAULT;

CREATE INDEX IF NOT EXISTS session_history_collected_at_idx ON monitoring.session_history (collected_at);
CREATE INDEX IF NOT EXISTS session_history_db_time_idx      ON monitoring.session_history (datname, collected_at);
CREATE INDEX IF NOT EXISTS session_history_state_time_idx   ON monitoring.session_history (state, collected_at);
CREATE INDEX IF NOT EXISTS session_history_wait_idx         ON monitoring.session_history (wait_event_type, wait_event, collected_at)
    WHERE wait_event IS NOT NULL;
CREATE INDEX IF NOT EXISTS session_history_query_id_idx     ON monitoring.session_history (query_id, collected_at)
    WHERE query_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS session_history_pid_time_idx     ON monitoring.session_history (pid, collected_at);
CREATE INDEX IF NOT EXISTS session_history_snapshot_idx     ON monitoring.session_history (snapshot_id);

COMMENT ON TABLE  monitoring.session_history IS 'pg_stat_activity snapshots, one row per backend per snapshot; RANGE partitioned by collected_at (one partition per UTC day)';
COMMENT ON COLUMN monitoring.session_history.collected_at     IS 'Collection time; identical for all rows of one snapshot (join to session_snapshots on snapshot_id)';
COMMENT ON COLUMN monitoring.session_history.snapshot_id      IS 'Snapshot identifier (monitoring.session_snapshots.snapshot_id)';
COMMENT ON COLUMN monitoring.session_history.server_id        IS 'Identifier of the monitored server';
COMMENT ON COLUMN monitoring.session_history.datname          IS 'Database the backend is connected to (NULL for background processes)';
COMMENT ON COLUMN monitoring.session_history.pid              IS 'Process ID of the backend (pids are reused over time: combine with backend_start to identify a session)';
COMMENT ON COLUMN monitoring.session_history.leader_pid       IS 'For parallel workers: pid of the leader backend; NULL otherwise';
COMMENT ON COLUMN monitoring.session_history.usename          IS 'Login role of the session';
COMMENT ON COLUMN monitoring.session_history.application_name IS 'application_name set by the client';
COMMENT ON COLUMN monitoring.session_history.client_addr      IS 'Client IP address; NULL for Unix-socket connections and background processes';
COMMENT ON COLUMN monitoring.session_history.client_hostname  IS 'Client host name (only when log_hostname = on)';
COMMENT ON COLUMN monitoring.session_history.client_port      IS 'Client TCP port; -1 for Unix sockets; NULL for background processes';
COMMENT ON COLUMN monitoring.session_history.backend_type     IS 'client backend, autovacuum worker, walsender, parallel worker, background worker, ...';
COMMENT ON COLUMN monitoring.session_history.backend_start    IS 'When the backend process (connection) started';
COMMENT ON COLUMN monitoring.session_history.xact_start       IS 'Start of the current transaction; NULL if no transaction is open';
COMMENT ON COLUMN monitoring.session_history.query_start      IS 'Start of the current query, or of the last query if the session is idle';
COMMENT ON COLUMN monitoring.session_history.state_change     IS 'When state last changed';
COMMENT ON COLUMN monitoring.session_history.state            IS 'active, idle, idle in transaction, idle in transaction (aborted), fastpath function call, disabled';
COMMENT ON COLUMN monitoring.session_history.wait_event_type  IS 'Class of event the backend waits for (Lock, LWLock, IO, Client, IPC, Timeout, Activity, ...); NULL if not waiting';
COMMENT ON COLUMN monitoring.session_history.wait_event       IS 'Name of the wait event (e.g. transactionid, relation, ClientRead, DataFileRead)';
COMMENT ON COLUMN monitoring.session_history.backend_xid      IS 'Top-level transaction id, if the session has written something';
COMMENT ON COLUMN monitoring.session_history.backend_xmin     IS 'xmin horizon of the backend (old values hold back VACUUM)';
COMMENT ON COLUMN monitoring.session_history.query_id         IS 'Query identifier (PG14+); NULL unless compute_query_id is on/auto with pg_stat_statements loaded';
COMMENT ON COLUMN monitoring.session_history.query            IS 'Text of the current/last query (truncated at track_activity_query_size and optionally by the collector)';
COMMENT ON COLUMN monitoring.session_history.query_duration   IS 'collected_at - query_start: runtime of the current query (meaningful when state = active)';
COMMENT ON COLUMN monitoring.session_history.xact_duration    IS 'collected_at - xact_start: age of the open transaction';
COMMENT ON COLUMN monitoring.session_history.state_duration   IS 'collected_at - state_change: how long the session has been in its current state';
COMMENT ON COLUMN monitoring.session_history.backend_age      IS 'collected_at - backend_start: age of the connection';
COMMENT ON COLUMN monitoring.session_history.blocking_pids    IS 'pg_blocking_pids(pid) for sessions waiting on a heavyweight lock (wait_event_type = Lock); NULL otherwise';
