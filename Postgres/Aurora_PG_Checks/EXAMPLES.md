# aurora_pg_check.sh - examples

All examples are read-only. Exit codes: 0 OK, 10 WARN, 11 CRIT, 3 AWS call failures, 2 pre-check, 1 usage.

## 1. First run: what would it do?
```bash
./aurora_pg_check.sh -P dba-prod -r ap-south-1 --dry-run
```
This prints the resolved settings, the thresholds and every `aws ...` command, without calling AWS.

## 2. Every Aurora PostgreSQL cluster in one region
```bash
./aurora_pg_check.sh -P dba-prod -r ap-south-1
```

## 3. Only the problems
```bash
./aurora_pg_check.sh -P dba-prod -r ap-south-1 -q
```
The summary table is always shown. Clusters without problems print `all N checks OK`.

## 4. Specific clusters (ids or ARNs), several regions
```bash
./aurora_pg_check.sh -P dba-prod -r us-east-1,ap-south-1 -c orders-prod -c payments-prod
./aurora_pg_check.sh -r us-east-1 -c arn:aws:rds:us-east-1:123456789012:cluster:orders-prod
```
A requested cluster that is found in none of the regions is reported as `cluster_found` CRIT.

## 5. The whole account
```bash
./aurora_pg_check.sh -P dba-prod --all-regions -q
```
Regions come from `ec2 describe-regions` (enabled regions only).

## 6. Pick check groups
```bash
./aurora_pg_check.sh -r ap-south-1 -C backups                  # backup posture only
./aurora_pg_check.sh -r ap-south-1 -C cluster,metrics -L 2h      # quick "is it healthy right now"
./aurora_pg_check.sh -r ap-south-1 -X metrics,events             # configuration audit, no CloudWatch cost
```

## 7. Metric window and resolution
```bash
./aurora_pg_check.sh -r ap-south-1 -C metrics -L 6h --period 60   # last 6 h, 1-minute resolution
./aurora_pg_check.sh -r ap-south-1 -C metrics -L 7d --period 3600 # weekly trend, hourly points
```
`-L` accepts `90m`, `6h`, `2d`, `1w`. A bare number means hours.

## 8. Tune thresholds
```bash
./aurora_pg_check.sh --list-thresholds
./aurora_pg_check.sh -r ap-south-1 -s cpu_warn=70 -s cpu_crit=90 -s backup_retention_warn=14
./aurora_pg_check.sh -r ap-south-1 -s public_access_crit=1 -s require_iam_auth=1   # stricter security
./aurora_pg_check.sh -r ap-south-1 -s require_auto_minor_upgrade=0                 # AMVU off on purpose
./aurora_pg_check.sh -r ap-south-1 -s max_connections=5000                         # known max_connections
```

## 9. Transaction-ID wraparound watch
```bash
./aurora_pg_check.sh -r ap-south-1 -C metrics -L 1h -q -s xid_warn=300000000
```
If `MaximumUsedTransactionIDs` is WARN/CRIT, look in the database at the oldest
`age(datfrozenxid)` per database, long-running transactions (`pg_stat_activity.backend_xmin`),
abandoned replication slots (`pg_replication_slots`) and prepared transactions (`pg_prepared_xacts`).

## 10. Replication slots holding WAL
```bash
./aurora_pg_check.sh -r ap-south-1 -C metrics -q -s slot_lag_warn_mb=512
```
`TransactionLogsDiskUsage` / `ReplicationSlotDiskUsage` / `OldestReplicationSlotLag` usually point at
a stopped DMS task or CDC consumer.

## 11. Before a maintenance weekend
```bash
./aurora_pg_check.sh -r ap-south-1 -C versions,config -D
```
Shows pending maintenance actions with their auto-apply dates, parameter groups waiting for a
reboot, upgrade targets and CA expiry, with per-instance details.

## 12. Serverless v2 capacity
```bash
./aurora_pg_check.sh -r eu-west-1 -c events-sls -C cluster,metrics -D
```
Shows the min/max ACU, peak `ServerlessDatabaseCapacity` and `ACUUtilization` against `acu_util_warn`.

## 13. JSON for scripting
```bash
./aurora_pg_check.sh -r ap-south-1 -f json -o /tmp/aurora.json
jq -r '.results[] | select(.status=="CRIT" or .status=="WARN") | [.cluster,.check,.status,.reason] | @tsv' /tmp/aurora.json
jq '.summary.clusters' /tmp/aurora.json
jq -r '.results[] | select(.check=="MaximumUsedTransactionIDs") | "\(.cluster) \(.value)"' /tmp/aurora.json
```
Top-level keys: `meta` (account, regions, thresholds, aws_calls...), `clusters`, `results`, `summary`.

## 14. HTML report to share
```bash
./aurora_pg_check.sh -P dba-prod --all-regions -f html -o ~/reports/aurora_$(date +%F).html
```
One self-contained file: a summary table and a section per cluster with colour-coded statuses and details.

## 15. Alerts
```bash
# Slack-compatible webhook, WARN and worse (default --alert-on warn)
./aurora_pg_check.sh -r ap-south-1 -q --alert-webhook "$SLACK_WEBHOOK_URL"
# structured JSON to an internal endpoint, only CRIT/ERROR
./aurora_pg_check.sh -r ap-south-1 --alert-webhook https://alerts.internal/aurora --alert-webhook-format json --alert-on crit
# e-mail to the DBA team
./aurora_pg_check.sh -r ap-south-1 --alert-email dba-team@example.com --alert-from aurora-check@example.com
# check the alert path without calling AWS
./aurora_pg_check.sh --alert-test --alert-email dba-team@example.com --alert-webhook "$SLACK_WEBHOOK_URL"
```
The alert body is the problems-only text report. The JSON format carries `status`, `exit_code`,
`clusters` and `problems[]`. Alerts never change the exit code.

## 16. Config file + cron
```bash
cp aurora_pg_check.conf.example /etc/dba/aurora_pg_check.conf
./aurora_pg_check.sh --config /etc/dba/aurora_pg_check.conf --dry-run      # check it
./aurora_pg_check.sh --config /etc/dba/aurora_pg_check.conf -C backups      # CLI overrides the file
```
```cron
*/30 * * * * AWS_PROFILE=dba-readonly-role /opt/dba/aurora_pg_checks/aurora_pg_check.sh --config /etc/dba/aurora_pg_check.conf -q -o /var/log/dba/aurora_latest.txt 2>>/var/log/dba/aurora_pg_check.log
```

## 17. Using the exit code
```bash
./aurora_pg_check.sh -r ap-south-1 -q > /tmp/aurora.txt; rc=$?
case $rc in
  0)  echo "healthy" ;;
  10) echo "warnings - review /tmp/aurora.txt" ;;
  11) echo "CRITICAL - page the on-call DBA" ;;
  3)  echo "incomplete: some AWS calls failed (permissions/throttling)" ;;
  2)  echo "cannot run: credentials or tooling" ;;
  *)  echo "usage/internal error $rc" ;;
esac
```
In a CI/CD pipeline you might gate on CRIT only: `./aurora_pg_check.sh ... || [ $? -eq 10 ]`.

## 18. SSO session
```bash
aws sso login --profile dba-prod
./aurora_pg_check.sh -P dba-prod -r ap-south-1
```
An expired token gives exit 2 and the exact `aws sso login --profile ...` command to run.

## 19. Debugging
```bash
./aurora_pg_check.sh -r ap-south-1 -v --keep-workdir     # log every AWS call, keep the raw JSON
```
The raw responses are kept under `$TMPDIR/aurora_pg_check.XXXXXX/<region>/` (`r_*.json`, `queries.json`,
`errors.json`, `eval.json`). `--max-attempts 10` helps with throttling on large fleets. `--aws-timeout`
sets the connect/read timeout.

## 20. Running the test suite (no AWS needed)
```bash
tests/run_tests.sh          # mock scenarios, all formats, alerts to local stubs
tests/validate_cli.sh       # real AWS CLI v2 validates every command line the script issues
MOCK_SCENARIO=metrics PATH="$PWD/tests/mock:$PATH" ./aurora_pg_check.sh -r us-east-1 -q   # play with a scenario
```
Scenarios: `fleet` (default), `issues`, `metrics`, `serverless` (eu-west-1), `apifail`, `instfail`, `badcreds`.
