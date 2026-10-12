# Title   : PowerShell script to find disk space
# Purpose : Get-Driveinfo function: reports size/used/free/% free per local drive on a remote server, with low-space warnings.
# Source  : https://sqlservv.blogspot.com/2017/07/powershell-script-to-find-disk-space_21.html
# Posted  : 2017-07-21 (sqlservv.blogspot.com, 5star tag)

function Get-Driveinfo
{

[cmdletbinding()] # Opens Commandlets
param( # Sets up Parameters for Functions
[parameter(Mandatory = $True)][string]$ComputerName, # Computer name to run report against
[parameter()][Switch]$Notepad # Output to Text File or not
)
$erroractionpreference = “SilentlyContinue”
$ComputerName = $ComputerName.toUpper() # Converts Server name to all Caps
[bool]$OID = $false
if (!(Test-Connection -computername $ComputerName -count 1 -quiet)) # Test Connections to Server
{
Write-host "`r`n`r`n`tUnable to reach Server $ComputerName" # Display message if unable to communicate
}
$Date = Get-Date
Write-Output "Reboot Report for Server $Computername run on $Date" > $LocalOut # Header for Output file
# Identifies all local hard drives on remote server
$OSInfo = (Get-WmiObject -computername $ComputerName -class win32_operatingsystem)
if ($OSInfo -eq $null)
{
[bool]$OID = $True
$Creds = Get-Credential -message "Enter Domain\ID that has Administrator Permissions on $ComputerName"
$OSInfo = (Get-WmiObject -Credential $Creds -computername $ComputerName -class win32_operatingsystem)
if ($OSInfo -eq $null)
{
Write-host "`tID/Password has no rights on server`r`n`tPlease try again "
Break
}
}

if ($OSInfo.caption |select-string -pattern "2000" -simplematch)
{
if ($OID -eq $false)
{$AllDrives = Get-WmiObject -computer $ComputerName Win32_Logicaldisk | Where-Object -FilterScript {$_.DriveType -eq "3"} |select DeviceID, FreeSpace, Size }
Else
{$AllDrives = Get-WmiObject -Credential $Creds -computer $ComputerName Win32_Logicaldisk | Where-Object -FilterScript {$_.DriveType -eq "3"} |select DeviceID, FreeSpace, Size}
$DateStamp = Get-Date
$Output = "`r`n`r`nServer = $ComputerName`r`nChecked on $DateStamp`r`n`r`nDrive`t Size`t Used`t Free`t% Free`r`n" # Displays header
foreach ($Drive in $AllDrives) # Starts Loop thru each Drive
{
[int]$PercentFree = ($Drive.FreeSpace / $Drive.size)*100 # Calculates % Free on Drive
$Size = ([int](($Drive.size /1gb))) # Calculates Total Size in Gig
$FreeSpace = ([int](($Drive.FreeSpace /1gb)*10))/10 # Calculates Free Space in Gig
[string]$DriveLetter = $Drive.DeviceID # Isolates Drive Letter
if ([int]$FreeSpace -eq $Freespace) {[string]$FreeS = "$FreeSpace.0 GB"} # Free Size OutPut information
Else {[string]$FreeS = "$FreeSpace GB" } # Free Size OutPut information
[string]$SizeS = "$Size GB" # Total Size OutPut information
[string]$Percent = "$PercentFree%" # Total Percent output Information
$Used = (([int](($drive.capacity - $drive.freespace)/1gb)*10))/10
[string]$UsedS = "$Used GB"
$SP1 = " " * ( 10 - $SizeS.length ) # Extra Spacing for Output
$SP2 = " " * ( 14 - $FreeS.length ) # Extra Spacing for Output
$SP3 = " " * ( 9 - $Percent.length) # Extra Spacing for Output
$sp5 = " " * ( 14 - $UsedS.length) # Extra Spacing for Output
#if (($PercentFree -lt "10") -and ($PercentFree -gt "5"))
# { $Alert = " <- Low Drive Space Warning" }
#Elseif ($PercentFree -le "5")
if ($PercentFree -le "5")
{ $Alert = " <- LOW DRIVE SPACE ALERT"}
else
{ $Alert = "" }
$OutPut += " $DriveLetter$SP1$Sizes$sp5$UsedS$Sp2$FreeS$SP3$Percent$Alert`r`n" # Displays Output
}
}
Else
{
if ($OID -Eq $false)
{
$AllDrives = Get-WmiObject -computer $ComputerName Win32_volume | Where-Object -FilterScript {($_.DriveType -eq "3") -and ($_.name -notlike "\\*")} |select name, freespace, capacity |sort name
$AllDrives1 = Get-WmiObject -computer $ComputerName Win32_Logicaldisk | Where-Object -FilterScript {$_.DriveType -eq "3"} |select DeviceID, FreeSpace, Size
}
else
{
$AllDrives = Get-WmiObject -Credential $Creds -computer $ComputerName Win32_volume | Where-Object -FilterScript {($_.DriveType -eq "3") -and ($_.name -notlike "\\*")} |select name, freespace, capacity |sort name
$AllDrives1 = Get-WmiObject -Credential $Creds -computer $ComputerName Win32_Logicaldisk | Where-Object -FilterScript {$_.DriveType -eq "3"} |select DeviceID, FreeSpace, Size
}
$DateStamp = Get-Date
$Output = "`r`n`r`nServer = $ComputerName`r`nChecked on $DateStamp" # Displays header
[int]$SP1L = "9"
foreach ($drive in $Alldrives)
{
$DRName = $drive.name
if ($DRName.length -gt $SP1L) { $SP1L = $drive.name.length}
}
$SP4 = " " * ($SP1L + "4" - $Drive.name.length)
$Output += "`r`n`r`nDrive$sp4 Size Used`t Free % Free`r`n"
foreach ($Drive in $AllDrives) # Starts Loop thru each Drive
{
[int]$PercentFree = ($Drive.FreeSpace / $Drive.capacity)*100 # Calculates % Free on Drive
$Size = ([int](($Drive.capacity /1gb))) # Calculates Total Size in Gig
$FreeSpace = ([int](($Drive.FreeSpace /1gb)*10))/10 # Calculates Free Space in Gig
[string]$DriveLetter = $Drive.name + (" " * ($SP1L- $Drive.name.length))
# Isolates Drive Letter
if ([int]$FreeSpace -eq $Freespace) {[string]$FreeS = "$FreeSpace.0 GB"} # Free Size OutPut information
Else {[string]$FreeS = "$FreeSpace GB" } # Free Size OutPut information
[string]$SizeS = "$Size GB" # Total Size OutPut information
[string]$Percent = "$PercentFree%" # Total Percent output Information
$Used = (([int](($drive.capacity - $drive.freespace)/1gb)*10))/10
[string]$UsedS = "$Used GB"

$SP1 = " " * ( 10 - $SizeS.length ) # Extra Spacing for Output
$SP2 = " " * ( 14 - $FreeS.length ) # Extra Spacing for Output
$SP3 = " " * ( 9 - $Percent.length) # Extra Spacing for Output
$sp5 = " " * ( 14 - $UsedS.length) # Extra Spacing for Output

if ($PercentFree -le "5")
{ $Alert = " <- LOW DRIVE SPACE ALERT"}
else
{ $Alert = "" }
$OutPut += " $DriveLetter$SP1$Sizes$sp5$UsedS$Sp2$FreeS$SP3$Percent$Alert`r`n" # Displays Output
}
$AppDrive = Compare-Object $AllDrives.name.substring(0,2) $AllDrives1.deviceid | ? {$_.Sideindicator -eq "=>"}
if ($AppDrive.InputObject.length -gt "0")
{
$Output += "`r`n`tApplication generated drive found on server`r`nDrive`t Size`t Free %`t Free`r`n"
foreach ($line in $AppDrive)
{
$Drive = $AllDrives1 |? {$_.Deviceid -eq $line.inputobject }
[int]$PercentFree = ($Drive.FreeSpace / $Drive.size)*100 # Calculates % Free on Drive
$Size = ([int](($Drive.size /1gb))) # Calculates Total Size in Gig
$FreeSpace = ([int](($Drive.FreeSpace /1gb)*10))/10 # Calculates Free Space in Gig
[string]$DriveLetter = $Drive.DeviceID # Isolates Drive Letter
if ([int]$FreeSpace -eq $Freespace) {[string]$FreeS = "$FreeSpace.0 GB"} # Free Size OutPut information
Else {[string]$FreeS = "$FreeSpace GB" } # Free Size OutPut information
[string]$SizeS = "$Size GB" # Total Size OutPut information
[string]$Percent = "$PercentFree%" # Total Percent output Information
$Used = (([int](($drive.capacity - $drive.freespace)/1gb)*10))/10
[string]$UsedS = "$Used GB"
$SP1 = " " * ( 10 - $SizeS.length ) # Extra Spacing for Output
$SP2 = " " * ( 14 - $FreeS.length ) # Extra Spacing for Output
$SP3 = " " * ( 9 - $Percent.length) # Extra Spacing for Output
$sp5 = " " * ( 14 - $UsedS.length) # Extra Spacing for Output
if (($PercentFree -lt "10") -and ($PercentFree -gt "5"))
{ $Alert = " <- Low Drive Space Warning" }
Elseif ($PercentFree -le "5")
{ $Alert = " <- LOW DRIVE SPACE ALERT"}
else
{ $Alert = "" }
$OutPut += " $DriveLetter$SP1$Sizes$sp5$UsedS$Sp2$FreeS$SP3$Percent$Alert`r`n" # Displays Output
}
}

}
$OutPut # Output to Screen
if ($Notepad) # Runs is Notepad is selected
{
[string]$LocalOut = $env:Temp+"\Driveinfo.txt" # Defines Output for Text file
$Output >$LocalOut # Saves Output to Text file
Notepad $LocalOut # Opens Text file
}
}
