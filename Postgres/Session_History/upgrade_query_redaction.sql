-- =============================================================================
-- pg_session_history : upgrade_query_redaction.sql
-- Upgrades an install made before query redaction (security review M3).
-- Idempotent: safe to run any number of times, on old or already-upgraded installs.
--
--   psql -d monitoring -U session_collector -v ON_ERROR_STOP=1 -f upgrade_query_redaction.sql
--
-- What it does
--   * (re)creates monitoring.redact_query(text)
--   * replaces collect_sessions(text,boolean,interval,text[],integer) with
--     collect_sessions(..., p_store_query boolean DEFAULT true). Existing calls
--     with 0-5 arguments (pg_cron jobs, older collect_sessions.sh) keep working
--     and now store redacted text.
--   * optionally redacts rows that are ALREADY stored. That rewrites history, so
--     it only runs when asked:
--       ... -v redact_existing=1 -f upgrade_query_redaction.sql
--     or, to drop stored query text entirely:
--       ... -v drop_existing_query_text=1 -f upgrade_query_redaction.sql
-- =============================================================================
\set ON_ERROR_STOP 1

\ir functions.sql

\if :{?drop_existing_query_text}
    UPDATE monitoring.session_history SET query = NULL WHERE query IS NOT NULL;
\elif :{?redact_existing}
    UPDATE monitoring.session_history
       SET query = monitoring.redact_query(query)
     WHERE query IS DISTINCT FROM monitoring.redact_query(query);
\endif
