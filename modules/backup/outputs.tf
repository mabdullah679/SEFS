# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "vault_name" {
  description = "Backup vault name."
  value       = aws_backup_vault.this.name
}

output "vault_arn" {
  description = "Backup vault ARN."
  value       = aws_backup_vault.this.arn
}

output "plan_id" {
  description = "Backup plan ID."
  value       = aws_backup_plan.this.id
}

output "selection_id" {
  description = "Backup selection ID."
  value       = aws_backup_selection.this.id
}

output "role_arn" {
  description = "IAM role AWS Backup assumes."
  value       = aws_iam_role.backup.arn
}

