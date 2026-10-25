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

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be >= 2 (R5: multi-AZ)."
  }

  validation {
    condition     = var.az_count <= 8 && floor(var.az_count) == var.az_count
    error_message = "az_count must be a whole number <= 8 (subnet CIDR layout reserves 8 public + 8 private /20 slots of a /16)."
  }
}

variable "nat_per_az" {
  description = "NAT per AZ (true) or single NAT (false)."
  type        = bool
}

