# bootstrap: the two things that must exist BEFORE the mother can run with shared state,
# plus the role GitHub Actions deploys with. Applied once by the owner (local state, tiny);
# never managed by CI, so CI cannot change its own permissions or delete the state it uses.
#
#   - S3 bucket for Terraform state: versioned, encrypted, private, TLS-only
#   - DynamoDB table for state locking (TF 1.9 uses DynamoDB; S3-native locking needs 1.10)
#   - optional: GitHub OIDC provider + deploy role trusted ONLY by <repo> on <branch>

data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}

locals {
  account     = data.aws_caller_identity.this.account_id
  partition   = data.aws_partition.this.partition
  bucket_name = "${var.name}-tfstate-${local.account}-${var.region}"
  table_name  = "${var.name}-tfstate-lock"
}

# ---------------------------------------------------------------- state bucket
resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = var.allow_state_destroy # false by default: `make down` never deletes state
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------- lock table
resource "aws_dynamodb_table" "lock" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }
}

# ---------------------------------------------------------------- GitHub OIDC deploy role
resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo != null && var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub's provider is validated by its root CA since 2023; AWS ignores the thumbprint
  # for this issuer but the argument is still required by the API.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  # Exact `sub` values allowed. GitHub sends the ID-pinned form (repo:owner@id/repo@id:ref:...)
  # when it knows the IDs; the plain form stays as a second exact value for older runners.
  # Both are StringEquals: no wildcards anywhere in the trust.
  github_owner = var.github_repo == null ? "" : split("/", var.github_repo)[0]
  github_name  = var.github_repo == null ? "" : split("/", var.github_repo)[1]
  # GitHub emits the ID-pinned form (owner@id/repo@id) today and the plain form historically; a job with
  # `environment:` presents ":environment:<name>" instead of ":ref:refs/heads/<branch>". All are listed
  # exactly (StringEquals, no wildcards).
  github_repo_forms = var.github_repo == null ? [] : compact([
    var.github_repo,
    var.github_owner_id != null && var.github_repo_id != null
    ? "${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repo_id}"
    : "",
  ])
  github_claims = compact([
    "ref:refs/heads/${var.github_branch}",
    var.github_environment != "" ? "environment:${var.github_environment}" : "",
  ])
  github_subs = flatten([for r in local.github_repo_forms : [for c in local.github_claims : "repo:${r}:${c}"]])

  oidc_provider_arn = var.github_repo == null ? null : (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:${local.partition}:iam::${local.account}:oidc-provider/token.actions.githubusercontent.com"
  )
}

resource "aws_iam_role" "github_deploy" {
  count = var.github_repo != null ? 1 : 0

  name                 = "${var.name}-github-deploy"
  description          = "Deploys ${var.name} from GitHub Actions (repo ${var.github_repo}, branch ${var.github_branch}) via OIDC."
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubOidcThisRepoThisBranchOnly"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_subs
        }
      }
    }]
  })
}

# PowerUserAccess = every service except IAM/Organizations/Account. The stack creates IAM
# roles (task, backup, bruno-reader), so IAM is added back ONLY for names under <name>-*.
# This is still a broad deploy role (it must create VPCs, EFS, ECS, ECR, Backup, Logs, SSM);
# the scoping that matters is the trust policy: one repo, one branch.
resource "aws_iam_role_policy_attachment" "github_poweruser" {
  count      = var.github_repo != null ? 1 : 0
  role       = aws_iam_role.github_deploy[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "github_project_iam" {
  count = var.github_repo != null ? 1 : 0
  name  = "project-iam-and-state"
  role  = aws_iam_role.github_deploy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageProjectRolesOnly"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
          "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole",
        ]
        Resource = "arn:${local.partition}:iam::${local.account}:role/${var.name}-*"
      },
      {
        Sid      = "ReadManagedPoliciesItAttaches"
        Effect   = "Allow"
        Action   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
        Resource = "arn:${local.partition}:iam::aws:policy/*"
      },
      {
        Sid      = "NeverTouchTheDeployOrBootstrapRole"
        Effect   = "Deny"
        Action   = "iam:*"
        Resource = "arn:${local.partition}:iam::${local.account}:role/${var.name}-github-deploy"
      },
      {
        Sid      = "State"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      },
      {
        Sid      = "StateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
        Resource = aws_dynamodb_table.lock.arn
      },
    ]
  })
}
