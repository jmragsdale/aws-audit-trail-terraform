terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ImmutableAuditTrail"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_s3_bucket" "audit_archive" {
  bucket = "${var.project_name}-archives-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "audit_archive" {
  bucket = aws_s3_bucket.audit_archive.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit_archive" {
  bucket = aws_s3_bucket.audit_archive.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit_archive" {
  bucket                  = aws_s3_bucket.audit_archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit_archive" {
  bucket = aws_s3_bucket.audit_archive.id

  rule {
    id     = "archive-old-logs"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 2555
    }
  }
}

resource "aws_dynamodb_table" "audit_logs" {
  name         = "${var.project_name}-audit-logs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "accountId"
  range_key    = "auditId"

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "auditId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "processor_lambda" {
  name              = "/aws/lambda/${var.project_name}-processor"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "verify_lambda" {
  name              = "/aws/lambda/${var.project_name}-verify"
  retention_in_days = 30
}

resource "aws_iam_role" "lambda_execution" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.audit_logs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.audit_archive.arn}/*"
      }
    ]
  })
}

data "archive_file" "processor_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/processor"
  output_path = "${path.module}/builds/processor.zip"
}

data "archive_file" "verify_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/verify"
  output_path = "${path.module}/builds/verify.zip"
}

resource "aws_lambda_function" "audit_processor" {
  filename         = data.archive_file.processor_lambda.output_path
  function_name    = "${var.project_name}-processor"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.processor_lambda.output_base64sha256
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      AUDIT_TABLE    = aws_dynamodb_table.audit_logs.name
      ARCHIVE_BUCKET = aws_s3_bucket.audit_archive.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.processor_lambda]
}

resource "aws_lambda_function" "verify_audit" {
  filename         = data.archive_file.verify_lambda.output_path
  function_name    = "${var.project_name}-verify"
  role             = aws_iam_role.lambda_execution.arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.verify_lambda.output_base64sha256
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      AUDIT_TABLE = aws_dynamodb_table.audit_logs.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.verify_lambda]
}

resource "aws_apigatewayv2_api" "audit_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.audit_api.id
  name        = "prod"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId   = "$context.requestId"
      ip          = "$context.identity.sourceIp"
      requestTime = "$context.requestTime"
      httpMethod  = "$context.httpMethod"
      status      = "$context.status"
    })
  }
}

resource "aws_apigatewayv2_integration" "create_audit" {
  api_id                 = aws_apigatewayv2_api.audit_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.audit_processor.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "verify_audit" {
  api_id                 = aws_apigatewayv2_api.audit_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.verify_audit.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "create_audit" {
  api_id    = aws_apigatewayv2_api.audit_api.id
  route_key = "POST /audit"
  target    = "integrations/${aws_apigatewayv2_integration.create_audit.id}"
}

resource "aws_apigatewayv2_route" "verify_audit" {
  api_id    = aws_apigatewayv2_api.audit_api.id
  route_key = "GET /audit/{accountId}/verify"
  target    = "integrations/${aws_apigatewayv2_integration.verify_audit.id}"
}

resource "aws_lambda_permission" "api_gateway_processor" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit_processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.audit_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_gateway_verify" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.verify_audit.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.audit_api.execution_arn}/*/*"
}

output "api_endpoint" {
  value = aws_apigatewayv2_stage.prod.invoke_url
}

output "audit_table_name" {
  value = aws_dynamodb_table.audit_logs.name
}

output "archive_bucket_name" {
  value = aws_s3_bucket.audit_archive.id
}
