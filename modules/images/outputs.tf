# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "writer_image" {
  description = "Full writer image ref (repo@sha256:digest or repo:contenthash), pushed BEFORE this output is known."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "reader_image" {
  description = "Full reader image ref, same rule."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "repository_urls" {
  description = "map(writer|reader => ECR repo URL)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

