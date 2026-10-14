# REST API with an API key, a usage plan (rate limit and daily quota) and request validation.
resource "aws_api_gateway_rest_api" "api" {
  name        = "${local.prefix}-image-api"
  description = "Image upload and metadata API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "uploads" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "uploads"
}

resource "aws_api_gateway_resource" "images" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "images"
}

resource "aws_api_gateway_resource" "image" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.images.id
  path_part   = "{image_id}"
}

resource "aws_api_gateway_request_validator" "all" {
  rest_api_id                 = aws_api_gateway_rest_api.api.id
  name                        = "validate-body-and-parameters"
  validate_request_body       = true
  validate_request_parameters = true
}

resource "aws_api_gateway_model" "upload_request" {
  rest_api_id  = aws_api_gateway_rest_api.api.id
  name         = "UploadRequest"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    title     = "UploadRequest"
    type      = "object"
    required  = ["filename", "content_type"]
    properties = {
      filename     = { type = "string", minLength = 1, maxLength = 100 }
      content_type = { type = "string", enum = ["image/jpeg", "image/png", "image/webp", "image/gif"] }
    }
    additionalProperties = false
  })
}

# ---- POST /uploads ----
resource "aws_api_gateway_method" "create_upload" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  resource_id          = aws_api_gateway_resource.uploads.id
  http_method          = "POST"
  authorization        = "NONE"
  api_key_required     = true
  request_validator_id = aws_api_gateway_request_validator.all.id

  request_models = {
    "application/json" = aws_api_gateway_model.upload_request.name
  }
}

resource "aws_api_gateway_integration" "create_upload" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.uploads.id
  http_method             = aws_api_gateway_method.create_upload.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
}

# ---- GET /images ----
resource "aws_api_gateway_method" "list_images" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  resource_id          = aws_api_gateway_resource.images.id
  http_method          = "GET"
  authorization        = "NONE"
  api_key_required     = true
  request_validator_id = aws_api_gateway_request_validator.all.id
}

resource "aws_api_gateway_integration" "list_images" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.images.id
  http_method             = aws_api_gateway_method.list_images.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
}

# ---- GET /images/{image_id} ----
resource "aws_api_gateway_method" "get_image" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  resource_id          = aws_api_gateway_resource.image.id
  http_method          = "GET"
  authorization        = "NONE"
  api_key_required     = true
  request_validator_id = aws_api_gateway_request_validator.all.id

  request_parameters = {
    "method.request.path.image_id" = true
  }
}

resource "aws_api_gateway_integration" "get_image" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.image.id
  http_method             = aws_api_gateway_method.get_image.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
}

# ---- deployment, stage and throttling ----
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  # Redeploy whenever the API definition changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.uploads.id,
      aws_api_gateway_resource.images.id,
      aws_api_gateway_resource.image.id,
      aws_api_gateway_model.upload_request.schema,
      aws_api_gateway_method.create_upload.id,
      aws_api_gateway_method.list_images.id,
      aws_api_gateway_method.get_image.id,
      aws_api_gateway_integration.create_upload.id,
      aws_api_gateway_integration.list_images.id,
      aws_api_gateway_integration.get_image.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "main" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  deployment_id        = aws_api_gateway_deployment.main.id
  stage_name           = var.environment
  xray_tracing_enabled = true
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = aws_api_gateway_stage.main.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    throttling_rate_limit  = var.api_rate_limit
    throttling_burst_limit = var.api_burst_limit
  }
}

# ---- API key and usage plan ----
resource "aws_api_gateway_usage_plan" "main" {
  name = "${local.prefix}-image-api"

  api_stages {
    api_id = aws_api_gateway_rest_api.api.id
    stage  = aws_api_gateway_stage.main.stage_name
  }

  throttle_settings {
    rate_limit  = var.api_rate_limit
    burst_limit = var.api_burst_limit
  }

  quota_settings {
    limit  = var.api_daily_quota
    period = "DAY"
  }
}

resource "aws_api_gateway_api_key" "client" {
  name = "${local.prefix}-image-client"
}

resource "aws_api_gateway_usage_plan_key" "client" {
  key_id        = aws_api_gateway_api_key.client.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.main.id
}
