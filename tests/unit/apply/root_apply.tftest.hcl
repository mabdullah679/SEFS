# Mother root, apply mode with mocks (temp copy only; see efs_wiring.tftest.hcl
# header for why). Proves every root output is really wired (no `value = null`
# placeholder survived the merge) and the cross-child wiring that root
# outputs can show. module.images is overridden: no docker.

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

run "root_outputs_all_wired" {
  command = apply

  assert {
    condition = alltrue([for v in [
      output.vpc_id, output.apps_security_group_id, output.efs_security_group_id,
      output.file_system_id, output.writer_access_point_id, output.reader_access_point_id,
      output.backup_vault_name, output.backup_plan_id, output.cluster_name,
      output.writer_service_name, output.reader_service_name,
      output.writer_log_group, output.reader_log_group, output.reader_task_definition_arn,
    ] : v != null && v != ""])
    error_message = "Every root output must be wired to a real value (a null placeholder survived)."
  }
  assert {
    condition     = length(output.private_subnet_ids) == var.az_count
    error_message = "R5/R6: one private subnet per AZ reaches the root."
  }
  assert {
    condition     = output.writer_access_point_id != output.reader_access_point_id
    error_message = "R10: writer and reader must use different access points."
  }
  assert {
    condition     = output.apps_security_group_id != output.efs_security_group_id
    error_message = "R8/R9: sg-apps and sg-efs must be different groups."
  }
  assert {
    condition     = output.writer_log_group == "/ecs/${var.name}/writer" && output.reader_log_group == "/ecs/${var.name}/reader"
    error_message = "CONTRACTS: log groups /ecs/<name>/writer and /ecs/<name>/reader (e2e.sh reads them)."
  }
}
