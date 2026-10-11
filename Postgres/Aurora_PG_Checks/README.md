# aurora_pg_check.sh - Aurora PostgreSQL health checks with the AWS CLI

`aurora_pg_check.sh` (v1.0.0) runs a read-only health check of Amazon Aurora PostgreSQL
clusters using the AWS CLI v2: cluster topology, versions and maintenance, configuration,
backups, CloudWatch metrics and recent RDS events. Every check is reported as
**OK / WARN / CRIT** (plus INFO, SKIP and ERROR) with the reason, as text, JSON or HTML, and the
exit code tells cron or a CI job the overall result. It can e-mail or post the problems to a webhook.

It is strictly **read-only**: it only calls `describe-*` and `get-*` operations. It never
modifies, reboots, upgrades or tags anything.

```
aurora_pg_checks/
├── aurora_pg_check.sh              main script (options, AWS calls, output, alerts)
├── lib/checks.jq                   check logic (pure jq over the AWS JSON)
├── lib/render.jq                   summary, text / HTML rendering, alert payload
├── aurora_pg_check.conf.example    config file template
├── EXAMPLES.md                     usage scenarios
└── tests/
    ├── mock/aws                    stub AWS CLI (canned JSON, 7 scenarios)
    ├── run_tests.sh                139 assertions, all scenarios and output formats
    └── validate_cli.sh             replays every AWS call through the real CLI v2 parser
```

## Requirements

* Bash 4.4+, `jq` 1.6+, **AWS CLI v2** (v1 is refused: it lacks `--no-cli-pager` and
  `describe-db-major-engine-versions`).
* Credentials: a profile, SSO, environment variables or an instance/task role. The script never
  takes keys on the command line or in its config file.
* For alerts: `mail`/`mailx`/`sendmail` for e-mail, `curl` for webhooks.

## Quick start

```bash
./aurora_pg_check.sh -P dba-prod -r ap-south-1                 # all aurora-postgresql clusters in Mumbai
./aurora_pg_check.sh -P dba-prod -r us-east-1 -c orders-prod -q # one cluster, show only problems
./aurora_pg_check.sh -P dba-prod --all-regions -f html -o /tmp/aurora.html
./aurora_pg_check.sh --list-thresholds                         # every threshold and its default
./aurora_pg_check.sh -r us-east-1 --dry-run                    # print the AWS calls, call nothing
```

## What it checks, and why it matters for Aurora PostgreSQL

Select groups with `--checks` / `--exclude-checks` (`cluster,versions,config,backups,metrics,events`).
Per-instance checks are folded into one row per cluster; the per-instance detail lines are shown
under every WARN/CRIT row (or for all rows with `-D`).

### cluster - topology and availability
| Check | OK / WARN / CRIT | Why |
|---|---|---|
| `cluster_status` | `available` OK; `stopped`, `modifying`, `upgrading`, `backing-up`... WARN; `failed`, `inaccessible-encryption-credentials*`, `incompatible-*` CRIT | Anything but available means reduced service or an operation in flight. |
| `instance_status` | all `available` OK; transient states WARN; `failed`, `storage-full`, `incompatible-*` CRIT | A reader that is not available is not a failover target. |
| `writer` | exactly one writer OK; none CRIT (WARN for a global-database secondary) | No writer = no writes. |
| `reader_count` | readers < `min_readers` WARN | Without a reader, failover must create a new instance (minutes of downtime instead of ~30 s). |
| `az_spread` | instances in fewer than `min_azs` AZs WARN | All instances in one AZ do not survive an AZ outage. |
| `instance_class` | mixed classes WARN | A failover to a smaller reader can overload the new writer. Promotion tiers are listed. |
| `serverless_v2` | min ACU = max ACU WARN; min 0 noted (auto-pause) | Serverless v2 needs headroom between min and max ACU. |

### versions - engine, maintenance, certificates
| Check | Rule | Why |
|---|---|---|
| `engine_version` | version `deprecated` CRIT (`describe-db-engine-versions --include-all`) | Deprecated versions are force-upgraded. |
| `support_lifecycle` | end of Aurora standard support within `support_warn_days` WARN, past it CRIT (`describe-db-major-engine-versions`) | After standard support ends the cluster runs on **RDS Extended Support**, which is billed per vCPU-hour, or is upgraded automatically if extended support is disabled. |
| `upgrade_targets` | INFO list of newer minor / major targets; WARN if `minor_behind_warn` > 0 and that many minors exist | Planning; minors carry security and bug fixes. |
| `pending_maintenance` | any action WARN; auto-applied/forced within `maint_crit_days` CRIT (`describe-pending-maintenance-actions`) | OS updates and minor upgrades restart instances. You want to choose when. |
| `auto_minor_upgrade` | off on any instance WARN (INFO with `require_auto_minor_upgrade=0`) | |
| `ca_certificate` | CA (`describe-certificates`) or server certificate expiring within `cert_warn_days` WARN, `cert_crit_days` CRIT, expired CRIT | Clients using `sslmode=verify-full` fail when the CA expires. Rotation needs a restart. |

### config - configuration hygiene
| Check | Rule | Why |
|---|---|---|
| `cluster_param_apply` | any member not `in-sync` (e.g. `pending-reboot`) WARN | Static parameters (shared_buffers, max_connections...) do nothing until a reboot. The next unplanned restart applies them. |
| `instance_param_apply` | any DB parameter group not `in-sync` WARN | Same, for instance-level groups. |
| `deletion_protection` | off WARN | One API call can delete the cluster. |
| `storage_encrypted` | off WARN | Encryption can only be added by snapshot + restore. |
| `iam_db_auth` | INFO (WARN with `require_iam_auth=1`) | |
| `public_access` | any `PubliclyAccessible` instance WARN (CRIT with `public_access_crit=1`) | The endpoint resolves to a public IP. Only security groups protect it. |
| `log_exports` | `postgresql` not in CloudWatch log exports WARN | Without it, logs are lost after the instance's local retention. |
| `performance_insights` | off, or retention < `pi_min_retention_days` WARN | PI is the main tool for wait-event analysis on Aurora. |
| `enhanced_monitoring` | interval 0 (off) or > `em_max_interval` WARN | OS-level metrics (per-process CPU and memory). |
| `copy_tags_to_snapshot` | off WARN | Snapshot cost allocation and tag-based retention. |

### backups
| Check | Rule | Why |
|---|---|---|
| `backup_retention` | < `backup_retention_warn` WARN, < `backup_retention_crit` CRIT | It is your point-in-time-recovery window. |
| `restore_lag` | now − `LatestRestorableTime` > `restore_lag_warn_min` / `_crit_min` | Normally ~5 min. A growing lag means continuous backup is not keeping up. |
| `automated_snapshot` | newest automated cluster snapshot older than `auto_snapshot_warn_hours` / `_crit_hours`; none on a cluster older than 2 days CRIT | Daily snapshots should exist. |
| `manual_snapshots` | count > `manual_snapshot_count_warn` WARN (100 per region is the default quota); optional max age | Shows manual / AWS Backup counts and the newest one. |
| `backup_window` | overlaps the weekly maintenance window WARN | Backups and maintenance should not overlap. |

### metrics - CloudWatch over `--lookback` (default 24h, `--period` 300 s)
All queries for a region go in batched `get-metric-data` calls (up to 500 queries each).
"peak" = the worst period value in the window. Low-is-bad metrics use the lowest value.

| Metric (stat) | Scope | Default WARN / CRIT | Why |
|---|---|---|---|
| CPUUtilization (Average) | all | > 80 / > 95 % | Saturation. |
| FreeableMemory (Minimum) | all | < 1024 / < 256 MiB | Low memory → swapping, OOM restarts. |
| DatabaseConnections (Maximum) | all | > 80 / > 95 % of max_connections | max_connections is read from the parameter group. With the default formula it is estimated from instance memory (or max ACU × 2 GiB for serverless). Otherwise optional absolute `conn_warn`/`conn_crit`. |
| AuroraReplicaLag (Maximum) | readers | > 1000 / > 10000 ms | Stale reads; slow failover catch-up. |
| AuroraReplicaLagMaximum (Maximum) | cluster | same | Worst reader, cluster level. |
| FreeLocalStorage (Minimum) | all | < 10240 / < 2048 MiB | Temp files and logs. When it is full, sorts and hashes fail. |
| DiskQueueDepth (Average) | all | > 20 / > 100 | I/O backlog. |
| Read/WriteLatency (Average) | all | > 20 / > 100 ms | |
| Deadlocks (Average) | all | any / > 0.1 per s | Shown with an estimated count for the window. |
| BufferCacheHitRatio (Average) | all | < 95 / < 90 % | The working set no longer fits in memory. |
| **MaximumUsedTransactionIDs** (Maximum) | writer | > 500M / > 1B | **Transaction ID wraparound**: at ~2.1B Postgres stops accepting writes. Growth means (auto)vacuum freeze is not keeping up: long transactions, abandoned slots, prepared transactions. |
| TransactionLogsDiskUsage (Maximum) | writer | > 10 / > 50 GiB | WAL held back, usually by logical replication slots. |
| ReplicationSlotDiskUsage (Maximum) | writer | > 10 / > 50 GiB | An inactive slot retains WAL indefinitely. |
| OldestReplicationSlotLag (Maximum) | writer | > 1 / > 10 GiB | Lagging logical consumer (DMS, Debezium...). |
| ServerlessDatabaseCapacity (Maximum) | serverless | INFO | ACU actually used. |
| ACUUtilization (Maximum) | serverless | > 90 / > 99 % | Pinned at max ACU = capacity-bound. Raise max ACU. |

A metric with no datapoints is reported as SKIP (e.g. no replication slots).

### events - `describe-events` for the cluster and its instances (lookback, capped at 14 days)
`failure` / `low storage` events are CRIT. `failover`, `availability` (restart/shutdown) and `recovery` events are WARN.
More than `failover_crit_count` failover events is CRIT. Other events are INFO. The newest `events_show`
events are listed.

### Thresholds
Override with `-s KEY=VALUE` (repeatable) or `KEY = VALUE` lines in the config file. High-is-bad
metrics trigger when the value is **greater than** the threshold, low-is-bad ones when **less than**.
Current defaults (`./aurora_pg_check.sh --list-thresholds`):

```
KEY                            VALUE        MEANING
min_readers                    1            cluster: WARN if fewer reader instances
min_azs                        2            cluster: WARN if instances span fewer AZs (capped at instance count)
support_warn_days              180          versions: WARN when Aurora standard support of the major ends within N days
minor_behind_warn              0            versions: WARN if N+ newer minor versions exist (0 = report only)
maint_crit_days                7            versions: CRIT if a pending action is auto-applied within N days
require_auto_minor_upgrade     1            versions: 1 = WARN when auto minor version upgrade is off, 0 = INFO
cert_warn_days                 60           versions: WARN if CA/server certificate expires within N days
cert_crit_days                 14           versions: CRIT if it expires within N days
require_iam_auth               0            config: 1 = WARN when IAM DB authentication is off
public_access_crit             0            config: 1 = publicly accessible instance is CRIT instead of WARN
pi_min_retention_days          7            config: WARN if Performance Insights retention is shorter
em_max_interval                60           config: WARN if enhanced monitoring is off or coarser (seconds)
backup_retention_warn          7            backups: WARN if retention (days) below
backup_retention_crit          3            backups: CRIT if retention (days) below
restore_lag_warn_min           15           backups: WARN if LatestRestorableTime lags more (minutes)
restore_lag_crit_min           60           backups: CRIT above (minutes)
auto_snapshot_warn_hours       26           backups: WARN if newest automated snapshot is older (hours)
auto_snapshot_crit_hours       50           backups: CRIT above (hours)
manual_snapshot_max_age_days   0            backups: WARN if no manual snapshot newer than N days (0 = off)
manual_snapshot_count_warn     80           backups: WARN if a cluster has more manual snapshots
cpu_warn                       80           metrics: CPUUtilization peak period average (%)
cpu_crit                       95           
mem_free_warn_mb               1024         metrics: FreeableMemory minimum (MiB, low = bad)
mem_free_crit_mb               256          
max_connections                0            metrics: force max_connections (0 = derive from parameter group)
conn_pct_warn                  80           metrics: DatabaseConnections peak as % of max_connections
conn_pct_crit                  95           
conn_warn                      0            metrics: absolute connection thresholds when max is unknown (0 = off)
conn_crit                      0            
replica_lag_warn_ms            1000         metrics: AuroraReplicaLag / AuroraReplicaLagMaximum (ms)
replica_lag_crit_ms            10000        
local_storage_warn_mb          10240        metrics: FreeLocalStorage minimum (MiB, low = bad)
local_storage_crit_mb          2048         
disk_queue_warn                20           metrics: DiskQueueDepth peak period average
disk_queue_crit                100          
read_latency_warn_ms           20           metrics: ReadLatency peak period average (ms)
read_latency_crit_ms           100          
write_latency_warn_ms          20           metrics: WriteLatency peak period average (ms)
write_latency_crit_ms          100          
deadlocks_warn                 0            metrics: Deadlocks peak rate (/s); 0 = any deadlock warns
deadlocks_crit                 0.1          
cache_hit_warn                 95           metrics: BufferCacheHitRatio lowest period average (%, low = bad)
cache_hit_crit                 90           
xid_warn                       500000000    metrics: MaximumUsedTransactionIDs (wraparound at ~2.1B)
xid_crit                       1000000000   
txlog_warn_mb                  10240        metrics: TransactionLogsDiskUsage (MiB)
txlog_crit_mb                  51200        
slot_disk_warn_mb              10240        metrics: ReplicationSlotDiskUsage (MiB)
slot_disk_crit_mb              51200        
slot_lag_warn_mb               1024         metrics: OldestReplicationSlotLag (MiB)
slot_lag_crit_mb               10240        
acu_util_warn                  90           metrics: ACUUtilization peak (% of max ACU, serverless v2)
acu_util_crit                  99           
failover_crit_count            4            events: CRIT if more failover events in the window (one failover logs ~2)
events_show                    10           events: number of recent events listed in details
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | all checks OK (INFO/SKIP count as OK) |
| 10 | at least one WARN |
| 11 | at least one CRIT |
| 1 | usage / option / config error |
| 2 | pre-check failed: aws or jq missing, AWS CLI v1, credentials invalid (`sts get-caller-identity`) |
| 3 | one or more AWS calls failed (AccessDenied, throttling...) and nothing is CRIT. The report is still produced, with ERROR rows |
| 4 | output / internal error |
| 130 | interrupted |

When several apply: **CRIT (11) > AWS failure (3) > WARN (10) > OK (0)**. A confirmed CRIT is never
hidden by an unrelated AccessDenied, and an incomplete run never looks healthy.

## Least-privilege IAM policy (read-only)

`sts:GetCallerIdentity` needs no permission. `ec2:DescribeRegions` is only used by
`--all-regions`. `rds:DescribeDBParameters` and `ec2:DescribeInstanceTypes` are optional (used
only to derive max_connections; without them the connection check falls back to
`conn_warn`/`conn_crit`). `rds:DescribeDBMajorEngineVersions` is optional (lifecycle check shows SKIP without it).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AuroraPgCheckReadOnly",
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBClusters",
        "rds:DescribeDBInstances",
        "rds:DescribePendingMaintenanceActions",
        "rds:DescribeDBEngineVersions",
        "rds:DescribeDBMajorEngineVersions",
        "rds:DescribeCertificates",
        "rds:DescribeDBClusterSnapshots",
        "rds:DescribeEvents",
        "rds:DescribeDBParameters",
        "cloudwatch:GetMetricData",
        "ec2:DescribeRegions",
        "ec2:DescribeInstanceTypes"
      ],
      "Resource": "*"
    }
  ]
}
```

The AWS managed policies `AmazonRDSReadOnlyAccess` + `CloudWatchReadOnlyAccess` also cover it.

## Credentials: profiles, SSO, roles

```ini
# ~/.aws/config
[profile dba-prod]                      # IAM Identity Center (SSO)
sso_session    = corp
sso_account_id = 123456789012
sso_role_name  = DBA-ReadOnly
region         = ap-south-1

[sso-session corp]
sso_start_url  = https://corp.awsapps.com/start
sso_region     = ap-south-1
sso_registration_scopes = sso:account:access

[profile dba-readonly-role]             # assume a role from another profile / instance role
role_arn       = arn:aws:iam::123456789012:role/DBA-ReadOnly
credential_source = Ec2InstanceMetadata
region         = us-east-1
```

```bash
aws sso login --profile dba-prod        # interactive, once per session
./aurora_pg_check.sh -P dba-prod
```

If the SSO token has expired, the script exits 2 and prints the `aws sso login` command. For cron,
use an instance role or an assume-role profile rather than SSO (SSO tokens expire and need a browser).
Region: `--region`, otherwise `AWS_REGION` / `AWS_DEFAULT_REGION`, otherwise the profile's region.

## Configuration file

`--config FILE` reads `key = value` lines. The file is **parsed, never sourced**. Unknown keys,
bad values and credential keys are rejected. Command-line options override the file. Threshold
keys can be set directly (`cpu_warn = 85`). See `aurora_pg_check.conf.example`.

## Scheduling (cron)

```cron
PATH=/usr/local/bin:/usr/bin:/bin
AWS_PROFILE=dba-readonly-role
# every 30 minutes: alert on WARN/CRIT/ERROR, keep the latest text report
*/30 * * * * /opt/dba/aurora_pg_checks/aurora_pg_check.sh --config /etc/dba/aurora_pg_check.conf -q -o /var/log/dba/aurora_latest.txt -l /var/log/dba/aurora_pg_check.log 2>/dev/null
# daily 07:15 HTML report across all regions
15 7 * * *   /opt/dba/aurora_pg_checks/aurora_pg_check.sh --all-regions -f html -o /var/www/dba/aurora_$(date +\%F).html 2>>/var/log/dba/aurora_pg_check.log
```

Exit codes 10 / 11 are normal results, not failures. Alerts are sent by the script itself
(`--alert-on warn` by default). Webhook URLs are passed to curl on stdin and only `scheme://host/...`
is logged.

## Sample output

A cluster with problems (`-q`, problems only; mock data):

```
Aurora PostgreSQL checks - aurora_pg_check.sh v1.0.0
Generated : 2026-10-11 07:24:50 IST   (host dba-jump-01)
Account   : 123456789012   profile: default
Regions   : us-east-1
Window    : lookback 1d (metrics period 300s)   checks: cluster,versions,config,backups,metrics,events

=== us-east-1 / billing-prod : CRIT  (aurora-postgresql 13.12, 2 instance(s): 1 writer, 1 reader(s))
    STATUS GROUP    CHECK                      VALUE                                     REASON
    WARN   cluster  az_spread                  us-east-1a                                instances span 1 AZ(s); want at least 2
    WARN   cluster  instance_class             db.r6g.2xlarge,db.r6g.large               mixed classes (writer db.r6g.2xlarge): a failover may land on a different size
        - billing-prod-1: db.r6g.2xlarge tier 0
        - billing-prod-2: db.r6g.large tier 0
    CRIT   versions support_lifecycle          std support ended 2026-03-01 05:29 IST    major 13 is past Aurora standard support: RDS Extended Support charges apply (until 2029-03-01 05:29 IST); cluster setting open-source-rds-extended-support
    CRIT   versions pending_maintenance        2                                         1 action(s) auto-applied within 7d: system-update on billing-prod-2
        - billing-prod: db-upgrade - Upgrade to Aurora PostgreSQL 13.20 [pending]
        - billing-prod-2: system-update - New Operating System update is available (auto-applied after 2026-10-14 07:24 IST) next window 2026-10-14 07:24 IST
    WARN   versions auto_minor_upgrade         1/2 enabled                               disabled on: billing-prod-2 (security/bug-fix minors are not applied automatically)
    CRIT   versions ca_certificate             rds-ca-2019,rds-ca-rsa2048-g1, expired... certificate EXPIRED: clients verifying TLS will fail; rotate the CA
        - billing-prod-1: CA rds-ca-rsa2048-g1 valid till 2061-05-26 05:29 IST; server cert till 2027-08-07 07:24 IST
        - billing-prod-2: CA rds-ca-2019 valid till 2024-08-22 22:38 IST; server cert till 2025-09-06 07:24 IST
    WARN   config   cluster_param_apply        billing-cluster-pg13                      not in-sync: billing-prod-1=pending-reboot (reboot to apply)
    WARN   config   instance_param_apply       billing-pg13,default.aurora-postgresql13  not in-sync: billing-prod-1=pending-reboot (reboot to apply)
    WARN   config   deletion_protection        no                                        deletion protection OFF: the cluster can be deleted by a single API call
    WARN   config   public_access              billing-prod-2                            publicly accessible: billing-prod-2 (DNS resolves to a public IP; check security groups)
    WARN   config   log_exports                none                                      postgresql log NOT exported to CloudWatch Logs
    WARN   config   performance_insights       1/2 enabled                               Performance Insights off on: billing-prod-2
        - billing-prod-1: PI yes, retention 7d, mode standard
        - billing-prod-2: PI no, retention -d, mode standard
    WARN   config   enhanced_monitoring        0s,60s                                    off or coarser than 60s: billing-prod-2=0s (0s = disabled)
    WARN   config   copy_tags_to_snapshot      no                                        tags are NOT copied to snapshots (cost allocation / retention tooling)
    CRIT   backups  backup_retention           1d                                        point-in-time recovery limited to 1 day(s); want >= 7
    WARN   backups  restore_lag                24m                                       latest restorable time 2026-10-11 06:59 IST (24m behind)
    WARN   backups  automated_snapshot         1d 5h old                                 newest automated snapshot rds:billing-prod-2026-10-09-19-54 at 2026-10-10 01:24 IST; 1 retained
    WARN   backups  backup_window              20:10-20:40 UTC                           backup window overlaps maintenance window sun:20:00-sun:20:30 UTC
    WARN   events   recent_events              1 event(s), 0 failover event(s)           last 1d 0h: availability=1
        - 2026-10-11 02:24 IST billing-prod-1 [availability] DB instance restarted

SUMMARY
    REGION          CLUSTER                           STATUS  OK   WARN  CRIT  ERROR
    us-east-1       billing-prod                      CRIT    24   15    4     0

Overall: CRIT (exit 11) - 1 cluster(s), 43 checks: 24 ok, 15 warn, 4 crit, 0 error
```

A healthy fleet across all enabled regions (`--all-regions -q`):

```
Aurora PostgreSQL checks - aurora_pg_check.sh v1.0.0
Generated : 2026-10-11 07:24:52 IST   (host dba-jump-01)
Account   : 123456789012   profile: default
Regions   : ap-south-1, eu-west-1, us-east-1, us-west-2
Window    : lookback 1d (metrics period 300s)   checks: cluster,versions,config,backups,metrics,events

=== ap-south-1 / payments-prod : OK  (aurora-postgresql 16.8, 2 instance(s): 1 writer, 1 reader(s))
    all 43 checks OK

=== us-east-1 / orders-prod : OK  (aurora-postgresql 16.8, 3 instance(s): 1 writer, 2 reader(s))
    all 43 checks OK

SUMMARY
    REGION          CLUSTER                           STATUS  OK   WARN  CRIT  ERROR
    ap-south-1      payments-prod                     OK      43   0     0     0
    us-east-1       orders-prod                       OK      43   0     0     0

Overall: OK (exit 0) - 2 cluster(s), 86 checks: 86 ok, 0 warn, 0 crit, 0 error
```

## Testing

There are no AWS credentials on the build box, so testing used a mock `aws` (`tests/mock/aws`).
It returns JSON with the AWS CLI v2 output shapes (field names taken from
`aws <svc> <op> --generate-cli-skeleton output`), with timestamps relative to now. Scenarios: `fleet`
(healthy, 4 regions incl. an aurora-mysql cluster), `issues`, `metrics`, `serverless`, `apifail`,
`instfail`, `badcreds`. The mock rejects any option the script is not expected to send.

```bash
tests/run_tests.sh        # 139 checks: every scenario, text/json/html, -o, config, alerts to local stubs, pre-check failures
tests/validate_cli.sh     # every distinct AWS command line the script issued -> real AWS CLI v2 parser
```

`validate_cli.sh` replays the logged command lines (76 distinct) through the real AWS CLI v2 with fake
credentials and an unreachable endpoint. The CLI parses options, `--filters` shorthand and the
`file://` metric-query JSON, and runs botocore parameter validation, before it connects. "Could not
connect" therefore means the command was accepted. The `--query` used for `describe-db-parameters`
is checked against a local fake RDS endpoint.

## Caveats

* **Verified only against the mock.** The command syntax is validated by the real CLI. The response
  shapes come from the CLI's own skeletons. The metric values, event texts, lifecycle dates and
  maintenance actions are invented. The first run against a real account should be reviewed by hand,
  especially the thresholds.
* max_connections with the default formula `LEAST({DBInstanceClassMemory/9531392},5000)` is
  estimated from the EC2 memory of the class. Real `DBInstanceClassMemory` is a few % lower, so the
  estimated max is slightly high and the percentage slightly low. Set `max_connections` to override.
* `AuroraReplicaLagMaximum` is queried with only the `DBClusterIdentifier` dimension. Writer-only
  metrics (XIDs, slots, WAL) are read from the **current** writer, so after a failover in the
  window, part of the history belongs to the other instance.
* RDS events are kept 14 days, so the events lookback is capped there. CloudWatch keeps 1-minute data
  for 15 days and 5-minute data for 63 days.
* A global-database secondary has no writer and is reported WARN, not CRIT.
* The script relies on the AWS CLI's built-in retries (`--max-attempts`, default 5, standard mode).
  A very large fleet can still hit API throttling. Failed calls show up as ERROR rows (exit 3).
