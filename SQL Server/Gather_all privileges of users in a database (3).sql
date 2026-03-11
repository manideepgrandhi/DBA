--1st script

/****** Object: StoredProcedure [dbo].[usp_get_object_permissions] Script Date: 10/07/2011 14:28:21 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- run this script from the user database
--exec usp_get_object_permissions
--drop proc usp_get_object_permissions
--go
CREATE PROCEDURE [dbo].[usp_get_object_permissions]
AS

set nocount on
set quoted_identifier off
declare @as_ObjectName sysname
set @as_ObjectName = NULL

--database owner info
select 'alter authorization on database::['+db_name()+'] to ['+ suser_sname(owner_sid)+']'
AS '--owner of database when script was created'
from master.sys.databases where name = db_name()


--drop and recreate users

--select '-- It is not always necessary to drop and recreate the users it will depend on the circumstances under which you need to run this script'

--select 'drop user [' + name + ']' from sys.database_principals 
--where principal_id > 4 and owning_principal_id is NULL 
--and type != 'A'
--order by name

select 'CREATE USER [' + dp.name collate database_default + '] FOR LOGIN [' + sp.name + ']'+
case dp.type 
when 'G' then ' '
else
' WITH DEFAULT_SCHEMA=['+dp.default_schema_name + ']' 
end
as '-- by default Orphaned users will not be recreated'
from sys.server_principals sp 
inner join sys.database_principals dp on dp.sid = sp.sid 
where dp.principal_id > 4 and dp.owning_principal_id is NULL and sp.name <> ''
order by dp.name

-- Recreate the User defined roles
select '-- server created roles should be added by the correct processes'

select 'CREATE ROLE ['+ name + '] AUTHORIZATION ['+USER_NAME(owning_principal_id)+']'
from sys.database_principals 
where name != 'public' and type = 'R' and is_fixed_role = 0

-- recreate application roles

select 'CREATE APPLICATION ROLE ['+ name + '] with password = '+QUOTENAME('insertpwdhere','''')+' ,default_schema = ['+default_schema_name+']'
from sys.database_principals where type = 'A'


-- ADD ROLE MEMBERS

SELECT 'EXEC sp_addrolemember [' + dp.name + '], [' + USER_NAME(drm.member_principal_id) + '] ' AS [-- AddRolemembers]
FROM sys.database_role_members drm
INNER JOIN sys.database_principals dp ON dp.principal_id = drm.role_principal_id
where USER_NAME(drm.member_principal_id) != 'dbo'
order by drm.role_principal_id


-- CREATE GRANT Object PERMISSIONS SCRIPT

SELECT replace(state_desc,'_with_grant_option','') + ' '+ permission_name + ' ON [' 
+ OBJECT_SCHEMA_NAME(major_id) + '].[' + OBJECT_NAME(major_id) + ']'+
case minor_id 
when 0 then ' '
else
' (['+col_name(sys.database_permissions.major_Id, sys.database_permissions.minor_id) + '])' 
end
+' TO [' + USER_NAME(grantee_principal_id)+']' +
case 
when state_desc like '%with_grant_option' then ' with grant option'
else
' '
end
as '-- object/column permissions'
FROM sys.database_permissions (NOLOCK)
WHERE class not in (0,3) and major_id = ISNULL(OBJECT_ID(@as_ObjectName), major_id)
--AND OBJECT_SCHEMA_NAME(major_id) != 'SYS'
ORDER BY USER_NAME(grantee_principal_id),OBJECT_SCHEMA_NAME(major_id), OBJECT_NAME(major_id)

--SCHEMA permissions
SELECT replace(state_desc,'_with_grant_option','') + ' '+ permission_name + ' ON SCHEMA::[' 
+ SCHEMA_NAME(major_id) + ']'+
+' TO [' + USER_NAME(grantee_principal_id)+']' +
case 
when state_desc like '%with_grant_option' then ' with grant option'
else
' '
end
as '-- Schema permissions'
FROM sys.database_permissions (NOLOCK)
WHERE class_desc = 'SCHEMA'
ORDER BY USER_NAME(grantee_principal_id),SCHEMA_NAME(major_id)

SELECT replace(state_desc,'_with_grant_option','') + ' '+ permission_name + 
' TO [' + USER_NAME(grantee_principal_id)+']' +
case 
when state_desc like '%with_grant_option' then ' with grant option'
else
' '
end
FROM sys.database_permissions (NOLOCK)
WHERE permission_name = 'VIEW DEFINITION' and class_desc = 'database'
ORDER BY USER_NAME(grantee_principal_id)




--2nd script

--USE [LMGHRDB]   --change DB name
--GO
--DECLARE	@return_value int
--EXEC	@return_value = [dbo].[usp_get_object_permissions]
--SELECT	'Return Value' = @return_value
--GO
