# aws-serverless-image-pipeline

A serverless, event-driven image-processing pipeline on AWS, built entirely with Terraform. An image uploaded to S3 triggers a Lambda function that creates a thumbnail, writes the image metadata to DynamoDB and sends a notification through SNS. There are no servers to manage, and the pipeline scales with the number of uploads.

**Author:** Bassem Jamal Hussein | DevSecOps & Cloud Engineer | [GitHub: jamalgoogle](https://github.com/jamalgoogle)

## Stack

AWS Lambda (Python 3.12, arm64), API Gateway, S3, SQS, SNS, DynamoDB, KMS, IAM, CloudWatch, X-Ray, Terraform, Pillow, pytest, moto, GitHub Actions

## Architecture

```
  Client
    |  1. POST /uploads  (API key)
    v
  API Gateway --> API Lambda ---> returns a presigned S3 POST
                     |                (size and content-type restricted)
                     |
    2. client uploads the image straight to S3
                     |
                     v
          S3 uploads bucket ---- ObjectCreated ----> SQS queue ----(3 failed attempts)----> Dead-letter queue
                                                        |                                          |
                                                        v                                          v
                                          Processor Lambda (Pillow)                    CloudWatch alarm
                                           |        |         |
                          thumbnail        |        |         +--> SNS topic --> email notification
                          v                v        v
                 S3 processed bucket   DynamoDB (metadata)
                                           ^
    3. GET /images, GET /images/{id}  ----+---- API Lambda  (thumbnail returned as a short-lived presigned URL)
```

CloudWatch alarms for the processor, the queues and the API publish to a separate SNS alerts topic.

## How it works

1. **Upload.** The client calls `POST /uploads` with a file name and content type. The API Lambda returns a presigned S3 POST that only accepts that content type and a file size between 1 byte and 10 MB, and expires after 5 minutes.
2. **Event.** The file goes directly to S3, so it never passes through API Gateway or Lambda. S3 sends an `ObjectCreated` event for the `uploads/` prefix to an SQS queue.
3. **Processing.** The processor Lambda reads messages from the queue in batches of up to 5. For each image it validates the file with Pillow, creates a 256 px WebP thumbnail without any EXIF metadata, stores the thumbnail in the processed bucket, writes the metadata (format, dimensions, size, SHA-256, thumbnail key, timestamps) to DynamoDB, and publishes an SNS notification.
4. **Query.** `GET /images/{id}` returns the metadata and a 5-minute thumbnail URL, and `GET /images` lists the newest processed images through a DynamoDB index (no table scan).

Files that are not valid images, are too large or use an unsupported format are saved with the status `REJECTED` and a reason, announced through SNS, and removed from the queue because retrying cannot fix them.

## Design decisions

- **SQS between S3 and Lambda.** The queue absorbs upload bursts, lets failed messages retry, and sends messages that fail every attempt to a dead-letter queue instead of losing them.
- **Partial batch responses.** If one message in a batch fails, only that message is retried.
- **Idempotent processing.** The image ID is a hash of the bucket and key, so SQS delivering a message twice overwrites the same DynamoDB item instead of creating a duplicate.
- **Separate buckets.** Thumbnails go to their own bucket, so they can never trigger the pipeline again.
- **Concurrency cap.** The event source mapping limits the processor to 5 concurrent invocations (2 in dev, 20 in prod).
- **Presigned POST instead of presigned PUT.** Only a POST policy can enforce a maximum file size.

## Security

**Least-privilege IAM.** Each Lambda has its own role, and every statement names exact resources and actions.

| Role | Allowed |
| --- | --- |
| Processor | Read and delete messages from one queue, `s3:GetObject` on `uploads/*` of the uploads bucket, `s3:PutObject` on `thumbnails/*` of the processed bucket, `dynamodb:PutItem` on one table, `sns:Publish` on one topic, use of one KMS key, write to its own log group |
| API | `dynamodb:GetItem` on one table, `dynamodb:Query` on the status index only, `s3:PutObject` on `uploads/*` and `s3:GetObject` on `thumbnails/*` (needed to sign presigned URLs), use of one KMS key, write to its own log group |

Neither role can scan or delete DynamoDB items, list buckets or touch other resources. The only `*` resource is X-Ray, which does not support resource-level permissions.

**Data protection.**
- One customer managed KMS key (with rotation) encrypts both buckets, both queues, both SNS topics, the DynamoDB table and the log groups.
- Buckets block all public access, enforce bucket-owner ownership and versioning, and deny any request that is not TLS. The queue policy also denies non-TLS requests.
- Original uploads expire after a configurable number of days (7 in dev, 30 in prod). Metadata and thumbnails are kept.

**Input handling.**
- API Gateway validates the request body against a JSON schema before the Lambda runs. An API key with a usage plan enforces rate limits, burst limits and a daily quota.
- The API Lambda allows only four image content types, requires the extension to match, and sanitizes the file name (path tricks like `../../` are removed).
- The processor accepts only JPEG, PNG, WebP and GIF, enforces the size limit, guards against decompression bombs, and strips EXIF data (location, camera) from thumbnails.

## Reliability and monitoring

CloudWatch alarms notify the alerts SNS topic (and its email subscription) and also notify when the alarm recovers:

| Alarm | Fires when |
| --- | --- |
| `processor-errors` | The processor Lambda throws any error |
| `processor-throttles` | The processor Lambda is throttled |
| `processor-duration-p95` | p95 duration is above 80% of the timeout for 10 minutes |
| `dlq-not-empty` | Any message reaches the dead-letter queue |
| `queue-oldest-message-age` | An upload has waited more than 5 minutes |
| `api-5xx` | More than 5 server errors in 5 minutes |
| `api-latency-p95` | p95 API latency above 3 seconds for 10 minutes |
| `api-lambda-errors` | The API Lambda throws any error |

A CloudWatch dashboard shows processor invocations, errors and duration, queue depth and age, and API traffic. Lambda log groups have a retention period, and X-Ray tracing is on for both functions and the API stage.

## Repository structure

```
lambda/processor/handler.py     S3 -> SQS -> Lambda image processor
lambda/processor/requirements.txt  Pillow, built for Linux arm64
lambda/api/handler.py           Presigned uploads and image metadata API
terraform/                      All infrastructure
  kms.tf s3.tf sqs.tf sns.tf dynamodb.tf iam.tf lambda.tf apigw.tf cloudwatch.tf outputs.tf
  environments/dev.tfvars       Small, cheap settings, buckets can be destroyed
  environments/prod.tfvars      Higher limits, longer retention, protected buckets
tests/                          25 tests with mocked AWS (moto)
scripts/build-lambdas.sh        Builds the Lambda packages (Pillow for the Lambda runtime)
scripts/smoke-test.sh           End-to-end test of a deployed stack
samples/                        A valid image and an invalid one to test rejection
.github/workflows/ci.yaml       Tests, terraform fmt and validate, Trivy scan
```

## Deploy

Requirements: an AWS account and credentials, Terraform 1.6 or newer, Python 3.12 with pip (to build the Lambda packages), and for the smoke test, the AWS CLI, curl and jq.

```bash
# 1. Build the Lambda packages (downloads Pillow for Linux arm64, even on macOS or Windows)
./scripts/build-lambdas.sh

# 2. Deploy
cd terraform
terraform init
terraform apply -var-file=environments/dev.tfvars \
  -var="notification_email=you@example.com" \
  -var="alert_email=you@example.com"
```

AWS sends a confirmation email for each SNS subscription. Click the link in both, otherwise no notifications arrive. For shared use, copy `terraform/backend.tf.example` to `backend.tf` to keep the state in S3.

## Try it

Run the end-to-end test. It requests an upload URL, uploads `samples/sample.png`, and waits until the API returns the processed metadata:

```bash
./scripts/smoke-test.sh
./scripts/smoke-test.sh samples/not-an-image.png   # shows a REJECTED upload
```

To call the API by hand:

```bash
API_URL=$(terraform -chdir=terraform output -raw api_base_url)
KEY_ID=$(terraform -chdir=terraform output -raw api_key_id)
API_KEY=$(aws apigateway get-api-key --api-key "$KEY_ID" --include-value --query value --output text)

curl -X POST "$API_URL/uploads" -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"filename": "photo.png", "content_type": "image/png"}'

curl "$API_URL/images" -H "x-api-key: $API_KEY"
```

If an upload never shows up, check the `dlq-not-empty` alarm and the processor's log group, then inspect the dead-letter queue. After fixing the cause, redrive the messages from the SQS console.

## Run the tests locally

```bash
pip install -r requirements-dev.txt
python -m pytest -q
```

The tests run both Lambdas against mocked AWS services (S3, DynamoDB, SNS, SQS) and cover valid and invalid images, EXIF stripping, size limits, idempotency, retry behavior for failed batch items, presigned upload policies, input validation and the API routes.

## Known limitations

- The client uses an API key, which identifies an application, not a user. For end users, add a Cognito or JWT authorizer.
- API Gateway access logging is not enabled, because it needs an account-wide CloudWatch role. Response caching and S3 access logging are also off. Trivy reports these three as MEDIUM and LOW findings, and nothing at HIGH or CRITICAL.
- The API key value is stored in the Terraform state, so protect the state bucket.
- Cost is pay per use. The fixed costs are the KMS key and the CloudWatch alarms, a few dollars a month.

## Clean up

```bash
cd terraform
terraform destroy -var-file=environments/dev.tfvars
```

`force_destroy` is enabled in the dev settings, so non-empty buckets are deleted. In prod, empty the buckets first.

## License

MIT, see [LICENSE](LICENSE).
