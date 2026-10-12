-- Title   : SQL query to get database size and free space
-- Purpose : Current database file sizes, free space and %, totals by data/log in GB, and file + disk details.
-- Source  : https://sqlservv.blogspot.com/2017/04/sql-query-to-get-database-size-and-free_22.html
-- Posted  : 2017-04-22 (sqlservv.blogspot.com, 5star tag)
-- Notes from the original post:
--   There are times we need to pull a database space details with details like file name,file path,total size,available free space and free space percent. i used to get all that info using the below piece of script. you just need to run against for any given database .
--   the second half of the script gives you all the details in GB which is more convenient to understood. please feel free to comment

SELECT name AS [logical_file_name] ,
physical_name AS [Physical Name],
size/128 AS [Total Size in MB],
size/128.0 - CAST(FILEPROPERTY(name, 'SpaceUsed') AS int)/128.0 AS [Available Space In MB],
(1.00 - (CAST(FILEPROPERTY(name, 'SpaceUsed') AS int)/128.0 / (size/128.0))) * 100.00 [pct_free_space]
FROM sys.database_files;
--SUM of space available used in a database
SELECT db_name(), file_type = CASE
WHEN type_desc = 'LOG' THEN 'LOG'
WHEN type_desc = 'ROWS' THEN 'DATA'
ELSE 'UNKNOWN'
END,
--CONVERT(DECIMAL(18,2), SUM(size/128.0)) [size_in_mb],
CONVERT(DECIMAL(18,2),SUM(size/128.0/1024.0)) [size_in_gb],
CONVERT(DECIMAL(18,2),SUM(size/128.0/1024) - SUM(size/128.0/1024 - CAST(FILEPROPERTY(name, 'SpaceUsed') AS int)/128.0/1024)) [used_space_in_gb],
CONVERT(DECIMAL(18,2),SUM(size/128.0/1024 - CAST(FILEPROPERTY(name, 'SpaceUsed') AS int)/128.0/1024)) [available_space_in_gb]
FROM sys.database_files
GROUP BY type_desc
SELECT
DB_NAME()DatabaseName,
f.[file_id],
f.name AS [File Name] ,
f.physical_name AS [Physical Name],
CAST((f.size/128.0) AS DECIMAL(15,2)) AS [File - Total Size In MB],
CAST(f.size/128.0 - CAST(FILEPROPERTY(f.name, 'SpaceUsed') AS int)/128.0 AS DECIMAL(15,2)) AS [File - Available Space In MB],
fg.name AS [Filegroup Name],
volume_mount_point [Disk Mount Point],
CONVERT(DECIMAL(18,2),total_bytes/1073741824.0) AS [Disk Total Size in GB], ---1GB = 1073741824 bytes
CONVERT(DECIMAL(18,2),available_bytes/1073741824.0) AS [Disk Available Size in GB],
CAST(CAST(available_bytes AS FLOAT)/ CAST(total_bytes AS FLOAT) AS DECIMAL(18,2)) * 100 AS [Disk Free Space %],
f.is_percent_growth,
file_system_type [File System Type]
FROM sys.database_files AS f WITH (NOLOCK)
INNER JOIN sys.master_files m on f.file_id = m.file_id
LEFT OUTER JOIN sys.data_spaces AS fg WITH (NOLOCK) ON f.data_space_id = fg.data_space_id
CROSS APPLY sys.dm_os_volume_stats(database_id, m.file_id)
WHERE m.database_id = DB_ID()
ORDER BY 6 OPTION (RECOMPILE)
