# rds_pending_maintenance_report.sh

A read-only report of every RDS, Aurora, DocumentDB and Neptune resource that has **pending maintenance**: what is pending, when it will be applied, and how urgent it is. It works across several AWS accounts (profiles) and regions. Output formats are text, CSV, JSON and a single-file HTML report. It can send optional e-mail or webhook alerts, and its exit codes are suitable for cron and monitoring.

```
./rds_pending_maintenance_report.sh -P prod,nonprod -r us-east-1,ap-south-1 -F csv,html -o /var/reports/rds
```

* **Engines:** Aurora PostgreSQL/MySQL, RDS PostgreSQL, MySQL, MariaDB, SQL Server (all editions), Oracle and Db2. DocumentDB and Neptune are included when the RDS API returns them. `--include-docdb` also queries `aws docdb describe-pending-maintenance-actions`; results are merged and de-duplicated per resource+action, and the rds entry wins.
* **Strictly read-only.** The only calls are `sts get-caller-identity`, `ec2 describe-regions` (only for `--all-regions`), `rds|docdb describe-pending-maintenance-actions`, `rds describe-db-instances`, `rds describe-db-clusters` (also for the clusters of pending member instances, to get writer / reader roles) and `rds|docdb|neptune describe-db-engine-versions` (minor-version check; skip with `--no-version-check`). The script never applies, defers, upgrades or modifies anything. The commands it prints are for you to review and run yourself.
* **Requirements:** Bash 4.4+, AWS CLI v2, jq 1.6+. curl is needed for webhooks and mail/mailx/sendmail for e-mail. The script consists of the main file plus `lib/report.jq`; keep them together.
* **Next step:** to apply the pending maintenance of one Aurora / DocumentDB / Neptune cluster safely (snapshot, readers first, writer last), use [RDS_Patch_Runner](../RDS_Patch_Runner/README.md).

## How it works

1. For each profile, `sts get-caller-identity` returns the account id. If a profile's credentials are invalid or expired, it is recorded as an error and the other profiles continue.
2. For each region: `describe-pending-maintenance-actions` returns ARNs plus action details. The ARNs are resolved through `describe-db-instances` and `describe-db-clusters` with `--filters Name=db-instance-id|db-cluster-id,Values=<ARNs>`. Lookups are batched 50 ARNs per call and made once per region. They add engine, version, instance class, cluster membership, maintenance window and tags (from `TagList`, so no extra tagging API is called). ARNs that no longer resolve, such as deleted resources, are still reported with engine `unknown`.
3. Each action gets an **effective apply date**:

   | Priority | Rule | `effective_basis` |
   |---|---|---|
   | 1 | `CurrentApplyDate` if present | `current-apply-date` |
   | 2 | OptInStatus `next-maintenance` → start of the next maintenance window | `next-window (opted in)` |
   | 3 | OptInStatus `immediate` → now | `immediate (opted in)` |
   | 4 | earliest of `AutoAppliedAfterDate` / `ForcedApplyDate` | `auto-applied-after` / `forced-apply` |
   | 5 | none → optional, no date | `none` |

4. **Urgency** comes from the days until the effective date:
   * `OVERDUE`: the date has passed.
   * `CRIT`: 7 days or less.
   * `WARN`: 30 days or less.
   * `INFO`: later.
   * `OPTIONAL`: no date.

   Change the 7 and 30 with `--crit-days` and `--warn-days`.
5. **Minor versions** (v1.3.0): for every engine + version found, one `aws rds|docdb|neptune describe-db-engine-versions --engine <engine> --engine-version <version>` call is made (cached per engine + version + region, so 100 instances on the same version cost one call). From `ValidUpgradeTarget` only targets with `IsMajorVersionUpgrade = false` and a higher version are kept. Versions compare numerically per part, so `16.10` is newer than `16.9`. `--no-version-check` skips these calls. A failed lookup (e.g. missing `rds:DescribeDBEngineVersions`) is logged as a warning and shown as `lookup failed`; it does not make the report incomplete or change the exit code.
6. **Roles** (v1.4.0) come from the describe calls already made: `DBClusterMembers[].IsClusterWriter` for Aurora / DocumentDB / Neptune members (the member's cluster is described too if it has no pending action of its own), `ReadReplicaSourceDBInstanceIdentifier` / `ReadReplicaDBInstanceIdentifiers` / `MultiAZ` for RDS instances, and `GlobalClusterIdentifier` / `ReplicationSourceIdentifier` for global-database and cross-region replica clusters. `describe-global-clusters` is not called: a global cluster with no writer member is reported as `cluster (global secondary)`, one with a writer as `cluster (global primary)`.
7. Filters are applied, rows are grouped **per engine** and sorted in **patching order** (see below), and the summary is computed: counts by urgency, action, engine, region and account, plus the number of servers behind their latest minor version.

## Patching order, roles and engine sections (v1.4.0)

Rows are sorted (case-insensitive) by **engine**, then **patch_group** (the cluster name; for an RDS read replica in the same region, its source instance; otherwise the instance itself), then **patch_sequence**, then the **instance name**. Read top-down, each group lists what to patch first.

| `role` | `patch_sequence` | Rule |
|---|---|---|
| `replica (reader)` | 1 | Aurora / DocumentDB / Neptune reader (`IsClusterWriter = false`): patch readers first, one at a time |
| `primary (writer)` | 2 | The cluster writer: patch last (a failover to an already-patched reader is possible) |
| `cluster` | 1 | The action is at cluster level (e.g. `db-upgrade` on the cluster): AWS applies it to the whole cluster, so there is no per-instance order. The note says so |
| `cluster (global secondary)` / `cluster (global primary)` | 1 / 2 | Global database: secondary-region clusters before the primary cluster |
| `cluster (replica)` | 1 | Cross-region replica cluster (`ReplicationSourceIdentifier`): before its source |
| `replica` / `replica (Multi-AZ)` | 1 | RDS read replica (`ReadReplicaSourceDBInstanceIdentifier`): replicas before the source. Cross-region replicas (source given as an ARN) form their own group |
| `primary` / `primary (Multi-AZ)` | 2 | RDS instance with read replicas, or a standalone instance. Multi-AZ: AWS patches the standby, then fails over (short outage) |
| `unknown` | empty | The ARN no longer resolves |

`sequence_note` explains each row (e.g. `reader of ledger-ams: patch readers first, one at a time, then the writer`).

**Engine sections:** the text report has one block per engine (`ENGINE: aurora-mysql - 4 pending action(s) on 4 resource(s) in 2 cluster/server group(s); urgency ...`), the HTML report has a table of contents and one section and table per engine with its own counts, and JSON has `engines: [{engine, total, resources, groups, by_urgency, by_action, behind_latest_minor, rows: [...]}]` next to the flat `rows` array (kept for compatibility). CSV stays one file sorted with engine first; `--split-by-engine` (needs `-o` and csv) also writes `<prefix>_<stamp>_<engine>.csv` per engine.

## Backup before maintenance (v1.4.0, printed only)

Every resolved row gets a snapshot command and a wait command, for example:

```bash
SNAP_ledger_ams="pre-maint-ledger-ams-$(date -u +%Y%m%d-%H%M)" && aws rds create-db-cluster-snapshot --db-cluster-identifier ledger-ams --db-cluster-snapshot-identifier "$SNAP_ledger_ams" --region us-west-2 --profile prod
aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAP_ledger_ams" --region us-west-2 --profile prod
```

* **Name:** `pre-maint-<identifier>-<YYYYMMDD-HHMM>`. The timestamp is **UTC** and is taken **when you run the command** (`$(date -u +%Y%m%d-%H%M)`), not when the report was generated, so the name shows the real backup time. The name is stored in a shell variable (`SNAP_<identifier>`), so run the **wait command in the same shell** right after the backup command. This works pasted into bash in CloudShell from the HTML Copy button, the CSV cell or the text report. The `backup_snapshot_name` column shows the pattern, e.g. `pre-maint-ledger-ams-YYYYMMDD-HHMM`.
* **Identifier rules:** the identifier part is sanitised to letters, digits and single hyphens (anything else becomes `-`, runs of `-` collapse, no trailing `-`) and cut to 231 characters, so the full name is at most 255 characters and always starts with a letter.
* **What is snapshotted:**
  * Aurora / DocumentDB / Neptune / Multi-AZ DB clusters and their member rows: `create-db-cluster-snapshot` of the cluster (`aws docdb` / `aws neptune` for those engines). Instance snapshots are not possible for cluster members; the cluster snapshot covers all of them.
  * Standalone instances: `aws rds create-db-snapshot`.
  * RDS read replicas: the snapshot is of the **source** instance (a replica snapshot is optional). Cross-region replicas get no command, only a note to snapshot the source in its own region.
* **Wait:** `aws rds wait db-cluster-snapshot-available` / `db-snapshot-available`. The DocumentDB and Neptune CLIs have no snapshot waiters, so `aws rds wait` is used for them too (same snapshot API).
* Taking the same backup twice in the same minute fails with "already exists" - wait a minute or change the name.

## Report columns (CSV; the same fields are in JSON, HTML and text)

| Column | Meaning |
|---|---|
| `account_id`, `profile`, `region` | Where the resource lives |
| `resource_type` | `instance` or `cluster` (from the ARN) |
| `identifier` | DB instance or cluster identifier |
| `cluster` | For an instance that belongs to a cluster (Aurora, DocumentDB, Neptune): the cluster identifier |
| `engine`, `engine_version` | From describe-db-instances / describe-db-clusters (`unknown` if the ARN no longer resolves) |
| `instance_class` | e.g. `db.r6g.xlarge`. For clusters, `DBClusterInstanceClass` (Multi-AZ DB clusters) or `serverless v2 <min>-<max> ACU` |
| `tag:<Key>` | One column per `--tag-columns` key (default `Environment,Owner,Application`) |
| `action` | `system-update`, `db-upgrade`, `os-upgrade`, `hardware-maintenance`, `ca-certificate-rotation`, ... |
| `description` | AWS description of the action |
| `opt_in_status` | `OptInStatus` from AWS (empty = no opt-in requested) |
| `auto_applied_after_utc` | `AutoAppliedAfterDate`: applied in the first maintenance window after this date |
| `forced_apply_utc` | `ForcedApplyDate`: applied automatically on this date, regardless of the window |
| `current_apply_utc` | `CurrentApplyDate`: the date AWS currently plans to apply it (takes opt-ins into account) |
| `effective_apply_utc`, `effective_apply_ist` | Effective date (see above) in UTC and in `--tz` (default Asia/Kolkata, IST) |
| `days_until` | Days from report time to the effective date (1 decimal; negative = overdue) |
| `urgency` | `OVERDUE`, `CRIT`, `WARN`, `INFO` or `OPTIONAL` |
| `maint_window_utc`, `maint_window_ist` | `PreferredMaintenanceWindow` as returned (UTC), and converted, e.g. `Tue 02:00-Tue 02:30 IST` |
| `next_window_ist` | Start of the next maintenance window |
| `source` | `rds` or `docdb` (which API reported it) |
| `arn` | Resource ARN (use it with `apply-pending-maintenance-action`) |
| `apply_immediate_command` | `aws rds\|docdb\|neptune apply-pending-maintenance-action --resource-identifier <ARN> --apply-action <action> --opt-in-type immediate ...`. **Printed only, never run.** **Warning: immediate may restart or fail over the DB right now.** Empty for not-found rows and rows already opted in `immediate` (see `apply_note`) |
| `status_command` | Read-only `describe-db-instances` / `describe-db-clusters` (members included) with `--query ... --output table`. Shows `Status` (`available`, `upgrading`, `maintenance`, `rebooting`, `modifying` ... anything other than `available` means work is in progress) and `PendingModified` |
| `pending_actions_command` | Read-only `aws <svc> describe-pending-maintenance-actions --resource-identifier <ARN> ... --output table`: live view of what is still pending. Shown for every row, including not-found ones |
| `apply_note` | Caution or why the immediate command is empty: "applies as soon as possible - may restart/fail over ...", "already scheduled for the next window ...", "already opted in (immediate) ...", "resource not found ... verify before applying" |
| `auto_minor_upgrade` | `AutoMinorVersionUpgrade` of the instance or cluster: `true` / `false` (empty if unknown) |
| `next_minor_version` | Smallest newer minor version available, or `up to date`, `not checked` (`--no-version-check`), `lookup failed`, `resource not found` |
| `latest_minor_version` | Highest newer minor version available (empty when up to date) |
| `minor_versions_available` | All newer minor versions, comma-separated; more than 6 are shortened to `first 3, ..., last 2 (N versions)` (JSON `minor_targets` has the full list) |
| `minor_upgrade_command` | `aws rds\|docdb\|neptune modify-db-cluster --db-cluster-identifier <cluster> --engine-version <latest minor>` for Aurora / DocumentDB / Neptune / Multi-AZ DB clusters (also on their member-instance rows), or `aws rds modify-db-instance --db-instance-identifier <id> --engine-version <latest minor>` for standalone instances. **Printed only, never run.** No `--apply-immediately`, so it applies in the next maintenance window. Empty when up to date |
| `patch_group` | Cluster name, or the source instance for an RDS read replica, or the instance itself (sorting key) |
| `role` | See the table above, e.g. `primary (writer)`, `replica (reader)`, `cluster`, `primary (Multi-AZ)`, `replica` |
| `patch_sequence` | `1` = patch first (replicas / readers / cluster-level), `2` = patch last (primary / writer) |
| `sequence_note` | Why, e.g. `source of 1 read replica(s) (billing-pg-rr1): patch the replicas first, then this primary; Multi-AZ: ...` |
| `backup_snapshot_name` | Snapshot name pattern, e.g. `pre-maint-ledger-ams-YYYYMMDD-HHMM` (UTC, filled in when the command runs) |
| `backup_command` | `SNAP_<id>="pre-maint-<id>-$(date -u +%Y%m%d-%H%M)" && aws <svc> create-db-cluster-snapshot ...` or `create-db-snapshot ...`. **Printed only** |
| `backup_wait_command` | `aws rds wait db-cluster-snapshot-available\|db-snapshot-available --db-...-snapshot-identifier "$SNAP_<id>" ...` (same shell) |
| `backup_note` | e.g. `replica (reader) of ledger-ams: ... the cluster snapshot covers all members`, `read replica: the snapshot is taken of its source billing-pg ...` |
| `minor_upgrade_note` | e.g. `upgrades cluster orders-prod 16.8 -> 16.10; applies in the next maintenance window unless --apply-immediately is added (restart / failover)` |

In the text format, each row is followed by indented `sequence`, `version`, `backup`, `wait`, `bkp note`, `immediate`, `status`, `pending`, `minor upg` and `note` lines. In HTML, a **Minor version** cell shows next / latest / all available versions and whether auto minor upgrade is on, a **Seq / role** cell shows the patch sequence and role, and one **Commands** cell holds: 1. backup first (snapshot + wait), 2. apply immediately (with the restart / failover warning), the minor version upgrade, and collapsible check-status and pending-actions lookups. Every command has a **Copy** button. A "behind latest minor" card counts the servers that are behind.

Removed in 1.3.0: the `apply_command` (next-maintenance) and `undo_command` (undo-opt-in) columns, and the `--apply-opt-in` option / `apply_opt_in` config key. Passing them still works but only logs a warning and is ignored.

The IST column names follow `--tz`; for example `--tz UTC` gives `effective_apply_utc` twice. The JSON output also has `effective_basis`, epoch values, the full `tags` map, `resolved` and the summary.

**HTML** is a single file with no external resources. It has:
* summary cards and count tables
* a free-text row filter
* click-to-sort columns
* colour-coded urgency
* every timestamp in both UTC and IST

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Nothing pending (after filters) |
| 10 | Pending actions, none CRIT/OVERDUE |
| 11 | At least one CRIT or OVERDUE action |
| 1 | Usage / configuration error |
| 2 | Pre-check failed: aws/jq missing, or **no** profile had valid credentials or a region |
| 3 | Some AWS calls failed (e.g. AccessDenied in one region, one bad profile) and nothing is CRIT. The report says "report incomplete" |
| 4 | Output error |
| 130 | Interrupted |

The order of precedence is 11 > 3 > 10 > 0. A CRIT finding is never masked by a partial failure. The failure is still listed under "ERRORS" in every format.

## Pending action types: what they mean and how to apply or defer them

| Action | What it is | Impact when applied |
|---|---|---|
| `system-update` | OS/host patches or engine patches that AWS manages (security, stability). Often **required**: these have `AutoAppliedAfterDate` or `ForcedApplyDate` | Usually a reboot. Multi-AZ instances patch the standby first, then fail over (short outage). Aurora patches each instance (zero-downtime patching where supported) |
| `os-upgrade` | Upgrade of the underlying operating system (e.g. new OS major version) | Reboot / failover as above. For Multi-AZ, the standby is upgraded first |
| `db-upgrade` | Engine minor version upgrade or required engine patch (e.g. auto minor version upgrade, end-of-support upgrade) | Engine restart; downtime depends on engine and Multi-AZ. Test the new version first |
| `hardware-maintenance` | Move to new underlying hardware | Instance restart or failover; plan for a few minutes of unavailability |
| `ca-certificate-rotation` | Rotate the server certificate to a new CA (e.g. to `rds-ca-rsa2048-g1`) | DB restart. **Clients that verify TLS must trust the new CA bundle first** |

Optional actions (no dates) are applied only when you choose. Required actions are applied automatically in your maintenance window after `AutoAppliedAfterDate`, and unconditionally on `ForcedApplyDate`.

### Printed commands (never executed)

Every row gets copy-pasteable commands, for example:

```
aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:crm-sql-prod --apply-action system-update --opt-in-type immediate --region us-east-1 --profile prod
aws rds describe-db-instances --db-instance-identifier crm-sql-prod --query 'DBInstances[0].{Status:DBInstanceStatus,...}' --output table --region us-east-1 --profile prod
aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:us-east-1:111111111111:db:crm-sql-prod --output table --region us-east-1 --profile prod
aws rds modify-db-instance --db-instance-identifier crm-sql-prod --engine-version 15.00.4430.1.v1 --region us-east-1 --profile prod
```

* **Service:** `aws docdb` for DocumentDB rows (engine `docdb` or rows from `--include-docdb`), `aws neptune` for Neptune, `aws rds` for everything else. All three accept the same RDS ARN.
* **Region and profile:** `--region` is always included. `--profile` is included only when the report ran with `-P`; with the default credential chain it is left out.
* **Quoting:** arguments are shell-quoted (single quotes) whenever they contain anything other than `A-Z a-z 0-9 _ . / : = @ , + % -`. Real ARNs and action names never need it.
* **Empty immediate command:** the ARN did not resolve (deleted or renamed resource), or the action is already opted in `immediate`.
* **Minor upgrade:** targets the latest minor version. Aurora / DocumentDB / Neptune versions belong to the cluster, so rows for member instances print the cluster command. Without `--apply-immediately` the change is applied in the next maintenance window; adding it restarts the DB now. Test the new version first and check the engine release notes.
* The script stays **read-only**. It builds these strings with jq and never executes them. The test suite checks that only `describe-*`/`get-*` operations are ever called.

> **Before running an `immediate` command:**
> * `immediate` starts the maintenance as soon as possible, outside your maintenance window. It **may restart the instance or fail over** a Multi-AZ instance or cluster. It **cannot be undone**.
> * Check the maintenance window (`maint_window_*` columns), the impact of the action type (table above) and the application's tolerance for a restart first.
> * Afterwards run `status_command`: a `Status` other than `available` (`upgrading`, `maintenance`, `rebooting`, `modifying`) means the work is in progress. `pending_actions_command` shows what is still pending.

### Other opt-in types (manual; no longer printed by the report since 1.3.0)

```bash
ARN=arn:aws:rds:us-east-1:111111111111:db:crm-sql-prod      # from the report's arn column
# apply as soon as possible (cannot be undone)
aws rds apply-pending-maintenance-action --resource-identifier "$ARN" --apply-action system-update --opt-in-type immediate
# apply during the next maintenance window
aws rds apply-pending-maintenance-action --resource-identifier "$ARN" --apply-action system-update --opt-in-type next-maintenance
# defer: withdraw a next-maintenance opt-in (back to AWS's schedule; Auto/Forced dates still apply)
aws rds apply-pending-maintenance-action --resource-identifier "$ARN" --apply-action system-update --opt-in-type undo-opt-in
```

* `--apply-action` takes the value from the `action` column: `system-update`, `db-upgrade`, `os-upgrade`, `hardware-maintenance` or `ca-certificate-rotation`. Use the cluster ARN for cluster-level rows.
* DocumentDB rows: use `aws docdb apply-pending-maintenance-action` with the same options.
* `immediate` cannot be undone with `undo-opt-in`.
* A required action cannot be deferred past its `ForcedApplyDate`. To control *when* it happens, move the maintenance window (`aws rds modify-db-instance` / `modify-db-cluster --preferred-maintenance-window`) or apply it yourself earlier at a time of your choosing.
* Check the result afterwards with `aws rds describe-pending-maintenance-actions --filters Name=db-instance-id,Values=$ARN`, or re-run this report.

### Console

1. Go to RDS console → **Databases**, then select the instance or cluster.
2. Open the **Maintenance & backups** tab. **Pending maintenance** lists each action with its status and dates.
3. Select an action, then choose **Apply now** (immediate) or **Apply at next maintenance window** (next-maintenance). For an action you already scheduled, **Defer upgrade** is shown (undo-opt-in).
4. To change when maintenance runs, choose **Modify**, set **Maintenance window**, and apply the change.

The **Maintenance** column of the Databases list shows `required`, `available` or `next window`, which is useful for a quick look.

## IAM policy (read-only)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RdsPendingMaintenanceReadOnly",
      "Effect": "Allow",
      "Action": [
        "rds:DescribePendingMaintenanceActions",
        "rds:DescribeDBInstances",
        "rds:DescribeDBClusters",
        "rds:DescribeDBEngineVersions",
        "ec2:DescribeRegions"
      ],
      "Resource": "*"
    }
  ]
}
```

* DocumentDB and Neptune use the same `rds:` IAM actions, so `--include-docdb` and the docdb/neptune engine-version lookups need nothing extra.
* `rds:DescribeDBEngineVersions` is only used for the minor-version columns (not with `--no-version-check`).
* `sts:GetCallerIdentity` needs no permission.
* `ec2:DescribeRegions` is only used with `--all-regions`.
* Tags come from `TagList` in the describe responses, so no `rds:ListTagsForResource` is needed.
* **Only for running the printed backup commands yourself** (not needed by the report): `rds:CreateDBSnapshot` (instances) and `rds:CreateDBClusterSnapshot` (clusters, incl. DocumentDB / Neptune), plus `rds:DescribeDBSnapshots` / `rds:DescribeDBClusterSnapshots` for the wait commands. The apply / modify commands need `rds:ApplyPendingMaintenanceAction` / `rds:ModifyDBInstance` / `rds:ModifyDBCluster`.
* The AWS managed policy `AmazonRDSReadOnlyAccess` also covers everything except `ec2:DescribeRegions`.

## Multiple accounts

Give one AWS CLI profile per account (SSO or role-assuming profiles work), e.g. `-P prod -P nonprod` or `-P prod,nonprod`. Each profile's account id is resolved with STS. With no `-r`, a profile's configured region is used. The script never reads, accepts or logs credentials. Config files containing credential keys are rejected.

## Configuration file

Use `--config FILE` with simple `key = value` lines; command-line options override them. The file is parsed, never sourced. See `rds_pending_maintenance_report.conf.example` for all keys.

## Cron examples

```cron
CRON_TZ=Asia/Kolkata
# Weekdays 08:00 IST: CSV + HTML for all accounts and regions; e-mail only when something is CRIT/overdue
0 8 * * 1-5  /opt/dba/rds_pending_maintenance/rds_pending_maintenance_report.sh --config /etc/dba/rds_pm.conf -F csv,html -o /var/reports/rds_pm -l /var/log/dba/rds_pm.log --alert-email dba-team@example.com >/dev/null 2>&1
# Monday 09:00 IST: weekly digest of everything pending (always mailed)
0 9 * * 1    /opt/dba/rds_pending_maintenance/rds_pending_maintenance_report.sh --config /etc/dba/rds_pm.conf --alert-on always --alert-email dba-team@example.com >/dev/null 2>&1
# Housekeeping: keep 90 days of reports
30 8 * * *   find /var/reports/rds_pm -name 'rds_pending_maintenance_*' -mtime +90 -delete
```

## Tests

* `tests/run_tests.sh`: 281 checks (including a large-fleet regression test) against a mock AWS CLI (`tests/mock/aws`). They use local stub mail and a webhook listener on 127.0.0.1, and include a read-only check of every AWS operation called.
* `tests/validate_cli.sh` replays every AWS command line the script issued (47 distinct, including `rds|docdb|neptune describe-db-engine-versions`) through the real AWS CLI v2 (fake credentials, dead local endpoint), runs negative controls, and checks that the mock's response shapes (9 operations) match `--generate-cli-skeleton output`. It also runs every printed `apply_immediate_command`/`status_command`/`pending_actions_command`/`minor_upgrade_command` (65 commands; rds, docdb, neptune; instance and cluster; `modify-db-instance` and `modify-db-cluster`; plus an awkward-quoting row) through the real CLI. Backup + wait snippets (18) are run in bash exactly as pasted (with `aws` replaced by a recorder), the recorded calls are replayed through the real CLI (130 printed commands in total, covering `create-db-snapshot`, `create-db-cluster-snapshot` for rds/docdb/neptune and both waiters), and every snapshot name is checked against the identifier rules and for being the same in the backup and wait command (incl. a 300-character awkward identifier that must be sanitised to 255). It also checks that no next-maintenance / undo-opt-in / `--apply-immediately` command is printed, and checks pagination against a local paging endpoint.

Samples from the mock fleet are in `samples/`, with screenshots of the HTML report at `sample_report.png` (full report) and `sample_report_apply_cmd.png` (Seq / role, minor-version and Commands cells expanded: backup + wait, apply immediately, minor upgrade, status, pending actions, each with Copy).

## Changelog

* **1.4.0**: backup before maintenance: `backup_snapshot_name`, `backup_command`, `backup_wait_command`, `backup_note` (snapshot `pre-maint-<id>-<UTC YYYYMMDD-HHMM at run time>`, cluster snapshot for cluster members, source snapshot for RDS read replicas). Roles and patch order: `patch_group`, `role`, `patch_sequence`, `sequence_note` (CSV 45 columns); the clusters of pending member instances are described too (read-only). Sort: engine, cluster / server, patch_sequence, instance (case-insensitive). Per-engine sections in text and HTML (with a table of contents), `engines` array in JSON, `--split-by-engine` / `split_by_engine` for per-engine CSVs. Tests: 281/281; CLI validation 47/47 calls, 130/130 printed commands, 18/18 backup snippets.
* **1.3.0**: removed `apply_command` (next-maintenance) and `undo_command` (undo-opt-in) and the `--apply-opt-in` option / `apply_opt_in` key (now ignored with a warning). New minor-version patch details: `auto_minor_upgrade`, `next_minor_version`, `latest_minor_version`, `minor_versions_available`, `minor_upgrade_command`, `minor_upgrade_note` (CSV 37 columns), from `describe-db-engine-versions` cached per engine + version + region; `--no-version-check` / `version_check = no` skips it. Summary: servers behind the latest minor version. HTML: Minor version cell, "behind latest minor" card, Commands cell = apply immediately + minor upgrade + status + pending actions, all with Copy. IAM: add `rds:DescribeDBEngineVersions`. Tests: 247/247; CLI validation 38/38 calls and 65/65 printed commands accepted.
* **1.2.0**: new columns `apply_immediate_command`, `status_command`, `pending_actions_command` in CSV (appended at the end, 33 columns), JSON, text and HTML. HTML groups commands in one cell with Copy buttons and collapsible sections. Tests: 212/212; CLI validation 79/79 accepted.

## Large fleets and pagination

* **v1.1.1** fixes `jq: Argument list too long`, which v1.1.0 hit with large fleets: the whole result set was passed to jq as a command-line argument.
* No result data is passed as a command-line argument any more. Results, errors, alert bodies and webhook payloads move through files and stdin (`jq --slurpfile/--rawfile`, `curl --data-binary @file`, mail fed from a file). This avoids Linux's 128 KiB limit per argument (MAX_ARG_STRLEN) and the ~2 MiB ARG_MAX limit.
* ARNs are resolved 50 per `describe-db-instances`/`describe-db-clusters` call, with one merge per region.
* Pagination: the script never passes `--max-items`, `--page-size` or `--no-paginate`, so the AWS CLI v2 follows every `Marker` page itself. `tests/validate_cli.sh` checks this end to end: it points the real CLI at a local fake endpoint that pages every response.
* Measured on the mock large fleet (2 accounts × 3 regions, 3,120 instances + 120 clusters, 5,322 pending actions, 15 tags each, long descriptions, about 7.7 MB of rows):

  | Formats | Time |
  |---|---|
  | json | about 8 s |
  | text | about 10 s |
  | html | about 17 s |
  | csv + html + json + text | about 20 s |

  Most of that time is the mocked AWS calls.
* Slack webhook messages are cut to 35,000 characters (Slack's limit is about 40k). E-mail and JSON webhooks carry the full report.

## Caveats

* Verified against a mock built from CLI skeleton output and the AWS documentation, **not against a live account**. Run it once with `-v --keep-workdir` in a real account to confirm the raw responses look as expected.
* `AutoAppliedAfterDate` means "applied in the first maintenance window *after* this date". The report uses the date itself as the effective date, which is the earliest possible moment. `next_window_ist` shows the next window to help with planning.
* Whether `rds describe-pending-maintenance-actions` returns DocumentDB/Neptune resources can vary. `--include-docdb` queries the DocumentDB API explicitly; duplicates are removed.
* `--opt-in-type` is a free string to the CLI, so the CLI accepts any value; only the service validates it. The printed commands only ever use `immediate`.
* `ValidUpgradeTarget` lists what AWS allows from the current version in that region; a version can be listed but not yet offered for your instance class. The minor upgrade command upgrades straight to the latest minor; pick `next_minor_version` instead if you prefer smaller steps. The commands were checked for syntax against CLI 2.37.12, but have not been run against AWS.
* `OptInStatus` values are shown as AWS returns them. Only `immediate` and `next-maintenance` change the effective date.
* Maintenance windows and dates are UTC in AWS; the second time zone is display only.
