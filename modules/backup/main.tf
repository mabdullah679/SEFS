# R14: AWS Backup of the shared EFS with >= 35-day retention (see docs/CONTRACTS.md §3 "backup").

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_partition" "current" {}

locals {
  # AWS managed service-role policies (path service-role/), verified against the
  # AWS Managed Policy Reference on 2026-10-25.
  managed_policy_arns = {
    backup   = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
    restores = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
  }
}

resource "aws_backup_vault" "this" {
  name = "${var.name}-vault"
  # null -> AWS Backup uses its AWS-managed key.
  kms_key_arn = var.kms_key_arn
  # Teardown must be able to remove recovery points, or destroy fails.
  force_destroy = true
}

resource "aws_backup_plan" "this" {
  name = "${var.name}-plan"

  rule {
    rule_name         = "${var.name}-daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 5 * * ? *)"

    lifecycle {
      delete_after = var.retention_days
    }
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = local.managed_policy_arns

  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_selection" "this" {
  name         = "${var.name}-selection"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = var.resource_arns

  # The role must carry its permissions before AWS Backup validates the selection.
  depends_on = [aws_iam_role_policy_attachment.managed]
}
