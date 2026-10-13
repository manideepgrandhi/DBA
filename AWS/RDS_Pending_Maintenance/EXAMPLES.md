# rds_pending_maintenance_report.sh: examples

All output below comes from the mock fleet in `tests/mock/aws`. Dates are relative to the run time (examples 2 and 13 were regenerated with v1.4.0 on 2026-10-13).

## 1. One account, default region, text to the terminal

```bash
./rds_pending_maintenance_report.sh                 # default credential chain + its region
./rds_pending_maintenance_report.sh -P prod -r ap-south-1
```

## 2. Two accounts, three regions, Aurora only, two tag columns

```bash
./rds_pending_maintenance_report.sh -P prod,nonprod -r us-east-1,ap-south-1,eu-west-1 -e 'aurora*' -T Environment,Owner
```

```
RDS pending maintenance report - rds_pending_maintenance_report.sh v1.4.0
Generated : 2026-10-13 14:55 UTC / 2026-10-13 20:25 IST
Accounts  : 111111111111 (prod), 222222222222 (nonprod)
Regions   : ap-south-1, eu-west-1, us-east-1
Filters   : engine=aurora*
Engines   : aurora-mysql (1), aurora-postgresql (3)
Order     : per engine; by cluster / server, then SEQ (1 = replicas / readers first, 2 = primary / writer last), then instance

====================================================================================================
ENGINE: aurora-mysql - 1 pending action(s) on 1 resource(s) in 1 cluster/server group(s); urgency CRIT=1; 1 behind latest minor
====================================================================================================
URGENCY  DAYS   APPLY (IST)           ACCOUNT      REGION         TYPE     SEQ ROLE               IDENTIFIER                    ENGINE                  ACTION                  OPT-IN           Environment  Owner        
CRIT     6.2    2026-10-20 02:00      111111111111 ap-south-1     cluster  1   cluster            payments-ams                  aurora-mysql 8.0.mysq.. db-upgrade              next-maintenance prod         payments-t.. 
         sequence : cluster-level action: applies to the whole cluster at once (1 member(s)); no per-instance order
         version  : 8.0.mysql_aurora.3.05.2 -> next 8.0.mysql_aurora.3.06.1, latest 8.0.mysql_aurora.3.08.0 (available: 8.0.mysql_aurora.3.06.1, 8.0.mysql_aurora.3.08.0) | auto minor upgrade: true
         backup   : SNAP_payments_ams="pre-maint-payments-ams-$(date -u +%Y%m%d-%H%M)" && aws rds create-db-cluster-snapshot --db-cluster-identifier payments-ams --db-cluster-snapshot-identifier "$SNAP_payments_ams" --region ap-south-1 --profile prod
         wait     : aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAP_payments_ams" --region ap-south-1 --profile prod
         bkp note : cluster snapshot; timestamp = UTC when the command runs; run the wait command in the same shell (uses $SNAP_payments_ams)
         immediate: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:ap-south-1:111111111111:cluster:payments-ams --apply-action db-upgrade --opt-in-type immediate --region ap-south-1 --profile prod   # may restart/fail over NOW
         status   : aws rds describe-db-clusters --db-cluster-identifier payments-ams --query 'DBClusters[0].{Status:Status,Engine:Engine,EngineVersion:EngineVersion,MaintWindow:PreferredMaintenanceWindow,PendingModified:PendingModifiedValues,MultiAZ:MultiAZ,Members:DBClusterMembers[].{Instance:DBInstanceIdentifier,Writer:IsClusterWriter}}' --output table --region ap-south-1 --profile prod
         pending  : aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:ap-south-1:111111111111:cluster:payments-ams --output table --region ap-south-1 --profile prod
         minor upg: aws rds modify-db-cluster --db-cluster-identifier payments-ams --engine-version 8.0.mysql_aurora.3.08.0 --region ap-south-1 --profile prod   # next maintenance window
         note     : already scheduled for the next window; immediate applies it now - may restart/fail over

====================================================================================================
ENGINE: aurora-postgresql - 3 pending action(s) on 3 resource(s) in 2 cluster/server group(s); urgency CRIT=1, WARN=1, INFO=1; 2 behind latest minor
====================================================================================================
URGENCY  DAYS   APPLY (IST)           ACCOUNT      REGION         TYPE     SEQ ROLE               IDENTIFIER                    ENGINE                  ACTION                  OPT-IN           Environment  Owner        
INFO     90     2027-01-11 20:25      222222222222 ap-south-1     cluster  1   cluster            dev-apg                       aurora-postgresql 15.8  ca-certificate-rotation -                dev          platform-t.. 
         sequence : cluster-level action: applies to the whole cluster at once (1 member(s)); no per-instance order
         version  : 15.8 -> next 15.10, latest 15.13 (available: 15.10, 15.12, 15.13) | auto minor upgrade: false
         backup   : SNAP_dev_apg="pre-maint-dev-apg-$(date -u +%Y%m%d-%H%M)" && aws rds create-db-cluster-snapshot --db-cluster-identifier dev-apg --db-cluster-snapshot-identifier "$SNAP_dev_apg" --region ap-south-1 --profile nonprod
         wait     : aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAP_dev_apg" --region ap-south-1 --profile nonprod
         bkp note : cluster snapshot; timestamp = UTC when the command runs; run the wait command in the same shell (uses $SNAP_dev_apg)
         immediate: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:ap-south-1:222222222222:cluster:dev-apg --apply-action ca-certificate-rotation --opt-in-type immediate --region ap-south-1 --profile nonprod   # may restart/fail over NOW
         status   : aws rds describe-db-clusters --db-cluster-identifier dev-apg --query 'DBClusters[0].{Status:Status,Engine:Engine,EngineVersion:EngineVersion,MaintWindow:PreferredMaintenanceWindow,PendingModified:PendingModifiedValues,MultiAZ:MultiAZ,Members:DBClusterMembers[].{Instance:DBInstanceIdentifier,Writer:IsClusterWriter}}' --output table --region ap-south-1 --profile nonprod
         pending  : aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:ap-south-1:222222222222:cluster:dev-apg --output table --region ap-south-1 --profile nonprod
         minor upg: aws rds modify-db-cluster --db-cluster-identifier dev-apg --engine-version 15.13 --region ap-south-1 --profile nonprod   # next maintenance window
         note     : applies as soon as possible - may restart/fail over; check impact first
WARN     20     2026-11-02 20:25      111111111111 us-east-1      cluster  1   cluster            orders-prod                   aurora-postgresql 16.8  db-upgrade              pending          prod         payments-t.. 
         sequence : cluster-level action: applies to the whole cluster at once (2 member(s)); no per-instance order
         version  : 16.8 -> next 16.9, latest 16.10 (available: 16.9, 16.10) | auto minor upgrade: true
         backup   : SNAP_orders_prod="pre-maint-orders-prod-$(date -u +%Y%m%d-%H%M)" && aws rds create-db-cluster-snapshot --db-cluster-identifier orders-prod --db-cluster-snapshot-identifier "$SNAP_orders_prod" --region us-east-1 --profile prod
         wait     : aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAP_orders_prod" --region us-east-1 --profile prod
         bkp note : cluster snapshot; timestamp = UTC when the command runs; run the wait command in the same shell (uses $SNAP_orders_prod)
         immediate: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:cluster:orders-prod --apply-action db-upgrade --opt-in-type immediate --region us-east-1 --profile prod   # may restart/fail over NOW
         status   : aws rds describe-db-clusters --db-cluster-identifier orders-prod --query 'DBClusters[0].{Status:Status,Engine:Engine,EngineVersion:EngineVersion,MaintWindow:PreferredMaintenanceWindow,PendingModified:PendingModifiedValues,MultiAZ:MultiAZ,Members:DBClusterMembers[].{Instance:DBInstanceIdentifier,Writer:IsClusterWriter}}' --output table --region us-east-1 --profile prod
         pending  : aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:us-east-1:111111111111:cluster:orders-prod --output table --region us-east-1 --profile prod
         minor upg: aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 --region us-east-1 --profile prod   # next maintenance window
         note     : applies as soon as possible - may restart/fail over; check impact first
CRIT     3      2026-10-16 20:25      111111111111 us-east-1      instance 1   replica (reader)   orders-prod-2 (orders-prod)   aurora-postgresql 16.8  system-update           -                prod         payments-t.. 
         sequence : reader of orders-prod: patch readers first, one at a time, then the writer
         version  : 16.8 -> next 16.9, latest 16.10 (available: 16.9, 16.10) | auto minor upgrade: true
         backup   : SNAP_orders_prod="pre-maint-orders-prod-$(date -u +%Y%m%d-%H%M)" && aws rds create-db-cluster-snapshot --db-cluster-identifier orders-prod --db-cluster-snapshot-identifier "$SNAP_orders_prod" --region us-east-1 --profile prod
         wait     : aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAP_orders_prod" --region us-east-1 --profile prod
         bkp note : replica (reader) of orders-prod: instance snapshots are not possible for cluster members; the cluster snapshot covers all members; timestamp = UTC when the command runs; run the wait command in the same shell (uses $SNAP_orders_prod)
         immediate: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:orders-prod-2 --apply-action system-update --opt-in-type immediate --region us-east-1 --profile prod   # may restart/fail over NOW
         status   : aws rds describe-db-instances --db-instance-identifier orders-prod-2 --query 'DBInstances[0].{Status:DBInstanceStatus,PendingModified:PendingModifiedValues,MaintWindow:PreferredMaintenanceWindow,Engine:Engine,EngineVersion:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,AutoMinorUpgrade:AutoMinorVersionUpgrade,CACert:CACertificateIdentifier,Cluster:DBClusterIdentifier}' --output table --region us-east-1 --profile prod
         pending  : aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:us-east-1:111111111111:db:orders-prod-2 --output table --region us-east-1 --profile prod
         minor upg: aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 --region us-east-1 --profile prod   # next maintenance window
         note     : applies as soon as possible - may restart/fail over; check impact first

Commands are printed only (never run). backup + wait: manual snapshot before patching (name pre-maint-<id>-<UTC time when run>; run both in the same shell). immediate (--opt-in-type immediate) starts the maintenance now and may restart/fail over the DB; status/pending are read-only lookups; minor upg (modify ... --engine-version) applies in the next maintenance window unless --apply-immediately is added.

SUMMARY: 4 pending action(s) on 4 resource(s) (15 before filters)
  by urgency : CRIT=2, WARN=1, INFO=1
  by action  : db-upgrade=2, ca-certificate-rotation=1, system-update=1
  by engine  : aurora-postgresql=3, aurora-mysql=1
  by region  : ap-south-1=2, us-east-1=2
  by account : 111111111111=3, 222222222222=1
  minor ver. : 3 server(s) behind the latest minor version: dev-apg (15.8 -> 15.13), orders-prod (16.8 -> 16.10), payments-ams (8.0.mysql_aurora.3.05.2 -> 8.0.mysql_aurora.3.08.0)

Overall: CRIT (exit 11)
```

## 3. All regions, every format into a directory

```bash
./rds_pending_maintenance_report.sh -P prod -P nonprod --all-regions -F csv,html,json,text -o /var/reports/rds_pm
# -> /var/reports/rds_pm/rds_pending_maintenance_20261011_081848.{csv,html,json,txt}  (mode 0640)
```

## 4. Filters

```bash
# only what is overdue or due within 7 days
./rds_pending_maintenance_report.sh -P prod -r us-east-1 -u OVERDUE,CRIT
# SQL Server OS work in production
./rds_pending_maintenance_report.sh -P prod -A -e 'sqlserver-*' -a system-update,os-upgrade -t Environment=prod
# a team's resources by tag (values are globs, case-insensitive; keys are exact)
./rds_pending_maintenance_report.sh -P prod -A -t 'Owner=payments*'
# one cluster and its instances
./rds_pending_maintenance_report.sh -P prod -r us-east-1 -i orders-prod
# CA rotations that still need doing (plan client trust-store updates)
./rds_pending_maintenance_report.sh -P prod -P nonprod -A -a ca-certificate-rotation -F csv -o ~/reports
```

## 5. DocumentDB via its own API

```bash
./rds_pending_maintenance_report.sh -P prod -r us-east-1 --include-docdb -e docdb -F json | jq -c '.rows[] | {identifier, cluster, source, action, urgency, days_until, effective_apply_local}'
```

```
{"identifier":"catalog-docdb","cluster":"","source":"docdb","action":"system-update","urgency":"CRIT","days_until":5,"effective_apply_local":"2026-10-16 08:23 IST"}
{"identifier":"catalog-docdb-1","cluster":"catalog-docdb","source":"rds","action":"db-upgrade","urgency":"WARN","days_until":12,"effective_apply_local":"2026-10-23 08:23 IST"}
```

The cluster-level action appeared only through the docdb API (`source: docdb`). The instance action was returned by both APIs and is listed once.

## 6. Partial failure (AccessDenied in one region)

```bash
./rds_pending_maintenance_report.sh -P prod -r eu-west-1,ap-south-1 -u overdue,crit
```

```
  by urgency : CRIT=2
  by action  : db-upgrade=2
  by engine  : aurora-mysql=1, oracle-ee=1
  by region  : ap-south-1=2
  by account : 111111111111=2
ERRORS (report incomplete):
  111111111111 prod eu-west-1 rds describe-pending-maintenance-actions: An error occurred (AccessDenied) when calling the DescribePendingMaintenanceActions operation: User: arn:aws:sts::111111111111:assumed-role/DBA-ReadOnly/manideep is not authorized to perform: rds:DescribePendingMaintenanceActions with an explicit deny in a service control policy
Overall: CRIT (exit 11)
2026-10-11 09:04:53 [INFO] Result: CRIT - 2 pending action(s) on 2 resource(s); urgency CRIT=2; 1 error(s); 5 AWS call(s); exit 11
```

If nothing were CRIT, the exit code would be 3 so the gap cannot go unnoticed.

## 7. Thresholds and time zone

```bash
./rds_pending_maintenance_report.sh -P prod -A --crit-days 3 --warn-days 14
./rds_pending_maintenance_report.sh -P prod -A --tz UTC           # UTC only
./rds_pending_maintenance_report.sh -P prod -A --tz Europe/London # UTC + London
```

## 8. Alerts

```bash
# e-mail only when something is CRIT/overdue or an AWS call failed (default --alert-on crit)
./rds_pending_maintenance_report.sh --config /etc/dba/rds_pm.conf --alert-email dba-team@example.com
# Slack-compatible webhook for anything pending
./rds_pending_maintenance_report.sh --config /etc/dba/rds_pm.conf --alert-webhook "$SLACK_WEBHOOK_URL" --alert-on pending
# JSON webhook payload (status, summary, urgent rows, errors)
./rds_pending_maintenance_report.sh --config /etc/dba/rds_pm.conf --alert-webhook https://alerts.example.com/hook --alert-webhook-format json
# test the alert path without calling AWS
./rds_pending_maintenance_report.sh --alert-test --alert-email dba-team@example.com
```

* Subject: `[rds_pending_maintenance] CRIT: 15 pending, 1 overdue, 4 due <= 7d (exit 11)`
* Webhook URLs are passed to curl through stdin, so they never appear on a command line, and they are redacted in logs.

## 9. Use the exit code

```bash
./rds_pending_maintenance_report.sh -P prod -A -F csv -o /var/reports/rds_pm; rc=$?
case $rc in
  0)  echo "nothing pending" ;;
  10) echo "pending, nothing urgent" ;;
  11) echo "CRIT/overdue maintenance - act now" ;;
  3)  echo "report incomplete - check permissions/regions" ;;
  *)  echo "failed ($rc)" ;;
esac
```

## 10. Dry run and debugging

```bash
./rds_pending_maintenance_report.sh -P prod,nonprod -A --include-docdb --dry-run   # shows the AWS calls, calls nothing
./rds_pending_maintenance_report.sh -P prod -r us-east-1 -v --keep-workdir         # keeps raw JSON responses
```

## 11. Commands in every row (printed only)

```bash
./rds_pending_maintenance_report.sh -P prod -r us-east-1 -i orders-prod
```

```
CRIT     3      2026-10-16 19:48      111111111111 us-east-1      instance orders-prod-2 (orders-prod)   aurora-postgresql 16.8  system-update           -                prod         payments-t.. orders       
         version  : 16.8 -> next 16.9, latest 16.10 (available: 16.9, 16.10) | auto minor upgrade: true
         immediate: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:orders-prod-2 --apply-action system-update --opt-in-type immediate --region us-east-1 --profile prod   # may restart/fail over NOW
         status   : aws rds describe-db-instances --db-instance-identifier orders-prod-2 --query 'DBInstances[0].{Status:DBInstanceStatus,PendingModified:PendingModifiedValues,MaintWindow:PreferredMaintenanceWindow,Engine:Engine,EngineVersion:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,AutoMinorUpgrade:AutoMinorVersionUpgrade,CACert:CACertificateIdentifier,Cluster:DBClusterIdentifier}' --output table --region us-east-1 --profile prod
         pending  : aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:us-east-1:111111111111:db:orders-prod-2 --output table --region us-east-1 --profile prod
         minor upg: aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 --region us-east-1 --profile prod   # next maintenance window
         note     : applies as soon as possible - may restart/fail over; check impact first
WARN     20     2026-11-02 19:48      111111111111 us-east-1      cluster  orders-prod                   aurora-postgresql 16.8  db-upgrade              pending          prod         payments-t.. orders       
         version  : 16.8 -> next 16.9, latest 16.10 (available: 16.9, 16.10) | auto minor upgrade: true
         immediate: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:cluster:orders-prod --apply-action db-upgrade --opt-in-type immediate --region us-east-1 --profile prod   # may restart/fail over NOW
         status   : aws rds describe-db-clusters --db-cluster-identifier orders-prod --query 'DBClusters[0].{Status:Status,Engine:Engine,EngineVersion:EngineVersion,MaintWindow:PreferredMaintenanceWindow,PendingModified:PendingModifiedValues,MultiAZ:MultiAZ,Members:DBClusterMembers[].{Instance:DBInstanceIdentifier,Writer:IsClusterWriter}}' --output table --region us-east-1 --profile prod
         pending  : aws rds describe-pending-maintenance-actions --resource-identifier arn:aws:rds:us-east-1:111111111111:cluster:orders-prod --output table --region us-east-1 --profile prod
         minor upg: aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 --region us-east-1 --profile prod   # next maintenance window
         note     : applies as soon as possible - may restart/fail over; check impact first
```

```bash
# just the immediate commands for overdue/critical rows, for review in a change ticket
./rds_pending_maintenance_report.sh -P prod -A -u OVERDUE,CRIT -F json | jq -r '.rows[] | select(.apply_immediate_command != "") | "# \(.identifier) \(.action) (\(.urgency))\n\(.apply_immediate_command)"'
# rows that need a manual look (no immediate command)
./rds_pending_maintenance_report.sh -P prod -A -F json | jq -r '.rows[] | select(.apply_immediate_command == "") | "\(.identifier): \(.apply_note)"'
```

* DocumentDB rows get `aws docdb ...` and Neptune rows get `aws neptune ...`.
* `apply_immediate_command` may restart / fail over the DB now. Run `status_command` afterwards: `Status` other than `available` (e.g. `upgrading`, `maintenance`, `rebooting`) means maintenance is in progress.
* In the HTML report, each command has a **Copy** button (see `sample_report_apply_cmd.png`).
* `--apply-opt-in` and the next-maintenance / undo commands were removed in v1.3.0; the option is ignored with a warning.

## 11b. Minor version patch details (v1.3.0)

```bash
# servers behind their latest minor version, with the upgrade command
./rds_pending_maintenance_report.sh -P prod,nonprod -A -F json \
  | jq -r '[.rows[] | select(.minor_behind)] | unique_by(.minor_upgrade_command)[]
           | "\(.identifier) \(.engine) \(.engine_version) -> \(.latest_minor_version) (auto minor upgrade: \(.auto_minor_upgrade))\n  \(.minor_upgrade_command)"'
# orders-prod aurora-postgresql 16.8 -> 16.10 (auto minor upgrade: true)
#   aws rds modify-db-cluster --db-cluster-identifier orders-prod --engine-version 16.10 --region us-east-1 --profile prod
# crm-sql-prod sqlserver-se 15.00.4415.2.v1 -> 15.00.4430.1.v1 (auto minor upgrade: false)
#   aws rds modify-db-instance --db-instance-identifier crm-sql-prod --engine-version 15.00.4430.1.v1 --region us-east-1 --profile prod

# faster run without the extra describe-db-engine-versions calls
./rds_pending_maintenance_report.sh -P prod -A --no-version-check
```

* Minor upgrades print without `--apply-immediately`, so they apply in the next maintenance window. Add `--apply-immediately` only in a change window: the DB restarts.
* Aurora / DocumentDB / Neptune rows (including member-instance rows) get `modify-db-cluster`; standalone instances get `modify-db-instance`.
* The text summary has a `minor ver.` line and the HTML a "behind latest minor" card.

## 13. Patching order and backups (v1.4.0)

```bash
./rds_pending_maintenance_report.sh -P prod -r us-west-2 -e postgres -T ''
```

```
====================================================================================================
ENGINE: postgres - 3 pending action(s) on 3 resource(s) in 2 cluster/server group(s); urgency WARN=3; 3 behind latest minor
====================================================================================================
URGENCY  DAYS   APPLY (IST)           ACCOUNT      REGION         TYPE     SEQ ROLE               IDENTIFIER                    ENGINE                  ACTION                  OPT-IN           
WARN     28     2026-11-10 20:25      111111111111 us-west-2      instance 1   replica            billing-pg-rr1                postgres 16.4           os-upgrade              -                
         sequence : read replica of billing-pg: patch replicas before the source
         backup   : SNAP_billing_pg="pre-maint-billing-pg-$(date -u +%Y%m%d-%H%M)" && aws rds create-db-snapshot --db-instance-identifier billing-pg --db-snapshot-identifier "$SNAP_billing_pg" --region us-west-2 --profile prod
         wait     : aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP_billing_pg" --region us-west-2 --profile prod
         bkp note : read replica: the snapshot is taken of its source billing-pg; a snapshot of the replica itself is optional; timestamp = UTC when the command runs; run the wait command in the same shell (uses $SNAP_billing_pg)
WARN     28     2026-11-10 20:25      111111111111 us-west-2      instance 2   primary (Multi-AZ) billing-pg                    postgres 16.4           os-upgrade              -                
         sequence : source of 1 read replica(s) (billing-pg-rr1): patch the replicas first, then this primary; Multi-AZ: the standby is patched first, then a failover (short outage)
         backup   : SNAP_billing_pg="pre-maint-billing-pg-$(date -u +%Y%m%d-%H%M)" && aws rds create-db-snapshot --db-instance-identifier billing-pg --db-snapshot-identifier "$SNAP_billing_pg" --region us-west-2 --profile prod
         wait     : aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP_billing_pg" --region us-west-2 --profile prod
         bkp note : instance snapshot; timestamp = UTC when the command runs; run the wait command in the same shell (uses $SNAP_billing_pg)
WARN     28     2026-11-10 20:25      111111111111 us-west-2      instance 1   replica            billing-pg-dr                 postgres 16.4           os-upgrade              -                
         sequence : read replica of arn:aws:rds:us-east-1:111111111111:db:billing-pg-east (cross-region): patch replicas before the source
         bkp note : cross-region read replica of arn:aws:rds:us-east-1:111111111111:db:billing-pg-east: snapshot the source in its own region (a snapshot of the replica is optional)
```

Read each group top-down: replica `billing-pg-rr1` (SEQ 1) before its source `billing-pg` (SEQ 2). The cross-region replica `billing-pg-dr` is its own group and gets no backup command (snapshot its source in us-east-1).

```bash
# run in CloudShell for one server: backup, wait, then patch
SNAP_billing_pg="pre-maint-billing-pg-$(date -u +%Y%m%d-%H%M)" && aws rds create-db-snapshot --db-instance-identifier billing-pg --db-snapshot-identifier "$SNAP_billing_pg" --region us-west-2 --profile prod
aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP_billing_pg" --region us-west-2 --profile prod
echo "$SNAP_billing_pg"     # e.g. pre-maint-billing-pg-20261013-1455 (UTC)

# per-engine CSV files next to the full one
./rds_pending_maintenance_report.sh -P prod,nonprod -A -F csv,html -o ~/reports --split-by-engine
# -> rds_pending_maintenance_<stamp>.csv/.html + rds_pending_maintenance_<stamp>_aurora-mysql.csv, ..._postgres.csv, ...

# JSON grouped by engine: patch order per Aurora PostgreSQL cluster
jq -r '.engines[] | select(.engine == "aurora-postgresql") | .rows[] | "\(.patch_group)\t\(.patch_sequence)\t\(.identifier)\t\(.role)"' report.json
```

## 12. From a report row to action (manual; the script never does this)

```bash
jq -r '.rows[] | select(.urgency == "OVERDUE" or .urgency == "CRIT")
       | "aws rds apply-pending-maintenance-action --profile \(.profile) --region \(.region) --resource-identifier \(.arn) --apply-action \(.action) --opt-in-type immediate"' \
   /var/reports/rds_pm/rds_pending_maintenance_*.json
```

This prints the commands for review; it runs nothing. The same commands are in the `apply_immediate_command` column. See README.md for what each opt-in type does.
