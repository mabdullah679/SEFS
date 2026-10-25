# modules/bootstrap: state bucket, lock table, GitHub OIDC deploy role. Mock provider only.
# Policies are jsonencode()d, so they are real JSON here.

mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::sefs-ut-tfstate-111122223333-ap-southeast-2"
    }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = {
      arn = "arn:aws:dynamodb:ap-southeast-2:111122223333:table/sefs-ut-tfstate-lock"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/sefs-ut-github-deploy"
    }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
      arn        = "arn:aws:iam::111122223333:user/ut"
      user_id    = "AIDAUNITTEST"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

variables {
  name        = "sefs-ut"
  region      = "ap-southeast-2"
  github_repo = "acme/sefs"
}

run "state_bucket_is_private_versioned_encrypted_tls_only" {
  command = apply
  module {
    source = "./modules/bootstrap"
  }

  assert {
    condition     = aws_s3_bucket.state.bucket == "sefs-ut-tfstate-111122223333-ap-southeast-2" && aws_s3_bucket.state.force_destroy == false
    error_message = "Bucket must be <name>-tfstate-<account>-<region> and must not be force-destroyable by default."
  }
  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State bucket versioning must be Enabled (state history is the undo button)."
  }
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "All four public-access blocks must be on."
  }
  assert {
    condition     = aws_s3_bucket_server_side_encryption_configuration.state.rule[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "With no CMK the bucket must still be encrypted (SSE-S3)."
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_s3_bucket_policy.state_tls_only.policy).Statement :
      st.Effect == "Deny" && st.Action == "s3:*" && try(st.Condition.Bool["aws:SecureTransport"], "") == "false"
    ])
    error_message = "Bucket policy must deny all non-TLS access."
  }
}

run "lock_table_shape" {
  command = apply
  module {
    source = "./modules/bootstrap"
  }

  assert {
    condition     = aws_dynamodb_table.lock.hash_key == "LockID" && aws_dynamodb_table.lock.billing_mode == "PAY_PER_REQUEST" && aws_dynamodb_table.lock.server_side_encryption[0].enabled
    error_message = "Lock table must be keyed by LockID (what the s3 backend writes), on-demand, encrypted."
  }
}

run "github_role_trusts_exactly_one_repo_and_branch" {
  command = apply
  module {
    source = "./modules/bootstrap"
  }

  assert {
    condition     = length(aws_iam_role.github_deploy) == 1 && length(aws_iam_openid_connect_provider.github) == 1
    error_message = "With github_repo set, the OIDC provider and deploy role must exist."
  }
  assert {
    condition = (
      jsondecode(aws_iam_role.github_deploy[0].assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.github_deploy[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:acme/sefs:ref:refs/heads/main" &&
      jsondecode(aws_iam_role.github_deploy[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    )
    error_message = "Trust must be StringEquals on sub=repo:<owner/repo>:ref:refs/heads/<branch> and aud=sts.amazonaws.com (no wildcards)."
  }
  assert {
    condition     = !can(regex("[*]", jsondecode(aws_iam_role.github_deploy[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]))
    error_message = "The sub condition must not contain a wildcard."
  }
}

run "github_role_iam_is_scoped_and_cannot_touch_itself" {
  command = apply
  module {
    source = "./modules/bootstrap"
  }

  assert {
    condition = alltrue([
      for st in jsondecode(aws_iam_role_policy.github_project_iam[0].policy).Statement :
      st.Effect != "Allow" || !anytrue([for a in flatten([st.Action]) : startswith(a, "iam:") && !startswith(a, "iam:GetPolicy") && !startswith(a, "iam:ListPolicyVersions")]) ||
      alltrue([for r in flatten([st.Resource]) : endswith(r, ":role/sefs-ut-*")])
    ])
    error_message = "Every IAM mutation the deploy role may perform must be scoped to role/<name>-*."
  }
  assert {
    condition = anytrue([
      for st in jsondecode(aws_iam_role_policy.github_project_iam[0].policy).Statement :
      st.Effect == "Deny" && st.Action == "iam:*" && endswith(st.Resource, ":role/sefs-ut-github-deploy")
    ])
    error_message = "The deploy role must explicitly deny all IAM on itself."
  }
  assert {
    condition     = endswith(aws_iam_role_policy_attachment.github_poweruser[0].policy_arn, ":iam::aws:policy/PowerUserAccess")
    error_message = "Deploy breadth comes from PowerUserAccess (no IAM), not AdministratorAccess."
  }
}

run "no_ci_role_without_github_repo" {
  command = apply
  module {
    source = "./modules/bootstrap"
  }
  variables {
    github_repo = null
  }

  assert {
    condition     = length(aws_iam_role.github_deploy) == 0 && length(aws_iam_openid_connect_provider.github) == 0 && output.github_deploy_role_arn == null
    error_message = "No CI role or OIDC provider may exist when github_repo is unset."
  }
}

run "rejects_bad_names_and_repos" {
  command = plan
  module {
    source = "./modules/bootstrap"
  }
  variables {
    name        = "Has_Upper"
    github_repo = "not-a-repo"
  }

  expect_failures = [var.name, var.github_repo]
}
