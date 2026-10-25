# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "azs" {
  description = "List of AZ names used, ordered."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered like azs."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered like azs (R6)."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "private_subnets_by_az" {
  description = "map(AZ name => private subnet ID); keys known at plan time (drives R7 for_each)."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs."
  value       = [for k in local.nat_keys : aws_nat_gateway.this[k].id]
}

