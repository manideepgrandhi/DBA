# rds_pending_maintenance_report.sh: examples

All output below comes from the mock fleet in `tests/mock/aws`. Dates are relative to the run time (2026-10-11 09:04 IST).

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
RDS pending maintenance report - rds_pending_maintenance_report.sh v1.1.0
Generated : 2026-10-11 03:34 UTC / 2026-10-11 09:04 IST
Accounts  : 111111111111 (prod), 222222222222 (nonprod)
Regions   : ap-south-1, eu-west-1, us-east-1
Filters   : engine=aurora*

URGENCY  DAYS   APPLY (IST)           ACCOUNT      REGION         TYPE     IDENTIFIER                    ENGINE                  ACTION                  OPT-IN           Environment  Owner        
CRIT     1.7    2026-10-13 02:00      111111111111 ap-south-1     cluster  payments-ams                  aurora-mysql 8.0.mysq.. db-upgrade              next-maintenance prod         payments-t.. 
         apply: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:ap-south-1:111111111111:cluster:payments-ams --apply-action db-upgrade --opt-in-type next-maintenance --region ap-south-1 --profile prod
         note : already opted in (next-maintenance); command not needed
CRIT     3      2026-10-14 09:04      111111111111 us-east-1      instance orders-prod-2 (orders-prod)   aurora-postgresql 16.8  system-update           -                prod         payments-t.. 
         apply: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:orders-prod-2 --apply-action system-update --opt-in-type next-maintenance --region us-east-1 --profile prod
WARN     20     2026-10-31 09:04      111111111111 us-east-1      cluster  orders-prod                   aurora-postgresql 16.8  db-upgrade              pending          prod         payments-t.. 
         apply: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:cluster:orders-prod --apply-action db-upgrade --opt-in-type next-maintenance --region us-east-1 --profile prod
INFO     90     2027-01-09 09:04      222222222222 ap-south-1     cluster  dev-apg                       aurora-postgresql 15.8  ca-certificate-rotation -                dev          platform-t.. 
         apply: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:ap-south-1:222222222222:cluster:dev-apg --apply-action ca-certificate-rotation --opt-in-type next-maintenance --region ap-south-1 --profile nonprod

Apply commands use --opt-in-type next-maintenance and are printed only (never run). Undo a next-maintenance opt-in with --opt-in-type undo-opt-in (see CSV/JSON undo_command).

SUMMARY: 4 pending action(s) on 4 resource(s) (15 before filters)
  by urgency : CRIT=2, WARN=1, INFO=1
  by action  : db-upgrade=2, ca-certificate-rotation=1, system-update=1
  by engine  : aurora-postgresql=3, aurora-mysql=1
  by region  : ap-south-1=2, us-east-1=2
  by account : 111111111111=3, 222222222222=1

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

## 11. The apply_command column

```bash
# default: commands use --opt-in-type next-maintenance
./rds_pending_maintenance_report.sh -P prod -r us-east-1 -i orders-prod
```

```
CRIT     3      2026-10-14 09:04      111111111111 us-east-1      instance orders-prod-2 (orders-prod)   aurora-postgresql 16.8  system-update  ...
         apply: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:db:orders-prod-2 --apply-action system-update --opt-in-type next-maintenance --region us-east-1 --profile prod
WARN     20     2026-10-31 09:04      111111111111 us-east-1      cluster  orders-prod                   aurora-postgresql 16.8  db-upgrade     ...
         apply: aws rds apply-pending-maintenance-action --resource-identifier arn:aws:rds:us-east-1:111111111111:cluster:orders-prod --apply-action db-upgrade --opt-in-type next-maintenance --region us-east-1 --profile prod
```

```bash
# print 'immediate' commands instead. They may restart / fail over the DB and cannot be undone; check the window first
./rds_pending_maintenance_report.sh -P nonprod -A --apply-opt-in immediate -F csv -o ~/reports
# just the commands for overdue/critical rows, for review in a change ticket
./rds_pending_maintenance_report.sh -P prod -A -u OVERDUE,CRIT -F json | jq -r '.rows[] | select(.apply_command != "") | "# \(.identifier) \(.action) (\(.urgency))\n\(.apply_command)"'
# rows that need a manual look (empty command)
./rds_pending_maintenance_report.sh -P prod -A -F json | jq -r '.rows[] | select(.apply_command == "") | "\(.identifier): \(.apply_note)"'
```

* DocumentDB rows get `aws docdb apply-pending-maintenance-action ...` and Neptune rows get `aws neptune ...`.
* `undo_command` holds the matching `--opt-in-type undo-opt-in` command.
* In the HTML report, each command has a **Copy** button (see `sample_report_apply_cmd.png`).

## 12. From a report row to action (manual; the script never does this)

```bash
jq -r '.rows[] | select(.urgency == "OVERDUE" or .urgency == "CRIT")
       | "aws rds apply-pending-maintenance-action --profile \(.profile) --region \(.region) --resource-identifier \(.arn) --apply-action \(.action) --opt-in-type next-maintenance"' \
   /var/reports/rds_pm/rds_pending_maintenance_*.json
```

This prints the commands for review; it runs nothing. Since v1.1.0, the same commands are in the `apply_command` column. See README.md for what each opt-in type does.
