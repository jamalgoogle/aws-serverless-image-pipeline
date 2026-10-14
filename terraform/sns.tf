resource "aws_sns_topic" "notifications" {
  name              = "${local.prefix}-image-notifications"
  kms_master_key_id = aws_kms_key.main.arn
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.prefix}-image-alerts"
  kms_master_key_id = aws_kms_key.main.arn
}

resource "aws_sns_topic_subscription" "notifications_email" {
  count = var.notification_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
