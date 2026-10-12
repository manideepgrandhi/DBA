-- Title   : SQL script to get disk free space
-- Purpose : Disk/volume total size, free space and % free via sys.dm_os_volume_stats (two variants).
-- Source  : https://sqlservv.blogspot.com/2017/04/sql-script-to-get-disk-free-space_22.html
-- Posted  : 2017-04-22 (sqlservv.blogspot.com, 5star tag)
-- Notes from the original post:
--   Recently I've come across a situation where I need to pull the disk free space percent on a server. I can achieve this by logging into the server or by using xp_cmdshell in query analyzer.
--   Since it is a time consuming task and xp_cmdshell will not give free percent details, I've used below script to complete the task which saved my time by 10 minutes.
--   Hope it will help you too.

SELECT DISTINCT
vs.volume_mount_point [Drive],
CAST(vs.total_bytes / 1048576 as decimal(12,2)) [TotalMBs],
CAST(vs.available_bytes / 1048576 as decimal(12,2)) [FreeSpaceMBs],
CAST((CAST(vs.available_bytes / 1048576 as decimal(12,2)) * 100) / (CAST(vs.total_bytes / 1048576 as decimal(12,2))) as decimal(12,2)) [% Free]
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.[file_id]) vs

SELECT DISTINCT
volume_mount_point [Disk Mount Point],
file_system_type [File System Type],
logical_volume_name as [Logical Drive Name],
CONVERT(DECIMAL(18,2),total_bytes/1073741824.0) AS [Total Size in GB], ---1GB = 1073741824 bytes
CONVERT(DECIMAL(18,2),available_bytes/1073741824.0) AS [Available Size in GB],
CAST(CAST(available_bytes AS FLOAT)/ CAST(total_bytes AS FLOAT) AS DECIMAL(18,2)) * 100 AS [Space Free %]
FROM sys.master_files
CROSS APPLY sys.dm_os_volume_stats(database_id, file_id)
