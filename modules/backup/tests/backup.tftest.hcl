# R14 unit tests: mock provider only, no AWS API calls.

mock_provider "aws" {
  # The provider validates ARN shape on aws_backup_selection.iam_role_arn even under mocks.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/sefs-test-backup"
    }
  }

  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:us-east-1:111122223333:backup-vault:sefs-test-vault"
    }
  }

  override_data {
    target = data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  # The mock's random string is not valid JSON and aws_iam_role validates it
  # even under mocks. Statement content is asserted from the data source inputs below.
  override_data {
    target = data.aws_iam_policy_document.assume
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"backup.amazonaws.com\"}}]}"
    }
  }
}

variables {
  name           = "sefs-test"
  resource_arns  = ["arn:aws:elasticfilesystem:us-east-1:111122223333:file-system/fs-0123456789abcdef0"]
  retention_days = 35
}

run "retention_34_rejected" {
  command = plan

  variables {
    retention_days = 34
  }

  expect_failures = [var.retention_days]
}

run "retention_35_accepted_and_wired" {
  command = apply

  assert {
    condition     = length(aws_backup_plan.this.rule) == 1
    error_message = "Backup plan must have exactly one rule."
  }

  assert {
    condition     = one(aws_backup_plan.this.rule).schedule == "cron(0 5 * * ? *)"
    error_message = "Rule must run daily at 05:00 UTC."
  }

  assert {
    condition     = one(one(aws_backup_plan.this.rule).lifecycle).delete_after == var.retention_days
    error_message = "delete_after must equal retention_days."
  }

  assert {
    condition     = one(aws_backup_plan.this.rule).target_vault_name == aws_backup_vault.this.name
    error_message = "Rule must target this module's vault."
  }

  assert {
    condition     = aws_backup_vault.this.force_destroy == true
    error_message = "Vault must have force_destroy = true."
  }

  assert {
    condition     = toset(aws_backup_selection.this.resources) == toset(var.resource_arns)
    error_message = "Selection must cover exactly the given ARNs."
  }

  assert {
    condition     = aws_backup_selection.this.iam_role_arn == aws_iam_role.backup.arn
    error_message = "Selection must use the module's backup role."
  }

  assert {
    condition     = aws_backup_selection.this.plan_id == aws_backup_plan.this.id
    error_message = "Selection must belong to the module's plan."
  }

  assert {
    condition = toset([for a in aws_iam_role_policy_attachment.managed : a.policy_arn]) == toset([
      "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
      "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
    ])
    error_message = "Both AWS Backup managed service-role policies must be attached."
  }

  assert {
    condition     = alltrue([for a in aws_iam_role_policy_attachment.managed : a.role == aws_iam_role.backup.name])
    error_message = "Managed policies must attach to the backup role."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.assume.statement) == 1 &&
      one(data.aws_iam_policy_document.assume.statement).actions == toset(["sts:AssumeRole"]) &&
      one(one(data.aws_iam_policy_document.assume.statement).principals).type == "Service" &&
      one(one(data.aws_iam_policy_document.assume.statement).principals).identifiers == toset(["backup.amazonaws.com"])
    )
    error_message = "Role must be assumable only by backup.amazonaws.com."
  }

  assert {
    condition     = output.vault_name == aws_backup_vault.this.name && output.vault_arn == aws_backup_vault.this.arn && output.plan_id == aws_backup_plan.this.id && output.selection_id == aws_backup_selection.this.id && output.role_arn == aws_iam_role.backup.arn
    error_message = "Outputs must expose the real resource attributes."
  }
}

run "kms_key_passed_through" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_backup_vault.this.kms_key_arn == var.kms_key_arn
    error_message = "Vault must use the provided CMK."
  }
}

run "retention_above_floor_propagates" {
  command = plan

  variables {
    retention_days = 90
  }

  assert {
    condition     = one(one(aws_backup_plan.this.rule).lifecycle).delete_after == 90
    error_message = "delete_after must track retention_days."
  }
}
