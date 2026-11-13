"""AWS simulé en mémoire (moto) : S3, SQS, DynamoDB, EventBridge.

Les handlers Lambda créent leurs clients boto3 à l'import : on les importe
donc APRÈS avoir démarré le simulateur.
"""

import importlib
import json
import os
from dataclasses import dataclass

import boto3
import pytest
from moto import mock_aws

os.environ.update(
    {
        "AWS_DEFAULT_REGION": "eu-west-3",
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "INVOICES_TABLE": "invoices",
        "IDEMPOTENCY_TABLE": "idempotency",
        "EVENT_BUS_NAME": "invoices",
        "UPLOAD_BUCKET": "invoices-upload",
        "APPROVED_SUPPLIERS": "SBEE,Canal Olympia,MTN Benin",
        "REVIEW_THRESHOLD": "5000000",
        "POWERTOOLS_TRACE_DISABLED": "1",
        "POWERTOOLS_SERVICE_NAME": "invoices",
        "POWERTOOLS_METRICS_NAMESPACE": "InvoicePipeline",
    }
)


@dataclass
class FakeContext:
    function_name: str = "processor"
    memory_limit_in_mb: int = 256
    invoked_function_arn: str = "arn:aws:lambda:eu-west-3:123456789012:function:processor"
    aws_request_id: str = "req-1"

    def get_remaining_time_in_millis(self) -> int:
        return 30_000


@pytest.fixture
def aws():
    with mock_aws():
        s3 = boto3.client("s3")
        s3.create_bucket(Bucket="invoices-upload", CreateBucketConfiguration={"LocationConstraint": "eu-west-3"})
        ddb = boto3.client("dynamodb")
        ddb.create_table(
            TableName="invoices",
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[
                {"AttributeName": "invoice_id", "AttributeType": "S"},
                {"AttributeName": "status", "AttributeType": "S"},
            ],
            KeySchema=[{"AttributeName": "invoice_id", "KeyType": "HASH"}],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "by-status",
                    "KeySchema": [{"AttributeName": "status", "KeyType": "HASH"}],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
        )
        ddb.create_table(
            TableName="idempotency",
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        )
        # Bus d'événements + règle qui recopie tout vers une file d'observation
        events = boto3.client("events")
        events.create_event_bus(Name="invoices")
        sqs = boto3.client("sqs")
        spy = sqs.create_queue(QueueName="spy")["QueueUrl"]
        spy_arn = sqs.get_queue_attributes(QueueUrl=spy, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
        events.put_rule(
            Name="all", EventBusName="invoices", EventPattern=json.dumps({"source": ["invoices.processor"]})
        )
        events.put_targets(Rule="all", EventBusName="invoices", Targets=[{"Id": "spy", "Arn": spy_arn}])

        from invoices import api, processor

        importlib.reload(processor)
        importlib.reload(api)
        yield {"s3": s3, "sqs": sqs, "spy": spy, "processor": processor, "api": api}


@pytest.fixture
def context():
    return FakeContext()


def published_events(aws) -> list[dict]:
    messages = aws["sqs"].receive_message(QueueUrl=aws["spy"], MaxNumberOfMessages=10).get("Messages", [])
    return [json.loads(m["Body"]) for m in messages]


def sqs_event(*objects: tuple[str, str]) -> dict:
    """Construit un lot SQS contenant des événements EventBridge « Object Created »."""
    records = []
    for i, (key, etag) in enumerate(objects):
        body = {
            "detail-type": "Object Created",
            "source": "aws.s3",
            "detail": {"bucket": {"name": "invoices-upload"}, "object": {"key": key, "etag": etag}},
        }
        records.append(
            {
                "messageId": f"msg-{i}",
                "receiptHandle": f"rh-{i}",
                "body": json.dumps(body),
                "attributes": {"ApproximateReceiveCount": "1"},
                "messageAttributes": {},
                "md5OfBody": "",
                "eventSource": "aws:sqs",
                "eventSourceARN": "arn:aws:sqs:eu-west-3:123456789012:invoices",
                "awsRegion": "eu-west-3",
            }
        )
    return {"Records": records}
