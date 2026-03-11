
Import-Module sqlps

function Get-DatabaseSize{
<#
 
.SYNOPSIS
Scripts out database size properties
 
.DESCRIPTION
This module will script sql server database sizes for all databases on a given server instance
 
.PARAMETER serverInstance
The name of the sql server instance that the jobs reside on
 
.PARAMETER IncludeSystemDBs
Switch to include system databases in results 
 
.EXAMPLE
Get database sizes for all databases including system databases
Get-DatabaseSize -serverInstance INHYNMGRANDHI01 -IncludeSystemDBs|out-gridview

$ServerList = Get-Content "C:\temp\dbservers.txt"
$objects = @();
foreach ( $server in $ServerList )
{
$objects +=Get-DatabaseSize -serverInstance $server -IncludeSystemDBs

}$objects|out-gridview
 
.EXAMPLE 
Get database sizes for all databases via pipeline
@('INHYNMGRANDHI01', 'INHYNMGRANDHI01', 'INHYNMGRANDHI01') | Get-DatabaseSize -IncludeSystemDBs |out-gridview

@('INHYNMGRANDHI01', 'INHYNMGRANDHI01', 'INHYNMGRANDHI01') | Get-DatabaseSize |format-table
 
.NOTES
This assumes that you have access to the sql server via windows-authentication. 
 
#>
 
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [string]$serverInstance,
        [Parameter(Mandatory=$false,Position=1,ValueFromPipeline=$false)]
        [switch]$IncludeSystemDBs
    )
    begin{
        $objects = @();
        $srvConn = New-Object microsoft.SqlServer.Management.Common.ServerConnection
        $srvConn.LoginSecure = $true;
        $srvConn.ServerInstance = $serverInstance
        $server = New-Object microsoft.SqlServer.Management.Smo.Server $srvConn
    }
    process{
        foreach($db in $server.Databases | where{$_.IsSystemObject -eq $IncludeSystemDBs -or -not $_.IsSystemObject})
        {
        $db.Size=$db.Size/1024;
        $db.DataSpaceUsage=$db.DataSpaceUsage/1024/1024;
        

        }
            $logSize = 0;
                       $UsedLogSpace = 0;
            foreach($log in $db.LogFiles){
                $logSize += $log.Size
                $UsedLogSpace += $log.UsedSpace
                 
            }
            $obj = New-Object -TypeName PSObject -Property @{
                ServerInstance = $serverInstance  #server properties
                Edition=$server.Edition           #server properties
                ProductLevel=$server.ProductLevel #server properties
                version=$server.version #server properties
                CompatibilityLevel=$db.CompatibilityLevel               
                DatabaseName = $db.Name
                DatabaseSizeMB = $db.Size
              #  $SQLDBLogSizeGB = $SQLDBLogSizeMB / 1000
                #$SQLDBLogSizeGB = [Math]::Round($SQLDBLogSizeGB,2)
                DataSpaceUsageKB = $db.DataSpaceUsage
                IndexSpaceUsageKB = $db.IndexSpaceUsage
                UsedLogSpaceKB = $UsedLogSpace
                LogSizeKB = $logSize
            }
            
            }
            $objects += $obj;
        
        $objects | SELECT ServerInstance,Edition,ProductLevel,version,DatabaseName,CompatibilityLevel, DatabaseSizeMB, DataSpaceUsagekb, IndexSpaceUsagekb, UsedLogSpacekb, LogSizekb
    
    end{
        $srvConn.Disconnect();
    }


@('INHYNMGRANDHI01') | Get-DatabaseSize |format-table

