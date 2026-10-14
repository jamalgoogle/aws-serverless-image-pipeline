import importlib.util
import io
import json
import os
from pathlib import Path

import boto3
import pytest
from moto import mock_aws
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
REGION = "us-east-1"
UPLOADS_BUCKET = "novacart-test-image-uploads-123456789012"
PROCESSED_BUCKET = "novacart-test-image-processed-123456789012"
TABLE_NAME = "novacart-test-images"
GSI_NAME = "status-processed_at-index"


def _load(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    for key, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_SESSION_TOKEN": "testing",
        "AWS_DEFAULT_REGION": REGION,
        "UPLOADS_BUCKET": UPLOADS_BUCKET,
        "PROCESSED_BUCKET": PROCESSED_BUCKET,
        "TABLE_NAME": TABLE_NAME,
        "GSI_NAME": GSI_NAME,
        "THUMBNAIL_SIZE": "256",
        "MAX_UPLOAD_BYTES": str(10 * 1024 * 1024),
    }.items():
        monkeypatch.setenv(key, value)


@pytest.fixture
def aws(aws_env):
    """Mocked AWS resources that mirror what Terraform creates."""
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket=UPLOADS_BUCKET)
        s3.create_bucket(Bucket=PROCESSED_BUCKET)

        dynamodb = boto3.resource("dynamodb", region_name=REGION)
        table = dynamodb.create_table(
            TableName=TABLE_NAME,
            BillingMode="PAY_PER_REQUEST",
            KeySchema=[{"AttributeName": "image_id", "KeyType": "HASH"}],
            AttributeDefinitions=[
                {"AttributeName": "image_id", "AttributeType": "S"},
                {"AttributeName": "status", "AttributeType": "S"},
                {"AttributeName": "processed_at", "AttributeType": "S"},
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": GSI_NAME,
                    "KeySchema": [
                        {"AttributeName": "status", "KeyType": "HASH"},
                        {"AttributeName": "processed_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
        )

        # SNS topic with an SQS subscriber, so tests can read published notifications
        sns = boto3.client("sns", region_name=REGION)
        sqs = boto3.client("sqs", region_name=REGION)
        topic_arn = sns.create_topic(Name="novacart-test-image-notifications")["TopicArn"]
        queue_url = sqs.create_queue(QueueName="notification-listener")["QueueUrl"]
        queue_arn = sqs.get_queue_attributes(QueueUrl=queue_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
        sns.subscribe(TopicArn=topic_arn, Protocol="sqs", Endpoint=queue_arn)
        os.environ["TOPIC_ARN"] = topic_arn

        class Env:
            pass

        env = Env()
        env.s3, env.table, env.sqs, env.queue_url = s3, table, sqs, queue_url
        env.processor = _load("processor_handler", "lambda/processor/handler.py")
        env.api = _load("api_handler", "lambda/api/handler.py")

        def notifications():
            messages = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10).get("Messages", [])
            return [json.loads(json.loads(m["Body"])["Message"]) for m in messages]

        env.notifications = notifications
        yield env
        os.environ.pop("TOPIC_ARN", None)


def make_image(fmt="PNG", size=(800, 600), color=(30, 120, 200), **save_kwargs):
    buffer = io.BytesIO()
    Image.new("RGB", size, color).save(buffer, format=fmt, **save_kwargs)
    return buffer.getvalue()


def sqs_event(key, message_id="msg-1", bucket=UPLOADS_BUCKET):
    """An SQS event carrying an S3 'ObjectCreated' notification (the key is URL-encoded, like S3 does)."""
    from urllib.parse import quote_plus

    s3_notification = {
        "Records": [
            {
                "eventName": "ObjectCreated:Post",
                "s3": {"bucket": {"name": bucket}, "object": {"key": quote_plus(key)}},
            }
        ]
    }
    return {"Records": [{"messageId": message_id, "body": json.dumps(s3_notification)}]}
