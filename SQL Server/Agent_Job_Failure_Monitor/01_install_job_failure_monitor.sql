/*==============================================================================
  SQL Agent Job Failure Monitor - install / upgrade (idempotent, re-runnable)
  Creates in database [dbadmin]:
    dba.JobMonitorList         - jobs to watch
    dba.JobFailureLog          - one row per failed job run
    dba.usp_MonitorAgentJobs   - detect failures, log, email (one email per failed run)
    dba.usp_PurgeJobFailureLog - optional cleanup
  Requires SQL Server 2016 SP1+ (CREATE OR ALTER).
==============================================================================*/
USE dbadmin;
GO
IF SCHEMA_ID(N'dba') IS NULL EXEC (N'CREATE SCHEMA dba AUTHORIZATION dbo;');
GO

/*---------------------------- 1. watch list ---------------------------------*/
IF OBJECT_ID(N'dba.JobMonitorList', N'U') IS NULL
    CREATE TABLE dba.JobMonitorList
    (
        JobName       sysname        NOT NULL CONSTRAINT PK_JobMonitorList PRIMARY KEY,
        IsEnabled     bit            NOT NULL CONSTRAINT DF_JobMonitorList_IsEnabled DEFAULT (1),
        Recipients    nvarchar(max)  NULL,   -- overrides @DefaultRecipients when set
        CcRecipients  nvarchar(max)  NULL,
        Notes         nvarchar(4000) NULL,
        AddedDate     datetime2(0)   NOT NULL CONSTRAINT DF_JobMonitorList_AddedDate DEFAULT (SYSDATETIME())
    );
GO
/* Sample:
INSERT dba.JobMonitorList (JobName, Recipients, Notes)
VALUES (N'DatabaseBackup - USER_DATABASES - FULL', NULL, N'Nightly full backups'),
       (N'IndexOptimize - USER_DATABASES', N'dba-team@example.com;app-owner@example.com', NULL);
UPDATE dba.JobMonitorList SET IsEnabled = 0 WHERE JobName = N'IndexOptimize - USER_DATABASES';
*/

/*---------------------------- 2. failure log --------------------------------*/
IF OBJECT_ID(N'dba.JobFailureLog', N'U') IS NULL
    CREATE TABLE dba.JobFailureLog
    (
        Id                  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobFailureLog PRIMARY KEY,
        ServerName          sysname          NOT NULL,
        JobName             sysname          NOT NULL,
        JobId               uniqueidentifier NOT NULL,
        FailedStepId        int              NULL,
        FailedStepName      sysname          NULL,
        StepMessage         nvarchar(max)    NULL,
        JobOutcomeMessage   nvarchar(max)    NULL,
        RunDateTime         datetime         NOT NULL,
        RunDurationSeconds  int              NULL,
        InstanceId          int              NOT NULL,   -- sysjobhistory.instance_id of the job outcome (step 0) row
        DetectedAt          datetime2(0)     NOT NULL CONSTRAINT DF_JobFailureLog_DetectedAt DEFAULT (SYSDATETIME()),
        EmailSent           bit              NOT NULL CONSTRAINT DF_JobFailureLog_EmailSent DEFAULT (0),
        EmailSentAt         datetime2(0)     NULL,
        EmailError          nvarchar(4000)   NULL,
        MailItemId          int              NULL,
        RetryCount          int              NOT NULL CONSTRAINT DF_JobFailureLog_RetryCount DEFAULT (0)
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dba.JobFailureLog') AND name = N'UX_JobFailureLog_JobId_RunDateTime')
    CREATE UNIQUE INDEX UX_JobFailureLog_JobId_RunDateTime ON dba.JobFailureLog (JobId, RunDateTime);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dba.JobFailureLog') AND name = N'IX_JobFailureLog_Unsent')
    CREATE INDEX IX_JobFailureLog_Unsent ON dba.JobFailureLog (EmailSent, RetryCount);
GO

/*---------------------------- 3. monitor proc -------------------------------*/
CREATE OR ALTER PROCEDURE dba.usp_MonitorAgentJobs
    @MailProfile        sysname,
    @DefaultRecipients  nvarchar(max),
    @LookbackMinutes    int           = 60,     -- window used when a job has no log rows yet
    @DebugOnly          bit           = 0,      -- 1 = show what would be logged/sent; no insert, no email
    @SubjectPrefix      nvarchar(100) = N'[SQL Agent Failure]',
    @MaxRetries         int           = 3       -- email attempts per failure before giving up
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Server sysname = @@SERVERNAME;     -- includes \INSTANCE for named instances
    DECLARE @Since  datetime = DATEADD(MINUTE, -ABS(@LookbackMinutes), GETDATE());

    IF @DebugOnly = 0 AND NULLIF(LTRIM(RTRIM(@MailProfile)), N'') IS NULL
    BEGIN
        RAISERROR(N'@MailProfile is required when @DebugOnly = 0.', 16, 1);
        RETURN;
    END;

    /* Warn about listed jobs that do not exist in msdb */
    DECLARE @missing nvarchar(max);
    SELECT @missing = STUFF((SELECT N', ' + l.JobName
                             FROM dba.JobMonitorList AS l
                             WHERE l.IsEnabled = 1
                               AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs AS j WHERE j.name = l.JobName)
                             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @missing IS NOT NULL
        RAISERROR(N'WARNING: listed job(s) not found in msdb.dbo.sysjobs: %s', 10, 1, @missing) WITH NOWAIT;

    /* New failed job outcomes */
    IF OBJECT_ID(N'tempdb..#new') IS NOT NULL DROP TABLE #new;

    WITH lastlog AS
    (
        SELECT JobId, MAX(InstanceId) AS MaxInstanceId FROM dba.JobFailureLog GROUP BY JobId
    ),
    outcome AS
    (
        SELECT j.job_id, j.name AS job_name, h.instance_id, h.message,
               msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_dt,
               (h.run_duration / 10000) * 3600 + ((h.run_duration / 100) % 100) * 60 + (h.run_duration % 100) AS dur_s,
               ll.MaxInstanceId
        FROM dba.JobMonitorList AS l
        JOIN msdb.dbo.sysjobs AS j       ON j.name = l.JobName
        JOIN msdb.dbo.sysjobhistory AS h ON h.job_id = j.job_id
        LEFT JOIN lastlog AS ll          ON ll.JobId = j.job_id
        WHERE l.IsEnabled = 1 AND h.step_id = 0 AND h.run_status = 0
    )
    SELECT o.job_id, o.job_name, o.instance_id, o.message AS outcome_msg, o.run_dt, o.dur_s,
           fs.step_id AS failed_step_id, fs.step_name AS failed_step_name, fs.message AS step_msg
    INTO #new
    FROM outcome AS o
    OUTER APPLY (SELECT MAX(p.instance_id) AS prev_id        -- previous outcome row of this job
                 FROM msdb.dbo.sysjobhistory AS p
                 WHERE p.job_id = o.job_id AND p.step_id = 0 AND p.instance_id < o.instance_id) AS prev
    OUTER APPLY (SELECT TOP (1) s.step_id, s.step_name, s.message
                 FROM msdb.dbo.sysjobhistory AS s
                 WHERE s.job_id = o.job_id AND s.step_id > 0 AND s.run_status = 0
                   AND s.instance_id < o.instance_id
                   AND s.instance_id > ISNULL(prev.prev_id, 0)
                 ORDER BY s.instance_id DESC) AS fs
    WHERE (o.MaxInstanceId IS NOT NULL AND o.instance_id > o.MaxInstanceId)
       OR (o.run_dt >= @Since);   -- first run, or msdb history was reset; dedup below

    DELETE n FROM #new AS n
    WHERE EXISTS (SELECT 1 FROM dba.JobFailureLog AS f WHERE f.JobId = n.job_id AND f.RunDateTime = n.run_dt);

    IF @DebugOnly = 1
    BEGIN
        SELECT N'WOULD LOG + EMAIL' AS action, @Server AS ServerName, n.job_name AS JobName, n.run_dt AS RunDateTime,
               n.dur_s AS RunDurationSeconds, n.failed_step_id, n.failed_step_name, n.step_msg, n.outcome_msg,
               COALESCE(NULLIF(l.Recipients, N''), @DefaultRecipients) AS Recipients, l.CcRecipients
        FROM #new AS n JOIN dba.JobMonitorList AS l ON l.JobName = n.job_name
        ORDER BY n.run_dt;

        SELECT N'WOULD RETRY EMAIL' AS action, f.*
        FROM dba.JobFailureLog AS f
        WHERE f.EmailSent = 0 AND f.RetryCount < @MaxRetries;
        RETURN;
    END;

    INSERT dba.JobFailureLog (ServerName, JobName, JobId, FailedStepId, FailedStepName, StepMessage,
                              JobOutcomeMessage, RunDateTime, RunDurationSeconds, InstanceId)
    SELECT @Server, job_name, job_id, failed_step_id, failed_step_name, step_msg, outcome_msg, run_dt, dur_s, instance_id
    FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY job_id, run_dt ORDER BY instance_id DESC) AS rn FROM #new) AS x
    WHERE rn = 1;

    /* One email per unsent failure */
    DECLARE @Id bigint, @Srv sysname, @Job sysname, @StepId int, @StepName sysname, @StepMsg nvarchar(max),
            @OutMsg nvarchar(max), @RunDt datetime, @Dur int, @To nvarchar(max), @Cc nvarchar(max),
            @Subject nvarchar(255), @Body nvarchar(max), @MailId int, @Err nvarchar(4000), @IdTxt nvarchar(20);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT f.Id, f.ServerName, f.JobName, f.FailedStepId, f.FailedStepName, f.StepMessage, f.JobOutcomeMessage,
               f.RunDateTime, ISNULL(f.RunDurationSeconds, 0),
               COALESCE(NULLIF(l.Recipients, N''), @DefaultRecipients), NULLIF(l.CcRecipients, N'')
        FROM dba.JobFailureLog AS f
        LEFT JOIN dba.JobMonitorList AS l ON l.JobName = f.JobName
        WHERE f.EmailSent = 0 AND f.RetryCount < @MaxRetries
        ORDER BY f.Id;

    OPEN c;
    FETCH NEXT FROM c INTO @Id, @Srv, @Job, @StepId, @StepName, @StepMsg, @OutMsg, @RunDt, @Dur, @To, @Cc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @MailId = NULL;
        SET @IdTxt = CONVERT(nvarchar(20), @Id);
        SET @Subject = LEFT(CONCAT(@SubjectPrefix, N' ', @Srv, N' - ', @Job,
                                   N' (', CONVERT(nvarchar(19), @RunDt, 120), N')'), 255);
        /* FOR XML PATH('') HTML-encodes & < > */
        SET @Body = CONCAT(
            N'<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:10pt">',
            N'<h2 style="color:#b00020;margin-bottom:2px">SQL Agent job failed on ', (SELECT @Srv FOR XML PATH('')), N'</h2>',
            N'<p style="font-size:12pt;margin-top:0"><b>Server:</b> ', (SELECT @Srv FOR XML PATH('')),
            N' &nbsp;|&nbsp; <b>Job:</b> ', (SELECT @Job FOR XML PATH('')), N'</p>',
            N'<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse">',
            N'<tr><th align="left">Server</th><td>',      (SELECT @Srv FOR XML PATH('')), N'</td></tr>',
            N'<tr><th align="left">Job</th><td>',         (SELECT @Job FOR XML PATH('')), N'</td></tr>',
            N'<tr><th align="left">Run time</th><td>',    CONVERT(nvarchar(19), @RunDt, 120), N' (server local time)</td></tr>',
            N'<tr><th align="left">Duration</th><td>',    @Dur / 3600, N'h ', (@Dur / 60) % 60, N'm ', @Dur % 60, N's</td></tr>',
            N'<tr><th align="left">Failed step</th><td>',
                 CASE WHEN @StepId IS NULL THEN N'(not found in history)'
                      ELSE CONCAT(@StepId, N' - ', (SELECT @StepName FOR XML PATH(''))) END, N'</td></tr>',
            N'<tr><th align="left" valign="top">Step message</th><td><pre style="white-space:pre-wrap;font-family:Consolas,monospace">',
                 (SELECT ISNULL(@StepMsg, N'') FOR XML PATH('')), N'</pre></td></tr>',
            N'<tr><th align="left" valign="top">Job outcome</th><td>', (SELECT ISNULL(@OutMsg, N'') FOR XML PATH('')), N'</td></tr>',
            N'</table><p>Full history: SSMS &gt; SQL Server Agent &gt; Jobs &gt; ', (SELECT @Job FOR XML PATH('')),
            N' &gt; View History, or<br><code>EXEC msdb.dbo.sp_help_jobhistory @job_name = N''',
                 (SELECT REPLACE(@Job, N'''', N'''''') FOR XML PATH('')), N''', @mode = N''FULL'';</code></p>',
            N'<p style="color:#666">Logged as dbadmin.dba.JobFailureLog Id ', @IdTxt, N' by dba.usp_MonitorAgentJobs.</p></body></html>');

        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                 @profile_name    = @MailProfile,
                 @recipients      = @To,
                 @copy_recipients = @Cc,
                 @subject         = @Subject,
                 @body            = @Body,
                 @body_format     = 'HTML',
                 @mailitem_id     = @MailId OUTPUT;

            UPDATE dba.JobFailureLog
               SET EmailSent = 1, EmailSentAt = SYSDATETIME(), MailItemId = @MailId, EmailError = NULL,
                   RetryCount = RetryCount + 1
             WHERE Id = @Id;
        END TRY
        BEGIN CATCH
            SET @Err = LEFT(CONCAT(N'Error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()), 4000);
            IF XACT_STATE() <> 0 ROLLBACK;
            UPDATE dba.JobFailureLog SET EmailError = @Err, RetryCount = RetryCount + 1 WHERE Id = @Id;
            RAISERROR(N'Email for JobFailureLog Id %s failed: %s', 10, 1, @IdTxt, @Err) WITH NOWAIT;
        END CATCH;

        FETCH NEXT FROM c INTO @Id, @Srv, @Job, @StepId, @StepName, @StepMsg, @OutMsg, @RunDt, @Dur, @To, @Cc;
    END;
    CLOSE c;
    DEALLOCATE c;
END;
GO

/*---------------------------- 4. purge proc ---------------------------------*/
CREATE OR ALTER PROCEDURE dba.usp_PurgeJobFailureLog
    @RetentionDays int = 180
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cut datetime2(0) = DATEADD(DAY, -ABS(@RetentionDays), SYSDATETIME()), @n int = 1;
    WHILE @n > 0
    BEGIN
        DELETE TOP (5000) FROM dba.JobFailureLog WHERE DetectedAt < @cut;
        SET @n = @@ROWCOUNT;
    END;
END;
GO
PRINT N'Agent job failure monitor installed in dbadmin.';
GO
