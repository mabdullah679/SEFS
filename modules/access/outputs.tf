output "role_arn" {
  description = "ARN of the Bruno read-only role (the collection assumes this)."
  value       = aws_iam_role.bruno_reader.arn
}

output "role_name" {
  description = "Name of the Bruno read-only role."
  value       = aws_iam_role.bruno_reader.name
}

output "ssm_prefix" {
  description = "SSM path prefix: /<name>/outputs/* is Terraform-managed, /<name>/secrets/* is written only by setup.sh."
  value       = "/${var.name}"
}
