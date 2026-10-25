# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

variable "name" {
  description = "Name prefix."
  type        = string
}

variable "resource_arns" {
  description = "ARNs to back up (the EFS)."
  type        = list(string)
}

variable "retention_days" {
  description = "Retention; MUST validate >= 35 (R14)."
  type        = number

  validation {
    condition     = var.retention_days >= 35
    error_message = "retention_days must be at least 35 (R14)."
  }
}

variable "kms_key_arn" {
  description = "CMK for vault or null."
  type        = string
  default     = null
}

