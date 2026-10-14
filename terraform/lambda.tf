# Run scripts/build-lambdas.sh first: it prepares the build/ folders zipped below.
data "archive_file" "processor" {
  type        = "zip"
  source_dir  = "${path.module}/../build/processor"
  output_path = "${path.module}/../build/processor.zip"
  excludes    = ["**/__pycache__/*", "**/*.pyc"]
}

data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.module}/../build/api"
  output_path = "${path.module}/../build/api.zip"
  excludes    = ["**/__pycache__/*", "**/*.pyc"]
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${local.processor_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.api_function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

# ------------------------------------------------------------ image processor
resource "aws_lambda_function" "processor" {
  function_name = local.processor_name
  description   = "Creates thumbnails, stores image metadata and sends notifications"
  role          = aws_iam_role.processor.arn

  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256

  timeout     = local.processor_timeout_seconds
  memory_size = var.processor_memory_mb

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      PROCESSED_BUCKET = aws_s3_bucket.this["processed"].id
      TABLE_NAME       = aws_dynamodb_table.images.name
      TOPIC_ARN        = aws_sns_topic.notifications.arn
      THUMBNAIL_SIZE   = tostring(var.thumbnail_size)
      MAX_UPLOAD_BYTES = tostring(local.max_upload_bytes)
      LOG_LEVEL        = "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.processor,
    aws_iam_role_policy.processor,
  ]
}

# SQS -> Lambda. ReportBatchItemFailures retries only the messages that failed.
resource "aws_lambda_event_source_mapping" "processor" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.processor.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.processor_max_concurrency
  }
}

# ------------------------------------------------------------ API
resource "aws_lambda_function" "api" {
  function_name = local.api_function_name
  description   = "Presigned uploads and image metadata API"
  role          = aws_iam_role.api.arn

  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256

  timeout     = 10
  memory_size = 256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      UPLOADS_BUCKET     = aws_s3_bucket.this["uploads"].id
      PROCESSED_BUCKET   = aws_s3_bucket.this["processed"].id
      TABLE_NAME         = aws_dynamodb_table.images.name
      GSI_NAME           = local.gsi_name
      MAX_UPLOAD_BYTES   = tostring(local.max_upload_bytes)
      URL_EXPIRY_SECONDS = "300"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.api,
    aws_iam_role_policy.api,
  ]
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}
