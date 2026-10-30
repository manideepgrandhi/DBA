# pg_session_history

Keep a history of `pg_stat_activity` in a Postgres table, so you can answer questions
like *"what was running at 03:12?"*, *"who held the lock?"*, *"when did connections peak?"*
long after the sessions are gone.

| File | What it is |
|------|------------|
| `schema.sql` | `monitoring` schema, `session_history` (partitioned by day) and `session_snapshots` tables, indexes, comments on every column |
| `functions.sql` | `monitoring.collect_sessions()`, `monitoring.redact_query()`, `monitoring.purge_sessions()`, `monitoring.create_partitions()` |
| `upgrade_query_redaction.sql` | Idempotent upgrade of older installs to query redaction (section 1) |
| `collect_sessions.sh` | Bash collector: one-shot (cron) or loop mode, retention, logging, dry run |
| `analysis_queries.sql` | 13 commented analysis queries (psql variables for the time window) |

Requires PostgreSQL 14+ (for `query_id`; tested on 17) and Bash 4.4+.

---

## 1. Setup

```bash
# 1. a database for the history (any db works; pg_stat_activity is cluster-wide)
createdb monitoring

# 2. a dedicated collector role that OWNS the objects and can read all sessions
psql -d monitoring <<'SQL'
CREATE ROLE session_collector LOGIN;          -- set a password, put it in ~/.pgpass
GRANT pg_monitor TO session_collector;         -- includes pg_read_all_stats
GRANT CREATE ON DATABASE monitoring TO session_collector;
SQL

# 3. create the objects AS that role (so it owns them and can create/drop partitions)
psql -d monitoring -U session_collector -v ON_ERROR_STOP=1 -f schema.sql -f functions.sql

# 4. first snapshot
./collect_sessions.sh -d monitoring -U session_collector
```

### Upgrading an existing install (query redaction)

Installs made before query redaction stored `pg_stat_activity.query` verbatim, so
statements such as `ALTER ROLE ... PASSWORD '...'`, `pgp_sym_encrypt(data, 'key')`
or `dblink_connect('... password=...')` kept their secrets for the whole retention
period. To upgrade, run this as the owning role. It is idempotent and safe to re-run:

```bash
psql -d monitoring -U session_collector -v ON_ERROR_STOP=1 -f upgrade_query_redaction.sql
# optionally also redact rows that are already stored (rewrites history):
psql -d monitoring -U session_collector -v ON_ERROR_STOP=1 -v redact_existing=1 -f upgrade_query_redaction.sql
# ... or drop all stored query text instead:
psql -d monitoring -U session_collector -v ON_ERROR_STOP=1 -v drop_existing_query_text=1 -f upgrade_query_redaction.sql
```

Upgrading works the same as re-running `functions.sql`. Existing callers keep working
and now store redacted text, including pg_cron jobs and older copies of
`collect_sessions.sh` that pass 0-5 arguments. The new `collect_sessions.sh` (1.1.0)
refuses to run (exit 2) against an install that has not been upgraded, so it never
stores unredacted text without you noticing. After upgrading, `session_snapshots.filters`
contains `"query_redaction": true` and `"store_query"`.

Optional readers (dashboards, analysts):

```sql
CREATE ROLE session_reader NOLOGIN;
GRANT USAGE ON SCHEMA monitoring TO session_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA monitoring TO session_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE session_collector IN SCHEMA monitoring GRANT SELECT ON TABLES TO session_reader;
```

### Permissions, and why `pg_monitor` matters

Without `pg_read_all_stats` (granted through `pg_monitor`) a role sees only its own
sessions in full. For everybody else's sessions, Postgres returns NULL for
`state`, `backend_type`, `wait_event*`, `query_id`, `client_addr`, `xact_start`, ...
and `<insufficient privilege>` as the query. This was verified on the test cluster.
The script warns when the role lacks it. Superusers also see everything, but a
dedicated `pg_monitor` role is the safer choice.

Partition creation and `purge_sessions` (DROP TABLE) need the **owner** of
`monitoring.session_history`, which is why the collector role should own the objects.
If a non-owner collects, snapshots still work. Rows that fall outside existing
partitions go to the default partition, and a warning is logged.

---

## 2. Table design

### Partitioning choice: daily RANGE partitions (UTC days) + a DEFAULT partition

At one snapshot per minute, a busy server easily produces 100k-1M rows per day. With
daily partitions, retention is a `DROP TABLE` of whole days: it's instant, creates no
bloat and needs no VACUUM. A `DELETE` of millions of rows would take far longer. Queries
with a time window also only touch the partitions involved (partition pruning).

- `collect_sessions()` creates today's and tomorrow's partition itself if they are
  missing. `collect_sessions.sh` also pre-creates `--partitions-ahead` days (7 by
  default) at start and when the UTC date changes.
- The **DEFAULT** partition is a safety net, so a snapshot is never lost if a
  partition is missing. A side effect: Postgres refuses to create a partition for a
  range that already has rows in the default partition. `purge_sessions` cleans old
  rows out of the default partition.
- Day boundaries are UTC, so they don't depend on the session time zone. This only
  affects partition names, not your queries.

**Plain-table alternative:** for small setups (a few dozen sessions, short retention)
you can skip partitioning. Create `session_history` without `PARTITION BY` and the
DEFAULT partition, and replace the partition loop in `purge_sessions` with
`DELETE FROM monitoring.session_history WHERE collected_at < now() - p_retention`.
Add a BRIN index on `collected_at` and let autovacuum handle the deletes. Partitioning
is the default here because it scales without any later migration.

### `monitoring.session_snapshots`: one row per collection run

| Column | Meaning |
|---|---|
| `snapshot_id` | Snapshot id. The same value is on every `session_history` row of the snapshot |
| `collected_at` | Collection time (see section 3) |
| `server_id` | Server label (`--server-id`; default `cluster_name`, or address:port) |
| `total_backends` | All rows of `pg_stat_activity`, before filters (all backend types) |
| `client_backends` | Client connections, before filters; these count against `max_connections` |
| `rows_stored` | Rows written to `session_history` (after filters) |
| `max_connections` | `max_connections` at that moment |
| `filters` | Filters used (`include_idle`, `min_duration`, ...) as jsonb |
| `collect_ms` | How long the collection took |

The unfiltered totals live here so that connection-count analysis is still correct
when you store only non-idle sessions.

### `monitoring.session_history`: one row per backend per snapshot

| Column | Meaning |
|---|---|
| `collected_at` | Snapshot time; **identical for all rows of one snapshot** |
| `snapshot_id`, `server_id` | Link to `session_snapshots` / server label |
| `datname` | Database (NULL for background processes) |
| `pid` | Backend process id. Pids are reused, so `(pid, backend_start)` identifies a session |
| `leader_pid` | Leader pid for parallel workers |
| `usename` | Login role |
| `application_name` | Set by the client |
| `client_addr`, `client_hostname`, `client_port` | Client IP (NULL = Unix socket), host name (needs `log_hostname`), port (-1 = socket) |
| `backend_type` | `client backend`, `autovacuum worker`, `walsender`, `parallel worker`, ... |
| `backend_start` | Connection start |
| `xact_start` | Start of the open transaction (NULL = none) |
| `query_start` | Start of the current query, or of the last query when idle |
| `state_change` | Last state change |
| `state` | `active`, `idle`, `idle in transaction`, `idle in transaction (aborted)`, ... |
| `wait_event_type`, `wait_event` | What the backend waits on (`Lock/transactionid`, `IO/DataFileRead`, `Client/ClientRead`, ...) |
| `backend_xid`, `backend_xmin` | Transaction id / xmin horizon (old xmin holds back VACUUM) |
| `query_id` | Query fingerprint (PG14+). NULL unless `compute_query_id` is `on`, or `auto` with pg_stat_statements loaded |
| `query` | Query text (cut at `track_activity_query_size`, default 1024 bytes; optionally at `--max-query-length`) |
| `query_duration` | `collected_at - query_start` (current query runtime when `active`) |
| `xact_duration` | `collected_at - xact_start` (age of the open transaction) |
| `state_duration` | `collected_at - state_change` (e.g. how long idle in transaction) |
| `backend_age` | `collected_at - backend_start` (connection age) |
| `blocking_pids` | `pg_blocking_pids(pid)` for sessions waiting on a heavyweight lock; NULL otherwise |

Indexes: `collected_at`; `(datname, collected_at)`; `(state, collected_at)`;
`(wait_event_type, wait_event, collected_at)` where `wait_event` is not null;
`(query_id, collected_at)` where `query_id` is not null; `(pid, collected_at)`;
`snapshot_id`. Indexes are defined on the parent, so every partition gets them.

---

## 3. How collection timing works

- `collect_sessions()` reads `clock_timestamp()` **once**, at its start, and writes that
  value into `collected_at` of every row and of the snapshot header. All durations are
  computed against the same value, so one snapshot is a consistent point in time.
- `pg_stat_activity` is read once per transaction, so the totals and the stored rows
  come from the same picture. The time between `collected_at` and that read is a few ms.
- `clock_timestamp()` is used instead of `now()`, so the time stays correct even if
  someone calls the function inside a long transaction.
- `collected_at` is `timestamptz`. It's stored in UTC and shown in your session's
  `TimeZone`.
- **Loop mode** (`--interval 60`) aligns snapshots to the clock: 10:00:00, 10:01:00, ...
  Snapshot times are then comparable across servers and days. `--no-align` turns this off.
- **cron** starts at second 0 of the minute plus process start-up time, usually under 100 ms.
- Durations are what was visible at collection time, so they are lower bounds. A
  70-second query sampled every 60 s may show up once, at, say, 25 s. Sample more often
  if you need finer detail; the cost is about 5 ms per snapshot.
- The calling backend is excluded. The collector sets `application_name=collect_sessions`
  and `statement_timeout` (30 s by default).

---

## 4. `collect_sessions.sh`

```
./collect_sessions.sh [connection] [filters] [scheduling] [retention]
```

| Option | Purpose |
|---|---|
| `-h -p -U -d` | Connection; `-d` is the database holding the `monitoring` schema |
| `-W`, `--pgpassfile FILE`, `--pg-bin DIR` | Password prompt / pgpass file / psql location. Passwords are never taken on the command line |
| `--server-id ID` | Label stored with each row |
| `--no-idle` | Don't store `idle` sessions (snapshot totals still count them) |
| `--min-duration IVL` | Store active / idle-in-transaction sessions only if running at least `IVL`. Lock waiters and their blockers are always kept |
| `--exclude-backend-type T` | Skip backend types (repeatable / comma list) |
| `--max-query-length N` | Truncate stored query text (secrets are redacted before truncating) |
| `--no-query-text` | Don't store query text at all (`query` is NULL); config key `store_query = false` |
| `--interval S`, `--count N`, `--no-align` | Loop mode |
| `--max-failures N` | Loop mode: give up after N consecutive failures |
| `--statement-timeout T` | Default `30s` |
| `--lock-file FILE` | Skip the run if another instance is still running (flock) |
| `--retention IVL`, `--purge-every S`, `--purge-only` | Retention via `purge_sessions` |
| `--partitions-ahead N` | Daily partitions to pre-create (default 7) |
| `--config FILE` | key=value settings (parsed, never sourced); CLI wins |
| `--log-file FILE`, `-q`, `-v` | Logging (timestamps with UTC offset) |
| `--dry-run` | Run inside a transaction that is rolled back; purge only reports |

Exit codes: `0` ok · `1` usage / invalid interval · `2` cannot connect or objects
missing · `3` snapshot failed · `4` purge / partition maintenance failed · `5` another
instance holds the lock · `130` interrupted (one-shot). In loop mode INT/TERM stop
cleanly after the current step; the exit code is then 0, or the worst failure seen.

### Examples

```bash
# one snapshot
./collect_sessions.sh -d monitoring -U session_collector

# what would be stored right now (rolled back)
./collect_sessions.sh -d monitoring --dry-run -v

# troubleshooting session: every 10 s for 30 minutes, only non-idle sessions
./collect_sessions.sh -d monitoring --interval 10 --count 180 --no-idle

# daemon-style: every 30 s, keep 14 days, log to a file
./collect_sessions.sh -d monitoring --interval 30 --retention '14 days' \
    --exclude-backend-type 'checkpointer,background writer,walwriter' \
    --log-file /var/log/postgresql/collect_sessions.log

# retention only
./collect_sessions.sh -d monitoring --purge-only --retention '30 days'
```

Config file example (`/etc/collect_sessions.conf`):

```ini
host = /var/run/postgresql
dbname = monitoring
user = session_collector
server_id = prod-db-01
exclude_backend_types = checkpointer, background writer, walwriter
max_query_length = 2000
retention = 30 days
log_file = /var/log/postgresql/collect_sessions.log
```

### cron (every minute)

```cron
# m h dom mon dow  command
* * * * *  /opt/pg_session_history/collect_sessions.sh --config /etc/collect_sessions.conf -q --lock-file /tmp/collect_sessions.lock
15 3 * * * /opt/pg_session_history/collect_sessions.sh --config /etc/collect_sessions.conf -q --purge-only
```

Run it as an OS user whose `~/.pgpass` holds the collector password. `-q` keeps cron
mail to warnings and errors. For sub-minute sampling, use loop mode under systemd
instead of cron.

### systemd (loop mode)

```ini
[Unit]
Description=pg_stat_activity history collector
After=postgresql.service

[Service]
User=postgres
ExecStart=/opt/pg_session_history/collect_sessions.sh --config /etc/collect_sessions.conf --interval 30 -q
Restart=always

[Install]
WantedBy=multi-user.target
```

### pg_cron alternative (no OS scheduler)

```sql
-- in the database where pg_cron is installed (cron.database_name)
SELECT cron.schedule_in_database('collect-sessions', '* * * * *',
       $$SELECT monitoring.collect_sessions(p_server_id => 'prod-db-01')$$, 'monitoring');
-- pg_cron 1.5+ also accepts '30 seconds' as the schedule
SELECT cron.schedule_in_database('purge-sessions', '15 3 * * *',
       $$SELECT * FROM monitoring.purge_sessions('30 days')$$, 'monitoring');
```

Jobs run as the role that scheduled them, so schedule them as `session_collector`.
Note that pg_cron fires at the full minute but can't align to seconds, and that
pg_cron itself shows up in `pg_stat_activity` as a background worker. If you don't want it
in the history, look up its `backend_type` there and pass it in `p_exclude_backend_types`.

---

## 5. Using the SQL functions directly

```sql
SELECT monitoring.collect_sessions();                                   -- everything
SELECT monitoring.collect_sessions(p_include_idle => false,
                                   p_min_duration => '5 seconds',
                                   p_exclude_backend_types => '{checkpointer,walwriter}',
                                   p_max_query_length => 2000);         -- returns rows stored
SELECT monitoring.collect_sessions(p_store_query => false);             -- no query text at all
SELECT monitoring.redact_query($$ALTER ROLE app PASSWORD 'x'$$);        -- ALTER ROLE app PASSWORD '***'
SELECT monitoring.create_partitions(14);                                -- next 14 days
SELECT * FROM monitoring.purge_sessions('30 days', p_dry_run => true);  -- what would go
SELECT * FROM monitoring.purge_sessions('30 days');
```

`purge_sessions` drops every daily partition whose whole day is older than
`now() - retention`. It then deletes older rows from the default partition and from
`session_snapshots`. Retention below 1 hour is refused.

---

## 6. Analysis

```bash
psql -d monitoring -f analysis_queries.sql                                   # last 24 h
psql -d monitoring -v from='2026-10-10 09:00+05:30' -v to='2026-10-10 12:00+05:30' \
     -v bucket='1 minute' -v min_dur='10 seconds' -f analysis_queries.sql
psql -d monitoring -v at='2026-10-10 11:42+05:30' -v pid=4711 -f analysis_queries.sql
```

| # | Query |
|---|---|
| 1 | Sessions over time by state (active / idle / idle in xact / lock waits) |
| 2a, 2b | Sessions per database over time; per user / application |
| 3, 3b | Peak connection counts and when; daily peak per server |
| 4, 4b | Long-running queries; long-running transactions (with `backend_xmin`) |
| 5 | Idle-in-transaction offenders |
| 6, 6b | Top wait events; wait classes over time |
| 7, 7b | Lock waits (waiter → blocker in the same snapshot); root blockers by impact |
| 8 | Most frequently seen active queries (by `query_id`, else by text) |
| 9 | Sessions by client address |
| 10 | Timeline of one pid |
| 11 | What was running at a given time |
| 12 | Connection growth vs `max_connections` |
| 13 | Collector health: gaps between snapshots, collection time |

Sampling note: "samples" counts are proportional to time spent. With 60 s snapshots,
100 samples of a query is roughly 100 minutes of one backend running it.

---

## 7. Storage sizing and retention

Rough rule: **about 1 KB per stored row**, including indexes. A heap row is about
250-400 bytes with typical query text; long query texts (up to
`track_activity_query_size`) make it bigger. `--max-query-length` caps it.

| Sessions stored per snapshot | Interval | Rows / day | ≈ Size / day | 30 days |
|---|---|---|---|---|
| 50 | 60 s | 72 k | 70 MB | 2 GB |
| 200 | 60 s | 288 k | 280 MB | 8.5 GB |
| 200 | 15 s | 1.15 M | 1.1 GB | 34 GB |
| 20 (`--no-idle`) | 15 s | 115 k | 110 MB | 3.4 GB |

Measure your actual rate after a day:

```sql
SELECT relname, pg_size_pretty(pg_total_relation_size(oid))
  FROM pg_class WHERE relname LIKE 'session_history_p%' ORDER BY relname DESC LIMIT 3;
```

Guidance:
- Idle sessions are usually the bulk of the rows. Use `--no-idle` if connection
  counts are all you need from them; the per-snapshot totals are kept anyway.
- Keep detailed history 7-30 days. For longer trends, aggregate `session_snapshots`
  (it's tiny) or roll up per hour before purging.
- Write the history to a database on the same cluster only if it can take the extra
  WAL. Collection adds a few ms of CPU, but the inserts are WAL-logged and replicated.
  Busy clusters can collect into a separate monitoring instance, or point `-d`/`-h`
  there. Note that `collect_sessions()` always reads the activity of the server it
  runs on.

---

## 8. Caveats

- Sampling misses anything shorter than the interval. For complete statement
  statistics, use `pg_stat_statements`; this history answers *when* and *who*.
- `query_id` needs `compute_query_id`. `blocking_pids` covers heavyweight locks only;
  LWLock contention shows up only as `wait_event_type = LWLock`.
- `client_hostname` is filled only with `log_hostname = on`.
- If the server has `track_activities = off`, there's nothing to collect.
- Dry runs consume a sequence value, so `snapshot_id` can have gaps.
- **Query text is redacted, but redaction is best effort.** `monitoring.redact_query()`
  runs before the text is stored, and before `--max-query-length` truncation. It masks:
  - the literal after `PASSWORD`, which covers `CREATE/ALTER USER/ROLE ... [ENCRYPTED] PASSWORD '...'`;
  - `password=`/`pwd=` values in connection strings;
  - `user:secret@` in URIs;
  - every string literal (`'...'`, `E'...'`, `$tag$...$tag$`) in a statement that
    mentions a password, `pgp_*`, `crypt`/`encrypt`/`decrypt`, `gen_salt`, `hmac`
    or `dblink*`.

  Secrets passed some other way still end up in the history, for example inside
  your own functions or as plain column values. If query text is not needed, use
  `--no-query-text` (`p_store_query => false`), and grant `SELECT` on the history
  only to roles that may see it.
