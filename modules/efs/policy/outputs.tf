output "json" {
  description = "Rendered file-system policy JSON."
  value       = data.aws_iam_policy_document.fs.json
}
