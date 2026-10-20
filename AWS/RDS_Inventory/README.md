# RDS_Inventory

`rds_inventory_report.sh` is a **read-only** Bash / AWS CLI v2 inventory of RDS and Aurora across accounts (profiles) and regions. It covers the following:

- **Aurora global clusters**: primary and secondary regions, member clusters, writer and readers.
- **Regional Aurora clusters** (provisioned and Serverless v2) and **Multi-AZ DB clusters**.
- **Standalone instances**, with their read replicas (including cross-region ones) linked to the source.
- With `--include-docdb`, also DocumentDB and Neptune clusters.

**No CloudWatch.** The script makes no metric calls at all, so there is no replication lag and no VolumeBytesUsed. `aws_call` refuses `cloudwatch` and any operation that is not `describe-*`, `list-*` or `get-*`, and the tests check this.

## Grouping

Everything that belongs to one cluster is kept together:

```
global cluster
  └─ primary regional cluster  → writer, then readers by promotion tier
  └─ secondary cluster (region) → its readers
regional cluster               → writer, readers
standalone primary             → same-region replicas → cross-region replicas
```

Each output format keeps this grouping:

- **text**: summary first, then one block per group.
- **csv**: one denormalized rows file, sorted by group key, with columns `group`, `group_type`, `seq`, `level` and `role`. A separate `_summary.csv` file holds the summary.
- **json**: `{meta, summary, groups:[{key,type,title,rows:[...]}], errors}`.
- **html**: one collapsible card per group, self-contained and offline. It has:
  - a live search over names, endpoints, engine, version, tag values, account and region, with highlighting, a match count and auto-expand of matching cards;
  - `/` to focus the search box and Esc or a clear button to reset it;
  - filters for engine, account, region and type;
  - expand all and collapse all.

A global member cluster in a region that was not scanned appears as a `not scanned` stub row.

## Fields

| Area | Fields |
|---|---|
| Identity | account, region, name, ARN, engine, version, major, mode (provisioned / serverless v2 with min/max ACU) |
| Size | class, vCPU / memory (static class table, approximate), storage type, allocated GB, IOPS, throughput, max allocated |
| HA | Multi-AZ, AZs, member AZs, reader count, promotion tier |
| Network | endpoint, reader endpoint, custom endpoints (type, static/excluded), port, VPC, subnet group, SGs, public |
| Security | encryption, KMS key, IAM auth, deletion protection, CA cert + expiry, `rds.force_ssl` / `require_secure_transport` from the parameter group |
| Backup / maintenance | retention, backup and maintenance windows, auto minor upgrade, pending maintenance actions and dates |
| Config | cluster/instance parameter group + apply status, option group, Performance Insights + retention, enhanced monitoring, log exports, Database Insights mode |
| Lifecycle | status, created, age (days), standard/extended support end dates (`describe-db-major-engine-versions`), support status |
| Tags | `--tags` keys as columns; all tags in JSON/HTML |

## Risk flags (summary)

| Flag | Meaning |
|---|---|
| `PUBLIC` | Publicly accessible. |
| `UNENCRYPTED` | Storage is not encrypted. |
| `NO_DELETION_PROTECTION` | Deletion protection is off. |
| `SINGLE_AZ_PROD` | Single-AZ, and the `--prod-tag-key` tag matches `--prod-regex`. |
| `CA_EXPIRING` | The CA certificate expires within `--ca-days` (default 90). |
| `EXTENDED_SUPPORT` | The major version is past the end of standard support. |
| `SUPPORT_ENDING` | The end of standard support is within `--support-warn-days`. |
| `PI_OFF` | Performance Insights is off. |
| `RETENTION_LT_7` | Backup retention is under 7 days. Replicas and cluster members are excluded. |
| `STOPPED_AUTO_RESTART` | The instance is stopped, and RDS restarts it automatically after 7 days. |

## Usage

```bash
./rds_inventory_report.sh -P prod,nonprod -r us-east-1,ap-south-1                 # text to stdout
./rds_inventory_report.sh -P prod -A -F text,csv,json,html -o ~/rds_inventory     # all regions, all formats
./rds_inventory_report.sh -e 'aurora-*' -i 'pay-*' --tags Environment,Owner -F html -o /tmp
./rds_inventory_report.sh --config rds_inventory_report.conf --fast --include-docdb
./rds_inventory_report.sh --dry-run -P prod -r us-east-1                          # print calls only
```

`--config` reads `key = value` settings (see `rds_inventory_report.conf.example`). The file is parsed, never sourced, and CLI options override it. Run `-h` to see all options.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Report produced. Per-region errors are listed in the report. |
| 1 | Usage error. |
| 2 | Pre-check failed. |
| 4 | Output error. |
| 130 | Interrupted. |

Requirements: Bash 4.4+, AWS CLI v2 and jq 1.6+. Support dates need a CLI version that has `rds describe-db-major-engine-versions`. With an older CLI, they show as unknown.

## IAM (read-only)

`sts:GetCallerIdentity`, `ec2:DescribeRegions` (only with `-A`), `rds:DescribeDBInstances`, `rds:DescribeDBClusters`, `rds:DescribeGlobalClusters`, `rds:DescribeDBClusterEndpoints`, `rds:DescribePendingMaintenanceActions`, `rds:DescribeCertificates`, `rds:DescribeDBMajorEngineVersions`, `rds:DescribeDBParameters`, `rds:DescribeDBClusterParameters` (the last two are not needed with `--fast`).

If an optional call is denied, the report still runs. The affected field shows `lookup failed`, and the error is listed.

## Samples and tests

- The `samples/` folder holds text, CSV (rows and summary), JSON and HTML samples from the mock fleet. A screenshot is in `docs/sample_html.png`.
- `tests/run_tests.sh` uses a mock `aws` (`tests/mock/aws`) that refuses writes and CloudWatch. It runs 127 checks covering:
  - shellcheck;
  - grouping order and CSV contiguity;
  - every field and every flag;
  - partial and denied failures, and an old CLI without the lifecycle API;
  - a fleet of 1,800 instances and 150 clusters;
  - the HTML page in headless Chrome, when node and puppeteer are available.
- `tests/validate_cli.sh` runs these checks against the real AWS CLI v2, with fake credentials and only loopback endpoints:
  - It replays every command line the script issued against a dead endpoint, plus negative controls and a guard.
  - It compares the mock response shapes with `--generate-cli-skeleton output`.
  - It runs end-to-end against a local fake endpoint (`tests/fake_aws_endpoint.py`) that pages the results, and asserts that 0 CloudWatch requests were made.

## Caveats

- vCPU and memory come from a static class table and are approximate. They are not shown for serverless instances.
- Allocated storage excludes Aurora, whose storage is dynamic and would need CloudWatch to measure.
- Global members in regions that were not scanned appear as stubs. Scan with `-A` or add the region to see them.
