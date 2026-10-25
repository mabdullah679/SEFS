# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

variable "name" {
  description = "Name prefix."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
}

variable "az_count" {
  description = "AZ count; MUST validate >= 2 (R5)."
  type        = number
}

variable "nat_per_az" {
  description = "NAT per AZ (true) or single NAT (false)."
  type        = bool
}

