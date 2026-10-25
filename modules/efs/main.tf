# Shared EFS: file system, mount targets, access points, file-system policy.
# R-IDs: R3 (FS policy), R4, R7, R10, R12, R13, R15. Contract: docs/CONTRACTS.md §3 "efs".

resource "aws_efs_file_system" "this" {
  creation_token = "${var.name}-shared"

  # R12: hard-coded, not variables, so nothing upstream can change them.
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  # R13: null => AWS-managed aws/elasticfilesystem key.
  kms_key_id = var.kms_key_arn

  # R15
  lifecycle_policy {
    transition_to_ia = var.transition_to_ia
  }

  tags = {
    Name = "${var.name}-shared"
  }

  # R4. Must be a literal; teardown is the deliberate two-step in PLAN.md §3.
  # Not assertable by `terraform test`; guarded by tests/check_prevent_destroy.sh.
  lifecycle {
    prevent_destroy = true
  }
}

# EFS automatic backups would create an AWS-owned default vault that Terraform
# does not track. R14 is met by modules/backup instead.
resource "aws_efs_backup_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  backup_policy {
    status = "DISABLED"
  }
}

# R7: one mount target per private-subnet AZ. Keys are AZ names (known at plan).
resource "aws_efs_mount_target" "this" {
  for_each = var.private_subnets_by_az

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [var.efs_security_group_id]
}

# R10: both access points are rooted at the SAME directory with IDENTICAL
# creation_info, so whichever AP touches the path first creates it the same way
# (owner writer_uid:posix_gid, 0775). Only posix_user differs.
locals {
  creation_info = {
    owner_uid   = var.writer_uid
    owner_gid   = var.posix_gid
    permissions = "0775"
  }
}

resource "aws_efs_access_point" "writer" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = var.writer_uid
    gid = var.posix_gid
  }

  root_directory {
    path = var.shared_root_path

    creation_info {
      owner_uid   = local.creation_info.owner_uid
      owner_gid   = local.creation_info.owner_gid
      permissions = local.creation_info.permissions
    }
  }

  tags = {
    Name = "${var.name}-writer"
  }
}

resource "aws_efs_access_point" "reader" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = var.reader_uid
    gid = var.posix_gid
  }

  root_directory {
    path = var.shared_root_path

    creation_info {
      owner_uid   = local.creation_info.owner_uid
      owner_gid   = local.creation_info.owner_gid
      permissions = local.creation_info.permissions
    }
  }

  tags = {
    Name = "${var.name}-reader"
  }
}

# The policy document lives in ./policy (data source only, no resources) so it
# can be rendered and asserted in isolation: this module's prevent_destroy makes
# apply-mode `terraform test` teardown impossible here, and in plan mode the AP
# ARNs it embeds are unknown.
module "fs_policy" {
  source = "./policy"

  file_system_arn         = aws_efs_file_system.this.arn
  writer_access_point_arn = aws_efs_access_point.writer.arn
  reader_access_point_arn = aws_efs_access_point.reader.arn
  writer_role_arn         = var.writer_role_arn
  reader_role_arn         = var.reader_role_arn
}

# SPEC DRIFT compensating control (PLAN.md §2.1): EFS access points have NO
# read-only switch; they only force UID/GID and root path. A ro ECS mount flag
# alone is a control the container could bypass. Reader read-only is enforced
# HERE, by IAM authorization on the NFS mount (needs transit encryption + iam
# ENABLED on the task volume, owned by modules/apps).
#
# bypass_policy_lockout_safety_check is left at the provider default (false):
# no statement denies the caller PutFileSystemPolicy over TLS, so the AWS
# lockout check has nothing to block.
resource "aws_efs_file_system_policy" "this" {
  file_system_id = aws_efs_file_system.this.id
  policy         = module.fs_policy.json

  bypass_policy_lockout_safety_check = false
}
