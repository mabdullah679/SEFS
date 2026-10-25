# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "file_system_id" {
  description = "EFS ID."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "file_system_arn" {
  description = "EFS ARN (fed to backup)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "writer_access_point_id" {
  description = "Writer access point ID."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "writer_access_point_arn" {
  description = "Writer access point ARN."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "reader_access_point_id" {
  description = "Reader access point ID."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "reader_access_point_arn" {
  description = "Reader access point ARN."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "mount_target_ids" {
  description = "map(AZ => mount target ID)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "file_system_policy_id" {
  description = "ID of aws_efs_file_system_policy; apps services MUST depend on it so no task mounts before the ro policy exists."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

