"""HTTP API behind API Gateway.

  POST /uploads              -> presigned S3 POST (size and content-type restricted)
  GET  /images               -> most recent processed images (DynamoDB GSI query)
  GET  /images/{image_id}    -> image metadata plus a short-lived thumbnail URL
"""

import hashlib
import json
import os
import re
import uuid
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

ALLOWED_CONTENT_TYPES = {
    "image/jpeg": (".jpg", ".jpeg"),
    "image/png": (".png",),
    "image/webp": (".webp",),
    "image/gif": (".gif",),
}
IMAGE_ID_PATTERN = re.compile(r"^[a-f0-9]{32}$")
FILENAME_UNSAFE = re.compile(r"[^A-Za-z0-9._-]")
HIDDEN_FIELDS = {"original_bucket", "sha256"}
LIST_FIELDS = {"image_id", "original_key", "format", "width", "height", "processed_at"}


def _config():
    return {
        "uploads_bucket": os.environ["UPLOADS_BUCKET"],
        "processed_bucket": os.environ["PROCESSED_BUCKET"],
        "table_name": os.environ["TABLE_NAME"],
        "gsi_name": os.environ["GSI_NAME"],
        "max_bytes": int(os.environ.get("MAX_UPLOAD_BYTES", str(10 * 1024 * 1024))),
        "expiry": int(os.environ.get("URL_EXPIRY_SECONDS", "300")),
    }


def image_id_for(bucket, key):
    return hashlib.sha256(f"{bucket}/{key}".encode()).hexdigest()[:32]


def _json_default(value):
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"Cannot serialize {type(value)}")


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body, default=_json_default),
    }


def lambda_handler(event, context):
    route = (event.get("httpMethod"), event.get("resource"))

    if route == ("POST", "/uploads"):
        return create_upload(event)
    if route == ("GET", "/images"):
        return list_images(event)
    if route == ("GET", "/images/{image_id}"):
        return get_image(event)
    return response(404, {"error": "not found"})


def create_upload(event):
    cfg = _config()

    try:
        payload = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return response(400, {"error": "body must be valid JSON"})
    if not isinstance(payload, dict):
        return response(400, {"error": "body must be a JSON object"})

    filename = payload.get("filename")
    content_type = payload.get("content_type")

    if content_type not in ALLOWED_CONTENT_TYPES:
        return response(400, {"error": f"content_type must be one of {sorted(ALLOWED_CONTENT_TYPES)}"})
    if not isinstance(filename, str) or not 1 <= len(filename) <= 100:
        return response(400, {"error": "filename must be a string of 1 to 100 characters"})

    safe_name = FILENAME_UNSAFE.sub("_", filename.split("/")[-1].split("\\")[-1])
    if not safe_name.lower().endswith(ALLOWED_CONTENT_TYPES[content_type]):
        return response(400, {"error": "file extension does not match content_type"})

    key = f"uploads/{uuid.uuid4()}/{safe_name}"
    post = boto3.client("s3").generate_presigned_post(
        Bucket=cfg["uploads_bucket"],
        Key=key,
        Fields={"Content-Type": content_type},
        Conditions=[
            {"Content-Type": content_type},
            ["content-length-range", 1, cfg["max_bytes"]],
        ],
        ExpiresIn=cfg["expiry"],
    )

    return response(
        201,
        {
            "image_id": image_id_for(cfg["uploads_bucket"], key),
            "key": key,
            "upload": post,
            "expires_in": cfg["expiry"],
            "max_bytes": cfg["max_bytes"],
        },
    )


def get_image(event):
    cfg = _config()
    image_id = (event.get("pathParameters") or {}).get("image_id", "")

    if not IMAGE_ID_PATTERN.match(image_id):
        return response(400, {"error": "invalid image_id"})

    item = boto3.resource("dynamodb").Table(cfg["table_name"]).get_item(Key={"image_id": image_id}).get("Item")
    if not item:
        return response(404, {"error": "image not found (it may still be processing)"})

    item = {k: v for k, v in item.items() if k not in HIDDEN_FIELDS}
    if item.get("status") == "PROCESSED":
        item["thumbnail_url"] = boto3.client("s3").generate_presigned_url(
            "get_object",
            Params={"Bucket": cfg["processed_bucket"], "Key": item["thumbnail_key"]},
            ExpiresIn=cfg["expiry"],
        )
    return response(200, item)


def list_images(event):
    cfg = _config()
    params = event.get("queryStringParameters") or {}

    try:
        limit = int(params.get("limit", 20))
    except ValueError:
        return response(400, {"error": "limit must be an integer"})
    if not 1 <= limit <= 50:
        return response(400, {"error": "limit must be between 1 and 50"})

    result = boto3.resource("dynamodb").Table(cfg["table_name"]).query(
        IndexName=cfg["gsi_name"],
        KeyConditionExpression=Key("status").eq("PROCESSED"),
        ScanIndexForward=False,  # newest first
        Limit=limit,
    )
    items = [{k: v for k, v in item.items() if k in LIST_FIELDS} for item in result["Items"]]
    return response(200, {"count": len(items), "images": items})
