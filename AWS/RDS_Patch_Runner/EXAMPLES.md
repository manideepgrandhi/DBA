# rds_patch_runner.sh - examples

All examples assume AWS CloudShell or a shell with AWS CLI v2 and jq, run from this folder.

## 1. Look first: dry run (the default)

```
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod
```
This makes describe calls only. It prints the members, their roles and pending actions, then the plan in execution order ([sample](samples/dry_run_plan.txt)):

```
PLAN (in this order; one step at a time, stop on the first failure):
  1. snapshot   : create-db-cluster-snapshot pre-maint-orders-prod-<UTC YYYYMMDD-HHMM>, wait until available
  2. reader     : orders-prod-2 <- system-update, os-upgrade (--opt-in-type immediate), wait until available and nothing pending
  3. reader     : orders-prod-3 <- system-update (--opt-in-type immediate), wait until available and nothing pending
  4. cluster    : orders-prod <- db-upgrade (cluster-level, --opt-in-type immediate), wait for cluster + members
  5. writer     : orders-prod-1 <- system-update (--opt-in-type immediate), wait until available and nothing pending
  6. verify     : no pending actions left, all available, versions
```

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
Other actions (for example `db-upgrade`) stay pending. They are shown as "not selected" in the plan and listed under "PENDING ACTIONS LEFT" in the summary.

## 5. Minor version upgrade together with the maintenance

```
# newest minor target of the current version (e.g. 15.4 -> 15.10); no step if already latest
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --minor-upgrade latest
# an exact version (must be a valid non-major upgrade target, else exit 2)
./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod --minor-upgrade 15.6 --execute
```
The upgrade runs right after the snapshot (`modify-db-cluster --engine-version V --apply-immediately`). The tool waits until the cluster and every member are available on V. After that, the readers, cluster-level actions and writer are processed as usual; any pending action that AWS cleared during the upgrade is shown as `skipped`.

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
* [Successful run with a failover during the writer patch](samples/orders-prod_sample.log) and its [summary](samples/orders-prod_sample.summary.txt).
* [A reader failure](samples/orders-prod_reader_failure_sample.log): the run stops before the writer, exits 3, and the [summary](samples/orders-prod_reader_failure_sample.summary.txt) lists what is still pending.

When a run stops (exit 3 or 130), fix the cause and then simply run the same command again. The tool re-reads what is still pending and continues from there. Steps whose actions are already done are skipped. A new pre-maintenance snapshot is taken on each run unless you pass `--skip-snapshot`.
