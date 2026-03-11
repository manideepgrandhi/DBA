SET NOCOUNT ON
--USE PPROD
GO
DECLARE @loop INT
DECLARE @USER sysname
 
IF OBJECT_ID('tempdb..#Orphaned') IS NOT NULL 
 BEGIN
  DROP TABLE #orphaned
 END
 
CREATE TABLE #Orphaned (UserName sysname, UserSID VARBINARY(85),IDENT INT IDENTITY(1,1))
 
INSERT INTO #Orphaned
EXEC sp_change_users_login 'report';
 
IF(SELECT COUNT(*) FROM #Orphaned) > 0
BEGIN
 SET @loop = 1
 WHILE @loop <= (SELECT MAX(IDENT) FROM #Orphaned)
  BEGIN
    SET @USER = (SELECT UserName FROM #Orphaned WHERE IDENT = @loop)
--    IF(SELECT COUNT(*) FROM sys.server_principals WHERE [Name] = @USER) <= 0
--     BEGIN
--        EXEC sp_addlogin @USER,'password'
--     END
     
    EXEC sp_change_users_login 'update_one',@USER,@USER
    PRINT @USER + ' link to DB user reset';
    SET @loop = @loop + 1
  END
END
SET NOCOUNT OFF
