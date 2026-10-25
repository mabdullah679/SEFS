# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "vpc_id" {
  description = "VPC ID."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "azs" {
  description = "List of AZ names used, ordered."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered like azs."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered like azs (R6)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "private_subnets_by_az" {
  description = "map(AZ name => private subnet ID); keys known at plan time (drives R7 for_each)."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs."
  value       = null # OWNER: replace with real value; name is contract-fixed
}

