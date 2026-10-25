# access: the least-privilege, READ-ONLY role the Bruno collection assumes.
#
# No static credentials exist anywhere: the client signs in to AWS the way they already
# do (SSO / `aws login` / keys in their own ~/.aws), assumes this role for one hour, and
# the collection reads deployed IDs + any secrets from SSM Parameter Store with it.
# Policy is built with jsonencode (not aws_iam_policy_document) so unit tests can read
# the real JSON instead of a mock-provider placeholder.

data "aws_caller_identity" "this" {}

data "aws_partition" "this" {}

locals {
  account   = data.aws_caller_identity.this.account_id
  partition = data.aws_partition.this.partition
  arn       = "arn:${local.partition}"

  trust_principals = length(var.trusted_principal_arns) > 0 ? var.trusted_principal_arns : ["${local.arn}:iam::${local.account}:root"]

  ssm_param_arn = "${local.arn}:ssm:${var.region}:${local.account}:parameter"
}

resource "aws_iam_role" "bruno_reader" {
  name                 = "${var.name}-bruno-reader"
  description          = "Read-only verifier for the ${var.name} Bruno collection. No write actions."
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AssumeFromTrustedPrincipals"
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = local.trust_principals }
    }]
  })
}

resource "aws_iam_role_policy" "bruno_reader" {
  name = "read-only-verify"
  role = aws_iam_role.bruno_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Deployed IDs (/<name>/outputs/*) and any secrets the setup script stored (/<name>/secrets/*).
        Sid    = "ReadProjectParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "${local.ssm_param_arn}/${var.name}",
          "${local.ssm_param_arn}/${var.name}/*",
        ]
      },
      {
        # SecureString values are encrypted with the AWS-managed aws/ssm key. Decrypt is
        # allowed only when SSM makes the call for one of this project's parameters.
        Sid      = "DecryptProjectSecretsViaSsmOnly"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "${local.arn}:kms:${var.region}:${local.account}:key/*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
          StringLike   = { "kms:EncryptionContext:PARAMETER_ARN" = "${local.ssm_param_arn}/${var.name}/*" }
        }
      },
      {
        Sid    = "ReadEfs"
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:DescribeMountTargetSecurityGroups",
          "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:DescribeFileSystemPolicy",
          "elasticfilesystem:DescribeLifecycleConfiguration",
          "elasticfilesystem:DescribeBackupPolicy",
        ]
        Resource = [
          "${local.arn}:elasticfilesystem:${var.region}:${local.account}:file-system/*",
          "${local.arn}:elasticfilesystem:${var.region}:${local.account}:access-point/*",
        ]
      },
      {
        Sid      = "ReadEcsProject"
        Effect   = "Allow"
        Action   = ["ecs:DescribeClusters", "ecs:DescribeServices", "ecs:ListTasks", "ecs:DescribeTasks"]
        Resource = ["${local.arn}:ecs:${var.region}:${local.account}:*/${var.name}", "${local.arn}:ecs:${var.region}:${local.account}:*/${var.name}/*"]
      },
      {
        # Describe/List calls on these services do not support resource-level scoping.
        Sid    = "ReadUnscopableMetadata"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSecurityGroupRules",
          "ec2:DescribeNatGateways",
          "ec2:DescribeRouteTables",
          "backup:ListBackupPlans",
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadProjectLogs"
        Effect   = "Allow"
        Action   = ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams"]
        Resource = ["${local.arn}:logs:${var.region}:${local.account}:log-group:/ecs/${var.name}/*", "${local.arn}:logs:${var.region}:${local.account}:log-group:/ecs/${var.name}/*:*"]
      },
      {
        Sid      = "ReadBackup"
        Effect   = "Allow"
        Action   = ["backup:GetBackupPlan", "backup:ListBackupSelections", "backup:GetBackupSelection", "backup:DescribeBackupVault"]
        Resource = ["${local.arn}:backup:${var.region}:${local.account}:backup-plan:*", "${local.arn}:backup:${var.region}:${local.account}:backup-vault:${var.name}*"]
      },
    ]
  })
}
