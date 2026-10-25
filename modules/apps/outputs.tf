# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "cluster_name" {
  description = "ECS cluster name."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "writer_service_name" {
  description = "Writer ECS service name."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "reader_service_name" {
  description = "Reader ECS service name."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "writer_task_definition_arn" {
  description = "Writer task def ARN."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "reader_task_definition_arn" {
  description = "Reader task def ARN."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "writer_task_role_arn" {
  description = "Writer task role ARN (consumed by efs FS policy)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "reader_task_role_arn" {
  description = "Reader task role ARN (consumed by efs FS policy)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "writer_log_group" {
  description = "CloudWatch log group for writer."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "reader_log_group" {
  description = "CloudWatch log group for reader."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

