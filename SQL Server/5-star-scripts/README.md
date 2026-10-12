# 5-star SQL Server scripts

Scripts copied from posts tagged **5star** on [sqlservv.blogspot.com](https://sqlservv.blogspot.com/). Code is unchanged from the blog; only line breaks were restored where needed.

| Script | What it does | Original post |
|---|---|---|
| [disk-space-and-database-growth.sql](./disk-space-and-database-growth.sql) | Per-volume size/free/assigned space plus per-database-file size, free space, max size and growth headroom. | [blog post](https://sqlservv.blogspot.com/2019/01/disk-space-usage-and-database-growth.html) |
| [cached-pages.sql](./cached-pages.sql) | Counts buffer-pool cached pages per index for a given table (dbo.Person in the sample) in the current database. | [blog post](https://sqlservv.blogspot.com/2017/11/script-cached-pages.html) |
| [blocking-information.sql](./blocking-information.sql) | Lists root blockers and blocked sessions (sysprocesses), plus a lock-level waiter/blocker query (Query2). | [blog post](https://sqlservv.blogspot.com/2017/10/script-sql-script-to-get-blocking_21.html) |
| [get-driveinfo.ps1](./get-driveinfo.ps1) | Get-Driveinfo function: reports size/used/free/% free per local drive on a remote server, with low-space warnings. | [blog post](https://sqlservv.blogspot.com/2017/07/powershell-script-to-find-disk-space_21.html) |
| [database-files-free-space.sql](./database-files-free-space.sql) | Uses sp_MSForEachDB to list size, free MB and free % of every data/log file on the instance. | [blog post](https://sqlservv.blogspot.com/2017/04/script-to-find-free-space-for-all-data_24.html) |
| [disk-free-space.sql](./disk-free-space.sql) | Disk/volume total size, free space and % free via sys.dm_os_volume_stats (two variants). | [blog post](https://sqlservv.blogspot.com/2017/04/sql-script-to-get-disk-free-space_22.html) |
| [database-size-and-free-space.sql](./database-size-and-free-space.sql) | Current database file sizes, free space and %, totals by data/log in GB, and file + disk details. | [blog post](https://sqlservv.blogspot.com/2017/04/sql-query-to-get-database-size-and-free_22.html) |

Related older copies in the parent folder: `blocking.txt` / `Blocking_chain.txt` share most of the blocking query, and `Space.txt` contains variants of the disk/database space queries.
