# Tests d'architecture : AWS est simulé, aucun compte n'est nécessaire.
# On vérifie les décisions de conception (résilience, sécurité, coûts).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  # ARN réalistes (le fournisseur AWS valide leur format)
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:eu-west-3:123456789012:invoices-dev"
      url = "https://sqs.eu-west-3.amazonaws.com/123456789012/invoices-dev"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/invoices-dev" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:eu-west-3:123456789012:invoices-dev-alerts" }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:eu-west-3:123456789012:function:invoices-dev"
      invoke_arn = "arn:aws:apigateway:eu-west-3:lambda:path/2015-03-31/functions/arn:aws:lambda:eu-west-3:123456789012:function:invoices-dev/invocations"
    }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:eu-west-3:123456789012:rule/invoices-dev" }
  }
  mock_resource "aws_cloudwatch_event_bus" {
    defaults = { arn = "arn:aws:events:eu-west-3:123456789012:event-bus/invoices-dev" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:eu-west-3:123456789012:table/invoices-dev" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::invoices-uploads-123456789012-eu-west-3" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-west-3:123456789012:log-group:/aws/lambda/invoices-dev" }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      execution_arn = "arn:aws:execute-api:eu-west-3:123456789012:abc123"
      api_endpoint  = "https://abc123.execute-api.eu-west-3.amazonaws.com"
    }
  }
}

variables {
  package_dir = "../src" # le zip est réellement construit (fournisseur archive)
}

run "resilience_retries_then_dead_letter_queue" {
  command = apply

  assert {
    condition     = jsondecode(aws_sqs_queue.inbox.redrive_policy).maxReceiveCount == 3
    error_message = "Après 3 échecs, un message doit partir dans la DLQ."
  }
  assert {
    condition     = aws_sqs_queue.inbox.visibility_timeout_seconds == 6 * var.lambda_timeout_seconds
    error_message = "Visibilité SQS = 6 x timeout Lambda (recommandation AWS)."
  }
  assert {
    condition     = aws_lambda_event_source_mapping.inbox.function_response_types == toset(["ReportBatchItemFailures"])
    error_message = "Les échecs partiels de lot doivent être activés."
  }
  assert {
    condition     = aws_sqs_queue.dlq.message_retention_seconds == 1209600
    error_message = "La DLQ doit conserver les messages 14 jours."
  }
}

run "functions_are_traced_arm64_and_current_runtime" {
  command = apply

  assert {
    condition = alltrue([for f in aws_lambda_function.this :
      f.architectures == tolist(["arm64"]) && f.runtime == "python3.13" && f.tracing_config[0].mode == "Active"
    ])
    error_message = "Lambdas en arm64 (Graviton), Python 3.13, traces X-Ray actives."
  }
}

run "iam_is_least_privilege" {
  command = apply

  assert {
    condition = alltrue(flatten([for p in aws_iam_role_policy.lambda : [
      for s in jsondecode(p.policy).Statement : !contains(flatten([s.Action]), "*") && !anytrue([for a in flatten([s.Action]) : endswith(a, ":*")])
    ]]))
    error_message = "Aucune action IAM générique (« * » ou « service:* »)."
  }
  assert {
    condition = alltrue(flatten([for p in aws_iam_role_policy.lambda : [
      for s in jsondecode(p.policy).Statement : s.Resource != "*" || alltrue([for a in s.Action : startswith(a, "xray:")])
    ]]))
    error_message = "Resource « * » réservée à X-Ray (qui ne supporte pas mieux)."
  }
  assert {
    condition     = !contains(flatten([for s in jsondecode(aws_iam_role_policy.lambda["api"].policy).Statement : s.Action]), "dynamodb:PutItem")
    error_message = "L'API ne doit pas pouvoir écrire dans la table des factures."
  }
}

run "data_is_protected" {
  command = apply

  assert {
    condition     = aws_dynamodb_table.invoices.point_in_time_recovery[0].enabled && aws_dynamodb_table.invoices.server_side_encryption[0].enabled
    error_message = "Sauvegarde continue (PITR) et chiffrement obligatoires."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.uploads.block_public_policy && aws_s3_bucket_public_access_block.uploads.restrict_public_buckets
    error_message = "Le bucket de dépôt ne doit jamais être public."
  }
  assert {
    condition     = aws_s3_bucket_notification.uploads.eventbridge
    error_message = "Les dépôts S3 doivent émettre des événements EventBridge."
  }
}

run "cost_and_abuse_controls" {
  command = apply

  assert {
    condition     = aws_dynamodb_table.invoices.billing_mode == "PAY_PER_REQUEST"
    error_message = "Paiement à la requête : 0 $ sans trafic."
  }
  assert {
    condition     = aws_apigatewayv2_stage.default.default_route_settings[0].throttling_rate_limit == 10
    error_message = "L'API doit être limitée en débit."
  }
  assert {
    condition     = aws_lambda_event_source_mapping.inbox.scaling_config[0].maximum_concurrency == 10
    error_message = "La concurrence du processeur doit être plafonnée."
  }
}

run "api_requires_authentication_by_default" {
  command = apply
  assert {
    condition     = alltrue([for r in aws_apigatewayv2_route.this : r.authorization_type == "AWS_IAM"])
    error_message = "Toutes les routes doivent exiger une authentification IAM par défaut."
  }
}

run "rejects_unknown_authorization" {
  command = plan
  variables {
    api_authorization = "JWT"
  }
  expect_failures = [var.api_authorization]
}

run "alarms_cover_failure_modes" {
  command = apply

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.this) == 5
    error_message = "5 alarmes attendues (DLQ, retard, erreurs, limitations, 5xx)."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.this["dlq-not-empty"].threshold == 0
    error_message = "Le moindre message en DLQ doit déclencher une alarme."
  }
  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "Sans e-mail fourni, aucun abonnement."
  }
}

run "email_alerts_when_configured" {
  command = apply
  variables {
    alert_email = "compta@example.com"
  }
  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1
    error_message = "Un abonnement e-mail doit être créé."
  }
}
