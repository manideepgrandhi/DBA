/*==============================================================================
  Test: creates a job that always fails, watches it, runs it twice, runs the
  monitor in debug then for real. Expect 2 log rows and 2 emails; rerunning
  the monitor must send nothing new. Run with sqlcmd so :setvar works, or
  replace $(MailProfile)/$(Recipients) by hand.
    sqlcmd -S . -E -i 03_test_job_failure_monitor.sql -v MailProfile="DBA_Mail" Recipients="you@x.com"
==============================================================================*/
USE msdb;
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DBA_TEST_FailingJob')
    EXEC dbo.sp_delete_job @job_name = N'DBA_TEST_FailingJob';
EXEC dbo.sp_add_job @job_name = N'DBA_TEST_FailingJob', @owner_login_name = N'sa';
EXEC dbo.sp_add_jobstep @job_name = N'DBA_TEST_FailingJob', @step_id = 1, @step_name = N'Step 1 ok',
     @subsystem = N'TSQL', @command = N'SELECT 1;', @on_success_action = 3;
EXEC dbo.sp_add_jobstep @job_name = N'DBA_TEST_FailingJob', @step_id = 2, @step_name = N'Step 2 divide <by> zero & fail',
     @subsystem = N'TSQL', @command = N'SELECT 1/0;', @on_fail_action = 2;
EXEC dbo.sp_add_jobserver @job_name = N'DBA_TEST_FailingJob';
GO
USE dbadmin;
GO
IF NOT EXISTS (SELECT 1 FROM dba.JobMonitorList WHERE JobName = N'DBA_TEST_FailingJob')
    INSERT dba.JobMonitorList (JobName, Notes) VALUES (N'DBA_TEST_FailingJob', N'test');
IF NOT EXISTS (SELECT 1 FROM dba.JobMonitorList WHERE JobName = N'DBA_TEST_NoSuchJob')
    INSERT dba.JobMonitorList (JobName, Notes) VALUES (N'DBA_TEST_NoSuchJob', N'test - should warn');
GO
EXEC msdb.dbo.sp_start_job @job_name = N'DBA_TEST_FailingJob';
WAITFOR DELAY '00:00:10';
EXEC msdb.dbo.sp_start_job @job_name = N'DBA_TEST_FailingJob';
WAITFOR DELAY '00:00:10';
GO
PRINT N'--- debug run (nothing logged / sent) ---';
EXEC dba.usp_MonitorAgentJobs @MailProfile = N'$(MailProfile)', @DefaultRecipients = N'$(Recipients)', @DebugOnly = 1;
PRINT N'--- real run ---';
EXEC dba.usp_MonitorAgentJobs @MailProfile = N'$(MailProfile)', @DefaultRecipients = N'$(Recipients)';
PRINT N'--- rerun (must send nothing new) ---';
EXEC dba.usp_MonitorAgentJobs @MailProfile = N'$(MailProfile)', @DefaultRecipients = N'$(Recipients)';
SELECT Id, ServerName, JobName, FailedStepId, FailedStepName, LEFT(StepMessage, 200) AS StepMessage,
       RunDateTime, RunDurationSeconds, EmailSent, MailItemId, RetryCount, EmailError
FROM dba.JobFailureLog WHERE JobName = N'DBA_TEST_FailingJob' ORDER BY Id;
WAITFOR DELAY '00:00:10';
SELECT mailitem_id, sent_status, subject, sent_date FROM msdb.dbo.sysmail_allitems ORDER BY mailitem_id DESC;
GO
/*---------------- cleanup (uncomment) ----------------
DELETE dbadmin.dba.JobFailureLog  WHERE JobName = N'DBA_TEST_FailingJob';
DELETE dbadmin.dba.JobMonitorList WHERE JobName IN (N'DBA_TEST_FailingJob', N'DBA_TEST_NoSuchJob');
EXEC msdb.dbo.sp_delete_job @job_name = N'DBA_TEST_FailingJob';
------------------------------------------------------*/
