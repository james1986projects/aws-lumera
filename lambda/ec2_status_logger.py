import os
from datetime import datetime, timezone

import boto3

ec2 = boto3.client("ec2")
s3 = boto3.client("s3")

def lambda_handler(event, context):
    # bucket name is passed via environment variable LOG_BUCKET
    bucket = os.environ["LOG_BUCKET"]

    # describe instances in the account/region
    resp = ec2.describe_instances()
    reservations = resp.get("Reservations", [])

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    lines = []
    for r in reservations:
        for inst in r.get("Instances", []):
            iid = inst["InstanceId"]
            state = inst["State"]["Name"]
            lines.append(f"{ts} - {iid} - {state}")

    if not lines:
        lines = [f"{ts} - no instances found"]

    body = "\n".join(lines).encode("utf-8")
    s3.put_object(Bucket=bucket, Key=f"logs/ec2_status_{ts}.txt", Body=body)

    return {"count": len(lines)}
