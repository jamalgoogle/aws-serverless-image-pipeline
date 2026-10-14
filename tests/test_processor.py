import io
import json

from PIL import Image

from conftest import PROCESSED_BUCKET, UPLOADS_BUCKET, make_image, sqs_event


def put_upload(aws, key, data):
    aws.s3.put_object(Bucket=UPLOADS_BUCKET, Key=key, Body=data)


def only_item(aws):
    items = aws.table.scan()["Items"]
    assert len(items) == 1, items
    return items[0]


def test_valid_image_is_processed(aws):
    key = "uploads/1111/photo.png"
    put_upload(aws, key, make_image("PNG", (800, 600)))

    result = aws.processor.lambda_handler(sqs_event(key), None)

    assert result == {"batchItemFailures": []}

    item = only_item(aws)
    assert item["status"] == "PROCESSED"
    assert item["format"] == "PNG"
    assert (item["width"], item["height"]) == (800, 600)
    assert item["original_key"] == key
    assert len(item["sha256"]) == 64

    thumbnail = aws.s3.get_object(Bucket=PROCESSED_BUCKET, Key=item["thumbnail_key"])
    assert thumbnail["ContentType"] == "image/webp"
    image = Image.open(io.BytesIO(thumbnail["Body"].read()))
    assert image.format == "WEBP"
    assert max(image.size) == 256
    assert (item["thumbnail_width"], item["thumbnail_height"]) == image.size


def test_notification_is_published_to_sns(aws):
    key = "uploads/2222/photo.jpg"
    put_upload(aws, key, make_image("JPEG"))

    aws.processor.lambda_handler(sqs_event(key), None)

    [notification] = aws.notifications()
    assert notification["status"] == "PROCESSED"
    assert notification["key"] == key
    assert notification["format"] == "JPEG"


def test_thumbnail_does_not_keep_exif_metadata(aws):
    key = "uploads/3333/camera.jpg"
    image = Image.new("RGB", (400, 300), (10, 10, 10))
    exif = Image.Exif()
    exif[0x010F] = "SecretCameraMaker"  # EXIF "Make" tag
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", exif=exif)
    put_upload(aws, key, buffer.getvalue())

    aws.processor.lambda_handler(sqs_event(key), None)

    item = only_item(aws)
    body = aws.s3.get_object(Bucket=PROCESSED_BUCKET, Key=item["thumbnail_key"])["Body"].read()
    assert b"SecretCameraMaker" not in body
    assert len(Image.open(io.BytesIO(body)).getexif()) == 0


def test_file_that_is_not_an_image_is_rejected_without_retry(aws):
    key = "uploads/4444/fake.png"
    put_upload(aws, key, b"this is not an image")

    result = aws.processor.lambda_handler(sqs_event(key), None)

    assert result["batchItemFailures"] == []  # consumed, retrying cannot help
    item = only_item(aws)
    assert item["status"] == "REJECTED"
    assert "not a valid image" in item["reason"]
    assert "thumbnail_key" not in item
    [notification] = aws.notifications()
    assert notification["status"] == "REJECTED"


def test_unsupported_format_is_rejected(aws):
    key = "uploads/5555/image.bmp"
    put_upload(aws, key, make_image("BMP"))

    aws.processor.lambda_handler(sqs_event(key), None)

    item = only_item(aws)
    assert item["status"] == "REJECTED"
    assert "unsupported format: BMP" in item["reason"]


def test_oversized_file_is_rejected(aws, monkeypatch):
    monkeypatch.setenv("MAX_UPLOAD_BYTES", "100")
    key = "uploads/6666/big.png"
    put_upload(aws, key, make_image("PNG", (500, 500)))

    aws.processor.lambda_handler(sqs_event(key), None)

    item = only_item(aws)
    assert item["status"] == "REJECTED"
    assert "limit is 100" in item["reason"]


def test_objects_outside_the_upload_prefix_are_ignored(aws):
    key = "somewhere-else/photo.png"
    put_upload(aws, key, make_image("PNG"))

    result = aws.processor.lambda_handler(sqs_event(key), None)

    assert result == {"batchItemFailures": []}
    assert aws.table.scan()["Items"] == []


def test_s3_test_event_is_ignored(aws):
    event = {"Records": [{"messageId": "m1", "body": json.dumps({"Service": "Amazon S3", "Event": "s3:TestEvent"})}]}
    assert aws.processor.lambda_handler(event, None) == {"batchItemFailures": []}


def test_transient_failure_is_reported_for_retry(aws):
    # The object does not exist, which surfaces as an unexpected AWS error
    result = aws.processor.lambda_handler(sqs_event("uploads/7777/missing.png", message_id="retry-me"), None)

    assert result == {"batchItemFailures": [{"itemIdentifier": "retry-me"}]}
    assert aws.table.scan()["Items"] == []


def test_only_the_failing_message_in_a_batch_is_retried(aws):
    good_key = "uploads/8888/good.png"
    put_upload(aws, good_key, make_image("PNG"))
    good = sqs_event(good_key, message_id="good")["Records"][0]
    bad = sqs_event("uploads/9999/missing.png", message_id="bad")["Records"][0]

    result = aws.processor.lambda_handler({"Records": [good, bad]}, None)

    assert result == {"batchItemFailures": [{"itemIdentifier": "bad"}]}
    assert only_item(aws)["original_key"] == good_key


def test_processing_is_idempotent(aws):
    key = "uploads/aaaa/photo.png"
    put_upload(aws, key, make_image("PNG"))

    aws.processor.lambda_handler(sqs_event(key), None)
    aws.processor.lambda_handler(sqs_event(key), None)  # SQS delivers at least once

    assert len(aws.table.scan()["Items"]) == 1


def test_url_encoded_keys_are_decoded(aws):
    key = "uploads/bbbb/my holiday photo.png"
    put_upload(aws, key, make_image("PNG"))

    result = aws.processor.lambda_handler(sqs_event(key), None)

    assert result == {"batchItemFailures": []}
    assert only_item(aws)["original_key"] == key
