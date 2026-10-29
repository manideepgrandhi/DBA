# RDS_Inventory_Explorer

`rds_inventory_explorer.sh` is a **read-only** Bash / AWS CLI v2 script that writes **one self-contained HTML file** of your RDS and Aurora fleet across accounts (profiles) and regions. It covers Aurora global clusters, regional Aurora clusters and Multi-AZ DB clusters, and RDS instances (standalone, read replicas and cluster members). Open the file, type or pick a resource, and you see the full metadata for **that cluster or instance alone**.

- One file, no server, no internet needed. The data is embedded in the page and nothing is loaded from the network (CSP `default-src 'none'`).
- **No CloudWatch, no secret values.** Only `sts get-caller-identity`, `ec2 describe-regions` and `rds describe-*` calls are made. The script refuses anything else (`read_only_guard`). It shows the ARN of a managed master secret, never its value.
- A **Pending maintenance** tab lists every pending action across the fleet, sorted by urgency, and both tabs export to **CSV**.
- Errors in one account or region (AccessDenied, SCP, throttling, expired SSO) are recorded and shown in the page. They never stop the run.

![Cluster card](docs/screenshot.png)

A sample page built from the test mock is in [samples/sample.html](samples/sample.html). Download it and open it in a browser.

## Quick start

```bash
# all enabled regions of two accounts; empty regions are skipped by a quick probe
./rds_inventory_explorer.sh -P prod,dev -A -o ~/rds_inventory

# one account, two regions
./rds_inventory_explorer.sh -P prod -r us-east-1,ap-south-1

# see the exact AWS calls first, without calling anything
./rds_inventory_explorer.sh -P prod,dev -A --dry-run
```

The output is `<prefix>_YYYYmmdd_HHMMSS.html` (default prefix `rds_inventory_explorer`) with mode 0640. Requirements: Bash 4.4+, AWS CLI v2 and jq.

## How it works

1. **Arguments** are validated (regions, prefix, time zone, numbers). With `--dry-run` the call plan is printed and the script stops.
2. **Pre-check:** `aws` v2 and `jq` must be present.
3. **For each profile:**
   - `sts get-caller-identity` gives the account ID. If this call fails, the profile is recorded as an error and skipped. If no profile has valid credentials, the exit code is 2.
   - The region list comes from `-r`, the profile or environment default, or with `-A` from `ec2 describe-regions`.
   - **Discovery (`-A`):** each region is probed in parallel (`--probe-parallel`, default 8) with 2 one-page calls: `describe-db-instances` and `describe-db-clusters` with `--max-records 20 --query 'length(...)' --no-paginate`.
     - Only regions with at least one instance or cluster are read in full.
     - A probe that fails (AccessDenied, SCP, timeout) is shown as an error, and that region is **still read in full**. A failed probe is never treated as an empty region.
     - `--no-discover` skips the probe.
   - **Each region is read in full** with `describe-db-clusters`, `describe-db-instances`, `describe-global-clusters`, `describe-db-cluster-endpoints` (only when the region has clusters), `describe-pending-maintenance-actions` and `describe-certificates`. All of them use the CLI's automatic pagination.
4. **Model:** `lib/explorer.jq` joins everything into one list of resources.
   - Global clusters are de-duplicated across regions.
   - Members are linked to their clusters, replicas to their sources, and pending actions and CA expiry to each resource.
   - Times are converted to UTC and the `--tz` zone (default Asia/Kolkata, IST).
   - DocumentDB and Neptune are dropped unless `--include-docdb` is given.
5. **HTML:** the model is embedded as JSON into `lib/explorer_template.html`. `<`, U+2028 and U+2029 are escaped, so a tag value like `</script>` cannot break the page. The file is written atomically.

## Using the page

- **Search box:** type-ahead over names, endpoints, engine, version, account, region and tag values. `/` focuses it, the arrow keys and Enter pick a suggestion, and Esc closes the list.
- **Dropdowns:** account, region, type (global / cluster / instance / cluster member) and engine. They filter the list table. **Clear** resets everything.
- **Selecting a resource** shows only its card.
  - Names inside the card (writer, members, global cluster, replica source, replicas) are links to their own cards.
  - The selection is kept in the URL hash, so it survives a reload and can be bookmarked. ← All resources goes back to the list.
  - **Copy JSON** copies the raw AWS describe output for that resource. **Copy ARN** copies its ARN.
- **Tabs:** **Inventory** and **Pending maintenance**. The active tab is kept in the URL hash (`#tab=pending`). Old `#id=…` links still open the Inventory card.
- **Pending maintenance tab:** one row per pending action, from the same `describe-pending-maintenance-actions` data (no extra AWS calls).
  - Count strip: total, past due, due within 7 days, due within 30 days (cumulative). Clicking a count filters by it.
  - Columns: account, region, resource (links to its card), type (cluster / instance / member), action, description, auto-applied after, forced apply, opt-in status, current apply, next maintenance window start (UTC + IST), and urgency.
  - Urgency comes from the earliest of the auto-applied, forced and current apply dates against the report time: **past due**, **< 7 days**, **< 30 days**, **later**, or **no date** (opt-in only). Rows are ordered most urgent first.
  - Filters for account, region, action and urgency, plus a text search. Every column header sorts (click again to reverse; empty values stay last).
  - Cards with pending actions show an **"N pending"** badge (a cluster counts its own and its members' actions). The list has a Pending column. Both jump to that resource's rows (`#tab=pending&res=…`); **Show all** drops the resource filter.
- **Export CSV:** a button on each tab downloads what is shown, after filters and sorting.
  - Pending: `rds_pending_maintenance_<YYYYmmdd_HHMMSS>.csv`, 19 columns (dates in UTC and the second zone, days until earliest, urgency, resource ARN).
  - Inventory: `rds_inventory_<YYYYmmdd_HHMMSS>.csv`, one flat row per resource (account, profile, region, type, identifier, engine, version, class, status, endpoint, port, Multi-AZ, encryption, KMS key, backup retention, auto minor upgrade, maintenance window in both zones, pending counts, ARN), then one `tag:<key>` column per tag key.
  - The time stamp is the report's generation time. Files are UTF-8 with a BOM (Excel opens them correctly), RFC 4180 quoting and CRLF line ends. Cells starting with `=`, `+`, `-`, `@` or a tab get a leading `'` so spreadsheets do not run them as formulas (plain numbers such as `-3` are left alone).
- **Header:** counts only. These are accounts, regions with databases, global clusters, clusters, instances (standalone and members), resources with pending maintenance, and errors. Regions without databases are never listed.
- **Theme:** auto, light and dark. The choice is stored in `localStorage` under `mg-theme`, the same key the other reports in this repo use.
- **Errors panel** at the bottom: account, profile, region, the call that failed and the message.

## What each card shows

| Card | Contents |
|---|---|
| **Global cluster** | Engine and version, status, global writer endpoint, primary and secondary regions, member clusters with role (primary / secondary), region, writer instance and write forwarding, storage encryption, deletion protection, failover state. |
| **Aurora / Multi-AZ cluster** | Writer and reader endpoints, port, custom endpoints (type, static and excluded members). Master username, whether the password is managed in Secrets Manager (secret ARN, status and its KMS key), storage KMS key, Performance Insights KMS key, IAM auth, deletion protection. **Instances:** role (writer / reader), class, AZ, status, endpoint:port, auto minor version upgrade, Performance Insights, CA and its expiry, and pending actions. **Backups:** retention, backup window (UTC + IST), earliest and latest restorable time, copy tags to snapshot, backtrack. **Maintenance:** maintenance window (UTC + IST), auto minor version upgrade (cluster setting, or how many members have it on), pending maintenance for the cluster and every member (action, description, opt-in, auto-applied-after and forced-apply dates with days left). Network and parameter groups, storage type, Serverless v2 capacity, engine lifecycle, global cluster link, and tags. |
| **Instance** (standalone or member) | Endpoint and port, class, AZ and secondary AZ, Multi-AZ, status. Storage type, allocated and max GB, IOPS and throughput. Master user, managed secret ARN and KMS key, storage KMS key, IAM auth, deletion protection, public access. Backups and maintenance windows (UTC + IST), auto minor version upgrade, pending actions, CA and its expiry. Read replica source and replicas (including cross-region), parent cluster and role, Performance Insights and its KMS key, Enhanced Monitoring, log exports, parameter and option groups, VPC, subnet group and security groups, and tags. |

## Options

| Option | Meaning |
|---|---|
| `-P, --profile NAME` | AWS CLI profile. Repeatable or comma-separated. The default is the default credential chain. |
| `-r, --region REGION` | Region(s). Repeatable or comma-separated. The default is the env / profile region. |
| `-A, --all-regions` | Every region enabled in each account, with discovery. |
| `--no-discover` | With `-A`: read every region in full, with no probe. |
| `--probe-parallel N` | Regions probed at once, 1–32 (default 8). |
| `--include-docdb` | Also list DocumentDB and Neptune clusters. |
| `-o, --output-dir DIR` | Output directory (default: the current directory). It is created if missing. |
| `--prefix NAME` | File name prefix. |
| `--csv` | Also write `<prefix>_inventory_<ts>.csv` and `<prefix>_pending_<ts>.csv` next to the HTML. They have the same columns and bytes as the page's Export CSV buttons with no filters applied. |
| `--tz ZONE` | Second time zone shown next to UTC (default `Asia/Kolkata`). |
| `--aws-timeout SEC` / `--max-attempts N` | CLI connect/read timeout (default 30) and retry attempts (default 5). |
| `--keep-workdir` | Keep the raw AWS responses for debugging. |
| `--dry-run` | Print the calls that would run, and call nothing. |
| `--save-data` | Also write `<prefix>_data_<ts>.json`: the page's dataset plus the raw describe output, with the schema version, script version, generation time, accounts and the regions scanned. This is the input for `--merge`. |
| `--merge FILE...` | Build one report from saved data files, with no AWS calls and no credentials (see below). Takes files, globs or folders. Works with `-o`, `--prefix`, `--csv`, `--save-data` and `--tz`. |
| `-v`, `-h`, `-V` | Verbose, help, version (1.2.0). |

**Exit codes:**

- `0`: the report was written. It may contain recorded errors.
- `1`: usage error.
- `2`: pre-check failed (aws or jq missing, or no profile has valid credentials).
- `3`: bad `--merge` input (file not found, not JSON, an HTML report, or an old or unknown data schema).
- `4`: output error.
- `130`: interrupted.

## Merging reports from several accounts on your desktop (Git Bash)

You do not need to copy files between accounts. Run the script in each account's CloudShell with `--save-data`, download the data files, and merge them on your own computer. The merge reads only the files, so it needs no AWS CLI, no credentials and no network.

1. In each account's CloudShell:

   ```bash
   ./rds_inventory_explorer.sh -A --save-data -o ~/rds_out
   ls ~/rds_out      # rds_inventory_explorer_data_<ts>.json is the file to download
   ```

2. Download it: **Actions → Download file**, then enter the full path, for example `/home/cloudshell-user/rds_out/rds_inventory_explorer_data_20261017_063000.json`. Put the files from every account in one folder, for example `C:\Users\<you>\Downloads\rds`.
3. Install jq once: run `winget install jqlang.jq` in PowerShell, then reopen Git Bash and check with `jq --version` (1.6 or later).
4. In Git Bash, from the folder that holds the script and its `lib/` folder:

   ```bash
   ./rds_inventory_explorer.sh --merge ~/Downloads/rds/*_data_*.json --csv -o ~/Downloads/rds/merged
   # a folder works too, as do Windows paths in quotes:
   ./rds_inventory_explorer.sh --merge "C:\Users\<you>\Downloads\rds" --csv
   start ~/Downloads/rds/merged/rds_inventory_explorer_*.html
   ```

How the merge works:

- The page is rebuilt from the raw data in each file, so it has the same tabs, filters, cards and Export CSV buttons as a normal report. `--csv` writes the two CSVs, and `--save-data` writes the merged data file, which you can merge again later.
- **Urgency is relative to the merge time.** Days left, past due and the 7 / 30 day counts on the Pending tab are worked out at the time you merge, not at the time each file was collected. The header says "Merged" and lists every source file with its collection time.
- If two files hold the same account, the file collected later is used and the older one is ignored. The log says which file won, and the header marks the ignored one.
- The header shows counts only, never lists of region names.
- A file that is not a data file stops the merge with exit code 3 and says why. Examples are an HTML report instead of the `_data_` JSON, a damaged download, or a file from an older script version.
- Requirements: Bash 4.4 or later (Git for Windows ships 5.x) and jq. The script copes with jq.exe's CRLF output, `C:\` and `/c/` paths, paths with spaces, and a `date` without `-d`.

## IAM permissions

Read-only. The AWS managed policy `ReadOnlyAccess` covers these, or use this minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "sts:GetCallerIdentity",
      "ec2:DescribeRegions",
      "rds:DescribeGlobalClusters",
      "rds:DescribeDBClusters",
      "rds:DescribeDBInstances",
      "rds:DescribeDBClusterEndpoints",
      "rds:DescribePendingMaintenanceActions",
      "rds:DescribeCertificates"
    ],
    "Resource": "*"
  }]
}
```

No CloudWatch, Secrets Manager or KMS permissions are needed. The script never calls those services.

## Tests

```bash
tests/run_tests.sh          # mock AWS CLI: options, model, HTML safety, call log, failure scenarios, browser check, scale
tests/validate_cli.sh       # the REAL AWS CLI v2 against a dead local port and a local paging fake endpoint
```

- **`run_tests.sh`** puts `tests/mock/aws` first on `PATH` and refuses to run if the `aws` it finds is not the mock. Credentials are fake, the endpoint is a dead local port, and all output goes to a temp dir.
  - It covers static checks (shellcheck, the jq library, the template), option validation, and a two-account fleet with a broken profile and an SCP-denied region.
  - It checks every card field listed above.
  - It checks the HTML: the `</script>` escape, no network references, the CSP, and empty regions never shown.
  - It checks the call log: only allowed operations, and probes are the only `--no-paginate` calls.
  - It runs the failure scenarios (throttled global clusters, empty fleet, no valid profile), the dry run (no calls), and a 1,950-resource scale run.
  - When `node` with `puppeteer-core` on `NODE_PATH` and Chrome are available, it also runs `tests/browser_check.js`. That drives the page in headless Chrome: search suggestions, filters, the card, links, the hash, Copy JSON, the theme, the Pending tab (hash, filters, search, sort, count strip, badge navigation, empty state), CSV export (the downloaded bytes are compared with the `--csv` files, plus one real Chrome download), layout at 680 / 900 / 1280 px and mobile dark, and no JS errors or network requests.
  - It checks `--save-data` and `--merge`: the data file round trip, a merge of three files where one account appears twice (the newer file wins and the log says so), and that the merged model and CSVs match a single scan. It also checks that urgency is recomputed at merge time, that bad, HTML, old-schema, newer-schema and partial files fail with exit code 3, and that the merge makes 0 AWS calls. The merge runs in a simulated Git Bash: no `aws` on PATH, a jq that writes CRLF, a `date` without `-d`, `C:\` and `/c/` paths, and spaces in paths. The browser check is run again on the merged page.
  - It checks the `--csv` files: names, mode 640, BOM, CRLF, quoting, the formula guard, and that header and values match the model (Python's `csv` module as the parser).
- **`validate_cli.sh`** replays every command line the script issues through the real CLI, so syntax, `--query` and parameter validation are checked. It also runs negative controls, checks the mock output shapes against `--generate-cli-skeleton output`, and runs a full `-A` end to end through `tests/fake_aws_endpoint.py`. That run checks paging, that the probe skips the empty region, and that no CloudWatch, Secrets Manager or KMS request is made.

## Files

```
rds_inventory_explorer.sh        the script
lib/explorer.jq                  raw AWS JSON -> page model
lib/csv.jq                       page model -> CSV (used by --csv)
lib/merge.jq                     saved data files -> one dataset (used by --merge)
lib/explorer_template.html       page (CSS + JS), data placeholder /*__EXPLORER_DATA__*/
samples/sample.html              page built from the test mock (fake accounts)
docs/screenshot.png              cluster card from the sample
tests/                           run_tests.sh, validate_cli.sh, browser_check.js, fake_aws_endpoint.py, mock/aws
```
