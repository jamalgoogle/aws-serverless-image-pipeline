output "api_base_url" {
  description = "Base URL of the API (append /uploads or /images)"
  value       = aws_api_gateway_stage.main.invoke_url
}

output "api_key_id" {
  description = "ID of the client API key (fetch the value with: aws apigateway get-api-key --api-key <id> --include-value)"
  value       = aws_api_gateway_api_key.client.id
}

output "uploads_bucket" {
  description = "Bucket that receives original uploads"
  value       = aws_s3_bucket.this["uploads"].id
}

output "processed_bucket" {
  description = "Bucket that stores thumbnails"
  value       = aws_s3_bucket.this["processed"].id
}

output "images_table" {
  description = "DynamoDB table with the image metadata"
  value       = aws_dynamodb_table.images.name
}

output "events_queue_url" {
  description = "Queue between S3 and the processor"
  value       = aws_sqs_queue.main.url
}

output "dead_letter_queue_url" {
  description = "Queue that holds messages that failed every retry"
  value       = aws_sqs_queue.dlq.url
}

output "notifications_topic_arn" {
  description = "SNS topic that announces processed and rejected images"
  value       = aws_sns_topic.notifications.arn
}

output "alerts_topic_arn" {
  description = "SNS topic used by the CloudWatch alarms"
  value       = aws_sns_topic.alerts.arn
}
