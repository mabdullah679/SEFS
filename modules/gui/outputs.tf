output "url" {
  description = "The map. Open it, sign in with the Cognito user, and the live stack renders."
  value       = "https://${aws_cloudfront_distribution.gui.domain_name}/"
}

output "api_url" {
  description = "HTTP API endpoint (every /api/* route requires a Cognito JWT; unauthenticated calls get 401)."
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "user_pool_id" {
  value = aws_cognito_user_pool.gui.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.gui.id
}

output "cognito_domain" {
  value = "https://${aws_cognito_user_pool_domain.gui.domain}.auth.${var.region}.amazoncognito.com"
}

output "bucket" {
  value = aws_s3_bucket.web.id
}

output "distribution_id" {
  value = aws_cloudfront_distribution.gui.id
}

output "lambda_function_name" {
  value = aws_lambda_function.api.function_name
}

output "api_role_arn" {
  description = "The read-only role the API runs as (what the GUI can see is exactly what this role can read)."
  value       = aws_iam_role.api.arn
}
