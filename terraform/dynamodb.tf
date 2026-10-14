# Image metadata. The status index lists the newest processed images without a table scan.
resource "aws_dynamodb_table" "images" {
  name         = "${local.prefix}-images"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "image_id"

  attribute {
    name = "image_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "processed_at"
    type = "S"
  }

  global_secondary_index {
    name            = local.gsi_name
    hash_key        = "status"
    range_key       = "processed_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }
}
