"""Image processor: S3 upload -> SQS -> this Lambda.

For every uploaded image it creates a thumbnail, writes metadata to DynamoDB and
sends a notification through SNS.

Error handling follows two rules:
  * Permanent problems (not an image, too large, unsupported format) are recorded
    as REJECTED and the message is consumed, because retrying can never succeed.
  * Transient problems (AWS throttling, network errors) are reported back to SQS
    as partial batch failures, so only those messages are retried and, after
    maxReceiveCount attempts, land in the dead-letter queue.
"""

import hashlib
import io
import json
import logging
import os
import urllib.parse
from datetime import datetime, timezone

import boto3
from PIL import Image, ImageOps, UnidentifiedImageError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Guard against decompression bombs (a small file that expands to a huge bitmap)
Image.MAX_IMAGE_PIXELS = 50_000_000

ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP", "GIF"}
UPLOAD_PREFIX = "uploads/"
THUMBNAIL_PREFIX = "thumbnails/"


class PermanentError(Exception):
    """The object can never be processed, so retrying is pointless."""


def _config():
    return {
        "processed_bucket": os.environ["PROCESSED_BUCKET"],
        "table_name": os.environ["TABLE_NAME"],
        "topic_arn": os.environ["TOPIC_ARN"],
        "thumbnail_size": int(os.environ.get("THUMBNAIL_SIZE", "256")),
        "max_bytes": int(os.environ.get("MAX_UPLOAD_BYTES", str(10 * 1024 * 1024))),
    }


def image_id_for(bucket, key):
    """Deterministic id, so a retried message overwrites the same item (idempotent)."""
    return hashlib.sha256(f"{bucket}/{key}".encode()).hexdigest()[:32]


def lambda_handler(event, context):
    failures = []

    for message in event.get("Records", []):
        try:
            body = json.loads(message["body"])
            for s3_record in body.get("Records", []):  # S3 test events have no Records
                process_s3_record(s3_record)
        except Exception:  # noqa: BLE001 - anything unexpected is retried via SQS
            logger.exception("Failed to process message %s", message.get("messageId"))
            failures.append({"itemIdentifier": message["messageId"]})

    return {"batchItemFailures": failures}


def process_s3_record(s3_record):
    cfg = _config()
    bucket = s3_record["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(s3_record["s3"]["object"]["key"])

    if not key.startswith(UPLOAD_PREFIX):
        logger.info("Ignoring object outside %s: %s", UPLOAD_PREFIX, key)
        return

    image_id = image_id_for(bucket, key)
    s3 = boto3.client("s3")

    try:
        item = build_item(s3, cfg, bucket, key, image_id)
        status_for_event = "PROCESSED"
    except PermanentError as error:
        logger.warning("Rejected %s: %s", key, error)
        item = {
            "image_id": image_id,
            "original_bucket": bucket,
            "original_key": key,
            "status": "REJECTED",
            "reason": str(error),
            "processed_at": _now(),
        }
        status_for_event = "REJECTED"

    boto3.resource("dynamodb").Table(cfg["table_name"]).put_item(Item=item)
    notify(cfg, item, status_for_event)
    logger.info("%s image_id=%s key=%s", status_for_event, image_id, key)


def build_item(s3, cfg, bucket, key, image_id):
    response = s3.get_object(Bucket=bucket, Key=key)
    size = response["ContentLength"]
    if size > cfg["max_bytes"]:
        response["Body"].close()
        raise PermanentError(f"file is {size} bytes, the limit is {cfg['max_bytes']}")

    data = response["Body"].read()

    try:
        image = Image.open(io.BytesIO(data))
        image_format = image.format
        if image_format not in ALLOWED_FORMATS:
            raise PermanentError(f"unsupported format: {image_format}")
        image.load()  # fully decodes the file, so corrupt images fail here
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError, SyntaxError) as error:
        raise PermanentError(f"not a valid image ({type(error).__name__})") from error

    width, height = image.size

    # Thumbnail: respect EXIF rotation, then drop all metadata (location, camera...)
    thumbnail = ImageOps.exif_transpose(image)
    thumbnail.thumbnail((cfg["thumbnail_size"], cfg["thumbnail_size"]))
    if thumbnail.mode not in ("RGB", "RGBA"):
        thumbnail = thumbnail.convert("RGBA" if "transparency" in thumbnail.info else "RGB")

    buffer = io.BytesIO()
    thumbnail.save(buffer, format="WEBP", quality=80)
    buffer.seek(0)

    thumbnail_key = f"{THUMBNAIL_PREFIX}{image_id}.webp"
    s3.put_object(
        Bucket=cfg["processed_bucket"],
        Key=thumbnail_key,
        Body=buffer.getvalue(),
        ContentType="image/webp",
    )

    return {
        "image_id": image_id,
        "original_bucket": bucket,
        "original_key": key,
        "format": image_format,
        "width": width,
        "height": height,
        "size_bytes": size,
        "sha256": hashlib.sha256(data).hexdigest(),
        "thumbnail_key": thumbnail_key,
        "thumbnail_width": thumbnail.size[0],
        "thumbnail_height": thumbnail.size[1],
        "status": "PROCESSED",
        "processed_at": _now(),
    }


def notify(cfg, item, status):
    if status == "PROCESSED":
        subject = "Image processed"
        message = {
            "image_id": item["image_id"],
            "status": status,
            "key": item["original_key"],
            "format": item["format"],
            "width": item["width"],
            "height": item["height"],
            "thumbnail_key": item["thumbnail_key"],
        }
    else:
        subject = "Image rejected"
        message = {
            "image_id": item["image_id"],
            "status": status,
            "key": item["original_key"],
            "reason": item["reason"],
        }

    boto3.client("sns").publish(
        TopicArn=cfg["topic_arn"],
        Subject=subject,
        Message=json.dumps(message),
        MessageAttributes={"status": {"DataType": "String", "StringValue": status}},
    )


def _now():
    return datetime.now(timezone.utc).isoformat()
