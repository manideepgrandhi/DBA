> Around 10:45 PM CEST, please change the AUTO_UPDATE_STATISTICS_ASYNC to OFF for database M3FDBGRD.

USE [master]
GO
ALTER DATABASE [M3FDBGRD] SET AUTO_UPDATE_STATISTICS_ASYNC OFF WITH NO_WAIT
GO

> Start the "Blockings_capture" extended event session.

ALTER EVENT SESSION Blockings_Capture ON SERVER STATE = START;


>Reindex job starts at 11PM CEST,Adjusted the index settings table to execute maintenance on "MITPLO" table first.
Use the below query to check the status of reindexing.Around 12 indexes are there on the table(1 Clustered,11 non-clustered)


SELECT  *
  FROM [dba].[Minion].[IndexMaintLogDetails]
  where [ExecutionDateTime] >'2020-09-18 23:00:00.837'
  and TableName='MITPLO'
--and FragLevel between 10 and 20
and Status='Complete'
order by OpBeginDateTime desc

>Once reindex process completes on MITPLO,Change the AUTO_UPDATE_STATISTICS_ASYNC to ON

USE [master]
GO
ALTER DATABASE [M3FDBGRD] SET AUTO_UPDATE_STATISTICS_ASYNC ON WITH NO_WAIT
GO

> Start the "Blockings_capture" extended event session.

ALTER EVENT SESSION Blockings_capture ON SERVER STATE = STOP;