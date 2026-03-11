1| > Around 10:45 PM CEST, please change the AUTO_UPDATE_STATISTICS_ASYNC to OFF for database dbxyz.
2| 
3| USE [master]
4| GO
5| ALTER DATABASE [dbxyz] SET AUTO_UPDATE_STATISTICS_ASYNC OFF WITH NO_WAIT
6| GO
7| 
8| > Start the "Blockings_capture" extended event session.
9| 
10| ALTER EVENT SESSION Blockings_Capture ON SERVER STATE = START;
11| 
12| 
13| >Reindex job starts at 11PM CEST,Adjusted the index settings table to execute maintenance on "MITPLO" table first.
14| Use the below query to check the status of reindexing.Around 12 indexes are there on the table(1 Clustered,11 non-clustered)
15| 
16| 
17| SELECT  *
18|   FROM [dba].[Minion].[IndexMaintLogDetails]
19|   where [ExecutionDateTime] >'2020-09-18 23:00:00.837'
20|   and TableName='MITPLO'
21| --and FragLevel between 10 and 20
22| and Status='Complete'
23| order by OpBeginDateTime desc
24| 
25| >Once reindex process completes on MITPLO,Change the AUTO_UPDATE_STATISTICS_ASYNC to ON
26| 
27| USE [master]
28| GO
29| ALTER DATABASE [dbxyz] SET AUTO_UPDATE_STATISTICS_ASYNC ON WITH NO_WAIT
30| GO
31| 
32| > Start the "Blockings_capture" extended event session.
33| 
34| ALTER EVENT SESSION Blockings_capture ON SERVER STATE = STOP;