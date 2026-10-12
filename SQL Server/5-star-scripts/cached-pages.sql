-- Title   : Cached pages
-- Purpose : Counts buffer-pool cached pages per index for a given table (dbo.Person in the sample) in the current database.
-- Source  : https://sqlservv.blogspot.com/2017/11/script-cached-pages.html
-- Posted  : 2017-11-20 (sqlservv.blogspot.com, 5star tag)

;WITH s_obj as
(
SELECT
OBJECT_NAME(OBJECT_ID) AS name, index_id ,allocation_unit_id, OBJECT_ID
FROM sys.allocation_units AS au
INNER JOIN sys.partitions AS p
ON au.container_id = p.hobt_id
AND (au.type = 1
OR au.type = 3)
 UNION ALL
 SELECT OBJECT_NAME(OBJECT_ID) AS name, index_id, allocation_unit_id, OBJECT_ID
FROM sys.allocation_units AS au
INNER JOIN sys.partitions AS p
ON au.container_id = p.partition_id
AND au.type = 2
), obj as (
SELECT
s_obj.name, s_obj.index_id, s_obj.allocation_unit_id, s_obj.OBJECT_ID, i.name IndexName, i.type_desc IndexTypeDesc
FROM s_obj
INNER JOIN sys.indexes i
ON i.index_id = s_obj.index_id
AND i.OBJECT_ID = s_obj.OBJECT_ID
)
 SELECT
COUNT(*) AS cached_pages_count, obj.name AS BaseTableName, IndexName, IndexTypeDesc FROM sys.dm_os_buffer_descriptors AS bd
INNER JOIN obj ON bd.allocation_unit_id = obj.allocation_unit_id
INNER JOIN sys.tables t ON t.object_id = obj.OBJECT_ID
WHERE database_id = DB_ID() AND obj.name = 'Person' AND schema_name(t.schema_id) = 'dbo'
GROUP BY obj.name, index_id, IndexName, IndexTypeDesc
ORDER BY cached_pages_count DESC;
