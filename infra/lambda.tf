# =============================================================================
# Fonctions Lambda : un rôle IAM PAR fonction, limité au strict nécessaire.
# Processeurs ARM (Graviton, « arm64 ») : environ 20 % moins chers à
# performance égale.
# =============================================================================

data "archive_file" "package" {
  type        = "zip"
  source_dir  = var.package_dir
  output_path = "${path.module}/.dist/lambda.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

locals {
  common_env = {
    INVOICES_TABLE               = aws_dynamodb_table.invoices.name
    POWERTOOLS_SERVICE_NAME      = "invoices"
    POWERTOOLS_METRICS_NAMESPACE = "InvoicePipeline"
    POWERTOOLS_LOG_LEVEL         = "INFO"
  }
  functions = {
    processor = {
      handler = "invoices.processor.handler"
      memory  = 256
      env = merge(local.common_env, {
        IDEMPOTENCY_TABLE  = aws_dynamodb_table.idempotency.name
        EVENT_BUS_NAME     = aws_cloudwatch_event_bus.invoices.name
        APPROVED_SUPPLIERS = join(",", var.approved_suppliers)
        REVIEW_THRESHOLD   = tostring(var.review_threshold)
      })
    }
    api = {
      handler = "invoices.api.handler"
      memory  = 256
      env     = merge(local.common_env, { UPLOAD_BUCKET = aws_s3_bucket.uploads.id })
    }
  }
  # Permissions minimales de chaque fonction
  permissions = {
    processor = [
      { actions = ["s3:GetObject"], resources = ["${aws_s3_bucket.uploads.arn}/incoming/*"] },
      { actions = ["dynamodb:PutItem"], resources = [aws_dynamodb_table.invoices.arn] },
      {
        actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
        resources = [aws_dynamodb_table.idempotency.arn]
      },
      { actions = ["events:PutEvents"], resources = [aws_cloudwatch_event_bus.invoices.arn] },
      {
        actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        resources = [aws_sqs_queue.inbox.arn]
      },
    ]
    api = [
      { actions = ["s3:PutObject"], resources = ["${aws_s3_bucket.uploads.arn}/incoming/*"] },
      { actions = ["dynamodb:GetItem"], resources = [aws_dynamodb_table.invoices.arn] },
      { actions = ["dynamodb:Query"], resources = ["${aws_dynamodb_table.invoices.arn}/index/by-status"] },
    ]
  }
}

resource "aws_iam_role" "lambda" {
  for_each = local.functions
  name     = "${var.name}-${var.environment}-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.functions
  name     = "least-privilege"
  role     = aws_iam_role.lambda[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [for p in local.permissions[each.key] : { Effect = "Allow", Action = p.actions, Resource = p.resources }],
      [
        {
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.lambda[each.key].arn}:*"
        },
        {
          Effect   = "Allow"
          Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
          Resource = "*" # X-Ray n'accepte pas de restriction par ressource
        },
      ]
    )
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.functions
  name              = "/aws/lambda/${var.name}-${var.environment}-${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  for_each         = local.functions
  function_name    = "${var.name}-${var.environment}-${each.key}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = each.value.handler
  memory_size      = each.value.memory
  timeout          = var.lambda_timeout_seconds
  filename         = data.archive_file.package.output_path
  source_code_hash = data.archive_file.package.output_base64sha256

  environment {
    variables = each.value.env
  }
  tracing_config {
    mode = "Active" # traces distribuées X-Ray
  }
  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda[each.key].name
  }
  depends_on = [aws_iam_role_policy.lambda]
}

# La file SQS déclenche le processeur par lots de 10
resource "aws_lambda_event_source_mapping" "inbox" {
  event_source_arn                   = aws_sqs_queue.inbox.arn
  function_name                      = aws_lambda_function.this["processor"].arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"] # échecs partiels
  scaling_config {
    maximum_concurrency = 10 # protège DynamoDB et les systèmes en aval
  }
}
