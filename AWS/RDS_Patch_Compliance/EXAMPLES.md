# rds_patch_compliance_report.sh - examples

All examples are read-only. Run them in AWS CloudShell (or anywhere with AWS CLI v2 and jq) from the tool folder.

```bash
# 1. Quick look at the current region
./rds_patch_compliance_report.sh

# 2. Two accounts, two regions, every format into ~/compliance
./rds_patch_compliance_report.sh -P prod,nonprod -r us-east-1,ap-south-1 -F csv,html,txt,json -o ~/compliance

# 3. Whole estate, every enabled region, HTML only
./rds_patch_compliance_report.sh -P prod --all-regions -F html -o ~/compliance

# 4. Only Aurora PostgreSQL production clusters that need patching
./rds_patch_compliance_report.sh -e aurora-postgresql -i 'prod-*' --non-compliant-only

# 5. SQL Server (all editions) and Oracle only
./rds_patch_compliance_report.sh -e 'sqlserver-*' -e 'oracle-*'

# 6. Stricter policy: at most 1 behind, warn a year before end of standard support
./rds_patch_compliance_report.sh --max-behind 1 --warn-days 365

# 7. Gate in a pipeline / cron: exit 5 when anything is NON-COMPLIANT
./rds_patch_compliance_report.sh -P prod --all-regions --fail-on-noncompliant -F csv -o /var/reports || echo "rc=$?"

# 8. Different tag columns, or none
./rds_patch_compliance_report.sh -T Environment,CostCenter
./rds_patch_compliance_report.sh -T ''

# 9. Config file + one override (CLI wins)
./rds_patch_compliance_report.sh --config rds_patch_compliance_report.conf.example --max-behind 3

# 10. Show the AWS calls without making them
./rds_patch_compliance_report.sh -P prod -r us-east-1 --dry-run

# 11. Weekly e-mail when anything is non-compliant (cron, IST)
# 30 9 * * 1  cd ~/DBA/AWS/RDS_Patch_Compliance && ./rds_patch_compliance_report.sh -P prod --all-regions -F html,csv -o ~/compliance --alert-email dba-team@example.com -l ~/compliance/run.log

# 12. Only the CSV columns you need (CSV goes to stdout without -o)
./rds_patch_compliance_report.sh -F csv | python3 -c 'import csv,sys; [print(r["identifier"], r["versions_behind"], r["compliance_status"]) for r in csv.DictReader(sys.stdin)]'

# 13. Non-compliant servers as JSON lines
./rds_patch_compliance_report.sh -F json | jq -c '.rows[] | select(.compliance_status == "NON-COMPLIANT") | {identifier, engine, current_version, latest_minor_version, versions_behind}'

# 14. All upgrade commands for one engine, to review (they are NOT run)
./rds_patch_compliance_report.sh -e aurora-mysql -F json | jq -r '.rows[].upgrade_command | select(. != "")'
```

# 15. Pending maintenance per server, readable
./rds_patch_compliance_report.sh -F json | jq -r '.rows[] | select(.pending_actions_count > 0) | "\(.identifier): \(.pending_actions)"'

# 16. Servers whose auto minor upgrade would move them, and to what
./rds_patch_compliance_report.sh -F json | jq -r '.rows[] | select(.default_auto_upgrade_target != null) | "\(.identifier) \(.current_version) -> \(.default_auto_upgrade_target) (auto minor upgrade: \(.auto_minor_upgrade))"'

# 17. Check one server's valid minor targets yourself (the exact source the report uses)
aws rds describe-db-engine-versions --engine aurora-postgresql --engine-version 15.8 --region us-east-1 \
  --query 'DBEngineVersions[].ValidUpgradeTarget[?IsMajorVersionUpgrade==`false`].[EngineVersion,AutoUpgrade]' --output table
```

Sample text summary (from the test mock, see `samples/sample_report.txt`):

```
RDS PATCH COMPLIANCE REPORT - 2026-10-15 10:53 UTC (2026-10-15 16:23 IST)
Accounts : 111111111111 (prod), 222222222222 (nonprod)   Regions: ap-south-1, us-east-1
Rule     : COMPLIANT when RDS lists at most 2 valid minor upgrade target(s) for the current version (NON-COMPLIANT = 3+; UNKNOWN = lookup failed or current version not returned)
Source   : ValidUpgradeTarget (IsMajorVersionUpgrade=false) of describe-db-engine-versions --engine-version <current>, per server. Latest minor per major = highest valid target seen (current version when up to date)

SUMMARY
  Servers/clusters : 22   COMPLIANT 13   NON-COMPLIANT 8   UNKNOWN 1   -> 59.1% compliant
  Support          : 2 past standard support (Extended Support charges), 2 ending within 180 days
  Pending maint.   : on 3 server(s): os-upgrade 2, system-update 2, db-upgrade 1 (5 action(s))
  Other flags      : auto minor upgrade off 3, current version not returned / deprecated 1

PER ENGINE / MAJOR VERSION
  ENGINE                MAJOR      TOTAL  COMPL  NON-C  UNKN  LATEST MINOR                        SUPPORT
```

## Summary script (rds_patch_compliance_summary.sh)

High-level summary plus the NON-COMPLIANT servers only (same scan and counting rules as the full report).

```bash
# 18. Summary on the screen (txt)
./rds_patch_compliance_summary.sh -P prod,nonprod -r us-east-1,ap-south-1

# 19. Summary as txt + one-page HTML + CSVs (non-compliant rows, and a summary CSV) into ~/compliance
./rds_patch_compliance_summary.sh -P prod --all-regions -F txt,html,csv -o ~/compliance

# 20. Only Oracle, stricter rule (non-compliant when 2 or more behind)
./rds_patch_compliance_summary.sh -P prod -r ap-south-1 -e 'oracle-*' --max-behind 1

# 21. Weekly job: e-mail the team only when something is non-compliant, non-zero exit for the scheduler
./rds_patch_compliance_summary.sh -P prod --all-regions --alert-email dba-team@example.com --fail-on-noncompliant
```

Sample output: [samples/sample_summary.txt](samples/sample_summary.txt), [samples/sample_summary.html](samples/sample_summary.html), screenshot [samples/sample_summary.png](samples/sample_summary.png).
