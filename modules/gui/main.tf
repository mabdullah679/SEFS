# gui: the optional "sidewagon" (D23). A 2.5D map of the live stack, served without any
# compute that bills while idle:
#
#   browser ──Cognito hosted UI (PKCE, no client secret)──► tokens
#   browser ──CloudFront──► S3 (static TypeScript app, compiled during the apply)
#   browser ──HTTP API (JWT authoriser = the user pool)──► Lambda (Python, READ-ONLY role)
#                                                             └─► Tagging API / ECS / EFS / EC2 /
#                                                                 Backup / CloudWatch / Logs / SSM /
#                                                                 Pricing (+ Cost Explorer, opt-in)
#
# Nothing here can change the stack: the Lambda role's only write is a cache parameter under
# /<name>/gui/cache/* (pricing rates, 24 h). Everything the API shows is read live; no simulation.
# Inventory is discovered by the tag Project=<name>, so several projects can share one account.

data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}
data "aws_region" "this" {}

locals {
  account   = data.aws_caller_identity.this.account_id
  partition = data.aws_partition.this.partition
  arn       = "arn:${local.partition}"
  suffix    = substr(sha1("${local.account}/${var.region}/${var.name}"), 0, 10)

  web_dir = "${path.module}/web"
  api_dir = "${path.module}/api"

  # Any change to the front-end sources rebuilds and re-uploads; config changes re-upload config only.
  web_files = sort(setunion(
    fileset(local.web_dir, "src/**"), fileset(local.web_dir, "*.html"),
    fileset(local.web_dir, "*.css"), fileset(local.web_dir, "*.json"),
  ))
  web_hash = sha1(join("", concat(
    [for f in local.web_files : filesha1("${local.web_dir}/${f}")],
    [filesha1("${path.module}/build.sh")],
  )))

  cache_param_arn = "${local.arn}:ssm:${var.region}:${local.account}:parameter/${var.name}/gui/cache"
  outputs_param   = "${local.arn}:ssm:${var.region}:${local.account}:parameter${var.ssm_prefix}"
  log_group_arns = [
    "${local.arn}:logs:${var.region}:${local.account}:log-group:${var.writer_log_group}:*",
    "${local.arn}:logs:${var.region}:${local.account}:log-group:${var.reader_log_group}:*",
  ]
}

# ---------------------------------------------------------------- identity (D25: Cognito login)
resource "aws_cognito_user_pool" "gui" {
  name                     = "${var.name}-gui"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "INACTIVE" # `make down` must be able to remove it
  mfa_configuration        = "OFF"

  admin_create_user_config {
    allow_admin_create_user_only = true # nobody can sign themselves up
    invite_message_template {
      email_subject = "Your ${var.name} map login"
      email_message = "Your ${var.name} map user is {username}. Temporary password: {####} (you set a new one on first sign-in)."
      sms_message   = "${var.name} map user {username}, temporary password {####}"
    }
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }
}

resource "aws_cognito_user_pool_domain" "gui" {
  domain       = "${var.name}-${local.suffix}"
  user_pool_id = aws_cognito_user_pool.gui.id
}

resource "aws_cognito_user_pool_client" "gui" {
  name         = "${var.name}-gui-web"
  user_pool_id = aws_cognito_user_pool.gui.id

  generate_secret                      = false # a browser cannot keep a secret; PKCE instead
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://${aws_cloudfront_distribution.gui.domain_name}/"]
  logout_urls                          = ["https://${aws_cloudfront_distribution.gui.domain_name}/"]
  # ADMIN_USER_PASSWORD_AUTH needs IAM rights on the pool (the deployer's), never the browser's: it lets
  # tests/live/e2e.sh E5 mint a token for a throwaway user and probe the API end to end.
  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH", "ALLOW_ADMIN_USER_PASSWORD_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 8
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
}

# First user. No password here: Cognito e-mails a temporary one (desired_delivery_mediums),
# so no secret ever enters Terraform state or the repo.
resource "aws_cognito_user" "admin" {
  count = var.admin_email == null ? 0 : 1

  user_pool_id             = aws_cognito_user_pool.gui.id
  username                 = var.admin_email
  desired_delivery_mediums = ["EMAIL"]
  attributes = {
    email          = var.admin_email
    email_verified = "true"
  }
}

# ---------------------------------------------------------------- static site (S3 behind CloudFront)
resource "aws_s3_bucket" "web" {
  bucket        = "${var.name}-gui-${local.suffix}"
  force_destroy = true # built artefacts only; rebuilt by the next apply
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudFrontReadOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.web.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.gui.arn } }
    }]
  })
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${var.name}-gui-${local.suffix}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "gui" {
  enabled             = true
  comment             = "${var.name} 2.5D map"
  default_root_object = "index.html"
  price_class         = "PriceClass_All" # Sydney viewers are only in the "All" class
  http_version        = "http2and3"
  is_ipv6_enabled     = true

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3-web"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-web"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03" # AWS managed: SecurityHeadersPolicy
  }

  # config.json must never be served stale: the API URL and pool IDs change on re-create.
  ordered_cache_behavior {
    path_pattern           = "config.json"
    target_origin_id       = "s3-web"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
  }

  # Single-page app: unknown paths (and S3's 403 for missing keys) load the app.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1"
  }
}

# Runtime configuration for the page: everything it needs to log in and call the API. Non-secret.
resource "aws_s3_object" "config" {
  bucket       = aws_s3_bucket.web.id
  key          = "config.json"
  content_type = "application/json"
  content = jsonencode({
    name           = var.name
    region         = var.region
    account        = local.account
    userPoolId     = aws_cognito_user_pool.gui.id
    clientId       = aws_cognito_user_pool_client.gui.id
    cognitoDomain  = "https://${aws_cognito_user_pool_domain.gui.domain}.auth.${var.region}.amazoncognito.com"
    apiUrl         = aws_apigatewayv2_api.api.api_endpoint
    refreshSeconds = var.refresh_seconds
  })
}

# Compile the TypeScript in a pinned Node container and upload the result. Like the app images,
# this runs inside the apply so "one apply deploys everything" stays true; the host needs Docker,
# not Node. Re-runs only when a source file changes.
resource "terraform_data" "web" {
  count = var.build_web ? 1 : 0 # unit tests set false: provisioners run in `terraform test` even on overridden resources (measured 2026-10-27)

  triggers_replace = {
    web_hash   = local.web_hash
    node_image = var.node_image
    bucket     = aws_s3_bucket.web.id
  }

  depends_on = [aws_s3_bucket_policy.web, aws_s3_object.config]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      WEB_DIR       = local.web_dir
      NODE_IMAGE    = var.node_image
      BUCKET        = aws_s3_bucket.web.id
      DISTRIBUTION  = aws_cloudfront_distribution.gui.id
      REGION        = var.region
      BUILD_TIMEOUT = var.build_timeout_seconds
    }
    command = <<-EOT
      set -eu
      work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
      # One build script for the apply and for `make test-web` (modules/gui/build.sh): npm ci honours
      # package-lock.json exactly (D27), three.js is copied next to the page, a watchdog bounds it.
      bash "${path.module}/build.sh" "$WEB_DIR" "$work/dist" "$NODE_IMAGE" "$BUILD_TIMEOUT"
      # Upload everything but config.json (Terraform owns that object), then purge the edge caches.
      aws s3 sync "$work/dist" "s3://$BUCKET" --region "$REGION" --delete --exclude config.json --only-show-errors
      aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION" --paths "/*" --output text --query 'Invalidation.Id'
    EOT
  }
}

# ---------------------------------------------------------------- read-only data API
data "archive_file" "api" {
  type        = "zip"
  source_dir  = local.api_dir
  output_path = "${path.module}/.build/api.zip"
  excludes    = ["__pycache__", "tests"]
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${var.name}-gui-api"
  retention_in_days = 14
}

resource "aws_iam_role" "api" {
  name_prefix = "${var.name}-gui-api-"
  description = "Read-only data API for the ${var.name} map. Only write: its own pricing cache parameter."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "api" {
  name = "read-only-map"
  role = aws_iam_role.api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "OwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.api.arn}:*"
      },
      {
        # Inventory by tag + describes for health and rooms. All read-only (Describe/List/Get).
        Sid    = "ReadInventory"
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeNatGateways", "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "ec2:DescribeAddresses", "ec2:DescribeInternetGateways",
          "ecs:DescribeClusters", "ecs:DescribeServices", "ecs:ListTasks", "ecs:DescribeTasks", "ecs:DescribeTaskDefinition",
          "elasticfilesystem:DescribeFileSystems", "elasticfilesystem:DescribeMountTargets", "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:DescribeFileSystemPolicy", "elasticfilesystem:DescribeLifecycleConfiguration",
          "backup:ListBackupVaults", "backup:ListBackupPlans", "backup:GetBackupPlan", "backup:ListBackupJobs", "backup:ListRecoveryPointsByBackupVault",
          "cloudwatch:DescribeAlarms", "cloudwatch:GetMetricData",
          "pricing:GetProducts",
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadAppLogs"
        Effect   = "Allow"
        Action   = ["logs:FilterLogEvents", "logs:DescribeLogStreams", "logs:GetLogEvents"]
        Resource = local.log_group_arns
      },
      {
        Sid      = "ReadRegistry"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [local.outputs_param, "${local.outputs_param}/*", local.cache_param_arn, "${local.cache_param_arn}/*"]
      },
      {
        # The ONLY write: a 24 h cache of Pricing API rates under /<name>/gui/cache/*.
        Sid      = "WritePricingCacheOnly"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = ["${local.cache_param_arn}/*"]
      },
      ],
      var.cost_actuals ? [{
        Sid      = "ReadActualSpend"
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = "*"
      }] : []
    )
  })
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.name}-gui-api"
  description      = "Read-only data API behind the ${var.name} map (Cognito JWT required at the gateway)."
  role             = aws_iam_role.api.arn
  runtime          = var.lambda_runtime
  architectures    = ["arm64"]
  handler          = "app.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 28 # HTTP API caps at 29 s
  memory_size      = 512

  environment {
    variables = {
      SEFS_NAME         = var.name
      SEFS_REGION       = var.region
      SEFS_SSM_PREFIX   = var.ssm_prefix
      SEFS_CACHE_PREFIX = "/${var.name}/gui/cache"
      SEFS_WRITER_LOGS  = var.writer_log_group
      SEFS_READER_LOGS  = var.reader_log_group
      SEFS_VAULT        = var.backup_vault_name
      SEFS_CLUSTER      = var.cluster_name
      SEFS_COST_ACTUALS = var.cost_actuals ? "true" : "false"
    }
  }

  depends_on = [aws_cloudwatch_log_group.api, aws_iam_role_policy.api]
}

resource "aws_apigatewayv2_api" "api" {
  name          = "${var.name}-gui-api"
  protocol_type = "HTTP"
  description   = "Read-only JSON for the ${var.name} map; every route requires a Cognito JWT."

  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.gui.domain_name}"]
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.api.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.gui.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.gui.id}"
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

resource "aws_apigatewayv2_route" "api" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "GET /api/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
