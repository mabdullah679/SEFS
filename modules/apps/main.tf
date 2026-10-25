# apps (compute): ECS cluster, logs, IAM roles, task definitions, services.
# Contract: docs/CONTRACTS.md §3 "apps (compute)". R-IDs: R2, R3 (roles + mount), R6, R8.

locals {
  writer_name = "${var.name}-writer"
  reader_name = "${var.name}-reader"
  volume_name = "shared"

  ecs_tasks_assume = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  # R2: writer may mount and write, only through the writer access point.
  writer_efs_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "WriterMountWrite"
      Effect    = "Allow"
      Action    = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
      Resource  = var.file_system_arn
      Condition = { StringEquals = { "elasticfilesystem:AccessPointArn" = var.writer_access_point_arn } }
    }]
  })

  # R3: reader may mount only (no ClientWrite), only through the reader access point.
  reader_efs_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ReaderMountOnly"
      Effect    = "Allow"
      Action    = ["elasticfilesystem:ClientMount"]
      Resource  = var.file_system_arn
      Condition = { StringEquals = { "elasticfilesystem:AccessPointArn" = var.reader_access_point_arn } }
    }]
  })
}

# ---------------------------------------------------------------- cluster + logs

resource "aws_ecs_cluster" "this" {
  name = var.name
}

resource "aws_cloudwatch_log_group" "writer" {
  name              = "/ecs/${var.name}/writer"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "reader" {
  name              = "/ecs/${var.name}/reader"
  retention_in_days = 7
}

# ---------------------------------------------------------------- IAM
# The aws_iam_role resources must NOT reference any efs output (CONTRACTS §4):
# efs consumes these role ARNs for its FS policy, so the roles must exist first.

resource "aws_iam_role" "execution" {
  name               = "${var.name}-task-execution"
  assume_role_policy = local.ecs_tasks_assume
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task roles use name_prefix, not a fixed name. The EFS file-system policy
# names these roles by ARN in Principal; AWS stores the role's unique principal
# ID, not the ARN. A fixed name means a replaced role keeps the same ARN, so
# Terraform sees no diff on the FS policy while AWS's stored ID points at the
# deleted role, and the app is locked out of EFS. A prefix gives every
# replacement a new ARN, which forces the FS policy to update in the same apply.
# (IAM User Guide, "AWS JSON policy elements: Principal" > IAM role principals.)
# Prefix max is 38 chars (64 - 26-char unique suffix), enforced on var.name.
# The execution role is not named in any resource policy, so it keeps a fixed name.
resource "aws_iam_role" "writer" {
  name_prefix        = "${local.writer_name}-task-"
  assume_role_policy = local.ecs_tasks_assume
}

resource "aws_iam_role" "reader" {
  name_prefix        = "${local.reader_name}-task-"
  assume_role_policy = local.ecs_tasks_assume
}

resource "aws_iam_role_policy" "writer_efs" {
  name   = "${local.writer_name}-efs"
  role   = aws_iam_role.writer.id
  policy = local.writer_efs_policy
}

resource "aws_iam_role_policy" "reader_efs" {
  name   = "${local.reader_name}-efs"
  role   = aws_iam_role.reader.id
  policy = local.reader_efs_policy
}

# ---------------------------------------------------------------- task definitions

resource "aws_ecs_task_definition" "writer" {
  family                   = local.writer_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.writer.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  volume {
    name = local.volume_name
    efs_volume_configuration {
      file_system_id     = var.file_system_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.writer_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "writer"
    image     = var.writer_image
    essential = true
    environment = [
      { name = "SHARED_DIR", value = var.container_mount_path },
      { name = "WRITER_INTERVAL_SECONDS", value = tostring(var.writer_interval_seconds) },
    ]
    mountPoints = [{
      sourceVolume  = local.volume_name
      containerPath = var.container_mount_path
      readOnly      = false
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.writer.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "writer"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "reader" {
  family                   = local.reader_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.reader.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  volume {
    name = local.volume_name
    efs_volume_configuration {
      file_system_id     = var.file_system_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.reader_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "reader"
    image     = var.reader_image
    essential = true
    environment = [
      { name = "SHARED_DIR", value = var.container_mount_path },
      { name = "READER_POLL_SECONDS", value = tostring(var.reader_poll_seconds) },
    ]
    mountPoints = [{
      sourceVolume  = local.volume_name
      containerPath = var.container_mount_path
      readOnly      = true
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.reader.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "reader"
      }
    }
  }])
}

# ---------------------------------------------------------------- services

# Gate: services must not start before the FS policy and mount targets exist.
# EFS with no FS policy lets any IAM-authorized client write, so a reader that
# mounts before the read-deny policy lands would get write access (R3).
resource "terraform_data" "efs_ready" {
  triggers_replace = var.efs_dependency_ids
}

resource "aws_ecs_service" "writer" {
  name                  = local.writer_name
  cluster               = aws_ecs_cluster.this.id
  task_definition       = aws_ecs_task_definition.writer.arn
  launch_type           = "FARGATE"
  platform_version      = "LATEST"
  desired_count         = 1
  wait_for_steady_state = true

  network_configuration {
    subnets          = var.private_subnet_ids       # R6
    security_groups  = [var.apps_security_group_id] # R8
    assign_public_ip = false                        # R6
  }

  depends_on = [terraform_data.efs_ready, aws_iam_role_policy.writer_efs, aws_iam_role_policy_attachment.execution]
}

resource "aws_ecs_service" "reader" {
  name                  = local.reader_name
  cluster               = aws_ecs_cluster.this.id
  task_definition       = aws_ecs_task_definition.reader.arn
  launch_type           = "FARGATE"
  platform_version      = "LATEST"
  desired_count         = 1
  wait_for_steady_state = true

  network_configuration {
    subnets          = var.private_subnet_ids       # R6
    security_groups  = [var.apps_security_group_id] # R8
    assign_public_ip = false                        # R6
  }

  depends_on = [terraform_data.efs_ready, aws_iam_role_policy.reader_efs, aws_iam_role_policy_attachment.execution]
}
