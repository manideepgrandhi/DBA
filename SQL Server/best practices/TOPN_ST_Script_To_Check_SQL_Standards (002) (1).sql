/*
This script contains basic checks. It will not ideally do anything of its own, but provides you the script\info to change the setting where ever necessary.
We can take the decisions based on the product\app.
Author: Prashanth Chiliveri
Date: 30\05\2017
Revision : 08/07/2017 by Bhanu
*/
SET NOCOUNT ON;

SELECT d.name
       , MAX(CASE WHEN bs.type='D' THEN bs.backup_finish_date ELSE NULL END) AS LastFullBackup
       , MAX(CASE WHEN bs.type='I' THEN bs.backup_finish_date ELSE NULL END) AS LastDifferential
       , MAX(CASE WHEN bs.type='L' THEN bs.backup_finish_date ELSE NULL END) AS LastLog
    FROM msdb.dbo.backupset bs
    INNER JOIN sys.databases d on d.name = bs.database_name
GROUP BY d.name
ORDER BY d.name DESC


-- Volume info for all LUNS that have database files 
SELECT DISTINCT vs.volume_mount_point, vs.file_system_type, 
vs.logical_volume_name, CONVERT(DECIMAL(18,2),vs.total_bytes/1073741824.0) AS [Total Size (GB)],
CONVERT(DECIMAL(18,2), vs.available_bytes/1073741824.0) AS [Available Size (GB)],  
CONVERT(DECIMAL(18,2), vs.available_bytes * 1. / vs.total_bytes * 100.) AS [Space Free %]
FROM sys.master_files AS f WITH (NOLOCK)
CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) AS vs 
ORDER BY vs.volume_mount_point;

BEGIN /*DATABASE SETTINGS CHECKS*/

		BEGIN
			BEGIN /*AUTOGROWTH CHECKS*/
				BEGIN TRY
					IF OBJECT_ID('tempdb..#databaseFiles') IS NOT NULL
						BEGIN
							DROP TABLE #databaseFiles;
						END;

					CREATE TABLE #databaseFiles
						(
							DBName NVARCHAR(4000),
							LogicalName NVARCHAR(4000),
							PhysicalName NVARCHAR(4000),
							FileType INT,
							FileSize INT,
							IsPercentGrowth INT,
							MaxSize INT,
							Growth INT,
							NewGrowthAmount INT
						);

					INSERT	INTO #databaseFiles
					SELECT	sdb.name,
							smf.name,
							smf.physical_name,
							smf.type,
							smf.size / 128,
							smf.is_percent_growth,
							smf.max_size,
							smf.growth,
							CASE	WHEN smf.size / 128 < 2048 THEN 256
									WHEN smf.size / 128 >= 2048
											AND smf.size / 128 < 5120 THEN 512
									WHEN smf.size / 128 >= 5120
											AND smf.size / 128 < 10240 THEN 512
									WHEN smf.size / 128 >= 10240
											AND smf.size / 128 < 51200 THEN 1024
									WHEN smf.size / 128 >= 51200
											AND smf.size / 128 < 102400 THEN 1024
									WHEN smf.size / 128 >= 102400 THEN 1024
							END AS NewGrowthAmount
					FROM	master.sys.master_files smf
					INNER JOIN master.sys.databases sdb
							ON smf.database_id = sdb.database_id;

					BEGIN TRY
						SELECT	'***PERCENT GROWTH CHECK***' DBName,
								NULL IsPercentGrowth,
								'--All databases should be growing incrementally and not by percent. Run these commands to switch from percent growth.' [Command(s) to change Percent Growth To Growth In MB's]
						UNION
						SELECT	DBName,
								IsPercentGrowth,
								'ALTER DATABASE [' + DBName
								+ '] MODIFY FILE ( NAME = ''' + LogicalName
								+ ''', FILEGROWTH = '
								+ CAST(NewGrowthAmount AS NVARCHAR) + 'MB)' AS [Command(s) to change Percent Growth]
						FROM	#databaseFiles
						WHERE	IsPercentGrowth <> 0;
					END TRY
					BEGIN CATCH
						SELECT	'***PERCENT GROWTH CHECK***' DBName,
								NULL IsPercentGrowth,
								'--All databases should be growing incrementally and not by percent. Run these commands to switch from percent growth.' [Command(s) to change Percent Growth To Growth In MB's]
						UNION
						SELECT	'******ERROR******' AS DBName,
								NULL IsPercentGrowth,
								'ERROR: ' + ERROR_MESSAGE()
								+ '  Located on line: '
								+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
					END CATCH;

					BEGIN TRY
						SELECT	'***GROWTH AMOUNT CHECK***' DBName,
								NULL Growth,
								NULL NewGrowthAmount,
								'--All databases should have consistent growth sizes. Run these commands to standardize your growth sizes.' [Command(s) to change Growth Amount -- Check and Change Wherever necessary considering the Growth column]
						UNION
						SELECT	DBName,
								( Growth * 8 ) / 1024 AS Growth,
								NewGrowthAmount,
								'ALTER DATABASE [' + DBName
								+ '] MODIFY FILE ( NAME = ''' + LogicalName
								+ ''', FILEGROWTH = '
								+ CAST(NewGrowthAmount AS NVARCHAR) + 'MB)' AS [Command(s) to change Growth Amount]
						FROM	#databaseFiles
						WHERE	( Growth * 8 ) / 1024 <> NewGrowthAmount
								AND IsPercentGrowth <> 1;
					END TRY
					BEGIN CATCH
						SELECT	'***GROWTH AMOUNT CHECK***' DBName,
								NULL Growth,
								NULL NewGrowthAmount,
								'--All databases should have consistent growth sizes. Run these commands to standardize your growth sizes.' [Command(s) to change Growth Amount]
						UNION
						SELECT	'******ERROR******' AS DBName,
								NULL Growth,
								NULL NewGrowthAmount,
								'ERROR: ' + ERROR_MESSAGE()
								+ '  Located on line: '
								+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
					END CATCH;

					BEGIN TRY
						SELECT	'***MAX GROWTH CHECK***' DBName,
								NULL MaxSize,
								'--All databases should have their maximum file growth size unlimited. Run these commands to set file growth to unlimited.' [Command(s) to change Max Growth]
						UNION
						SELECT	DBName,
								MaxSize,
								'ALTER DATABASE [' + DBName
								+ '] MODIFY FILE ( NAME = ''' + LogicalName
								+ ''', MAXSIZE = UNLIMITED )' AS [Command(s) to change Max Growth]
						FROM	#databaseFiles
						WHERE	MaxSize NOT IN ( 268435456, -1 );
					END TRY
					BEGIN CATCH
						SELECT	'***MAX GROWTH CHECK***' DBName,
								NULL MaxSize,
								'--All databases should have their maximum file growth size unlimited. Run these commands to set file growth to unlimited.' [Command(s) to change Max Growth]
						UNION
						SELECT	'******ERROR******' AS DBName,
								NULL MaxSize,
								'ERROR: ' + ERROR_MESSAGE()
								+ '  Located on line: '
								+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
					END CATCH;

					DROP TABLE #databaseFiles;
				END TRY
				BEGIN CATCH
					SELECT	'***PERCENT GROWTH CHECK***' DBName,
							'--All databases should be growing incrementally and not by percent. Run these commands to switch from percent growth.' [Command(s) to change Percent Growth]
					UNION
					SELECT	'***GROWTH AMOUNT CHECK***' DBName,
							'--All databases should have consistent growth sizes. Run these commands to standardize your growth sizes.' [Command(s) to change Percent Growth]
					UNION
					SELECT	'***MAX GROWTH CHECK***' DBName,
							'--All databases should have their maximum file growth size unlimited. Run these commands to set file growth to unlimited.' [Command(s) to change Max Growth]
					UNION
					SELECT	'******ERROR******' AS DBName,
							'ERROR: ' + ERROR_MESSAGE() + '  Located on line: '
							+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
				END CATCH;

			END;

		--	BEGIN /*RECOVERY MODEL CHECK*/
		--	BEGIN TRY
		--		SELECT '***RECOVERY MODEL CHECK***' [DatabaseName]
		--			 , NULL [RecoveryModel]
		--			 , '--All databases should be in FULL recovery. Run these commands to change the recovery model to FULL recovery.' [Command(s) to change Recovery Model]
		--		 UNION
		--		SELECT name AS [DatabaseName]
		--			 , recovery_model_desc AS [RecoveryModel]
		--			 , 'USE ['
		--			 + name
		--			 + ']; ALTER DATABASE ['
		--			 + name
		--			 + '] SET RECOVERY FULL WITH NO_WAIT; ' AS [Command(s) to change Recovery Model]
		--		  FROM master.sys.databases
		--		 WHERE recovery_model_desc <> 'FULL'
		--		   AND name NOT IN ( 'master'
		--						   , 'model'
		--						   , 'msdb'
		--						   , 'tempdb' )
		--	END TRY
		--	BEGIN CATCH
		--		SELECT '***RECOVERY MODEL CHECK***' [DatabaseName]
		--			 , NULL [RecoveryModel]
		--			 , '--All databases should be in FULL recovery. Run these commands to change the recovery model to FULL recovery.' [Command(s) to change Recovery Model]
		--		 UNION
		--		SELECT '******ERROR******'AS [DatabaseName]
		--			 , NULL [RecoveryModel]
		--			 , 'ERROR: ' + ERROR_MESSAGE() + '  Located on line: ' + CONVERT(varchar(5), ERROR_LINE()) AS [ErrorMessage]
		--	END CATCH
		
		--END

			BEGIN /*AUTOCLOSE CHECK*/
				BEGIN TRY
					SELECT	'***AUTO CLOSE CHECK***' DatabaseName,
							'--All databases should have auto close disabled. Run these commands to disable auto close. ' [Command(s) to change Auto Close]
					UNION
					SELECT	name AS DatabaseName,
							'USE [' + name + ']; ALTER DATABASE [' + name
							+ '] SET AUTO_CLOSE OFF WITH NO_WAIT' AS [Command(s) to change Auto Close]
					FROM	master.sys.databases
					WHERE	is_auto_close_on = 1;
				END TRY
				BEGIN CATCH
					SELECT	'***AUTO CLOSE CHECK***' DatabaseName,
							'--All databases should have auto close disabled. Run these commands to disable auto close. ' [Command(s) to change Auto Close]
					UNION
					SELECT	'******ERROR******' AS DatabaseName,
							'ERROR: ' + ERROR_MESSAGE() + '  Located on line: '
							+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
				END CATCH;
			END;


			BEGIN /*AUTOSHRINK CHECK*/
				BEGIN TRY
					SELECT	'***AUTO SHRINK CHECK***' [Database Name],
							'--All databases should have auto shrink disabled. Run these commands to disable auto shrink.' [Command(s) to change Auto Shrink]
					UNION
					SELECT	name AS [Database Name],
							'USE [' + name + ']; ALTER DATABASE [' + name
							+ '] SET AUTO_SHRINK OFF WITH NO_WAIT' AS [Command(s) to change Auto Shrink]
					FROM	master.sys.databases
					WHERE	is_auto_shrink_on = 1;
				END TRY
				BEGIN CATCH
					SELECT	'***AUTO SHRINK CHECK***' [Database Name],
							'--All databases should have auto shrink disabled. Run these commands to disable auto shrink.' [Command(s) to change Auto Shrink]
					UNION
					SELECT	'******ERROR******' AS DatabaseName,
							'ERROR: ' + ERROR_MESSAGE() + '  Located on line: '
							+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
				END CATCH;

			END;

			BEGIN /*AUTO CREATE STATS CHECK*/
				BEGIN TRY
					SELECT	'***AUTO CREATE STATS CHECK***' [Database Name],
							'--All databases should have Auto Create Stats enabled. Run these commands to enable Auto Create Stats.' [Command(s) to change Auto Stats]
					UNION
					SELECT	name AS [Database Name],
							'USE [' + name + ']; ALTER DATABASE [' + name
							+ '] SET AUTO_CREATE_STATISTICS ON WITH NO_WAIT' AS [Command(s) to change Auto Stats]
					FROM	master.sys.databases
					WHERE	is_auto_create_stats_on = 0;
				END TRY
				BEGIN CATCH
					SELECT	'***AUTO CREATE STATS CHECK***' [Database Name],
							'--All databases should have Auto Create Stats enabled. Run these commands to enable Auto Create Stats.' [Command(s) to change Auto Stats]
					UNION
					SELECT	'******ERROR******' AS DatabaseName,
							'ERROR: ' + ERROR_MESSAGE() + '  Located on line: '
							+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
				END CATCH;

			END;

			BEGIN /*AUTO UPDATE STATS CHECK*/
				BEGIN TRY
					SELECT	'***AUTO UPDATE STATS CHECK***' [Database Name],
							'--All databases should have Auto Update Stats enabled. Run these commands to enable Auto Update Stats.' [Command(s) to change Auto Stats]
					UNION
					SELECT	name AS [Database Name],
							'USE [' + name + ']; ALTER DATABASE [' + name
							+ '] SET AUTO_UPDATE_STATISTICS ON WITH NO_WAIT' AS [Command(s) to change Auto Stats]
					FROM	master.sys.databases
					WHERE	is_auto_update_stats_on = 0;
				END TRY
				BEGIN CATCH
					SELECT	'***AUTO UPDATE STATS CHECK***' [Database Name],
							'--All databases should have Auto Update Stats enabled. Run these commands to enable Auto Update Stats.' [Command(s) to change Auto Stats]
					UNION
					SELECT	'******ERROR******' AS DatabaseName,
							'ERROR: ' + ERROR_MESSAGE() + '  Located on line: '
							+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
				END CATCH;

			END;
      


			BEGIN /*PAGE VERIFY CHECK*/
				BEGIN TRY
					SELECT	'***PAGE VERIFY CHECK***' DatabaseName,
							'***********' PageVerify,
							'--All databases need to have their Page Verify option set to CHECKSUM. Run these commands to fix databases out of compliance.' [Command(s) to change Page Verify]
					UNION
					SELECT	name AS DatabaseName,
							page_verify_option_desc AS PageVerify,
							'USE [' + name + ']; ALTER DATABASE [' + name
							+ '] SET PAGE_VERIFY CHECKSUM WITH NO_WAIT' AS [Command(s) to change Page Verify]
					FROM	master.sys.databases
					WHERE	page_verify_option <> 2;
				END TRY
				BEGIN CATCH
					SELECT	'***PAGE VERIFY CHECK***' DatabaseName,
							'***********' PageVerify,
							'--All databases need to have their Page Verify option set to CHECKSUM. Run these commands to fix databases out of compliance.' [Command(s) to change Page Verify]
					UNION
					SELECT	'******ERROR******' AS DatabaseName,
							'***********' PageVerify,
							'ERROR: ' + ERROR_MESSAGE() + '  Located on line: '
							+ CONVERT(VARCHAR(5), ERROR_LINE()) AS ErrorMessage;
				END CATCH;

			END;
	END;
END;



--VLF COUNT:
-------------

declare @query varchar(4000)  
declare @dbname sysname  
declare @vlfs int  
  
--table variable used to 'loop' over databases  
declare @databases table (dbname sysname)  
insert into @databases  
--only choose online databases  
select name from sys.databases where state = 0  
  
--table variable to hold results  
declare @vlfcounts table  
    (dbname sysname,  
    vlfcount int)  
  
 
 
--table variable to capture DBCC loginfo output  
--changes in the output of DBCC loginfo from SQL2012 mean we have to determine the version 

declare @MajorVersion tinyint  
set @MajorVersion = LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)),CHARINDEX('.',CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(max)))-1) 
 
if @MajorVersion < 11 -- pre-SQL2012 
begin 
    declare @dbccloginfo table  
    (  
        fileid tinyint,  
        file_size bigint,  
        start_offset bigint,  
        fseqno int,  
        [status] tinyint,  
        parity tinyint,  
        create_lsn numeric(25,0)  
    )  
  
    while exists(select top 1 dbname from @databases)  
    begin  
  
        set @dbname = (select top 1 dbname from @databases)  
        set @query = 'dbcc loginfo (' + '''' + @dbname + ''') '  
  
        insert into @dbccloginfo  
        exec (@query)  
  
        set @vlfs = @@rowcount  
  
        insert @vlfcounts  
        values(@dbname, @vlfs)  
  
        delete from @databases where dbname = @dbname  
  
    end --while 
end 
else 
begin 
    declare @dbccloginfo2012 table  
    (  
        RecoveryUnitId int, 
        fileid tinyint,  
        file_size bigint,  
        start_offset bigint,  
        fseqno int,  
        [status] tinyint,  
        parity tinyint,  
        create_lsn numeric(25,0)  
    )  
  
    while exists(select top 1 dbname from @databases)  
    begin  
  
        set @dbname = (select top 1 dbname from @databases)  
        set @query = 'dbcc loginfo (' + '''' + @dbname + ''') '  
  
        insert into @dbccloginfo2012  
        exec (@query)  
  
        set @vlfs = @@rowcount  
  
        insert @vlfcounts  
        values(@dbname, @vlfs)  
  
        delete from @databases where dbname = @dbname  
  
    end --while 
end 
  
--output the full list  
select dbname, vlfcount  
from @vlfcounts  
Where vlfcount >= 100
order by vlfcount desc

-- File names and paths for all user and system databases on OS/root drive, C:\
SELECT '**** System DBs Loction Check ****'AS [Database Name], NULL [file_id], NULL [LogicalName], NULL [physical_name],NULL [type_desc],
NULL state_desc, NULL [Total Size in MB], '-- *** System DBs needs to be moved from C to their dedicated drives' AS ' DBA Action Item '
UNION
SELECT DB_NAME([database_id]) AS [Database Name], 
       [file_id], [name] AS [LogicalName], physical_name, [type_desc], state_desc,
       CONVERT(bigint, size/128.0) AS [Total Size in MB]
	   , 'System DBs to be moved from C to their dedicated drives' AS ' DBA Action Item '
FROM sys.master_files WITH (NOLOCK)
WHERE database_id IN (1,3,4)
AND physical_name like 'C:\%'
ORDER BY [Database Name], [file_id];

-- File names and paths for all user and system databases on OS/root drive, C:\
SELECT '**** TempDBs Loction Check ****'AS [Database Name], NULL [file_id], NULL [LogicalName], NULL [physical_name],NULL [type_desc],
NULL state_desc, NULL [Total Size in MB], '-- *** Temp DBs needs to be moved from C to their dedicated drives' AS ' DBA Action Item '
UNION
SELECT DB_NAME([database_id]) AS [Database Name], 
       [file_id], [name] AS [LogicalName], physical_name, [type_desc], state_desc,
       CONVERT(bigint, size/128.0) AS [Total Size in MB]
	   , 'Temp DB to be moved from C to its dedicated drive T:\Data' AS ' DBA Action Item '
FROM sys.master_files WITH (NOLOCK)
WHERE database_id = 2
AND physical_name like 'C:\%'
ORDER BY [Database Name], [file_id];

-- Databases, File names and paths of log files existing on D:\ (Data drive) and E:\ ( Index Drive)
-- All Log files in ST should reside on F:\Logs\ only.
SELECT '**** All DBs - Data Files Loction Check ****'AS [Database Name], NULL [file_id], NULL [LogicalName], NULL [physical_name],NULL [type_desc],
NULL state_desc, NULL [Total Size in MB], '-- *** All DATA Files needs to be moved to D:\Data\' AS ' DBA Action Item '
UNION
SELECT DB_NAME([database_id]) AS [Database Name], 
       [file_id], [name] AS [LogicalName], physical_name, [type_desc], state_desc,
       CONVERT(bigint, size/128.0) AS [Total Size in MB]
	   , 'All DATA Files to be moved to D:\Data\' AS ' DBA Action Item '
FROM sys.master_files WITH (NOLOCK)
WHERE file_id = 1 -- filtering data files
AND physical_name NOT like 'D:\%'
AND database_id > 4
ORDER BY [Database Name];

-- Databases, File names and paths of log files existing on D:\ (Data drive) and E:\ ( Index Drive)
-- All Log files in ST should reside on F:\Logs\ only.
SELECT '**** All DBs - Log Files Loction Check ****'AS [Database Name], NULL [file_id], NULL [LogicalName], NULL [physical_name],NULL [type_desc],
NULL state_desc, NULL [Total Size in MB], '-- *** All LOG Files needs to be moved to F:\Logs\' AS ' DBA Action Item '
UNION
SELECT DB_NAME([database_id]) AS [Database Name], 
       [file_id], [name] AS [LogicalName], physical_name, [type_desc], state_desc,
       CONVERT(bigint, size/128.0) AS [Total Size in MB]
	   , 'All LOG Files to be moved to F:\Logs\' AS ' DBA Action Item '
FROM sys.master_files WITH (NOLOCK)
WHERE file_id = 2 -- filtering Log files
AND physical_name NOT like 'F:\%'
AND database_id > 4
ORDER BY [Database Name], [file_id];

-- Databases, File names and paths of log files existing on C:\ (OS/Root Drive);  D:\ (Data drive); and F:\ ( Log Drive)
-- All INDEX files in ST should reside on E:\Data\ only.
SELECT '**** All DBs - Index Files Loction Check ****'AS [Database Name], NULL [file_id], NULL [LogicalName], NULL [physical_name],NULL [type_desc],
NULL state_desc, NULL [Total Size in MB], '-- ***All INDEX Files needs to be moved to E:\Data\' AS ' DBA Action Item '
UNION
SELECT DB_NAME([database_id]) AS [Database Name], 
       [file_id], [name] AS [LogicalName], physical_name, [type_desc], state_desc,
       CONVERT(bigint, size/128.0) AS [Total Size in MB]
	   , 'All INDEX Files to be moved to E:\Data\' AS ' DBA Action Item '
FROM sys.master_files WITH (NOLOCK)
WHERE file_id NOT IN (1, 2) -- filtering both data & Log files to show only Index files or Secondary Data files
AND physical_name NOT like 'E:\%'
AND database_id > 4
ORDER BY [Database Name], [file_id];



--Check instant file initailization
CREATE TABLE #xp_cmdshell_output (Output VARCHAR (8000));
GO

INSERT INTO #xp_cmdshell_output EXEC ('xp_cmdshell "whoami /priv"');
GO

IF EXISTS (SELECT * FROM #xp_cmdshell_output WHERE Output LIKE '%SeManageVolumePrivilege%')
SELECT 'Instant Initialization enabled' as '*** Instant Initialization Status ***'
ELSE
SELECT 'Instant Initialization disabled' as '*** Instant Initialization Status ***'

select 'Use this SQL account for Instant Initialization Enablement' as 'SQL Account for Initialization', service_account, servicename from sys.dm_server_services Where servicename = 'SQL Server (MSSQLSERVER)'

DROP TABLE #xp_cmdshell_output;
GO

exec sp_configure 'advanced options', 1
reconfigure with override

IF OBJECT_ID('tempdb..#SSProperties') IS NOT NULL
	DROP TABLE tempdb..#SSProperties

CREATE TABLE #SSProperties
(
	SlNo smallint identity(1,1)
	,Name nvarchar(500)
	,Value sql_variant
	,valueinuse sql_variant
	,[DBA_Recommendations] varchar(500)
	, Commands nvarchar(1024)
)

INSERT INTO #SSProperties
Select name, value, value_in_use, NULL, NULL
FROM sys.configurations WITH (NOLOCK)
WHERE name in ('backup compression default','cost threshold for parallelism','lightweight pooling','max degree of parallelism',
		'max server memory (MB)','max server memory (MB)','optimize for ad hoc workloads','priority boost', 'remote admin connections')
ORDER BY name;

Update #SSProperties Set DBA_Recommendations = 1, Commands = ' exec sp_configure ''backup compression default'', 1; reconfigure with override;'
Where Name = 'backup compression default';

Update #SSProperties Set DBA_Recommendations = 50, Commands = ' exec sp_configure ''cost threshold for parallelism'', 50; reconfigure with override;'
Where Name = 'cost threshold for parallelism';

Update #SSProperties Set DBA_Recommendations = 0, Commands = ' exec sp_configure ''lightweight pooling'', 0; reconfigure with override;'
Where Name = 'lightweight pooling';

Update #SSProperties Set DBA_Recommendations = 4, Commands = ' exec sp_configure ''max degree of parallelism'', 4; reconfigure with override;'
Where Name = 'max degree of parallelism';

Update #SSProperties Set DBA_Recommendations = (SELECT ROUND(CAST((physical_memory_kb/1024)*0.8 AS FLOAT),0,0) FROM sys.dm_os_sys_info)
Where Name = 'max server memory (MB)';

Update #SSProperties Set DBA_Recommendations = 1, Commands = ' exec sp_configure ''optimize for ad hoc workloads'', 1; reconfigure with override;'
Where Name = 'optimize for ad hoc workloads';

Update #SSProperties Set DBA_Recommendations = 0, Commands = ' exec sp_configure ''priority boost'', 0; reconfigure with override;'
Where Name = 'priority boost';

Update #SSProperties Set DBA_Recommendations = 1, Commands = ' exec sp_configure ''remote admin connections'', 1; reconfigure with override;'
Where Name = 'remote admin connections';

--Update #SSProperties set Commands = ' exec sp_configure ''max degree of parallelism'',' + DBA_Recommendations + '; reconfigure with override;'
--Where Name = 'max degree of parallelism'

Update #SSProperties set Commands = ' exec sp_configure ''max server memory (MB)'',' + DBA_Recommendations + '; reconfigure with override;'
Where Name = 'max server memory (MB)'

SELECT '0' as [SLNO],'**** SQL Server Properties ****'AS [Name], '----' [value], '----' [value_in_use], '**** DBA Recommendations ****' as [DBA_Recommendations], '-- Review the Commands Before EXECUTE ***' [Commands]
UNION
SELECT * FROM #SSProperties

DBCC TRACESTATUS(-1);
Select  'DBCC TRACEON(3226, -1)' as CommandToTraceON, 'TF 3226 - Supresses logging of successful database backup messages to the SQL Server Error Log' as Description


USE [master]
GO
DECLARE @cpu_count      int,
        @file_count     int,
        @logical_name   sysname,
        @file_name      nvarchar(520),
        @physical_name  nvarchar(520),
        @alter_command  nvarchar(max)

SELECT  @physical_name = physical_name
FROM    tempdb.sys.database_files
WHERE   name = 'tempdev'

SELECT  @file_count = COUNT(*)
FROM    tempdb.sys.database_files
WHERE   type_desc = 'ROWS'


SELECT  @cpu_count = cpu_count
FROM    sys.dm_os_sys_info

--- In general, one tempdb file per one CPU. 
--- Maximum tempdb files should be 8 only through we have more than 8 CPUs.
--- So caping on 8 by below statement
If @cpu_count > 8 set @cpu_count = 8

If OBJECT_ID('tempdb..#CommandstoExecute') IS NOT NULL
	DROP TABLE tempdb..#CommandstoExecute

CREATE table #CommandstoExecute
(
	SQLCommands nvarchar(4000)
)

WHILE @file_count < @cpu_count
 BEGIN
    
	SELECT  @logical_name = 'tempdev' + CAST(@file_count AS nvarchar)
    SELECT  @file_name = REPLACE(@physical_name, 'tempdb.mdf', @logical_name + '.ndf')
    SELECT  @alter_command = 'ALTER DATABASE [tempdb] ADD FILE ( NAME = N''' + @logical_name + ''', FILENAME =N''' +  @file_name + ''', SIZE = ' + CAST(1024 as nvarchar)+ 'MB, FILEGROWTH = ' + CAST(256 as nvarchar) + 'MB )'
    INSERT INTO #CommandstoExecute
	SELECT  @alter_command
    SELECT  @file_count = @file_count + 1
 END

Select 1 as slno, '*** TempDB Sizing (Make sure to CREATE TempDB Files Off from C drive and to its dedicated disk only ***' As TempDBSizing
UNION
Select 2 as slno, '*** If you noticed tempdb in C:\, Make sure you have add these files in T:\ or other given dedicate drive by changing the path from the below results ***' As TempDBSizing
UNION
Select 3 as slno, '*** Ensure NOT to place the tempdb files in the existing Data/Log file drives ***' As TempDBSizing
UNION 
select 4 as slno, * from #CommandstoExecute


/*
DECLARE @TraceFlags table (TraceFlag nvarchar(10), status nvarchar(10),global nvarchar(10), session nvarchar(10))
insert into @TraceFlags execute('DBCC TRACESTATUS(-1)')

select 1 as Slno, '*** TraceFlags *** ' As TraceFlags, '*** status ***' as Status, '*** global ***' as global, '*** session ***' as session, '*** Command ***' as Command
union
select 2 as Slno, *, 'DBCC TRACESTATUS(3226, -1)' as command from @TraceFlags
*/

/*
-- Focus on these settings:
-- backup compression default (should be 1 in most cases)
-- clr enabled (only enable if it is needed)
-- cost threshold for parallelism (depends on your workload)
-- lightweight pooling (should be zero)
-- max degree of parallelism (depends on your workload and hardware)
-- max server memory (MB) (set to an appropriate value, not the default)
-- optimize for ad hoc workloads (should be 1)
-- priority boost (should be zero)
-- remote admin connections (should be 1)

exec sp_configure 'advanced options', 1
reconfigure with override
exec sp_configure 'max degree of parallelism', 4  ----- Please check the CPUs before applying 
exec sp_configure 'backup compression default', 1
exec sp_configure 'cost threshold for parallelism', 50;
exec sp_configure 'remote admin connections', 1;
exec sp_configure 'optimize for ad hoc workloads', 1;
reconfigure with override

go

--- If you observe more SQL Server Agent Jobs

--- Increase the job history
USE [msdb]
GO
EXEC msdb.dbo.sp_set_sqlagent_properties @jobhistory_max_rows=100000
GO
*/


/*EXEC xp_instance_regread
'HKEY_LOCAL_MACHINE',
'HARDWARE\DESCRIPTION\System\CentralProcessor\0',
'ProcessorNameString';
 
-- Script to get CPU and Memory Info
SELECT
 cpu_count AS [Number of Logical CPU]
,hyperthread_ratio
,cpu_count/hyperthread_ratio AS [Number of Physical CPU]
,physical_memory_in_bytes/1048576 AS [Total Physical Memory IN MB]
FROM sys.dm_os_sys_info OPTION (RECOMPILE);*/