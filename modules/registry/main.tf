# registry: publishes the deployed IDs to SSM Parameter Store so the Bruno collection can
# hydrate itself. Everything here is NON-secret and Terraform-managed. Secrets are never
# created by Terraform (their values would land in state); they live under /<name>/secrets/
# and are written only by setup.sh.

resource "aws_ssm_parameter" "output" {
  for_each = var.values

  name        = "/${var.name}/outputs/${each.key}"
  description = "Deployed value published by Terraform for the Bruno collection (non-secret)."
  type        = "String"
  value       = each.value
}
