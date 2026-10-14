import json

from conftest import GSI_NAME, UPLOADS_BUCKET, make_image, sqs_event  # noqa: F401


def call(aws, method, resource, body=None, path_params=None, query=None):
    event = {
        "httpMethod": method,
        "resource": resource,
        "body": json.dumps(body) if body is not None else None,
        "pathParameters": path_params,
        "queryStringParameters": query,
    }
    result = aws.api.lambda_handler(event, None)
    return result["statusCode"], json.loads(result["body"])


def test_create_upload_returns_presigned_post(aws):
    status, body = call(aws, "POST", "/uploads", {"filename": "cat.png", "content_type": "image/png"})

    assert status == 201
    assert body["key"].startswith("uploads/") and body["key"].endswith("/cat.png")
    assert len(body["image_id"]) == 32
    assert body["upload"]["fields"]["Content-Type"] == "image/png"
    assert "policy" in body["upload"]["fields"]
    assert body["max_bytes"] == 10 * 1024 * 1024


def test_upload_policy_restricts_size_and_content_type(aws):
    import base64

    _, body = call(aws, "POST", "/uploads", {"filename": "cat.png", "content_type": "image/png"})
    policy = json.loads(base64.b64decode(body["upload"]["fields"]["policy"]))

    assert ["content-length-range", 1, 10 * 1024 * 1024] in policy["conditions"]
    assert {"Content-Type": "image/png"} in policy["conditions"]


def test_upload_rejects_disallowed_content_type(aws):
    status, body = call(aws, "POST", "/uploads", {"filename": "run.exe", "content_type": "application/x-msdownload"})
    assert status == 400
    assert "content_type" in body["error"]


def test_upload_rejects_extension_that_does_not_match_content_type(aws):
    status, _ = call(aws, "POST", "/uploads", {"filename": "cat.exe", "content_type": "image/png"})
    assert status == 400


def test_upload_sanitizes_path_tricks_in_filename(aws):
    status, body = call(aws, "POST", "/uploads", {"filename": "../../etc/pass wd.png", "content_type": "image/png"})
    assert status == 201
    assert body["key"].endswith("/pass_wd.png")
    assert ".." not in body["key"]


def test_upload_rejects_invalid_json_and_missing_fields(aws):
    event = {"httpMethod": "POST", "resource": "/uploads", "body": "{not json"}
    assert aws.api.lambda_handler(event, None)["statusCode"] == 400
    status, _ = call(aws, "POST", "/uploads", {"content_type": "image/png"})
    assert status == 400


def process_image(aws, key="uploads/cccc/photo.png"):
    aws.s3.put_object(Bucket=UPLOADS_BUCKET, Key=key, Body=make_image("PNG"))
    aws.processor.lambda_handler(sqs_event(key), None)
    return aws.processor.image_id_for(UPLOADS_BUCKET, key)


def test_get_image_returns_metadata_and_thumbnail_url(aws):
    image_id = process_image(aws)

    status, body = call(aws, "GET", "/images/{image_id}", path_params={"image_id": image_id})

    assert status == 200
    assert body["status"] == "PROCESSED"
    assert body["width"] == 800
    assert body["thumbnail_url"].startswith("https://")
    assert "sha256" not in body and "original_bucket" not in body


def test_get_image_validates_the_id(aws):
    status, _ = call(aws, "GET", "/images/{image_id}", path_params={"image_id": "../../etc/passwd"})
    assert status == 400


def test_get_image_returns_404_when_not_found(aws):
    status, _ = call(aws, "GET", "/images/{image_id}", path_params={"image_id": "a" * 32})
    assert status == 404


def test_rejected_image_has_no_thumbnail_url(aws):
    key = "uploads/dddd/fake.png"
    aws.s3.put_object(Bucket=UPLOADS_BUCKET, Key=key, Body=b"nope")
    aws.processor.lambda_handler(sqs_event(key), None)

    image_id = aws.processor.image_id_for(UPLOADS_BUCKET, key)
    status, body = call(aws, "GET", "/images/{image_id}", path_params={"image_id": image_id})

    assert status == 200
    assert body["status"] == "REJECTED"
    assert "thumbnail_url" not in body


def test_list_images_returns_processed_images_newest_first(aws):
    first = process_image(aws, "uploads/e001/a.png")
    second = process_image(aws, "uploads/e002/b.png")
    aws.s3.put_object(Bucket=UPLOADS_BUCKET, Key="uploads/e003/bad.png", Body=b"nope")
    aws.processor.lambda_handler(sqs_event("uploads/e003/bad.png"), None)  # rejected, must not be listed

    status, body = call(aws, "GET", "/images")

    assert status == 200
    assert body["count"] == 2
    assert [i["image_id"] for i in body["images"]] == [second, first]


def test_list_images_validates_limit(aws):
    for bad in ("0", "51", "abc"):
        status, _ = call(aws, "GET", "/images", query={"limit": bad})
        assert status == 400


def test_unknown_route_returns_404(aws):
    status, _ = call(aws, "DELETE", "/images/{image_id}")
    assert status == 404
