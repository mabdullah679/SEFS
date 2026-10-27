# modules/gui: the map is login-gated, its API role can only read, the page bucket is never public,
# and the build step is overridden so no docker runs. Mock providers only.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/sefs-ut-gui-api" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { domain_name = "d111111abcdef8.cloudfront.net", arn = "arn:aws:cloudfront::111122223333:distribution/E1UT" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::sefs-ut-gui-abc", bucket_regional_domain_name = "sefs-ut-gui-abc.s3.ap-southeast-2.amazonaws.com" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { invoke_arn = "arn:aws:apigateway:ap-southeast-2:lambda:path/2015-03-31/functions/arn:aws:lambda:ap-southeast-2:111122223333:function:sefs-ut-gui-api/invocations" }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = { api_endpoint = "https://ut.execute-api.ap-southeast-2.amazonaws.com", execution_arn = "arn:aws:execute-api:ap-southeast-2:111122223333:ut" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-southeast-2:111122223333:log-group:/aws/lambda/sefs-ut-gui-api" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-2", region = "ap-southeast-2" }
  }
}

mock_provider "archive" {
  mock_data "archive_file" {
    defaults = { output_path = "/dev/null", output_base64sha256 = "dW5pdA==" }
  }
}

variables {
  build_web         = false # the docker build + upload never runs in a unit test (override_resource still runs provisioners)
  name              = "sefs-ut"
  region            = "ap-southeast-2"
  admin_email       = "ops@example.com"
  ssm_prefix        = "/sefs-ut"
  writer_log_group  = "/ecs/sefs-ut/writer"
  reader_log_group  = "/ecs/sefs-ut/reader"
  backup_vault_name = "sefs-ut"
  cluster_name      = "sefs-ut"
  cost_actuals      = true
}

run "login_required_on_every_api_route" {
  command = apply
  module {
    source = "./modules/gui"
  }

  assert {
    condition     = aws_apigatewayv2_route.api.authorization_type == "JWT" && aws_apigatewayv2_route.api.authorizer_id == aws_apigatewayv2_authorizer.cognito.id
    error_message = "D25: every API route must require the Cognito JWT; an open route exposes the account topology."
  }
  assert {
    condition     = aws_apigatewayv2_authorizer.cognito.jwt_configuration[0].audience == toset([aws_cognito_user_pool_client.gui.id]) && aws_apigatewayv2_route.api.route_key == "GET /api/{proxy+}"
    error_message = "The authoriser must accept tokens for this client only, and the API is GET-only."
  }
}

run "nobody_can_sign_themselves_up" {
  command = apply
  module {
    source = "./modules/gui"
  }

  assert {
    condition     = aws_cognito_user_pool.gui.admin_create_user_config[0].allow_admin_create_user_only == true
    error_message = "D25: self sign-up must be off; only the owner creates map users."
  }
  assert {
    condition     = aws_cognito_user_pool_client.gui.generate_secret == false && aws_cognito_user_pool_client.gui.allowed_oauth_flows == toset(["code"])
    error_message = "A browser client cannot keep a secret: PKCE authorization-code flow only."
  }
  assert {
    condition     = length(aws_cognito_user.admin) == 1 && aws_cognito_user.admin[0].desired_delivery_mediums == toset(["EMAIL"])
    error_message = "With admin_email set, the first user is created and gets a temporary password by e-mail (no password in Terraform)."
  }
}

run "api_role_can_only_read" {
  command = apply
  module {
    source = "./modules/gui"
  }

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.api.policy).Statement : [
        for a in flatten([s.Action]) :
        can(regex("^(tag:GetResources|logs:(CreateLogStream|PutLogEvents|FilterLogEvents|DescribeLogStreams|GetLogEvents)|ssm:(GetParameter|GetParameters|GetParametersByPath|PutParameter)|ce:GetCostAndUsage|pricing:GetProducts|[a-z0-9]+:(Describe|List|Get)[A-Za-z]+)$", a))
      ]
    ]))
    error_message = "The API role must hold read actions only (Describe/List/Get, its own logs, the pricing cache write). A write action here lets the map change the stack."
  }
  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.api.policy).Statement :
      [for r in flatten([s.Resource]) : can(regex(":parameter/sefs-ut/gui/cache/\\*$", r))]
      if contains(flatten([s.Action]), "ssm:PutParameter")
    ]))
    error_message = "ssm:PutParameter is allowed only under /<name>/gui/cache/*; anything wider lets the map write the registry."
  }
  assert {
    condition     = anytrue([for s in jsondecode(aws_iam_role_policy.api.policy).Statement : contains(flatten([s.Action]), "ce:GetCostAndUsage")])
    error_message = "cost_actuals = true must grant ce:GetCostAndUsage (the cost panel shows real spend)."
  }
}

run "cost_actuals_off_grants_no_cost_explorer" {
  command = apply
  module {
    source = "./modules/gui"
  }
  variables {
    cost_actuals = false
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.api.policy, "ce:GetCostAndUsage")
    error_message = "cost_actuals = false must not grant Cost Explorer."
  }
}

run "page_is_private_and_https_only" {
  command = apply
  module {
    source = "./modules/gui"
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.web.block_public_acls && aws_s3_bucket_public_access_block.web.block_public_policy &&
      aws_s3_bucket_public_access_block.web.ignore_public_acls && aws_s3_bucket_public_access_block.web.restrict_public_buckets
    )
    error_message = "The page bucket must block all public access; CloudFront reads it through OAC only."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.web.policy).Statement[0].Principal.Service == "cloudfront.amazonaws.com" && jsondecode(aws_s3_bucket_policy.web.policy).Statement[0].Action == "s3:GetObject"
    error_message = "The bucket policy must let only CloudFront read objects."
  }
  assert {
    condition     = aws_cloudfront_distribution.gui.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https" && aws_cloudfront_distribution.gui.ordered_cache_behavior[0].path_pattern == "config.json" && aws_cloudfront_distribution.gui.ordered_cache_behavior[0].cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    error_message = "HTTPS only, and config.json must never be cached at the edge (pool/API IDs change on re-create)."
  }
  assert {
    condition     = aws_apigatewayv2_api.api.cors_configuration[0].allow_origins == toset(["https://d111111abcdef8.cloudfront.net"]) && aws_apigatewayv2_api.api.cors_configuration[0].allow_methods == toset(["GET", "OPTIONS"])
    error_message = "CORS must admit the page's own origin only, GET only."
  }
}

run "lambda_is_arm_and_bounded" {
  command = apply
  module {
    source = "./modules/gui"
  }

  assert {
    condition     = aws_lambda_function.api.architectures == tolist(["arm64"]) && aws_lambda_function.api.timeout <= 29 && aws_lambda_function.api.runtime == "python3.12"
    error_message = "ARM64 (cheapest), timeout within the HTTP API's 29 s cap, pinned runtime."
  }
  assert {
    condition     = length(terraform_data.web) == 0
    error_message = "build_web = false must leave no build step (the unit suite must never run docker)."
  }
  assert {
    condition     = output.url == "https://d111111abcdef8.cloudfront.net/" && aws_cognito_user_pool_client.gui.callback_urls == toset(["https://d111111abcdef8.cloudfront.net/"])
    error_message = "The login must redirect back to the page's own origin and nowhere else."
  }
}
