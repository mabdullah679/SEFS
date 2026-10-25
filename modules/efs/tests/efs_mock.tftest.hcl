# Mock-provider unit tests for modules/efs. No AWS calls. R-IDs: R4, R7, R10, R12, R13, R15.
#
# Every run is `command = plan`: aws_efs_file_system has prevent_destroy (R4),
# so an apply-mode run cannot be torn down and the test file would always fail
# (observed on TF 1.9.8). Everything asserted here is known at plan time.
# The FS-policy content is proven by fs_policy.tftest.hcl (real rendered JSON);
# prevent_destroy by check_prevent_destroy.sh; policy wiring by check_policy_wiring.sh.

mock_provider "aws" {}

variables {
  name = "sefs-test"
  private_subnets_by_az = {
    "us-east-1a" = "subnet-0aaaaaaaaaaaaaaa1"
    "us-east-1b" = "subnet-0bbbbbbbbbbbbbbb2"
    "us-east-1c" = "subnet-0ccccccccccccccc3"
  }
  efs_security_group_id = "sg-0efs000000000000"
  kms_key_arn           = null
  transition_to_ia      = "AFTER_30_DAYS"
  shared_root_path      = "/shared"
  posix_gid             = 1000
  writer_uid            = 1001
  reader_uid            = 1002
  writer_role_arn       = "arn:aws:iam::111122223333:role/sefs-test-writer-task"
  reader_role_arn       = "arn:aws:iam::111122223333:role/sefs-test-reader-task"
}

run "file_system_settings" {
  command = plan

  assert {
    condition     = aws_efs_file_system.this.encrypted == true
    error_message = "R12: EFS must be encrypted."
  }
  assert {
    condition     = aws_efs_file_system.this.performance_mode == "generalPurpose"
    error_message = "R12: performance_mode must be generalPurpose."
  }
  assert {
    condition     = aws_efs_file_system.this.throughput_mode == "bursting"
    error_message = "R12: throughput_mode must be bursting."
  }
  assert {
    condition     = length(aws_efs_file_system.this.lifecycle_policy) == 1 && aws_efs_file_system.this.lifecycle_policy[0].transition_to_ia == "AFTER_30_DAYS"
    error_message = "R15: exactly one lifecycle_policy with transition_to_ia = AFTER_30_DAYS."
  }
  assert {
    condition     = aws_efs_backup_policy.this.backup_policy[0].status == "DISABLED"
    error_message = "EFS automatic backup must be DISABLED (R14 handled by modules/backup)."
  }
  assert {
    condition     = aws_efs_file_system_policy.this.bypass_policy_lockout_safety_check == false
    error_message = "FS policy must not bypass the lockout safety check."
  }
}

run "kms_key_passthrough" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_efs_file_system.this.kms_key_id == "arn:aws:kms:us-east-1:111122223333:key/11111111-2222-3333-4444-555555555555"
    error_message = "R13: kms_key_arn must reach kms_key_id."
  }
}

run "transition_to_ia_rejects_unsupported_value" {
  command = plan

  variables {
    transition_to_ia = "AFTER_31_DAYS"
  }

  expect_failures = [var.transition_to_ia]
}

run "transition_to_ia_passthrough" {
  command = plan

  variables {
    transition_to_ia = "AFTER_90_DAYS"
  }

  assert {
    condition     = aws_efs_file_system.this.lifecycle_policy[0].transition_to_ia == "AFTER_90_DAYS"
    error_message = "R15: transition_to_ia must come from the variable."
  }
}

run "mount_targets_one_per_az" {
  command = plan

  assert {
    condition     = length(aws_efs_mount_target.this) == 3
    error_message = "R7: one mount target per entry of private_subnets_by_az."
  }
  assert {
    condition     = toset(keys(aws_efs_mount_target.this)) == toset(keys(var.private_subnets_by_az))
    error_message = "R7: mount targets must be keyed by AZ."
  }
  assert {
    condition     = alltrue([for az, mt in aws_efs_mount_target.this : mt.subnet_id == var.private_subnets_by_az[az]])
    error_message = "R7: each mount target must sit in its AZ's private subnet."
  }
  assert {
    condition     = alltrue([for mt in aws_efs_mount_target.this : mt.security_groups == toset(["sg-0efs000000000000"])])
    error_message = "R9: mount targets must carry exactly sg-efs."
  }
  assert {
    condition     = toset(keys(output.mount_target_ids)) == toset(keys(var.private_subnets_by_az))
    error_message = "mount_target_ids output must be keyed by AZ."
  }
}

run "access_points_share_root_with_distinct_posix_users" {
  command = plan

  assert {
    condition     = aws_efs_access_point.writer.root_directory[0].path == "/shared" && aws_efs_access_point.reader.root_directory[0].path == "/shared"
    error_message = "R2/R3: both access points must be rooted at /shared."
  }
  assert {
    condition     = aws_efs_access_point.writer.root_directory[0].creation_info == aws_efs_access_point.reader.root_directory[0].creation_info
    error_message = "R10: creation_info must be identical on both access points."
  }
  assert {
    condition = (
      aws_efs_access_point.writer.root_directory[0].creation_info[0].owner_uid == 1001 &&
      aws_efs_access_point.writer.root_directory[0].creation_info[0].owner_gid == 1000 &&
      aws_efs_access_point.writer.root_directory[0].creation_info[0].permissions == "0775"
    )
    error_message = "R10: creation_info must be 1001:1000 0775."
  }
  assert {
    condition     = aws_efs_access_point.writer.posix_user[0].uid == 1001 && aws_efs_access_point.writer.posix_user[0].gid == 1000
    error_message = "R10: writer posix_user must be 1001:1000."
  }
  assert {
    condition     = aws_efs_access_point.reader.posix_user[0].uid == 1002 && aws_efs_access_point.reader.posix_user[0].gid == 1000
    error_message = "R10: reader posix_user must be 1002:1000."
  }
}
