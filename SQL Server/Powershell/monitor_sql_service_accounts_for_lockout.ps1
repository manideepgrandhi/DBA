######## check !chqsqlsvr account

$cetsqlsvr_locked_out = get-aduser !cetsqlsvr -Properties lockedout | where-object {$_.LockedOut-eq $true}
if ($cetsqlsvr_locked_out -ne $null){

#SMTP server name
$smtpServer = "mailrelay.comcast.com"

#Creating a Mail object
$msg = new-object Net.Mail.MailMessage

#Creating SMTP server object
$smtp = new-object Net.Mail.SmtpClient($smtpServer)
#Email structure
[string]$from = Get-WmiObject -Class Win32_ComputerSystem | %{$_.Name}
$from = $from + ".cable.comcast.com"
$msg.From = $from
#$msg.ReplyTo = "stephen_kusen@cable.comcast.com"
$msg.To.Add("stephen_kusen@cable.comcast.com")
$msg.subject = "CRITICAL ALERT: CABLE\!cetsqlsvr Account Locked Out"
$msg.body = "Please get the CABLE\!cetsqlsvr account unlocked.  SQL L1 and L2 have the permissions to do this in the Active Directory Users and Computers tool, if installed."

#Sending email 
$smtp.Send($msg)


}


######## check !chqsqlsvr account

$chqsqlsvr_locked_out = get-aduser !chqsqlsvr -Properties lockedout | where-object {$_.LockedOut-eq $true}
if ($chqsqlsvr_locked_out -ne $null){

#SMTP server name
$smtpServer = "mailrelay.comcast.com"

#Creating a Mail object
$msg = new-object Net.Mail.MailMessage

#Creating SMTP server object
$smtp = new-object Net.Mail.SmtpClient($smtpServer)
#Email structure
[string]$from = Get-WmiObject -Class Win32_ComputerSystem | %{$_.Name}
$from = $from + ".cable.comcast.com"
$msg.From = $from
#$msg.ReplyTo = "stephen_kusen@cable.comcast.com"
$msg.To.Add("stephen_kusen@cable.comcast.com")
$msg.subject = "CRITICAL ALERT: CABLE\!chqsqlsvr Account Locked Out"
$msg.body = "Please get the CABLE\!chqsqlsvr account unlocked.  This is likely impacting scheduled jobs while this is locked out as most SQL Servers are leveraging this account.  SQL L1 and L2 have the permissions to do this in the Active Directory Users and Computers tool, if installed."

#Sending email 
$smtp.Send($msg)

}



######## check !netosqlrepl account

$netosqlrepl_locked_out = get-aduser !netosqlrepl -Properties lockedout | where-object {$_.LockedOut-eq $true}
if ($netosqlrepl_locked_out -ne $null){

#SMTP server name
$smtpServer = "mailrelay.comcast.com"

#Creating a Mail object
$msg = new-object Net.Mail.MailMessage

#Creating SMTP server object
$smtp = new-object Net.Mail.SmtpClient($smtpServer)
#Email structure
[string]$from = Get-WmiObject -Class Win32_ComputerSystem | %{$_.Name}
$from = $from + ".cable.comcast.com"
$msg.From = $from
#$msg.ReplyTo = "stephen_kusen@cable.comcast.com"
$msg.To.Add("stephen_kusen@cable.comcast.com")
$msg.subject = "CRITICAL ALERT: CABLE\!netosqlrepl Account Locked Out"
$msg.body = "Please get the CABLE\!netosqlrepl account unlocked.  This is potentially impacting SQL Server replication configurations."

#Sending email 
$smtp.Send($msg)

}

