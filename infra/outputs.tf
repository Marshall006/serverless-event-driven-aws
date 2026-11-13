output "api_url" {
  description = "URL de base de l'API."
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "upload_bucket" {
  value = aws_s3_bucket.uploads.id
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.pipeline.dashboard_name}"
}
