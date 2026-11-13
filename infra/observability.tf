# =============================================================================
# Alarmes : on est prévenu AVANT les utilisateurs.
# =============================================================================
locals {
  alarms = {
    dlq-not-empty = {
      description = "Des factures n'ont pas pu être traitées après 3 tentatives (DLQ)."
      namespace   = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", stat = "Maximum"
      dimensions  = { QueueName = aws_sqs_queue.dlq.name }, threshold = 0
    }
    inbox-backlog-age = {
      description = "La plus ancienne facture attend depuis plus de 10 minutes."
      namespace   = "AWS/SQS", metric = "ApproximateAgeOfOldestMessage", stat = "Maximum"
      dimensions  = { QueueName = aws_sqs_queue.inbox.name }, threshold = 600
    }
    processor-errors = {
      description = "Le processeur de factures produit des erreurs techniques."
      namespace   = "AWS/Lambda", metric = "Errors", stat = "Sum"
      dimensions  = { FunctionName = aws_lambda_function.this["processor"].function_name }, threshold = 0
    }
    processor-throttles = {
      description = "Le processeur est limité (concurrence insuffisante)."
      namespace   = "AWS/Lambda", metric = "Throttles", stat = "Sum"
      dimensions  = { FunctionName = aws_lambda_function.this["processor"].function_name }, threshold = 0
    }
    api-5xx = {
      description = "L'API renvoie des erreurs serveur."
      namespace   = "AWS/ApiGateway", metric = "5xx", stat = "Sum"
      dimensions  = { ApiId = aws_apigatewayv2_api.http.id, Stage = "$default" }, threshold = 5
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each            = local.alarms
  alarm_name          = "${var.name}-${var.environment}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.stat
  dimensions          = each.value.dimensions
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.name}-${var.environment}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Factures traitées", region = var.region, stat = "Sum", period = 300
          metrics = [
            ["InvoicePipeline", "InvoicesAccepted", "service", "invoices"],
            [".", "InvoicesReviewRequired", ".", "."],
            [".", "InvoicesRejected", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "File d'attente", region = var.region, stat = "Maximum", period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.inbox.name],
            ["...", aws_sqs_queue.dlq.name],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "Processeur : durée p95 et erreurs", region = var.region, period = 300
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.this["processor"].function_name, { stat = "p95" }],
            [".", "Errors", ".", ".", { stat = "Sum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "API : requêtes et erreurs", region = var.region, stat = "Sum", period = 300
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.http.id, "Stage", "$default"],
            [".", "4xx", ".", ".", ".", "."],
            [".", "5xx", ".", ".", ".", "."],
          ]
        }
      },
    ]
  })
}
