# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "file_system_id" {
  description = "EFS ID."
  value       = aws_efs_file_system.this.id
}

output "file_system_arn" {
  description = "EFS ARN (fed to backup)."
  value       = aws_efs_file_system.this.arn
}

output "writer_access_point_id" {
  description = "Writer access point ID."
  value       = aws_efs_access_point.writer.id
}

output "writer_access_point_arn" {
  description = "Writer access point ARN."
  value       = aws_efs_access_point.writer.arn
}

output "reader_access_point_id" {
  description = "Reader access point ID."
  value       = aws_efs_access_point.reader.id
}

output "reader_access_point_arn" {
  description = "Reader access point ARN."
  value       = aws_efs_access_point.reader.arn
}

output "mount_target_ids" {
  description = "map(AZ => mount target ID)."
  value       = { for az, mt in aws_efs_mount_target.this : az => mt.id }
}

output "file_system_policy_id" {
  description = "ID of aws_efs_file_system_policy; apps services MUST depend on it so no task mounts before the ro policy exists."
  value       = aws_efs_file_system_policy.this.id
}

