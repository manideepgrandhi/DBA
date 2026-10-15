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

Sample text summary (from the test mock, see `samples/sample_report.txt`):

```
RDS PATCH COMPLIANCE REPORT - 2026-10-15 10:17 UTC (2026-10-15 15:47 IST)
Accounts : 111111111111 (prod), 222222222222 (nonprod)   Regions: ap-south-1, us-east-1
Rule     : COMPLIANT when the server is at most 2 minor version(s) behind the newest minor AWS offers in its major line (NON-COMPLIANT = 3+ behind; UNKNOWN = version lookup failed)

SUMMARY
  Servers/clusters : 22   COMPLIANT 13   NON-COMPLIANT 9   UNKNOWN 0   -> 59.1% compliant
  Support          : 2 past standard support (Extended Support charges), 2 ending within 180 days
  Other flags      : auto minor upgrade off 3, pending maintenance on 3 (4 action(s)), deprecated version 1

PER ENGINE / MAJOR VERSION
  ENGINE                MAJOR      TOTAL  COMPL  NON-C  UNKN  LATEST MINOR                        SUPPORT
  aurora-mysql          8.0            2      1      1     0  8.0.mysql_aurora.3.10.0             ok (standard end 2029-04-02)
```
