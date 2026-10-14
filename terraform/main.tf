data "aws_caller_identity" "current" {}

locals {
  prefix     = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id

  uploads_bucket_name   = "${local.prefix}-image-uploads-${local.account_id}"
  processed_bucket_name = "${local.prefix}-image-processed-${local.account_id}"
  processor_name        = "${local.prefix}-image-processor"
  api_function_name     = "${local.prefix}-image-api"
  gsi_name              = "status-processed_at-index"

  processor_timeout_seconds = 30
  max_upload_bytes          = var.max_upload_mb * 1024 * 1024

  buckets = {
    uploads   = local.uploads_bucket_name
    processed = local.processed_bucket_name
  }
}
