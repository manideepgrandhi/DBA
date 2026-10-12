-- Title   : SQL script to get blocking information
-- Purpose : Lists root blockers and blocked sessions (sysprocesses), plus a lock-level waiter/blocker query (Query2).
-- Source  : https://sqlservv.blogspot.com/2017/10/script-sql-script-to-get-blocking_21.html
-- Posted  : 2017-10-22 (sqlservv.blogspot.com, 5star tag)

-- List down all the blocking process or root blockers

    SELECT  DISTINCT p1.spid  AS [Blocking/Root Blocker SPID]
         , p1.[loginame] AS [RootBlocker_Login]
  , st.text AS [SQL Query Text]
         , p1.[CPU]
         , p1.[Physical_IO]
         , DB_NAME(p1.[dbid]) AS DBName
         , p1.[Program_name]
         , p1.[HostName]
         , p1.[Status]
         , p1.[CMD]
         , p1.[Blocked]
         , p1.[ECID] AS [ExecutionContextID]
    FROM  sys.sysprocesses p1
 INNER JOIN  sys.sysprocesses p2 ON p1.spid = p2.blocked AND p1.ecid = p2.ecid
 CROSS APPLY sys.dm_exec_sql_text(p1.sql_handle) st
 WHERE p1.blocked = 0
 ORDER BY p1.spid, p1.ecid

-- List Down all the blocked processes
    SELECT p2.spid AS 'Blocked SPID'
         , p2.blocked AS 'Blocking/Root Blocker SPID'
         , p2.[loginame] AS [BlockedSPID_Login]
         ,  st.text AS [SQL Query Text]
         , p2.[CPU]
         , p2.[Physical_IO]
         , DB_NAME(p2.[dbid]) AS DBName
         , p2.[Program_name]
         , p2.[HostName]
         , p2.[Status]
         , p2.[CMD]
         , p2.ECID AS [ExecutionContextID]
    FROM sys.sysprocesses p1
 INNER JOIN sys.sysprocesses p2 ON p1.spid = p2.blocked AND p1.ecid = p2.ecid
 CROSS APPLY sys.dm_exec_sql_text(p1.sql_handle) st

------------Query2-------------------

SELECT t1.resource_type AS [lock type], DB_NAME(resource_database_id) AS [database],
t1.resource_associated_entity_id AS [blk object],t1.request_mode AS [lock req],  -- lock requested
t1.request_session_id AS [waiter sid], t2.wait_duration_ms AS [wait time],       -- spid of waiter
(SELECT [text] FROM sys.dm_exec_requests AS r WITH (NOLOCK)                      -- get sql for waiter
CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle])
WHERE r.session_id = t1.request_session_id) AS [waiter_batch],
(SELECT SUBSTRING(qt.[text],r.statement_start_offset/2,
    (CASE WHEN r.statement_end_offset = -1
    THEN LEN(CONVERT(nvarchar(max), qt.[text])) * 2
    ELSE r.statement_end_offset END - r.statement_start_offset)/2)
FROM sys.dm_exec_requests AS r WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) AS qt
WHERE r.session_id = t1.request_session_id) AS [waiter_stmt],     -- statement blocked
t2.blocking_session_id AS [blocker sid],          -- spid of blocker
(SELECT [text] FROM sys.sysprocesses AS p          -- get sql for blocker
CROSS APPLY sys.dm_exec_sql_text(p.[sql_handle])
WHERE p.spid = t2.blocking_session_id) AS [blocker_batch]
FROM sys.dm_tran_locks AS t1 WITH (NOLOCK)
INNER JOIN sys.dm_os_waiting_tasks AS t2 WITH (NOLOCK)
ON t1.lock_owner_address = t2.resource_address OPTION (RECOMPILE);
