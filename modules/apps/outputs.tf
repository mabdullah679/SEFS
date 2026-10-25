# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "writer_service_name" {
  description = "Writer ECS service name."
  value       = aws_ecs_service.writer.name
}

output "reader_service_name" {
  description = "Reader ECS service name."
  value       = aws_ecs_service.reader.name
}

output "writer_task_definition_arn" {
  description = "Writer task def ARN."
  value       = aws_ecs_task_definition.writer.arn
}

output "reader_task_definition_arn" {
  description = "Reader task def ARN."
  value       = aws_ecs_task_definition.reader.arn
}

output "writer_task_role_arn" {
  description = "Writer task role ARN (consumed by efs FS policy)."
  value       = aws_iam_role.writer.arn
}

output "reader_task_role_arn" {
  description = "Reader task role ARN (consumed by efs FS policy)."
  value       = aws_iam_role.reader.arn
}

output "writer_log_group" {
  description = "CloudWatch log group for writer."
  value       = aws_cloudwatch_log_group.writer.name
}

output "reader_log_group" {
  description = "CloudWatch log group for reader."
  value       = aws_cloudwatch_log_group.reader.name
}

