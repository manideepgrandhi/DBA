-- =============================================================================
-- pg_session_history : analysis_queries.sql
--
-- Run the whole file (every query prints a heading):
--     psql -d monitoring_db -f analysis_queries.sql
-- or set the window / parameters:
--     psql -d monitoring_db -v from='2026-10-10 09:00+05:30' -v to='2026-10-10 18:00+05:30' \
--          -v bucket='15 minutes' -v min_dur='30 seconds' -v pid=12345 \
--          -v at='2026-10-10 11:42+05:30' -f analysis_queries.sql
-- To run a single query, copy it and replace :'from', :'to', ... with literals.
--
-- Notes
--  * One snapshot = all rows with the same snapshot_id / collected_at.
--  * A session is identified by (pid, backend_start): pids get reused.
--  * Durations are as seen at collection time, so they are lower bounds: a query
--    that ran 61 s with 60 s snapshots may be seen once, at e.g. 35 s.
--  * Counts per snapshot come from session_snapshots (unfiltered), counts by
--    attribute come from session_history (affected by the collector filters).
-- =============================================================================

\set QUIET on
\pset footer off
\if :{?from}
\else
    SELECT (now() - interval '24 hours')::text AS from \gset
\endif
\if :{?to}      \else \set to infinity          \endif
\if :{?bucket}  \else \set bucket '5 minutes'   \endif
\if :{?min_dur} \else \set min_dur '1 minute'   \endif
\if :{?top}     \else \set top 20               \endif
\if :{?pid}
\else
    -- default pid: the longest-running active client session of the latest snapshot
    SELECT coalesce((SELECT pid FROM monitoring.session_history
                      WHERE state = 'active' AND backend_type = 'client backend'
                      ORDER BY collected_at DESC, query_duration DESC NULLS LAST LIMIT 1), 0) AS pid \gset
\endif
\if :{?at}
\else
    SELECT coalesce(max(collected_at), now())::text AS at FROM monitoring.session_snapshots \gset
\endif
\echo 'window:' :from '..' :to '  bucket:' :bucket '  min_dur:' :min_dur '  pid:' :pid '  at:' :at

-- -----------------------------------------------------------------------------
\echo '\n== 1. Sessions over time by state (client backends; max per bucket) =='
-- Count per snapshot, then the peak of each bucket, one column per state.
WITH per_snap AS (
    SELECT collected_at,
           count(*) FILTER (WHERE state = 'active')                        AS active,
           count(*) FILTER (WHERE state = 'idle')                          AS idle,
           count(*) FILTER (WHERE state LIKE 'idle in transaction%')       AS idle_in_xact,
           count(*) FILTER (WHERE wait_event_type = 'Lock')                AS waiting_on_lock,
           count(*)                                                        AS total
      FROM monitoring.session_history
     WHERE collected_at >= :'from' AND collected_at < :'to'
       AND backend_type = 'client backend'
     GROUP BY collected_at
)
SELECT date_bin(:'bucket'::interval, collected_at, timestamptz '2000-01-01') AS bucket,
       max(active) AS active, max(idle) AS idle, max(idle_in_xact) AS idle_in_xact,
       max(waiting_on_lock) AS lock_waits, max(total) AS total, count(*) AS snapshots
  FROM per_snap
 GROUP BY 1 ORDER BY 1;

-- -----------------------------------------------------------------------------
\echo '\n== 2a. Sessions per database over time (max per bucket) =='
WITH per_snap AS (
    SELECT collected_at, datname, count(*) AS sessions,
           count(*) FILTER (WHERE state = 'active') AS active
      FROM monitoring.session_history
     WHERE collected_at >= :'from' AND collected_at < :'to'
       AND backend_type = 'client backend'
     GROUP BY collected_at, datname
)
SELECT date_bin(:'bucket'::interval, collected_at, timestamptz '2000-01-01') AS bucket,
       datname, max(sessions) AS max_sessions, max(active) AS max_active
  FROM per_snap GROUP BY 1, 2 ORDER BY 1, 3 DESC;

\echo '\n== 2b. Sessions per user / application in the window =='
-- avg/max concurrent sessions and distinct sessions seen per (user, application)
WITH per_snap AS (
    SELECT collected_at, usename, application_name, count(*) AS sessions
      FROM monitoring.session_history
     WHERE collected_at >= :'from' AND collected_at < :'to'
       AND backend_type = 'client backend'
     GROUP BY 1, 2, 3
), distinct_sessions AS (
    SELECT usename, application_name, count(DISTINCT (pid, backend_start)) AS distinct_sessions
      FROM monitoring.session_history
     WHERE collected_at >= :'from' AND collected_at < :'to'
       AND backend_type = 'client backend'
     GROUP BY 1, 2
)
SELECT p.usename, p.application_name,
       round(avg(p.sessions), 1) AS avg_concurrent, max(p.sessions) AS max_concurrent,
       d.distinct_sessions
  FROM per_snap p JOIN distinct_sessions d USING (usename, application_name)
 GROUP BY p.usename, p.application_name, d.distinct_sessions
 ORDER BY max_concurrent DESC, avg_concurrent DESC
 LIMIT :top;

-- -----------------------------------------------------------------------------
\echo '\n== 3. Peak connection counts and when they happened =='
-- From session_snapshots, i.e. independent of the collector filters.
SELECT collected_at, server_id, client_backends, total_backends, max_connections,
       round(100.0 * client_backends / max_connections, 1) AS pct_of_max
  FROM monitoring.session_snapshots
 WHERE collected_at >= :'from' AND collected_at < :'to'
 ORDER BY client_backends DESC, collected_at DESC
 LIMIT :top;

\echo '\n== 3b. Daily peak per server =='
SELECT DISTINCT ON (server_id, day)
       server_id, collected_at::date AS day, client_backends AS peak_clients, collected_at AS peak_at,
       max_connections
  FROM (SELECT *, collected_at::date AS day FROM monitoring.session_snapshots
         WHERE collected_at >= :'from' AND collected_at < :'to') s
 ORDER BY server_id, day, client_backends DESC, collected_at;

-- -----------------------------------------------------------------------------
\echo '\n== 4. Long-running queries in the window (active >= min_dur) =='
-- One row per execution: (pid, backend_start, query_start) identifies it.
SELECT pid, datname, usename, application_name,
       query_start, max(query_duration) AS longest_seen,
       min(collected_at) AS first_seen, max(collected_at) AS last_seen,
       count(*) AS snapshots, string_agg(DISTINCT wait_event, ', ') AS wait_events,
       left(max(query), 120) AS query
  FROM monitoring.session_history
 WHERE collected_at >= :'from' AND collected_at < :'to'
   AND state = 'active' AND backend_type = 'client backend'
   AND query_duration >= :'min_dur'::interval
 GROUP BY pid, backend_start, query_start, datname, usename, application_name
 ORDER BY longest_seen DESC
 LIMIT :top;

\echo '\n== 4b. Long-running transactions (open >= min_dur, any state) =='
SELECT pid, datname, usename, application_name, xact_start,
       max(xact_duration) AS longest_seen,
       string_agg(DISTINCT state, ', ') AS states_seen,
       min(backend_xmin::text) AS backend_xmin,
       left((array_agg(query ORDER BY collected_at DESC))[1], 120) AS last_query
  FROM monitoring.session_history
 WHERE collected_at >= :'from' AND collected_at < :'to'
   AND xact_start IS NOT NULL AND backend_type = 'client backend'
   AND xact_duration >= :'min_dur'::interval
 GROUP BY pid, backend_start, xact_start, datname, usename, application_name
 ORDER BY longest_seen DESC
 LIMIT :top;

-- -----------------------------------------------------------------------------
\echo '\n== 5. Idle-in-transaction offenders (by user / application / client) =='
-- episodes = distinct (session, transaction) pairs seen idle in transaction
SELECT usename, application_name, client_addr,
       count(DISTINCT (pid, backend_start, xact_start)) AS episodes,
       max(state_duration) AS longest_idle_in_xact,
       max(xact_duration)  AS longest_xact,
       count(*)            AS snapshots_seen,
       left((array_agg(query ORDER BY state_duration DESC))[1], 120) AS last_statement_before_idling
  FROM monitoring.session_history
 WHERE collected_at >= :'from' AND collected_at < :'to'
   AND state LIKE 'idle in transaction%'
 GROUP BY usename, application_name, client_addr
 ORDER BY longest_idle_in_xact DESC
 LIMIT :top;

-- -----------------------------------------------------------------------------
\echo '\n== 6. Top wait events of ACTIVE sessions =='
-- "samples" ~ time spent waiting (each sample = one snapshot interval)
SELECT wait_event_type, wait_event, count(*) AS samples,
       count(DISTINCT (pid, backend_start)) AS sessions,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
  FROM monitoring.session_history
 WHERE collected_at >= :'from' AND collected_at < :'to'
   AND state = 'active' AND wait_event IS NOT NULL
 GROUP BY 1, 2
 ORDER BY samples DESC
 LIMIT :top;

\echo '\n== 6b. Wait event classes over time (active sessions, per bucket) =='
SELECT date_bin(:'bucket'::interval, collected_at, timestamptz '2000-01-01') AS bucket,
       count(*) FILTER (WHERE wait_event_type IS NULL)  AS on_cpu,
       count(*) FILTER (WHERE wait_event_type = 'Lock')   AS lock,
       count(*) FILTER (WHERE wait_event_type = 'LWLock') AS lwlock,
       count(*) FILTER (WHERE wait_event_type = 'IO')     AS io,
       count(*) FILTER (WHERE wait_event_type = 'IPC')    AS ipc,
       count(*) FILTER (WHERE wait_event_type = 'Client') AS client,
       count(*) FILTER (WHERE wait_event_type = 'Timeout') AS timeout,
       count(*) FILTER (WHERE wait_event_type NOT IN ('Lock','LWLock','IO','IPC','Client','Timeout')) AS other
  FROM monitoring.session_history
 WHERE collected_at >= :'from' AND collected_at < :'to'
   AND state = 'active' AND backend_type = 'client backend'
 GROUP BY 1 ORDER BY 1;

-- -----------------------------------------------------------------------------
\echo '\n== 7. Lock waits: who waited for whom (same snapshot) =='
SELECT w.collected_at, w.pid AS waiting_pid, w.application_name AS waiting_app,
       w.wait_event AS waiting_for, w.query_duration AS waited_so_far,
       b.pid AS blocking_pid, b.application_name AS blocking_app, b.state AS blocking_state,
       b.xact_duration AS blocker_xact_age,
       left(w.query, 60) AS waiting_query, left(b.query, 60) AS blocker_last_query
  FROM monitoring.session_history w
  CROSS JOIN LATERAL unnest(w.blocking_pids) AS bp(pid)
  LEFT JOIN monitoring.session_history b
         ON b.snapshot_id = w.snapshot_id AND b.pid = bp.pid
 WHERE w.collected_at >= :'from' AND w.collected_at < :'to'
   AND w.blocking_pids IS NOT NULL AND cardinality(w.blocking_pids) > 0
 ORDER BY w.collected_at DESC, w.pid
 LIMIT :top;

\echo '\n== 7b. Root blockers (block others but are not waiting themselves), by impact =='
WITH edges AS (
    SELECT w.snapshot_id, w.collected_at, w.pid AS waiter, bp.pid AS blocker
      FROM monitoring.session_history w
      CROSS JOIN LATERAL unnest(w.blocking_pids) AS bp(pid)
     WHERE w.collected_at >= :'from' AND w.collected_at < :'to'
)
SELECT b.pid, b.backend_start, b.usename, b.application_name, b.client_addr,
       count(DISTINCT e.waiter)       AS sessions_blocked,
       count(DISTINCT e.snapshot_id)  AS snapshots_blocking,
       min(e.collected_at) AS first_seen, max(e.collected_at) AS last_seen,
       string_agg(DISTINCT b.state, ', ') AS blocker_states,
       left(max(b.query), 100) AS blocker_query
  FROM edges e
  JOIN monitoring.session_history b ON b.snapshot_id = e.snapshot_id AND b.pid = e.blocker
 WHERE b.blocking_pids IS NULL OR cardinality(b.blocking_pids) = 0
 GROUP BY b.pid, b.backend_start, b.usename, b.application_name, b.client_addr
 ORDER BY sessions_blocked DESC, snapshots_blocking DESC
 LIMIT :top;

-- -----------------------------------------------------------------------------
\echo '\n== 8. Most frequently seen ACTIVE queries (query_id; text when query_id is NULL) =='
-- samples ~ share of DB time; needs compute_query_id = on/auto (+pg_stat_statements) for query_id
SELECT query_id,
       count(*) AS samples,
       count(DISTINCT (pid, backend_start, query_start)) AS executions_seen,
       max(query_duration) AS longest_seen,
       string_agg(DISTINCT datname, ', ') AS databases,
       left(min(query), 120) AS example_query
  FROM monitoring.session_history
 WHERE collected_at >= :'from' AND collected_at < :'to'
   AND state = 'active' AND backend_type = 'client backend'
 GROUP BY query_id, CASE WHEN query_id IS NULL THEN left(query, 200) END
 ORDER BY samples DESC
 LIMIT :top;

-- -----------------------------------------------------------------------------
\echo '\n== 9. Sessions by client address =='
WITH per_snap AS (
    SELECT collected_at, client_addr, count(*) AS n
      FROM monitoring.session_history
     WHERE collected_at >= :'from' AND collected_at < :'to'
       AND backend_type = 'client backend'
     GROUP BY 1, 2
)
SELECT coalesce(host(p.client_addr), '[local socket]') AS client,
       max(p.n) AS max_concurrent, round(avg(p.n), 1) AS avg_concurrent,
       (SELECT count(DISTINCT (h.pid, h.backend_start)) FROM monitoring.session_history h
         WHERE h.collected_at >= :'from' AND h.collected_at < :'to'
           AND h.backend_type = 'client backend'
           AND h.client_addr IS NOT DISTINCT FROM p.client_addr) AS distinct_sessions,
       (SELECT string_agg(DISTINCT h.usename, ', ') FROM monitoring.session_history h
         WHERE h.collected_at >= :'from' AND h.collected_at < :'to'
           AND h.backend_type = 'client backend'
           AND h.client_addr IS NOT DISTINCT FROM p.client_addr) AS users
  FROM per_snap p
 GROUP BY p.client_addr
 ORDER BY max_concurrent DESC
 LIMIT :top;

-- -----------------------------------------------------------------------------
\echo '\n== 10. Timeline of one pid (-v pid=...) =='
SELECT collected_at, backend_start, state, wait_event_type, wait_event,
       query_duration, xact_duration, blocking_pids, left(query, 80) AS query
  FROM monitoring.session_history
 WHERE pid = :pid AND collected_at >= :'from' AND collected_at < :'to'
 ORDER BY collected_at;

-- -----------------------------------------------------------------------------
\echo '\n== 11. What was running at a given time (-v at=...): nearest snapshot at or before it =='
WITH snap AS (
    SELECT snapshot_id, collected_at FROM monitoring.session_snapshots
     WHERE collected_at <= :'at'::timestamptz
     ORDER BY collected_at DESC LIMIT 1
)
SELECT h.collected_at, h.pid, h.datname, h.usename, h.application_name, h.state,
       h.wait_event_type, h.wait_event, h.query_duration, h.xact_duration, h.blocking_pids,
       left(h.query, 100) AS query
  FROM monitoring.session_history h JOIN snap s USING (snapshot_id)
 WHERE h.backend_type = 'client backend' AND h.state IS DISTINCT FROM 'idle'
 ORDER BY h.query_duration DESC NULLS LAST;

-- -----------------------------------------------------------------------------
\echo '\n== 12. Connection growth vs max_connections (per bucket) =='
-- usable = max_connections - superuser_reserved_connections (- reserved_connections on PG16+)
SELECT date_bin(:'bucket'::interval, collected_at, timestamptz '2000-01-01') AS bucket,
       min(client_backends) AS min_clients, round(avg(client_backends), 1) AS avg_clients,
       max(client_backends) AS max_clients, max(max_connections) AS max_connections,
       round(100.0 * max(client_backends) / max(max_connections), 1) AS peak_pct,
       max(client_backends) - lag(max(client_backends)) OVER (ORDER BY 1) AS change_vs_prev_bucket
  FROM monitoring.session_snapshots
 WHERE collected_at >= :'from' AND collected_at < :'to'
 GROUP BY 1 ORDER BY 1;

-- -----------------------------------------------------------------------------
\echo '\n== 13. Collector health: snapshot gaps and collection time =='
SELECT collected_at, collected_at - lag(collected_at) OVER (PARTITION BY server_id ORDER BY collected_at) AS gap,
       rows_stored, collect_ms
  FROM monitoring.session_snapshots
 WHERE collected_at >= :'from' AND collected_at < :'to'
 ORDER BY gap DESC NULLS LAST
 LIMIT 10;
