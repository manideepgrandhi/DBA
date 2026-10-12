-- Title   : Disk Space usage and database growth details
-- Purpose : Per-volume size/free/assigned space plus per-database-file size, free space, max size and growth headroom.
-- Source  : https://sqlservv.blogspot.com/2019/01/disk-space-usage-and-database-growth.html
-- Posted  : 2019-01-14 (sqlservv.blogspot.com, 5star tag)

--Latin1_General_CI_AI
--SQL_Latin1_General_CPI_CI_AS

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED

declare @rownum int=1;
declare @rowtotal int=0;

create table #volumeinfo
(
rownbr int identity(1,1),
volume_mount_point varchar(4000),
file_system_type varchar(50),
logical_volume_name varchar(254),
[total size(GB)] decimal(18,2),
[Available size (GB)] decimal(18,2),
[Space free %] decimal(18,2),
[total assigned(GB)] decimal(18,2),
[Remaining unassigned(GB)] decimal(18,2)
)

create table #dbsizes
(
Rownbr int identity(1,1),
databasename varchar(255),
logical_name varchar(255),
physical_name varchar(255),
sizemb decimal(15,3),
 max_sizemb decimal(15,3),
total_sizemb decimal(15,3),
free_spaceMB decimal(15,3),
statdate datetime
)

insert into #volumeinfo(
volume_mount_point,
file_system_type,
logical_volume_name,
[total size(GB)],
[Available size (GB)],
[space free %]
)

select distinct
vs.volume_mount_point,
vs.file_system_type,
vs.logical_volume_name,
convert(decimal(18,2),vs.total_bytes/1073741824.0) as [total size (GB)],
convert(decimal(18,2),vs.available_bytes/1073741824.0) as [available size(GB)],
cast(cast(vs.available_bytes as float)/cast(vs.total_bytes as float) as decimal(18,2))*100 as[space free%]
from sys.master_files as f with(nolock)
cross apply sys.dm_os_volume_stats(f.database_id,f.[file_id]) as vs option(recompile);

insert into #dbsizes(databasename,logical_name,physical_name,sizemb,max_sizemb,statdate)
select
db_name(database_id) as databasename,
name as logical_name,
physical_name,
(size*8)/1024 sizemb
,(case
when max_size >0 then (cast(max_size as bigint)*8)/1024
when max_size=0 then ((size*8)/1024)
when max_size=-1 then(size*8)/1024
when growth=0 then (size*8)/1024
else 0 end ) max_sizemb,
getdate()
from master.sys.master_files
--order by db_name(database_id),name

exec master.sys.sp_MSforeachdb '
use [?]
update DBS set
total_sizemb=size/128,
max_sizemb=(case when max_sizemb=2097152 and df.growth=0 then DBS.sizemb else max_sizemb end),
free_spaceMB=size/128.0-cast(fileproperty(name,"SpaceUsed") as int)/128.0
from #dbsizes DBS
inner join sys.database_files df on df.name collate Latin1_General_CI_AI=DBS.logical_name collate Latin1_General_CI_AI
and df.physical_name collate Latin1_General_CI_AI= DBS.physical_name collate Latin1_General_CI_AI
'
set @rowtotal=(select count(*) from #volumeinfo)
set @rownum=1;

while @rownum <=@rowtotal
begin
update vi set
[total assigned(GB)]=((select sum(DBS.max_sizemb) from #dbsizes DBS where 1=patindex(vi.volume_mount_point+'%',DBS.physical_name))/1024)
from #volumeinfo as vi where vi.rownbr=@rownum;

update vi set
vi.[remaining unassigned(GB)]=vi.[total size(GB)]-vi.[total assigned(GB)]
from #volumeinfo as vi
where vi.rownbr=@rownum;
set @rownum=@rownum+1;
end;

select @@servername [Server],
vi.volume_mount_point,
vi.file_system_type,
vi.logical_volume_name,
vi.[total size(GB)],
vi.[space free %],
vi.[total assigned (GB)],
vi.[remaining unassigned (GB)]
from #volumeInfo as VI
order by vi.volume_mount_point;

select
@@servername[server],
dbs.databasename,
dbs.logical_name,
dbs.physical_name,
cast(dbs.sizemb/1024 as decimal(10,3)) [size GB],
cast(dbs.free_spacemb/1024 as decimal(10,3)) [free space GB],
cast(dbs.max_sizeMB/1024 as decimal(10,3)) [max size GB],
cast(((dbs.max_sizemb-dbs.sizemb)+dbs.free_spaceMB)/1024 as decimal(10,3)) as [max growth GB],
(case when dbs.max_sizemb > 0 then
cast((((dbs.max_sizemb-((dbs.max_sizemb-dbs.sizemb)+dbs.free_spaceMB))/dbs.max_sizemb)*100) as decimal(10,2))
else -1 end) as [%full],
statdate [stat date]
from #dbsizes dbs
order by dbs.databasename,dbs.physical_name

drop table #dbsizes;
drop table #volumeinfo
