/*==============================================================================
  Creates/updates SQL Agent job "DBA - Monitor Agent Job Failures" (every 5 min).
  Idempotent: drops and recreates the job if it already exists.
  EDIT the two placeholders below before running.
==============================================================================*/
USE msdb;
GO
DECLARE @MailProfile sysname       = N'<<YourDatabaseMailProfile>>';   -- e.g. N'DBA_Mail'
DECLARE @Recipients  nvarchar(400) = N'<<dba-team@yourcompany.com>>';  -- ; separated
DECLARE @JobName     sysname       = N'DBA - Monitor Agent Job Failures';
DECLARE @Owner       sysname       = N'sa';                            -- or a dedicated login
DECLARE @jobId uniqueidentifier, @cmd nvarchar(max);

IF @MailProfile LIKE N'<<%' OR @Recipients LIKE N'<<%'
BEGIN
    RAISERROR(N'Edit @MailProfile and @Recipients placeholders first.', 16, 1);
    RETURN;
END;

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @JobName)
    EXEC dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

SET @cmd = N'EXEC dba.usp_MonitorAgentJobs @MailProfile = N''' + REPLACE(@MailProfile, N'''', N'''''')
         + N''', @DefaultRecipients = N''' + REPLACE(@Recipients, N'''', N'''''') + N''', @LookbackMinutes = 60;';

EXEC dbo.sp_add_job @job_name = @JobName, @enabled = 1, @owner_login_name = @Owner,
     @description = N'Emails one alert per failed run of jobs listed in dbadmin.dba.JobMonitorList; logs to dbadmin.dba.JobFailureLog.',
     @job_id = @jobId OUTPUT;

EXEC dbo.sp_add_jobstep @job_id = @jobId, @step_id = 1, @step_name = N'Run monitor',
     @subsystem = N'TSQL', @database_name = N'dbadmin', @command = @cmd,
     @on_success_action = 3, @on_fail_action = 2;

EXEC dbo.sp_add_jobstep @job_id = @jobId, @step_id = 2, @step_name = N'Purge log (180 days, Sundays only)',
     @subsystem = N'TSQL', @database_name = N'dbadmin',
     @command = N'IF DATEPART(WEEKDAY, GETDATE()) = 1 AND DATEPART(HOUR, GETDATE()) = 2 AND DATEPART(MINUTE, GETDATE()) < 5
    EXEC dba.usp_PurgeJobFailureLog @RetentionDays = 180;',
     @on_success_action = 1, @on_fail_action = 2;

EXEC dbo.sp_add_jobschedule @job_id = @jobId, @name = N'Every 5 minutes', @enabled = 1,
     @freq_type = 4, @freq_interval = 1, @freq_subday_type = 4, @freq_subday_interval = 5,
     @active_start_time = 0;

EXEC dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
PRINT N'Created job: ' + @JobName;
GO
