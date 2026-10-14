# The queue sits between S3 and Lambda: it absorbs bursts, retries failures and
# moves poison messages to a dead-letter queue instead of losing them.
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-image-events-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate and redrive
  kms_master_key_id         = aws_kms_key.main.id
}

resource "aws_sqs_queue" "main" {
  name = "${local.prefix}-image-events"

  # Must be at least the Lambda timeout, 6x is the AWS recommendation
  visibility_timeout_seconds = local.processor_timeout_seconds * 6
  message_retention_seconds  = 345600
  kms_master_key_id          = aws_kms_key.main.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "AllowUploadsBucketToSendMessages"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main.arn]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.this["uploads"].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.main.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  policy    = data.aws_iam_policy_document.queue.json
}
