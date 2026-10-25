# EFS file-system policy document (R2, R3). Data source only: no resources, so
# it renders locally (no AWS API call) and can be tested in isolation.
# Consumed by ../main.tf -> aws_efs_file_system_policy.this.
#
# SPEC DRIFT compensating control: EFS access points have no read-only switch,
# so the reader's read-only access is enforced by statements 3 + 4 below.

data "aws_iam_policy_document" "fs" {
  # 1. No plaintext NFS for anyone. Deny-only; grants nothing to "*".
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["*"]
    resources = [var.file_system_arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # 2. Writer (R2): mount + write, only through the writer access point.
  statement {
    sid       = "AllowWriterMountWriteViaWriterAP"
    effect    = "Allow"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [var.file_system_arn]

    principals {
      type        = "AWS"
      identifiers = [var.writer_role_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [var.writer_access_point_arn]
    }
  }

  # 3. Reader (R3): mount only (ClientMount = read-only), only through the reader AP.
  statement {
    sid       = "AllowReaderMountViaReaderAP"
    effect    = "Allow"
    actions   = ["elasticfilesystem:ClientMount"]
    resources = [var.file_system_arn]

    principals {
      type        = "AWS"
      identifiers = [var.reader_role_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [var.reader_access_point_arn]
    }
  }

  # 4. Explicit, UNCONDITIONAL deny of write/root for the reader. EFS allows an
  # action if EITHER the identity policy OR this policy allows it, so without
  # this a later ClientWrite grant on the reader role would re-open write.
  # An explicit Deny in any policy overrides every Allow.
  statement {
    sid       = "DenyReaderWriteAndRoot"
    effect    = "Deny"
    actions   = ["elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"]
    resources = [var.file_system_arn]

    principals {
      type        = "AWS"
      identifiers = [var.reader_role_arn]
    }
  }
}
