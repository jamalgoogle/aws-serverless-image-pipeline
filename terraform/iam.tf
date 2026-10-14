# Least privilege: each Lambda gets its own role, and every statement names the
# exact resources and actions that function needs. Nothing uses "*" except X-Ray,
# which does not support resource-level permissions.

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ------------------------------------------------------------ image processor
resource "aws_iam_role" "processor" {
  name               = "${local.processor_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "processor" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.processor.arn}:*"]
  }

  statement {
    sid       = "ConsumeImageEvents"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.main.arn]
  }

  statement {
    sid       = "ReadUploadedImages"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["uploads"].arn}/uploads/*"]
  }

  statement {
    sid       = "WriteThumbnails"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["processed"].arn}/thumbnails/*"]
  }

  statement {
    sid       = "WriteMetadata"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.images.arn]
  }

  statement {
    sid       = "PublishNotifications"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]
  }

  statement {
    sid       = "UseEncryptionKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid       = "SendTraces"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "processor" {
  name   = "least-privilege"
  role   = aws_iam_role.processor.id
  policy = data.aws_iam_policy_document.processor.json
}

# ------------------------------------------------------------ API
resource "aws_iam_role" "api" {
  name               = "${local.api_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }

  statement {
    sid       = "ReadMetadata"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.images.arn]
  }

  statement {
    sid       = "ListByStatus"
    actions   = ["dynamodb:Query"]
    resources = ["${aws_dynamodb_table.images.arn}/index/${local.gsi_name}"]
  }

  # Presigned URLs are signed with this role, so it needs the permission it hands out
  statement {
    sid       = "SignUploads"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["uploads"].arn}/uploads/*"]
  }

  statement {
    sid       = "SignThumbnailDownloads"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["processed"].arn}/thumbnails/*"]
  }

  statement {
    sid       = "UseEncryptionKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid       = "SendTraces"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "least-privilege"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}
