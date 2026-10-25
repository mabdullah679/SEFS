# EFS wiring, apply mode with mocks. TEMP COPY ONLY: tests/unit/run.sh runs
# this directory in a copy with the prevent_destroy line stripped, because
# `terraform test` cannot tear down a prevent_destroy resource (measured on
# TF 1.9.8). prevent_destroy (R4) is checked statically by run.sh.
#
# The policy CONTENT is proven against the real rendered JSON in
# tests/unit/efs_policy.tftest.hcl. This file proves that rendered JSON is the
# one attached to THIS file system, and that every EFS child object hangs off
# the same file system.

mock_provider "aws" {
  # The provider validates aws_efs_file_system_policy.policy as JSON even on
  # mocked values. This stand-in is NOT asserted on for content (that is
  # efs_policy.tftest.hcl's job); only "attached == rendered" is checked here.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"MOCK\",\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\",\"Principal\":{\"AWS\":\"*\"}}]}"
    }
  }
}

variables {
  name = "sefs-ut"
  private_subnets_by_az = {
    "us-east-1a" = "subnet-0aaaaaaaaaaaaaaa1"
    "us-east-1b" = "subnet-0bbbbbbbbbbbbbbb2"
  }
  efs_security_group_id = "sg-0eeeeeeeeeeeeeee1"
  kms_key_arn           = null
  transition_to_ia      = "AFTER_30_DAYS"
  shared_root_path      = "/shared"
  posix_gid             = 1000
  writer_uid            = 1001
  reader_uid            = 1002
  writer_role_arn       = "arn:aws:iam::111122223333:role/sefs-ut-writer-task"
  reader_role_arn       = "arn:aws:iam::111122223333:role/sefs-ut-reader-task"
}

run "r03_fs_policy_attached_to_shared_fs" {
  command = apply
  module {
    source = "./modules/efs"
  }

  assert {
    condition     = aws_efs_file_system_policy.this.file_system_id == aws_efs_file_system.this.id
    error_message = "R3: the FS policy must be attached to the shared file system."
  }
  assert {
    condition     = aws_efs_file_system_policy.this.policy == module.fs_policy.json
    error_message = "R3: the attached policy must be the rendered document from modules/efs/policy."
  }
  assert {
    condition     = output.file_system_policy_id == aws_efs_file_system_policy.this.id
    error_message = "apps gates its services on file_system_policy_id; it must be the real policy id."
  }
}

run "efs_children_share_one_file_system" {
  command = apply
  module {
    source = "./modules/efs"
  }

  assert {
    condition = alltrue([for id in concat(
      [aws_efs_access_point.writer.file_system_id, aws_efs_access_point.reader.file_system_id, aws_efs_backup_policy.this.file_system_id],
      [for mt in values(aws_efs_mount_target.this) : mt.file_system_id],
    ) : id == aws_efs_file_system.this.id])
    error_message = "R2/R3/R7: access points, mount targets and backup policy must all target the one shared file system."
  }
  assert {
    condition     = toset(keys(output.mount_target_ids)) == toset(keys(var.private_subnets_by_az))
    error_message = "R7: mount_target_ids output keyed by AZ."
  }
  assert {
    condition     = output.writer_access_point_arn == aws_efs_access_point.writer.arn && output.reader_access_point_arn == aws_efs_access_point.reader.arn
    error_message = "AP ARN outputs must point at the right access points (apps scopes IAM on them)."
  }
}

run "r13_cmk_passed_through" {
  command = apply
  module {
    source = "./modules/efs"
  }
  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_efs_file_system.this.kms_key_id == "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
    error_message = "R13: a supplied CMK ARN must be set as kms_key_id."
  }
  assert {
    condition     = aws_efs_file_system.this.encrypted == true
    error_message = "R13: CMK requires encrypted = true."
  }
}
