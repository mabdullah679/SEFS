# Mother root: the whole graph plans with mocks, and the root defaults meet
# the contract. module.images is overridden so NO docker build/push runs.
#
# Limits (TF 1.9.8, measured): test assertions cannot reference resources
# inside child modules, and root outputs are mostly computed (unknown at
# plan). So per-attribute proof lives in the per-module files; this file
# proves the wiring plans (no cycle, every child input satisfied) and the
# defaults. The apply-mode root wiring run is tests/unit/apply/root_apply.

mock_provider "aws" {
  # Provider ARN validators run on mocked values, so ARN attrs need real shapes.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/sefs-ut-mock"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"backup.amazonaws.com\"}}]}"
    }
  }
}

override_module {
  target = module.images
  outputs = {
    writer_image = "111122223333.dkr.ecr.us-east-1.amazonaws.com/sefs-writer:unit"
    reader_image = "111122223333.dkr.ecr.us-east-1.amazonaws.com/sefs-reader:unit"
    repository_urls = {
      writer = "111122223333.dkr.ecr.us-east-1.amazonaws.com/sefs-writer"
      reader = "111122223333.dkr.ecr.us-east-1.amazonaws.com/sefs-reader"
    }
  }
}

run "root_defaults_meet_contract" {
  command = plan

  assert {
    condition     = var.az_count >= 2
    error_message = "R5: root default az_count must be >= 2."
  }
  assert {
    condition     = var.backup_retention_days >= 35
    error_message = "R14: root default backup_retention_days must be >= 35."
  }
  assert {
    condition     = var.transition_to_ia == "AFTER_30_DAYS"
    error_message = "R15: root default transition_to_ia must be AFTER_30_DAYS."
  }
  assert {
    condition     = var.posix_gid == 1000 && var.writer_uid == 1001 && var.reader_uid == 1002
    error_message = "R10 / CONTRACTS §2: GID 1000, writer UID 1001, reader UID 1002."
  }
  assert {
    condition     = var.shared_root_path == "/shared" && var.container_mount_path == "/mnt/shared"
    error_message = "CONTRACTS §2: AP root /shared, container mount /mnt/shared."
  }
}

run "root_whole_graph_plans" {
  command = plan
  # No asserts on purpose: a passing plan proves every child is wired, every
  # module input type-checks, and there is no dependency cycle (efs <-> apps).
}
