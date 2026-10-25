# R7, R10, R12, R13, R15 + EFS backup policy DISABLED. Mock provider only.
#
# Why command = plan here: aws_efs_file_system has lifecycle.prevent_destroy,
# so an apply-mode run cannot be torn down by `terraform test` (verified on
# TF 1.9.8: teardown errors "Instance cannot be destroyed"). Every value
# asserted below is config-known at plan time. The file-system POLICY needs
# computed ARNs, so it lives in tests/unit/policy/ and is run by
# tests/unit/run.sh against a temp copy with prevent_destroy stripped.
# prevent_destroy itself (R4) is a static check in tests/unit/run.sh.
#
# ADDRESS ASSUMPTIONS (fix after merge if renamed):
#   aws_efs_file_system.this, aws_efs_mount_target.this (for_each by AZ),
#   aws_efs_access_point.writer / .reader, aws_efs_backup_policy.this

mock_provider "aws" {}

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

run "r12_encrypted_generalpurpose_bursting" {
  command = plan
  module {
    source = "./modules/efs"
  }

  assert {
    condition     = aws_efs_file_system.this.encrypted == true
    error_message = "R12: EFS must be encrypted = true."
  }
  assert {
    condition     = aws_efs_file_system.this.performance_mode == "generalPurpose"
    error_message = "R12: EFS performance_mode must be generalPurpose."
  }
  assert {
    condition     = aws_efs_file_system.this.throughput_mode == "bursting"
    error_message = "R12: EFS throughput_mode must be bursting."
  }
}

# R13 null -> AWS-managed key: kms_key_id is optional+computed, so it is
# UNKNOWN at plan when unset and cannot be asserted null here. Covered live
# (verify.sh R13 resolves KmsKeyId against alias/aws/elasticfilesystem).
# r13_cmk_passed_through lives in apply/efs_wiring.tftest.hcl: if the CMK
# wiring is broken, kms_key_id becomes computed and is UNKNOWN at plan, so a
# plan-mode assert errors ("Unknown condition value") instead of failing.
# The mutation harness only counts assertion failures, so it must be apply.

run "r15_ia_after_30_days" {
  command = plan
  module {
    source = "./modules/efs"
  }

  assert {
    condition     = contains([for p in aws_efs_file_system.this.lifecycle_policy : p.transition_to_ia if p.transition_to_ia != null], "AFTER_30_DAYS")
    error_message = "R15: lifecycle_policy.transition_to_ia must be AFTER_30_DAYS."
  }
}

run "r15_rejects_invalid_transition" {
  command = plan
  module {
    source = "./modules/efs"
  }
  variables {
    transition_to_ia = "AFTER_31_DAYS"
  }
  expect_failures = [var.transition_to_ia]
}

run "r07_mount_target_per_private_az" {
  command = plan
  module {
    source = "./modules/efs"
  }

  assert {
    condition     = toset(keys(aws_efs_mount_target.this)) == toset(keys(var.private_subnets_by_az))
    error_message = "R7: exactly one mount target per private-subnet AZ."
  }
  assert {
    condition     = alltrue([for az, mt in aws_efs_mount_target.this : mt.subnet_id == var.private_subnets_by_az[az]])
    error_message = "R7: each mount target must be in that AZ's private subnet."
  }
  assert {
    condition     = alltrue([for mt in values(aws_efs_mount_target.this) : toset(mt.security_groups) == toset([var.efs_security_group_id])])
    error_message = "R7/R9: mount targets must carry sg-efs and only sg-efs."
  }
}

run "r10_access_points_posix_and_same_root" {
  command = plan
  module {
    source = "./modules/efs"
  }

  assert {
    condition     = aws_efs_access_point.writer.posix_user[0].uid == 1001 && aws_efs_access_point.writer.posix_user[0].gid == 1000
    error_message = "R10: writer access point must force UID 1001 / GID 1000."
  }
  assert {
    condition     = aws_efs_access_point.reader.posix_user[0].uid == 1002 && aws_efs_access_point.reader.posix_user[0].gid == 1000
    error_message = "R10: reader access point must force UID 1002 / GID 1000."
  }
  assert {
    condition     = aws_efs_access_point.writer.root_directory[0].path == "/shared" && aws_efs_access_point.reader.root_directory[0].path == "/shared"
    error_message = "R2/R3: both access points must be rooted at the SAME path /shared."
  }
  assert {
    condition = alltrue([for ap in [aws_efs_access_point.writer, aws_efs_access_point.reader] :
      ap.root_directory[0].creation_info[0].owner_uid == 1001 &&
      ap.root_directory[0].creation_info[0].owner_gid == 1000 &&
      ap.root_directory[0].creation_info[0].permissions == "0775"
    ])
    error_message = "R10: both access points need identical creation_info 1001:1000 perms 0775."
  }
}

run "efs_automatic_backups_disabled" {
  command = plan
  module {
    source = "./modules/efs"
  }

  assert {
    condition     = aws_efs_backup_policy.this.backup_policy[0].status == "DISABLED"
    error_message = "CONTRACTS: aws_efs_backup_policy must be DISABLED (R14 is met by modules/backup; no untracked default vault)."
  }
}
