# Mock-provider tests for modules/apps. No AWS calls.
# Run: cd modules/apps && terraform init -backend=false && terraform test
# R-IDs: R2, R3, R6, R8.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111122223333:cluster/mock", id = "arn:aws:ecs:us-east-1:111122223333:cluster/mock" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111122223333:task-definition/mock:1" }
  }
}

# Distinct ARNs so "each task def uses its own role" is not vacuously true.
override_resource {
  target = aws_iam_role.writer
  values = { arn = "arn:aws:iam::111122223333:role/sefs-test-writer-task" }
}
override_resource {
  target = aws_iam_role.reader
  values = { arn = "arn:aws:iam::111122223333:role/sefs-test-reader-task" }
}

variables {
  name                    = "sefs-test"
  region                  = "us-east-1"
  private_subnet_ids      = ["subnet-priv-a", "subnet-priv-b"]
  apps_security_group_id  = "sg-apps123"
  file_system_id          = "fs-12345678"
  file_system_arn         = "arn:aws:elasticfilesystem:us-east-1:111122223333:file-system/fs-12345678"
  writer_access_point_id  = "fsap-writer"
  writer_access_point_arn = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-writer"
  reader_access_point_id  = "fsap-reader"
  reader_access_point_arn = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-reader"
  efs_dependency_ids      = ["fs-policy-id", "fsmt-a", "fsmt-b"]
  writer_image            = "111122223333.dkr.ecr.us-east-1.amazonaws.com/sefs-writer:abc"
  reader_image            = "111122223333.dkr.ecr.us-east-1.amazonaws.com/sefs-reader:def"
  container_mount_path    = "/mnt/shared"
  writer_interval_seconds = 10
  reader_poll_seconds     = 5
}

run "services_private_same_sg_no_public_ip" {
  command = apply

  # R8: one SG, on both services.
  assert {
    condition     = one(aws_ecs_service.writer.network_configuration).security_groups == toset(["sg-apps123"])
    error_message = "writer service must use exactly sg-apps"
  }
  assert {
    condition     = one(aws_ecs_service.reader.network_configuration).security_groups == one(aws_ecs_service.writer.network_configuration).security_groups
    error_message = "reader and writer must share the same SG"
  }

  # R6: private subnets, no public IP.
  assert {
    condition     = one(aws_ecs_service.writer.network_configuration).subnets == toset(var.private_subnet_ids)
    error_message = "writer must run in the private subnets"
  }
  assert {
    condition     = one(aws_ecs_service.reader.network_configuration).subnets == toset(var.private_subnet_ids)
    error_message = "reader must run in the private subnets"
  }
  assert {
    condition     = one(aws_ecs_service.writer.network_configuration).assign_public_ip == false && one(aws_ecs_service.reader.network_configuration).assign_public_ip == false
    error_message = "no service may get a public IP"
  }

  assert {
    condition     = aws_ecs_service.writer.launch_type == "FARGATE" && aws_ecs_service.reader.launch_type == "FARGATE"
    error_message = "both services must be FARGATE"
  }
  assert {
    condition     = aws_ecs_service.writer.wait_for_steady_state && aws_ecs_service.reader.wait_for_steady_state
    error_message = "both services must wait for steady state"
  }
  assert {
    condition     = aws_ecs_service.writer.desired_count == 1 && aws_ecs_service.reader.desired_count == 1
    error_message = "desired_count must be 1"
  }

  # Gate resource carries the efs dependency ids.
  assert {
    condition     = terraform_data.efs_ready.triggers_replace == var.efs_dependency_ids
    error_message = "efs_ready gate must track efs_dependency_ids"
  }
}

run "mounts_ro_rw" {
  command = apply

  # R3: reader mount is read-only.
  assert {
    condition     = jsondecode(aws_ecs_task_definition.reader.container_definitions)[0].mountPoints[0].readOnly == true
    error_message = "reader mount must be readOnly=true"
  }
  # R2: writer mount is read-write.
  assert {
    condition     = jsondecode(aws_ecs_task_definition.writer.container_definitions)[0].mountPoints[0].readOnly == false
    error_message = "writer mount must be readOnly=false"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.reader.container_definitions)[0].mountPoints[0].containerPath == "/mnt/shared" && jsondecode(aws_ecs_task_definition.writer.container_definitions)[0].mountPoints[0].containerPath == "/mnt/shared"
    error_message = "both containers mount at container_mount_path"
  }
  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.reader.container_definitions)[0].mountPoints) == 1 && length(jsondecode(aws_ecs_task_definition.writer.container_definitions)[0].mountPoints) == 1
    error_message = "exactly one mount point per container"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.reader.container_definitions)[0].logConfiguration.logDriver == "awslogs" && jsondecode(aws_ecs_task_definition.writer.container_definitions)[0].logConfiguration.logDriver == "awslogs"
    error_message = "both containers must use awslogs"
  }
  assert {
    condition     = contains(jsondecode(aws_ecs_task_definition.writer.container_definitions)[0].environment, { name = "SHARED_DIR", value = "/mnt/shared" }) && contains(jsondecode(aws_ecs_task_definition.reader.container_definitions)[0].environment, { name = "READER_POLL_SECONDS", value = "5" })
    error_message = "env SHARED_DIR / READER_POLL_SECONDS must be set"
  }
}

run "volumes_encrypted_iam_correct_ap" {
  command = apply

  assert {
    condition     = one(aws_ecs_task_definition.writer.volume).efs_volume_configuration[0].transit_encryption == "ENABLED" && one(aws_ecs_task_definition.reader.volume).efs_volume_configuration[0].transit_encryption == "ENABLED"
    error_message = "both EFS volumes must use transit encryption"
  }
  assert {
    condition     = one(aws_ecs_task_definition.writer.volume).efs_volume_configuration[0].authorization_config[0].iam == "ENABLED" && one(aws_ecs_task_definition.reader.volume).efs_volume_configuration[0].authorization_config[0].iam == "ENABLED"
    error_message = "both EFS volumes must use IAM authorization"
  }
  assert {
    condition     = one(aws_ecs_task_definition.writer.volume).efs_volume_configuration[0].authorization_config[0].access_point_id == "fsap-writer"
    error_message = "writer volume must use the writer access point"
  }
  assert {
    condition     = one(aws_ecs_task_definition.reader.volume).efs_volume_configuration[0].authorization_config[0].access_point_id == "fsap-reader"
    error_message = "reader volume must use the reader access point"
  }
  assert {
    condition     = one(aws_ecs_task_definition.writer.volume).efs_volume_configuration[0].file_system_id == "fs-12345678" && one(aws_ecs_task_definition.reader.volume).efs_volume_configuration[0].file_system_id == "fs-12345678"
    error_message = "both volumes must be on the same file system"
  }
}

run "iam_and_platform" {
  command = apply

  # R3: no reader statement grants ClientWrite (or a wildcard).
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.reader_efs.policy).Statement :
      !contains(flatten([s.Action]), "elasticfilesystem:ClientWrite") && !contains(flatten([s.Action]), "elasticfilesystem:*") && !contains(flatten([s.Action]), "*")
    ])
    error_message = "reader task role policy must not grant ClientWrite"
  }
  assert {
    condition     = flatten([for s in jsondecode(aws_iam_role_policy.reader_efs.policy).Statement : s.Action]) == ["elasticfilesystem:ClientMount"]
    error_message = "reader policy must grant ClientMount only"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.reader_efs.policy).Statement[0].Condition.StringEquals["elasticfilesystem:AccessPointArn"] == var.reader_access_point_arn
    error_message = "reader policy must be conditioned on the reader AP ARN"
  }
  # R2: writer gets mount + write via writer AP.
  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_role_policy.writer_efs.policy).Statement : s.Action])) == toset(["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"])
    error_message = "writer policy must grant ClientMount + ClientWrite"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.writer_efs.policy).Statement[0].Condition.StringEquals["elasticfilesystem:AccessPointArn"] == var.writer_access_point_arn
    error_message = "writer policy must be conditioned on the writer AP ARN"
  }
  assert {
    condition     = aws_ecs_task_definition.writer.task_role_arn == "arn:aws:iam::111122223333:role/sefs-test-writer-task" && aws_ecs_task_definition.reader.task_role_arn == "arn:aws:iam::111122223333:role/sefs-test-reader-task" && output.reader_task_role_arn == aws_iam_role.reader.arn && output.writer_task_role_arn == aws_iam_role.writer.arn
    error_message = "task defs must use their own task roles"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.execution.policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    error_message = "execution role must have AmazonECSTaskExecutionRolePolicy"
  }

  # ARM64 + sizing.
  assert {
    condition     = one(aws_ecs_task_definition.writer.runtime_platform).cpu_architecture == "ARM64" && one(aws_ecs_task_definition.reader.runtime_platform).cpu_architecture == "ARM64"
    error_message = "both task defs must be ARM64"
  }
  assert {
    condition     = aws_ecs_task_definition.writer.cpu == "256" && aws_ecs_task_definition.writer.memory == "512" && aws_ecs_task_definition.reader.cpu == "512" && aws_ecs_task_definition.reader.memory == "1024"
    error_message = "task sizing must be writer 256/512, reader 512/1024"
  }
  assert {
    condition     = aws_cloudwatch_log_group.writer.retention_in_days == 7 && aws_cloudwatch_log_group.reader.retention_in_days == 7
    error_message = "log retention must be 7 days"
  }
  assert {
    condition     = output.cluster_name == "sefs-test" && output.writer_log_group == "/ecs/sefs-test/writer" && output.reader_log_group == "/ecs/sefs-test/reader"
    error_message = "outputs must be wired"
  }
}

# Task roles must be name_prefix'd so a replacement gets a new ARN and the EFS
# FS policy (which AWS pins to the role's unique ID) is forced to update.
# If `name` were fixed instead, name_prefix would be provider-computed (a mock
# random string here) and these asserts go red.
run "task_roles_use_name_prefix" {
  command = apply

  assert {
    condition     = aws_iam_role.writer.name_prefix == "sefs-test-writer-task-"
    error_message = "writer task role must use name_prefix, not a fixed name"
  }
  assert {
    condition     = aws_iam_role.reader.name_prefix == "sefs-test-reader-task-"
    error_message = "reader task role must use name_prefix, not a fixed name"
  }
  assert {
    condition     = length(aws_iam_role.writer.name_prefix) <= 38 && length(aws_iam_role.reader.name_prefix) <= 38
    error_message = "IAM role name_prefix max is 38 characters"
  }
}

# var.name longer than 25 would push the prefix past 38 chars: rejected.
run "name_too_long_rejected" {
  command = plan
  variables {
    name = "abcdefghijklmnopqrstuvwxyz"
  }
  expect_failures = [var.name]
}
