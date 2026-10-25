# R14. Mock provider only.
#
# ADDRESS ASSUMPTIONS (fix after merge if renamed):
#   aws_backup_vault.this, aws_backup_plan.this, aws_backup_selection.this,
#   aws_iam_role.backup, aws_iam_role_policy_attachment.managed (for_each),
#   data.aws_iam_policy_document.assume, data.aws_partition.current

mock_provider "aws" {
  # Provider ARN validators run on mocked values, so ARN attrs need real shapes.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/sefs-ut-mock"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  # Realistic JSON so aws_iam_role.assume_role_policy is a real document.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"backup.amazonaws.com\"}}]}"
    }
  }
}

variables {
  name           = "sefs-ut"
  resource_arns  = ["arn:aws:elasticfilesystem:us-east-1:111122223333:file-system/fs-0123456789abcdef0"]
  retention_days = 35
  kms_key_arn    = null
}

run "r14_backup_35_days_selects_efs" {
  command = apply
  module {
    source = "./modules/backup"
  }

  assert {
    condition     = alltrue([for r in aws_backup_plan.this.rule : alltrue([for l in r.lifecycle : l.delete_after >= 35])]) && length(aws_backup_plan.this.rule) >= 1
    error_message = "R14: every backup rule must retain >= 35 days."
  }
  assert {
    condition     = alltrue([for r in aws_backup_plan.this.rule : alltrue([for l in r.lifecycle : l.delete_after == var.retention_days])])
    error_message = "R14: delete_after must come from retention_days (not a hard-coded number)."
  }
  assert {
    condition     = alltrue([for r in aws_backup_plan.this.rule : r.target_vault_name == aws_backup_vault.this.name])
    error_message = "R14: the plan must target the module's vault."
  }
  assert {
    condition     = alltrue([for r in aws_backup_plan.this.rule : r.schedule == "cron(0 5 * * ? *)"])
    error_message = "CONTRACTS: daily rule at cron(0 5 * * ? *)."
  }
  assert {
    condition     = contains(tolist(aws_backup_selection.this.resources), "arn:aws:elasticfilesystem:us-east-1:111122223333:file-system/fs-0123456789abcdef0")
    error_message = "R14: the backup selection must include the EFS ARN."
  }
  assert {
    condition     = aws_backup_selection.this.plan_id == aws_backup_plan.this.id && aws_backup_selection.this.iam_role_arn == aws_iam_role.backup.arn
    error_message = "R14: selection must bind the plan to the backup role."
  }
  # The mocked .json above is ours, so asserting on it would prove nothing.
  # Assert on the module's own statement inputs, and that the role uses them.
  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.assume.statement :
      contains(s.actions, "sts:AssumeRole") &&
      anytrue([for p in s.principals : p.type == "Service" && contains(p.identifiers, "backup.amazonaws.com")])
    ])
    error_message = "R14: the backup role must trust backup.amazonaws.com."
  }
  assert {
    condition     = aws_iam_role.backup.assume_role_policy == data.aws_iam_policy_document.assume.json
    error_message = "R14: the backup role must use that trust document."
  }
  assert {
    condition = toset([for a in values(aws_iam_role_policy_attachment.managed) : a.policy_arn]) == toset([
      "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
      "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
    ])
    error_message = "R14: the backup role needs the AWS managed Backup + Restores service-role policies."
  }
  assert {
    condition     = aws_backup_vault.this.force_destroy == true
    error_message = "CONTRACTS: vault force_destroy = true so teardown can remove recovery points."
  }
}

run "r14_rejects_34_day_retention" {
  command = plan
  module {
    source = "./modules/backup"
  }
  variables {
    retention_days = 34
  }
  expect_failures = [var.retention_days]
}
