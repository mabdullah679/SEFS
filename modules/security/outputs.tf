# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "apps_security_group_id" {
  description = "sg-apps: attached to BOTH app services (R8)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "efs_security_group_id" {
  description = "sg-efs: ingress 2049 ONLY from sg-apps (R9)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

