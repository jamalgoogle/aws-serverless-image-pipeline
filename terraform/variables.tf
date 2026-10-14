variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as a prefix for resource names"
  type        = string
  default     = "novacart"
}

variable "environment" {
  description = "Deployment environment (dev or prod)"
  type        = string
  default     = "dev"
}

variable "notification_email" {
  description = "Email that receives a message for every processed or rejected image (leave empty to skip)"
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email that receives CloudWatch alarm notifications (leave empty to skip)"
  type        = string
  default     = ""
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete non-empty buckets (use only in dev)"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "How long CloudWatch keeps Lambda logs"
  type        = number
  default     = 30
}

variable "uploads_retention_days" {
  description = "Days after which original uploads are deleted (metadata and thumbnails are kept)"
  type        = number
  default     = 30
}

variable "max_upload_mb" {
  description = "Maximum accepted file size in megabytes"
  type        = number
  default     = 10
}

variable "thumbnail_size" {
  description = "Thumbnail bounding box in pixels"
  type        = number
  default     = 256
}

variable "processor_memory_mb" {
  description = "Memory for the image processor Lambda"
  type        = number
  default     = 512
}

variable "processor_max_concurrency" {
  description = "Maximum concurrent processor invocations from SQS (protects downstream services and cost)"
  type        = number
  default     = 5
}

variable "max_receive_count" {
  description = "Delivery attempts before a message moves to the dead-letter queue"
  type        = number
  default     = 3
}

variable "api_rate_limit" {
  description = "Sustained API requests per second"
  type        = number
  default     = 10
}

variable "api_burst_limit" {
  description = "Maximum API burst"
  type        = number
  default     = 20
}

variable "api_daily_quota" {
  description = "API requests per day allowed for the client API key"
  type        = number
  default     = 5000
}
