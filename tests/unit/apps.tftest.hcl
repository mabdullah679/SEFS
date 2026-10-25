# R2, R3 (task-role + mount side), R6 (service side), R8. Mock provider only.
#
# ADDRESS ASSUMPTIONS (fix after merge if renamed):
#   aws_ecs_task_definition.writer / .reader,
#   aws_ecs_service.writer / .reader,
#   aws_iam_role.writer / .reader,
#   aws_iam_role_policy.writer_efs / .reader_efs,
#   terraform_data.efs_ready
# Container JSON is read with jsondecode(container_definitions)[0].

mock_provider "aws" {
  # Provider ARN validators run on mocked values, so ARN attrs need real shapes.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/sefs-ut-mock"
    }
  }
}

# Distinct role ARNs so "reader and writer use different roles" is meaningful.
override_resource {
  target = aws_iam_role.writer
  values = {
    arn = "arn:aws:iam::111122223333:role/sefs-ut-writer-task"
    id  = "sefs-ut-writer-task"
  }
}

override_resource {
  target = aws_iam_role.reader
  values = {
    arn = "arn:aws:iam::111122223333:role/sefs-ut-reader-task"
    id  = "sefs-ut-reader-task"
  }
}

variables {
  name                    = "sefs-ut"
  region                  = "us-east-1"
  private_subnet_ids      = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  apps_security_group_id  = "sg-0aaaaaaaaaaaaaaa1"
  file_system_id          = "fs-0123456789abcdef0"
  file_system_arn         = "arn:aws:elasticfilesystem:us-east-1:111122223333:file-system/fs-0123456789abcdef0"
  writer_access_point_id  = "fsap-0aaaaaaaaaaaaaaa1"
  writer_access_point_arn = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-0aaaaaaaaaaaaaaa1"
  reader_access_point_id  = "fsap-0bbbbbbbbbbbbbbb2"
  reader_access_point_arn = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-0bbbbbbbbbbbbbbb2"
  efs_dependency_ids      = ["fs-0123456789abcdef0", "fsmt-0aaaaaaaaaaaaaaa1", "fsmt-0bbbbbbbbbbbbbbb2"]
  writer_image            = "111122223333.dkr.ecr.us-east-1.amazonaws.com/sefs-ut-writer:abc123"
  reader_image            = "111122223333.dkr.ecr.us-east-1.amazonaws.com/sefs-ut-reader:abc123"
  container_mount_path    = "/mnt/shared"
  writer_interval_seconds = 10
  reader_poll_seconds     = 10
}

run "r02_writer_rw_config" {
  command = apply
  module {
    source = "./modules/apps"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.writer.container_definitions)[0].mountPoints[0].readOnly == false
    error_message = "R2: writer mount must be readOnly = false."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.writer.container_definitions)[0].mountPoints[0].containerPath == "/mnt/shared"
    error_message = "R2: writer must mount the share at /mnt/shared."
  }
  assert {
    condition = alltrue([for v in aws_ecs_task_definition.writer.volume : alltrue([for e in v.efs_volume_configuration :
      e.file_system_id == var.file_system_id &&
      e.transit_encryption == "ENABLED" &&
      e.authorization_config[0].iam == "ENABLED" &&
      e.authorization_config[0].access_point_id == var.writer_access_point_id
    ])]) && length(aws_ecs_task_definition.writer.volume) == 1
    error_message = "R2: writer volume must use the writer AP with transit encryption + IAM auth ON."
  }
  assert {
    condition     = aws_ecs_task_definition.writer.task_role_arn == aws_iam_role.writer.arn
    error_message = "R2: writer task def must run with the writer task role."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.writer_efs.policy).Statement :
      s.Effect == "Allow" &&
      contains(flatten([s.Action]), "elasticfilesystem:ClientMount") &&
      contains(flatten([s.Action]), "elasticfilesystem:ClientWrite") &&
      try(s.Condition.StringEquals["elasticfilesystem:AccessPointArn"], null) == var.writer_access_point_arn
    ])
    error_message = "R2: writer role must allow ClientMount + ClientWrite scoped to the writer AP."
  }
  assert {
    condition     = aws_iam_role_policy.writer_efs.role == aws_iam_role.writer.id
    error_message = "R2: the EFS policy must be attached to the writer role."
  }
}

run "r03_reader_ro_config" {
  command = apply
  module {
    source = "./modules/apps"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.reader.container_definitions)[0].mountPoints[0].readOnly == true
    error_message = "R3: reader mount must be readOnly = true."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.reader.container_definitions)[0].mountPoints[0].containerPath == "/mnt/shared"
    error_message = "R3: reader must mount the SAME share path /mnt/shared."
  }
  assert {
    condition = alltrue([for v in aws_ecs_task_definition.reader.volume : alltrue([for e in v.efs_volume_configuration :
      e.file_system_id == var.file_system_id &&
      e.transit_encryption == "ENABLED" &&
      e.authorization_config[0].iam == "ENABLED" &&
      e.authorization_config[0].access_point_id == var.reader_access_point_id
    ])]) && length(aws_ecs_task_definition.reader.volume) == 1
    error_message = "R3: reader volume must use the reader AP with transit encryption + IAM auth ON (IAM auth is what makes the FS-policy Deny bite)."
  }
  assert {
    condition     = aws_ecs_task_definition.reader.task_role_arn == aws_iam_role.reader.arn
    error_message = "R3: reader task def must run with the reader task role."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.reader_efs.policy).Statement :
      s.Effect != "Allow" || !anytrue([for a in flatten([s.Action]) : contains(["elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess", "elasticfilesystem:*", "*"], a)])
    ])
    error_message = "R3: reader role must NOT be allowed ClientWrite / ClientRootAccess / wildcards."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.reader_efs.policy).Statement :
      s.Effect == "Allow" && contains(flatten([s.Action]), "elasticfilesystem:ClientMount") &&
      try(s.Condition.StringEquals["elasticfilesystem:AccessPointArn"], null) == var.reader_access_point_arn
    ])
    error_message = "R3: reader role must allow ClientMount scoped to the reader AP."
  }
  assert {
    condition     = aws_iam_role_policy.reader_efs.role == aws_iam_role.reader.id
    error_message = "R3: the EFS policy must be attached to the reader role."
  }
  assert {
    condition     = aws_iam_role.reader.arn != aws_iam_role.writer.arn
    error_message = "R3: reader and writer must have distinct task roles."
  }
}

run "r06_services_private_no_public_ip" {
  command = apply
  module {
    source = "./modules/apps"
  }

  assert {
    condition = alltrue([for svc in [aws_ecs_service.writer, aws_ecs_service.reader] :
      toset(svc.network_configuration[0].subnets) == toset(var.private_subnet_ids) &&
      svc.network_configuration[0].assign_public_ip == false
    ])
    error_message = "R6: both services must run only in the private subnets with assign_public_ip = false."
  }
  assert {
    condition     = aws_ecs_service.writer.launch_type == "FARGATE" && aws_ecs_service.reader.launch_type == "FARGATE"
    error_message = "Q1 decision: both services run on Fargate."
  }
  assert {
    condition = alltrue([for td in [aws_ecs_task_definition.writer, aws_ecs_task_definition.reader] :
      td.runtime_platform[0].cpu_architecture == "ARM64" && td.runtime_platform[0].operating_system_family == "LINUX"
    ])
    error_message = "CONTRACTS: task defs must be LINUX/ARM64 to match the linux/arm64 images."
  }
}

run "r08_both_services_use_sg_apps" {
  command = apply
  module {
    source = "./modules/apps"
  }

  assert {
    condition = alltrue([for svc in [aws_ecs_service.writer, aws_ecs_service.reader] :
      toset(svc.network_configuration[0].security_groups) == toset([var.apps_security_group_id])
    ])
    error_message = "R8: both services must carry sg-apps and only sg-apps."
  }
  assert {
    condition     = terraform_data.efs_ready.triggers_replace == var.efs_dependency_ids
    error_message = "R3 ordering: services' gate must be tied to the EFS policy + mount target ids."
  }
}
