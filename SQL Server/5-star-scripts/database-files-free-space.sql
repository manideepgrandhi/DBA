-- Title   : Free space for all data and log files of all databases
-- Purpose : Uses sp_MSForEachDB to list size, free MB and free % of every data/log file on the instance.
-- Source  : https://sqlservv.blogspot.com/2017/04/script-to-find-free-space-for-all-data_24.html
-- Posted  : 2017-04-25 (sqlservv.blogspot.com, 5star tag)

create table #DBInfo (
DatabaseName VARCHAR(100),
FileSizeMB INT,
LogicalFileName sysname,
PhysicalFileName NVARCHAR(520),
DiskDrive CHAR(2),
Status sysname,
RecoveryMode sysname,
FreeSpaceMB INT,
FreeSpacePct VARCHAR(7)
)
DECLARE @command VARCHAR(5000)
SELECT @command = 'Use [' + '?' + '] SELECT
' + '''' + '?' + '''' + ' AS DatabaseName,
CAST(sysfiles.size/128.0 AS int) AS FileSize,
sysfiles.name AS LogicalFileName, sysfiles.filename AS PhysicalFileName,  substring(sysfiles.filename,1,2) as DiskDrive,
CONVERT(sysname,DatabasePropertyEx(''?'',''Status'')) AS Status,
CONVERT(sysname,DatabasePropertyEx(''?'',''Recovery'')) AS RecoveryMode,CAST(sysfiles.size/128.0 - CAST(FILEPROPERTY(sysfiles.name, ' + '''' +
       'SpaceUsed' + '''' + ' ) AS int)/128.0 AS int) AS FreeSpaceMB,
CAST(100 * (CAST (((sysfiles.size/128.0 -CAST(FILEPROPERTY(sysfiles.name,
' + '''' + 'SpaceUsed' + '''' + ' ) AS int)/128.0)/(sysfiles.size/128.0))
AS decimal(4,2))) AS varchar(8)) + ' + '''' + '%' + '''' + ' AS FreeSpacePct FROM dbo.sysfiles'
INSERT INTO #DBInfo
   (
   DatabaseName,
   FileSizeMB,
   LogicalFileName,
   PhysicalFileName,
   DiskDrive,
   Status,
   RecoveryMode,
   FreeSpaceMB,
   FreeSpacePct)
EXEC sp_MSForEachDB @command
SELECT

   DatabaseName,
   FileSizeMB,
   LogicalFileName,
   PhysicalFileName,
   DiskDrive,
   Status,
   RecoveryMode,
   FreeSpaceMB,
   FreeSpacePct
FROM #DBInfo
ORDER BY
   DiskDrive, FileSizeMB desc
drop table #DBInfo
