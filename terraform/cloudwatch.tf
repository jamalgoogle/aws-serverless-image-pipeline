locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ------------------------------------------------------------ processor
resource "aws_cloudwatch_metric_alarm" "processor_errors" {
  alarm_name          = "${local.prefix}-processor-errors"
  alarm_description   = "The image processor Lambda threw an error"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.processor.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "processor_throttles" {
  alarm_name          = "${local.prefix}-processor-throttles"
  alarm_description   = "The image processor Lambda was throttled"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.processor.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "processor_duration" {
  alarm_name          = "${local.prefix}-processor-duration-p95"
  alarm_description   = "p95 processing time is above 80% of the Lambda timeout"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = aws_lambda_function.processor.function_name }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.processor_timeout_seconds * 1000 * 0.8
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ------------------------------------------------------------ queues
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.prefix}-dlq-not-empty"
  alarm_description   = "Messages reached the dead-letter queue: an upload failed every retry"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${local.prefix}-queue-oldest-message-age"
  alarm_description   = "Uploads have been waiting more than 5 minutes: the processor is not keeping up"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.main.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ------------------------------------------------------------ API
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.prefix}-api-5xx"
  alarm_description   = "API Gateway returned more than 5 server errors in 5 minutes"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  dimensions          = { ApiName = aws_api_gateway_rest_api.api.name, Stage = aws_api_gateway_stage.main.stage_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "api_latency" {
  alarm_name          = "${local.prefix}-api-latency-p95"
  alarm_description   = "p95 API latency is above 3 seconds"
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiName = aws_api_gateway_rest_api.api.name, Stage = aws_api_gateway_stage.main.stage_name }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 3000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "api_lambda_errors" {
  alarm_name          = "${local.prefix}-api-lambda-errors"
  alarm_description   = "The API Lambda threw an error"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.api.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# ------------------------------------------------------------ dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.prefix}-image-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Processor invocations and errors"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.processor_name],
            ["AWS/Lambda", "Errors", "FunctionName", local.processor_name],
            ["AWS/Lambda", "Throttles", "FunctionName", local.processor_name],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Processor duration"
          region = var.aws_region
          period = 300
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", local.processor_name, { stat = "p50", label = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", local.processor_name, { stat = "p95", label = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Queue depth and dead-letter queue"
          region = var.aws_region
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.main.name, { label = "waiting" }],
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", aws_sqs_queue.main.name, { label = "oldest message age (s)" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.dlq.name, { label = "dead-letter queue" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "API requests and errors"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", aws_api_gateway_rest_api.api.name, "Stage", var.environment],
            ["AWS/ApiGateway", "4XXError", "ApiName", aws_api_gateway_rest_api.api.name, "Stage", var.environment],
            ["AWS/ApiGateway", "5XXError", "ApiName", aws_api_gateway_rest_api.api.name, "Stage", var.environment],
          ]
        }
      },
    ]
  })
}
