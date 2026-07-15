# lambda_function.py
#
# Purpose:
#   Triggered by a CloudWatch Alarm (via EventBridge) when the
#   "PasswordAuthFailureCount-<cluster>" metric breaches its threshold.
#   The function:
#     1. Dynamically resolves the correct CloudWatch Logs group for the
#        Aurora PostgreSQL cluster that fired the alarm (no hard-coded
#        log group name).
#     2. Runs a Logs Insights query to pull the failed-auth log lines
#        for the alarm's evaluation window.
#     3. Parses out usernames / client IPs and builds a failure summary.
#     4. Publishes a formatted, enterprise-style alert email via SNS.
#
# Environment variables required:
#   SNS_TOPIC_ARN   - ARN of the SNS topic used to send the alert email
#
# IAM permissions required (attach to the Lambda execution role):
#   logs:DescribeLogGroups
#   logs:StartQuery
#   logs:GetQueryResults
#   logs:StopQuery
#   sns:Publish

import boto3
import os
import re
import time
import json
from collections import defaultdict
from datetime import datetime
from botocore.exceptions import ClientError

logs = boto3.client("logs")
sns = boto3.client("sns")

# ---------------------------------------------------------------------------
# Configuration (env-driven, nothing hard-coded)
# ---------------------------------------------------------------------------
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

# How long we are willing to wait for a Logs Insights query to finish before
# giving up and alerting anyway (in seconds), and how often to poll.
QUERY_TIMEOUT_SECONDS = int(os.environ.get("QUERY_TIMEOUT_SECONDS", "60"))
QUERY_POLL_INTERVAL_SECONDS = int(os.environ.get("QUERY_POLL_INTERVAL_SECONDS", "1"))

# Aurora/RDS PostgreSQL log group naming conventions. We try cluster-level
# first (Aurora), then instance-level (standalone RDS), since the same
# alarm-naming pattern can front either type of resource.
LOG_GROUP_PREFIXES = [
    "/aws/rds/cluster/{name}/postgresql",
    "/aws/rds/instance/{name}/postgresql",
]

USER_REGEX = r'user "([^"]+)"'
IP_REGEX = r'UTC:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)'
DB_REGEX = r'@([^:]+):\[\d+\]'


def resolve_log_group(cluster_name):
    """
    Dynamically resolve the CloudWatch Logs group for a given Aurora/RDS
    PostgreSQL cluster or instance identifier. Tries the Aurora cluster
    naming convention first, then falls back to the standalone RDS instance
    convention. Raises ValueError if no matching log group exists.
    """
    for prefix_template in LOG_GROUP_PREFIXES:
        candidate = prefix_template.format(name=cluster_name)
        try:
            resp = logs.describe_log_groups(logGroupNamePrefix=candidate)
        except ClientError as e:
            print(f"describe_log_groups failed for prefix {candidate}: {e}")
            continue

        for log_group in resp.get("logGroups", []):
            if log_group["logGroupName"] == candidate:
                return candidate

    raise ValueError(
        f"No CloudWatch log group found for '{cluster_name}' "
        f"(tried: {[p.format(name=cluster_name) for p in LOG_GROUP_PREFIXES]})"
    )


def run_insights_query(log_group, start_time, end_time):
    """
    Runs the failed-auth Logs Insights query against the given log group
    for the given time window, polling until completion or timeout.
    Returns the list of result rows (possibly empty).
    """
    query = """
    fields @timestamp, @message
    | filter @message like /password authentication failed/
    | sort @timestamp desc
    """

    start_query_response = logs.start_query(
        logGroupName=log_group,
        startTime=int(start_time.timestamp()),
        endTime=int(end_time.timestamp()),
        queryString=query,
    )
    query_id = start_query_response["queryId"]

    elapsed = 0
    while elapsed < QUERY_TIMEOUT_SECONDS:
        result = logs.get_query_results(queryId=query_id)
        status = result["status"]

        if status == "Complete":
            return result["results"]

        if status in ("Failed", "Cancelled", "Timeout"):
            raise RuntimeError(f"Logs Insights query ended with status: {status}")

        time.sleep(QUERY_POLL_INTERVAL_SECONDS)
        elapsed += QUERY_POLL_INTERVAL_SECONDS

    # Query didn't finish in time - stop it server-side and bail out.
    try:
        logs.stop_query(queryId=query_id)
    except ClientError as e:
        print(f"stop_query failed (non-fatal): {e}")

    raise TimeoutError(
        f"Logs Insights query did not complete within {QUERY_TIMEOUT_SECONDS}s"
    )


def build_failure_summary(rows):
    """
    Parses raw Logs Insights rows into a {(username, database, ip): count}
    summary.
    """
    failures = defaultdict(int)

    for row in rows:
        message = ""
        for field in row:
            if field["field"] == "@message":
                message = field["value"]
                break

        if not message:
            continue

        user_match = re.search(USER_REGEX, message)
        ip_match = re.search(IP_REGEX, message)
        db_match = re.search(DB_REGEX, message)

        username = user_match.group(1) if user_match else "Unknown"
        ip = ip_match.group(1) if ip_match else "Unknown"
        database = db_match.group(1) if db_match else "Unknown"

        failures[(username, database, ip)] += 1

    return failures


def build_email_body(event, alarm_name, metric_name, cluster_name,
                      threshold, period, datapoints_alarm, start_date, end_date,
                      failures, total_failures):
    """
    Builds the enterprise-style plaintext email body, including the
    Failure Summary table. No "Recent Failed Login Attempts" section.
    """
    email_body = f"""
===============================================================================
                     RDS AUTHENTICATION FAILURE ALERT
===============================================================================

AWS Account : {event.get('accountId', 'Unknown')}
Region      : {event.get('region', 'Unknown')}

Cluster     : {cluster_name}

Alarm Name  : {alarm_name}
Metric      : {metric_name}

Alarm Configuration
-------------------------------------------------------------------------------
Threshold            : >= {int(threshold)} Failures
Period               : {period} Seconds
Datapoints to Alarm  : {datapoints_alarm}

Evaluation Window
-------------------------------------------------------------------------------
Start Time           : {start_date.strftime('%Y-%m-%d %H:%M:%S UTC')}
End Time             : {end_date.strftime('%Y-%m-%d %H:%M:%S UTC')}

Total Failed Logins  : {total_failures}

Failure Summary
===========================================================================
| Username             | Database          | Client IP         | Failures |
===========================================================================
"""

    for (username, database, ip), count in sorted(
        failures.items(), key=lambda x: x[1], reverse=True
    ):
        email_body += f"| {username:<20}| {database:<18}| {ip:<17}| {count:>8} |\n"

    email_body += """===========================================================================

Alert Description
-------------------------------------------------------------------------------
Amazon CloudWatch detected repeated PostgreSQL authentication failures during
the evaluation window. Review the failed login attempts above to determine
whether they are expected application behavior or a potential brute-force
attempt.

===============================================================================
Generated automatically by AWS Lambda & Amazon CloudWatch
===============================================================================
"""

    return email_body


def publish_debug_alert(alarm_name, reason):
    """Sends a lightweight SNS notification when the alarm fired but we
    could not produce a full report (e.g. no matching log lines, or an
    internal error). Keeps the on-call loop informed instead of failing
    silently."""
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"DEBUG - {alarm_name}",
            Message=reason,
        )
    except ClientError as e:
        # Nothing more we can do if SNS itself is failing - log for
        # CloudWatch Logs / metric-filter based alerting on the Lambda.
        print(f"Failed to publish debug alert to SNS: {e}")


def lambda_handler(event, context):
    print("Received Event:")
    print(json.dumps(event))

    # ---- Only act on alarms that are actually in ALARM state -------------
    try:
        if event["alarmData"]["state"]["value"] != "ALARM":
            return {"statusCode": 200, "body": "Alarm not in ALARM state, ignoring."}
    except (KeyError, TypeError) as e:
        print(f"Unexpected event shape, could not read alarm state: {e}")
        return {"statusCode": 200, "body": "Unrecognized event shape, ignoring."}

    alarm_name = event["alarmData"]["alarmName"]

    # ---- Parse alarm metadata ---------------------------------------------
    try:
        reason_data = json.loads(event["alarmData"]["state"]["reasonData"])

        threshold = reason_data.get("threshold")
        period = reason_data.get("period")
        datapoints_alarm = len(reason_data.get("evaluatedDatapoints", []))

        metric_name = (
            event["alarmData"]["configuration"]["metrics"][0]
            ["metricStat"]["metric"]["name"]
        )

        cluster_name = (
            metric_name.replace("PasswordAuthFailureCount-", "")
            if metric_name.startswith("PasswordAuthFailureCount-")
            else None
        )

        if not cluster_name:
            raise ValueError(f"Could not derive cluster name from metric '{metric_name}'")

        start_date = datetime.strptime(
            reason_data["startDate"], "%Y-%m-%dT%H:%M:%S.%f%z"
        )
        end_date = datetime.strptime(
            reason_data["queryDate"], "%Y-%m-%dT%H:%M:%S.%f%z"
        )

    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as e:
        print(f"Failed to parse alarm metadata: {e}")
        publish_debug_alert(
            alarm_name,
            f"Alarm '{alarm_name}' fired but its metadata could not be parsed: {e}",
        )
        return {"statusCode": 200, "body": "Alarm metadata parse error, debug alert sent."}

    # ---- Dynamically resolve the log group for this cluster --------------
    try:
        log_group = resolve_log_group(cluster_name)
    except ValueError as e:
        print(f"Log group resolution failed: {e}")
        publish_debug_alert(alarm_name, str(e))
        return {"statusCode": 200, "body": "Log group not found, debug alert sent."}

    # ---- Run the Logs Insights query --------------------------------------
    try:
        rows = run_insights_query(log_group, start_date, end_date)
    except (RuntimeError, TimeoutError, ClientError) as e:
        print(f"Logs Insights query failed: {e}")
        publish_debug_alert(
            alarm_name,
            f"Alarm '{alarm_name}' fired for cluster '{cluster_name}', but the "
            f"log query against '{log_group}' failed: {e}",
        )
        return {"statusCode": 200, "body": "Query error, debug alert sent."}

    failures = build_failure_summary(rows)

    if not failures:
        publish_debug_alert(
            alarm_name,
            f"Alarm '{alarm_name}' fired for cluster '{cluster_name}' "
            f"(log group '{log_group}'), but no matching authentication "
            f"failures were found in the evaluation window.",
        )
        return {"statusCode": 200, "body": "No failures found, debug alert sent."}

    total_failures = sum(failures.values())

    email_body = build_email_body(
        event, alarm_name, metric_name, cluster_name,
        threshold, period, datapoints_alarm, start_date, end_date,
        failures, total_failures,
    )

    # ---- Publish the final alert -------------------------------------------
    try:
        response = sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[RDS Alert] {cluster_name} | {total_failures} Authentication Failures",
            Message=email_body,
        )
        print(f"SNS publish response: {response}")
    except ClientError as e:
        # If SNS publish itself fails there's little else to do besides log
        # it clearly for CloudWatch-based Lambda error alerting to pick up.
        print(f"Failed to publish final alert to SNS: {e}")
        return {"statusCode": 500, "body": f"Failed to publish alert: {e}"}

    return {"statusCode": 200, "body": "Alert published successfully."}
