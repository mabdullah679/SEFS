output "state_bucket" {
  description = "Terraform state bucket name."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  description = "DynamoDB lock table name."
  value       = aws_dynamodb_table.lock.name
}

output "github_deploy_role_arn" {
  description = "ARN of the GitHub Actions deploy role (null when github_repo is unset)."
  value       = var.github_repo == null ? null : aws_iam_role.github_deploy[0].arn
}

output "backend_hcl" {
  description = "Partial backend config for the mother: write to backend.hcl and `terraform init -backend-config=backend.hcl`."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.bucket}"
    key            = "${var.name}/terraform.tfstate"
    region         = "${var.region}"
    dynamodb_table = "${aws_dynamodb_table.lock.name}"
    encrypt        = true
  EOT
}
