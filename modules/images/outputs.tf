# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "writer_image" {
  description = "Full writer image ref (repo@sha256:digest or repo:contenthash), pushed BEFORE this output is known."
  # terraform_data.build.output is unknown until the build+push provisioner has finished.
  value = "${aws_ecr_repository.this["writer"].repository_url}:${terraform_data.build["writer"].output}"
}

output "reader_image" {
  description = "Full reader image ref, same rule."
  value       = "${aws_ecr_repository.this["reader"].repository_url}:${terraform_data.build["reader"].output}"
}

output "repository_urls" {
  description = "map(writer|reader => ECR repo URL)."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
