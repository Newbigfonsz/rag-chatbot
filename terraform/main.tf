# main.tf - RAG Chatbot Infrastructure
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.5" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "rag-chatbot", Environment = var.environment, ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "suffix" { byte_length = 4 }

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
}

# S3 Bucket
resource "aws_s3_bucket" "documents" {
  bucket = "${local.name_prefix}-docs-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

# IAM Role for Bedrock KB
resource "aws_iam_role" "bedrock_kb_role" {
  name = "${local.name_prefix}-bedrock-kb-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_kb_policy" {
  name = "${local.name_prefix}-bedrock-kb-policy"
  role = aws_iam_role.bedrock_kb_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [aws_s3_bucket.documents.arn, "${aws_s3_bucket.documents.arn}/*"] },
      { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = ["arn:aws:bedrock:${local.region}::foundation-model/amazon.titan-embed-text-v2:0"] },
      { Effect = "Allow", Action = ["aoss:APIAccessAll"], Resource = "*" }
    ]
  })
}

# Lambda Role
resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${local.name_prefix}-lambda-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:*" },
      { Effect = "Allow", Action = ["bedrock:InvokeModel", "bedrock:Retrieve", "bedrock:RetrieveAndGenerate", "bedrock:ListDataSources", "bedrock:StartIngestionJob", "bedrock:GetIngestionJob"], Resource = "*" },
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"], Resource = [aws_s3_bucket.documents.arn, "${aws_s3_bucket.documents.arn}/*"] },
      { Effect = "Allow", Action = ["aoss:APIAccessAll"], Resource = "*" }
    ]
  })
}

# OpenSearch Serverless
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${var.project_name}-enc"
  type = "encryption"
  policy = jsonencode({ Rules = [{ Resource = ["collection/${var.project_name}-vectors"], ResourceType = "collection" }], AWSOwnedKey = true })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${var.project_name}-net"
  type = "network"
  policy = jsonencode([{ Rules = [{ Resource = ["collection/${var.project_name}-vectors"], ResourceType = "collection" }], AllowFromPublic = true }])
}

resource "aws_opensearchserverless_access_policy" "data" {
  name = "${var.project_name}-data"
  type = "data"
  policy = jsonencode([{
    Rules = [
      { Resource = ["collection/${var.project_name}-vectors"], Permission = ["aoss:CreateCollectionItems", "aoss:DeleteCollectionItems", "aoss:UpdateCollectionItems", "aoss:DescribeCollectionItems"], ResourceType = "collection" },
      { Resource = ["index/${var.project_name}-vectors/*"], Permission = ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"], ResourceType = "index" }
    ]
    Principal = [aws_iam_role.bedrock_kb_role.arn, aws_iam_role.lambda_role.arn, "arn:aws:iam::${local.account_id}:root"]
  }])
}

resource "aws_opensearchserverless_collection" "vectors" {
  name = "${var.project_name}-vectors"
  type = "VECTORSEARCH"
  depends_on = [aws_opensearchserverless_security_policy.encryption, aws_opensearchserverless_security_policy.network, aws_opensearchserverless_access_policy.data]
}

# Bedrock Knowledge Base
resource "aws_bedrockagent_knowledge_base" "main" {
  name     = "${local.name_prefix}-kb"
  role_arn = aws_iam_role.bedrock_kb_role.arn
  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration { embedding_model_arn = "arn:aws:bedrock:${local.region}::foundation-model/amazon.titan-embed-text-v2:0" }
  }
  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.vectors.arn
      vector_index_name = "bedrock-knowledge-base-index"
      field_mapping {
        vector_field   = "vector"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }
  depends_on = [aws_opensearchserverless_collection.vectors, aws_iam_role_policy.bedrock_kb_policy]
}

resource "aws_bedrockagent_data_source" "s3" {
  name              = "${local.name_prefix}-s3-source"
  knowledge_base_id = aws_bedrockagent_knowledge_base.main.id
  data_deletion_policy = "RETAIN"
  data_source_configuration {
    type = "S3"
    s3_configuration { bucket_arn = aws_s3_bucket.documents.arn }
  }
}

# Lambda
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/builds/lambda.zip"
}

resource "aws_lambda_function" "api" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "${local.name_prefix}-api"
  role             = aws_iam_role.lambda_role.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 512
  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.main.id
      S3_BUCKET         = aws_s3_bucket.documents.id
      MODEL_ID          = var.model_id
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.api.function_name}"
  retention_in_days = 7
}

# API Gateway
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_headers = ["Content-Type", "Authorization"]
    allow_methods = ["GET", "POST", "DELETE", "OPTIONS"]
    allow_origins = ["*"]
  }
}

resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = var.environment
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "chat" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "upload" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /upload"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "documents" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /documents"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "sync" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /sync"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
