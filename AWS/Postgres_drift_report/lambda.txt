
import boto3
import json
import csv
import io
import os
from datetime import datetime

rds = boto3.client("rds")
s3 = boto3.client("s3")
sns = boto3.client("sns")

BUCKET = os.environ["BUCKET_NAME"]
BASELINE_KEY = os.environ["BASELINE_KEY"]
SNS_TOPIC = os.environ["SNS_TOPIC_ARN"]


def load_baseline():
    response = s3.get_object(
        Bucket=BUCKET,
        Key=BASELINE_KEY
    )

    return json.loads(
        response["Body"].read().decode("utf-8")
    )


def load_exceptions():
    try:
        response = s3.get_object(
            Bucket=BUCKET,
            Key="exceptions/exceptions.json"
        )

        return json.loads(
            response["Body"].read().decode("utf-8")
        )

    except Exception:
        print("No exceptions file found")
        return {}


def get_parameter_values(parameter_group):
    params = {}
    marker = None

    while True:
        kwargs = {
            "DBParameterGroupName": parameter_group
        }

        if marker:
            kwargs["Marker"] = marker

        response = rds.describe_db_parameters(**kwargs)

        for p in response["Parameters"]:

            if p.get("ParameterName") in [
                "rds.force_ssl",
                "log_connections",
                "log_disconnections"
            ]:
                print("DEBUG PARAMETER")
                print(p)

            if "ParameterValue" in p:
                params[p["ParameterName"]] = p["ParameterValue"]

        marker = response.get("Marker")

        if not marker:
            break

    return params


def lambda_handler(event, context):

    baseline = load_baseline()
    exceptions = load_exceptions()

    drifts = []

    response = rds.describe_db_instances()

    for db in response["DBInstances"]:

        if db["Engine"] != "postgres":
            continue

        instance_name = db["DBInstanceIdentifier"]

        parameter_group = (
            db["DBParameterGroups"][0]["DBParameterGroupName"]
        )

        params = get_parameter_values(parameter_group)

        print("DEBUG VALUES")
        print("rds.force_ssl =", params.get("rds.force_ssl"))
        print("log_connections =", params.get("log_connections"))
        print("log_disconnections =", params.get("log_disconnections"))

        current_values = {
            "deletion_protection": db.get("DeletionProtection"),
            "publicly_accessible": db.get("PubliclyAccessible"),
            "storage_encrypted": db.get("StorageEncrypted"),
            "backup_retention_period": db.get("BackupRetentionPeriod"),
            "force_ssl": params.get("rds.force_ssl"),
            "log_connections": params.get("log_connections"),
            "log_disconnections": params.get("log_disconnections")
        }

        for check, rule in baseline["checks"].items():

            expected = rule["expected"]

            if (
                instance_name in exceptions
                and check in exceptions[instance_name]
            ):
                expected = exceptions[instance_name][check]

            actual = current_values.get(check)

            if str(expected) != str(actual):
                drifts.append({
                    "instance": instance_name,
                    "check": check,
                    "expected": expected,
                    "current": actual,
                    "severity": rule["severity"]
                })

    print("DRIFTS FOUND")
    print(json.dumps(drifts, indent=2, default=str))

    csv_buffer = io.StringIO()

    writer = csv.DictWriter(
        csv_buffer,
        fieldnames=[
            "instance",
            "check",
            "expected",
            "current",
            "severity"
        ]
    )

    writer.writeheader()

    for drift in drifts:
        writer.writerow(drift)

    report_name = (
        "reports/drift-report-"
        + datetime.utcnow().strftime("%Y%m%d-%H%M%S")
        + ".csv"
    )

    s3.put_object(
        Bucket=BUCKET,
        Key=report_name,
        Body=csv_buffer.getvalue()
    )

    if drifts:
        message = (
            f"PostgreSQL Drift Detection Completed\n\n"
            f"Drift Count: {len(drifts)}\n"
            f"Report: s3://{BUCKET}/{report_name}"
        )
    else:
        message = (
            "PostgreSQL Drift Detection Completed\n\n"
            "No drift detected."
        )

    sns.publish(
        TopicArn=SNS_TOPIC,
        Subject="PostgreSQL Drift Report",
        Message=message
    )

    return {
        "status": "success",
        "drift_count": len(drifts),
        "report": report_name
    }

