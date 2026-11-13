# =============================================================================
# Chaîne d'événements :
#   S3 --(Object Created)--> EventBridge (bus par défaut) --> SQS --> Lambda
#   Lambda --(InvoiceProcessed / InvoiceRejected)--> bus « invoices » --> SNS
# =============================================================================

# --- File d'attente + file des messages en échec (DLQ) --------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-${var.environment}-dlq"
  message_retention_seconds = 1209600 # 14 jours pour analyser et rejouer
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "inbox" {
  name                       = "${var.name}-${var.environment}-inbox"
  visibility_timeout_seconds = var.lambda_timeout_seconds * 6 # recommandation AWS
  message_retention_seconds  = 345600                         # 4 jours
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3 # 3 tentatives, puis DLQ
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.inbox.arn]
  })
}

# --- S3 -> EventBridge -> SQS -----------------------------------------------------
resource "aws_cloudwatch_event_rule" "invoice_uploaded" {
  name        = "${var.name}-${var.environment}-uploaded"
  description = "Nouvelle facture déposée dans incoming/"
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.uploads.id] }
      object = { key = [{ prefix = "incoming/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "to_inbox" {
  rule = aws_cloudwatch_event_rule.invoice_uploaded.name
  arn  = aws_sqs_queue.inbox.arn
}

# Seule CETTE règle EventBridge peut écrire dans la file
resource "aws_sqs_queue_policy" "inbox" {
  queue_url = aws_sqs_queue.inbox.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.inbox.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.invoice_uploaded.arn } }
    }]
  })
}

# --- Événements métier ---------------------------------------------------------------
resource "aws_cloudwatch_event_bus" "invoices" {
  name = "${var.name}-${var.environment}"
}

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-${var.environment}-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Factures rejetées ou à vérifier -> alerte e-mail à la comptabilité
resource "aws_cloudwatch_event_rule" "needs_attention" {
  name           = "${var.name}-${var.environment}-needs-attention"
  event_bus_name = aws_cloudwatch_event_bus.invoices.name
  event_pattern = jsonencode({
    source = ["invoices.processor"]
    "$or" = [
      { detail-type = ["InvoiceRejected"] },
      { detail = { status = ["REVIEW_REQUIRED"] } },
    ]
  })
}

resource "aws_cloudwatch_event_target" "to_alerts" {
  rule           = aws_cloudwatch_event_rule.needs_attention.name
  event_bus_name = aws_cloudwatch_event_bus.invoices.name
  arn            = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.needs_attention.arn } }
      },
      {
        Sid       = "CloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
      },
    ]
  })
}
