# rds_patch_runner.sh - examples

All examples assume AWS CloudShell or a shell with AWS CLI v2 and jq, run from this folder.

## 1. Look first: dry run (the default)

```
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod
```
This makes describe calls only and saves the output to `./rds_patch_runs` (see example 11). It prints the minor version availability, the members with role, status, version and pending actions, each pending action with its type, description and dates, and then the plan numbered in the exact execution order ([sample](samples/dry_run_plan.txt)):

```
MINOR VERSION AVAILABILITY (describe-db-engine-versions, non-major targets only)
  current engine version : 15.4
  auto minor upgrade     : true
  next minor             : 15.5
  latest minor           : 15.10
  available minors       : 15.5, 15.6, 15.10
  --minor-upgrade        : latest -> 15.10 (runs LAST, after the rolling pass is verified)

MEMBERS   ROLE    INSTANCE                        STATUS      CLASS             VERSION       PENDING
          reader  orders-prod-2                   available   db.r6g.large      15.4          system-update, os-upgrade
          reader  orders-prod-3                   available   db.r6g.large      15.4          system-update
          writer  orders-prod-1                   available   db.r6g.large      15.4          system-update
          cluster orders-prod                     available   -                 15.4          db-upgrade

PENDING MAINTENANCE (per resource, in apply order)
  ROLE    RESOURCE                      ACTION                    TYPE                    AUTO-APPLIED AFTER    FORCED APPLY          DESCRIPTION
  reader  orders-prod-2                 system-update             system patch            2026-11-01T04:00:00Z  -                     New Operating System update is available
  reader  orders-prod-2                 os-upgrade                OS update               2026-11-01T04:00:00Z  2026-12-01T04:00:00Z  OS upgrade
  reader  orders-prod-3                 system-update             system patch            2026-11-01T04:00:00Z  -                     New Operating System update is available
  writer  orders-prod-1                 system-update             system patch            2026-11-01T04:00:00Z  -                     New Operating System update is available
  cluster orders-prod                   db-upgrade                DB update               2026-11-01T04:00:00Z  -                     Cluster engine patch

PLAN (exact execution order; ONE rolling pass, then the minor upgrade; stop on the first failure):
  1.  snapshot   : create-db-cluster-snapshot pre-maint-orders-prod-<UTC YYYYMMDD-HHMM>, wait until available
  2.  reader     : orders-prod-2 <- system-update [system patch] (--opt-in-type immediate), wait until available and system-update gone
  3.  reader     : orders-prod-2 <- os-upgrade [OS update] (--opt-in-type immediate), wait until available and os-upgrade gone
  4.  reader     : orders-prod-3 <- system-update [system patch] (--opt-in-type immediate), wait until available and system-update gone
  5.  cluster    : orders-prod <- db-upgrade [DB update, cluster-level] (--opt-in-type immediate), wait for cluster + members
  6.  writer     : orders-prod-1 <- system-update [system patch] (--opt-in-type immediate), wait until available and system-update gone
  7.  verify     : rolling pass done? cluster + all members available, selected actions gone (else STOP, no minor upgrade)
  8.  minor upg  : re-check the latest minor (skip if a DB update already got there), then modify-db-cluster --engine-version 15.10 --apply-immediately (from 15.4; ALL instances restart together), wait until cluster + members available on 15.10
```

One rolling pass: each reader gets its actions back to back (`system-update`, then `os-upgrade`, then `db-upgrade`, then any other type), then the cluster-level actions, then the writer. The minor upgrade comes last.

## 2. Patch (interactive)

```
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --execute --html -o ~/patch_runs
# Patch orders-prod (account 123456789012, us-east-1)? [y/N] y
```
CloudShell ends idle sessions (about 20 minutes without keyboard input), which would stop a long run. For long clusters, use `nohup` with `--yes` (example 3), or keep the session active.

## 3. Unattended (cron / nohup / CodeBuild): `--yes` is required without a terminal

```
nohup ./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --execute --yes \
      --timeout-min 90 -o /var/log/rds_patch --html \
      --alert-email dba-team@example.com --alert-on always >/dev/null 2>&1 &
tail -f /var/log/rds_patch/orders-prod_*.log
```
Without `--yes`, a run with no terminal aborts with exit 4 and changes nothing.

## 4. Only some actions

```
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --action system-update --execute
```
Other actions (for example `db-upgrade`) stay pending. They are shown as "not selected" in the plan and listed under "PENDING ACTIONS LEFT" in the summary. The minor upgrade still runs at the end unless you add `--minor-upgrade none` (the log warns when unselected actions are still pending).

## 5. Minor version upgrade (last step)

```
# default: patch everything, then the latest minor (e.g. 15.4 -> 15.10); skipped if already latest
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --execute
# an exact minor (must be a valid non-major upgrade target, else exit 2)
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --minor-upgrade 15.6 --execute
# maintenance only, no engine version change
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --minor-upgrade none --execute
```
The upgrade runs only after the rolling pass is verified. The tool re-reads the version first; if a `db-upgrade` already moved the cluster to the latest minor, the step is `skipped: already at latest`. Otherwise it runs `modify-db-cluster --engine-version T --apply-immediately` and waits until the cluster and every member are available on T. An Aurora minor upgrade restarts all instances at the same time (not rolling), so this is the main downtime moment of the run.

## 6. DocumentDB / Neptune

```
./rds_patch_runner.sh -P prod -r us-east-1 -c catalog-docdb --execute
```
These engines use the same flow. Apply and snapshot calls go through `aws docdb` / `aws neptune`. The snapshot waiter is `aws rds wait db-cluster-snapshot-available`, because docdb and neptune have no waiters, with polling as the fallback.

## 7. Using a config file

```
cp rds_patch_runner.conf.example ~/rds_patch_runner.conf     # edit profile/region/output
./rds_patch_runner.sh --config ~/rds_patch_runner.conf -c orders-prod            # dry run
./rds_patch_runner.sh --config ~/rds_patch_runner.conf -c orders-prod --execute  # real run
```
The config file cannot switch on `--execute` or `--yes`.

## 8. Several clusters, one after the other (stop on the first problem)

```
for c in orders-prod billing-prod; do
  ./rds_patch_runner.sh -P prod -r us-east-1 -c "$c" --execute --yes -o ~/patch_runs || { echo "stopped at $c (exit $?)"; break; }
done
```

## 9. Find candidates with the report, then patch

```
../RDS_Pending_Maintenance/rds_pending_maintenance_report.sh -P prod -r us-east-1 -F text
./rds_patch_runner.sh -P prod -r us-east-1 -c <cluster from the report>
```

## 10. Reading the result

```
$ echo $?            # 0 ok / nothing to do, 2 preflight abort, 3 step failed or timeout, 4 declined, 130 interrupted
$ cat ~/patch_runs/orders-prod_*.summary.txt
```
* [Successful run: rolling pass, then the minor upgrade](samples/orders-prod_sample.log) and its [summary](samples/orders-prod_sample.summary.txt).
* [A reader failure](samples/orders-prod_reader_failure_sample.log): the run stops before the writer, does not run the minor upgrade, exits 3, and the [summary](samples/orders-prod_reader_failure_sample.summary.txt) lists what is still pending.

When a run stops (exit 3 or 130), fix the cause and then simply run the same command again. The tool re-reads what is still pending and continues from there. Steps whose actions are already done are skipped. A new pre-maintenance snapshot is taken on each run unless you pass `--skip-snapshot`.

## 11. Where the files go, and downloading them from CloudShell

```
$ ./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --html -o ~/patch_reports
...
[INFO] Saved (dry-run): /home/cloudshell-user/patch_reports/orders-prod_20261015_041241_plan.json, /home/cloudshell-user/patch_reports/orders-prod_20261015_041241_plan.txt, /home/cloudshell-user/patch_reports/orders-prod_20261015_041241_plan.html, /home/cloudshell-user/patch_reports/orders-prod_20261015_041241_dryrun.log
$ ls -l ~/patch_reports
orders-prod_20261015_041241_dryrun.log
orders-prod_20261015_041241_plan.html
orders-prod_20261015_041241_plan.json
orders-prod_20261015_041241_plan.txt
```
* Without `-o`, the files go to `./rds_patch_runs` under the folder you ran the script from. `--no-save` prints only.
* Execute runs write `<cluster>_<stamp>.log`, `.summary.txt`, `.summary.csv`, `.json` (+ `.summary.html` with `--html`) to the same folder.
* `-l ~/orders_dry.log` writes the log there instead; the plan files still go to the output folder.
* Download one file: CloudShell **Actions > Download file**, then paste the full path from the `Saved` line.
* Download everything: `cd ~ && zip -r patch_runs.zip rds_patch_runs` (or zip the folder you passed to `-o`), then download `/home/cloudshell-user/patch_runs.zip`.

See README "Output files" for the full table per mode (dry run / execute / failed / interrupted).
