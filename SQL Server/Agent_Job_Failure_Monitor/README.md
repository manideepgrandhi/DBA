# SQL Agent Job Failure Monitor

Watches a list of SQL Agent jobs, logs every failed run to a table, and sends **one HTML email per failed run** through Database Mail. Installed per server, in the `dbadmin` database.

| File | Purpose |
|---|---|
| `01_install_job_failure_monitor.sql` | Creates schema `dba`, tables `dba.JobMonitorList` / `dba.JobFailureLog`, procs `dba.usp_MonitorAgentJobs` / `dba.usp_PurgeJobFailureLog`. Re-runnable. |
| `02_create_monitor_agent_job.sql` | Creates the Agent job `DBA - Monitor Agent Job Failures` (every 5 min). Edit the profile/recipient placeholders. Re-runnable. |
| `03_test_job_failure_monitor.sql` | Creates a job that always fails, runs it twice, runs the monitor, shows the log and mail queue. Cleanup at the bottom. |

## Steps
1. Database Mail configured with a working profile (`EXEC msdb.dbo.sysmail_help_profile_sp;`), and `dbadmin` exists.
2. Run `01_install_job_failure_monitor.sql`.
3. Add the jobs to watch:
   ```sql
   INSERT dbadmin.dba.JobMonitorList (JobName) VALUES (N'DatabaseBackup - USER_DATABASES - FULL');
   INSERT dbadmin.dba.JobMonitorList (JobName, Recipients, CcRecipients)
   VALUES (N'ETL Nightly', N'etl-team@example.com', N'dba@example.com');   -- per-job override
   ```
4. Try it: `EXEC dbadmin.dba.usp_MonitorAgentJobs @MailProfile=N'DBA_Mail', @DefaultRecipients=N'dba@example.com', @DebugOnly=1;`
5. Edit and run `02_create_monitor_agent_job.sql`.
6. Optional: run `03_test_job_failure_monitor.sql` on a non-prod server.

## Parameters (`dba.usp_MonitorAgentJobs`)
| Parameter | Default | Meaning |
|---|---|---|
| `@MailProfile` | required | Database Mail profile |
| `@DefaultRecipients` | required | Used when the job's `Recipients` is NULL |
| `@LookbackMinutes` | 60 | How far back to look for a job with no log rows yet (first run) |
| `@DebugOnly` | 0 | 1 = show what would be logged and emailed; writes and sends nothing |
| `@SubjectPrefix` | `[SQL Agent Failure]` | Subject prefix |
| `@MaxRetries` | 3 | Email attempts per failure before giving up |

## How it works
- Reads job outcome rows (`step_id = 0`, `run_status = 0`) from `msdb.dbo.sysjobhistory` for enabled listed jobs, newer than the last logged `instance_id` for that job (or within `@LookbackMinutes`).
- Finds the failing step: latest step row with `run_status = 0` between the previous outcome row and this one, and stores its message.
- Unique index on `(JobId, RunDateTime)` plus a pre-check means a failure is never logged or emailed twice.
- For each row with `EmailSent = 0` and `RetryCount < @MaxRetries`, calls `sp_send_dbmail` inside TRY/CATCH; stores `MailItemId` or `EmailError`. Failed sends are retried on the next run.
- Warns (severity 10, does not fail) when a listed job is not in `msdb`.

## Sample email
Subject: `[SQL Agent Failure] PRODSQL01\INST1 - ETL Nightly (2026-10-22 02:15:00)`

Body starts with **SQL Agent job failed on PRODSQL01\INST1**, then a table: Server, Job, Run time, Duration, Failed step (`2 - Load staging`), Step message (full error, HTML-encoded), Job outcome, and the `sp_help_jobhistory` command to see full history. Server name is `@@SERVERNAME`, so named instances show `HOST\INSTANCE`.

## Permissions
- Reading `msdb.dbo.sysjobs` / `sysjobhistory`: `sysadmin`, or a user in msdb with `SQLAgentReaderRole` (sees all jobs' history) plus SELECT on those tables.
- Sending mail: `DatabaseMailUserRole` in msdb, and access to the profile (public or granted).
- INSERT/UPDATE on `dbadmin.dba.*` and EXECUTE on the procs.
- The monitor job's owner (default `sa` in script 02) must have all of the above; `sa`/sysadmin is simplest.

## Troubleshooting
```sql
SELECT TOP 50 * FROM dbadmin.dba.JobFailureLog ORDER BY Id DESC;
SELECT TOP 50 mailitem_id, sent_status, recipients, subject, send_request_date, sent_date
FROM msdb.dbo.sysmail_allitems ORDER BY mailitem_id DESC;
SELECT TOP 50 * FROM msdb.dbo.sysmail_event_log ORDER BY log_id DESC;
EXEC msdb.dbo.sysmail_help_status_sp;          -- is Database Mail started?
EXEC msdb.dbo.sp_help_jobhistory @job_name = N'DBA - Monitor Agent Job Failures';
-- resend a failure: UPDATE dbadmin.dba.JobFailureLog SET EmailSent = 0, RetryCount = 0 WHERE Id = <id>;
```

## Limits
- `EmailSent = 1` means Database Mail **accepted** the message. SMTP failures after that show in `sysmail_allitems.sent_status = 'failed'` / `sysmail_event_log`, not in `EmailError`.
- Failures purged from msdb history before the monitor runs are missed (check Agent history retention: max rows per job).
- Jobs are matched by name. Renamed jobs must be renamed in `JobMonitorList` too.
- Only failures (`run_status = 0`); cancelled, retried or long-running jobs are not reported.
- Run times are server local time (as Agent stores them).
- Requires SQL Server 2016 SP1+.
