variable "name" {
  description = "Name prefix; also the SSM path prefix (/<name>/...) and the project tag value the role is scoped to."
  type        = string

  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 25
    error_message = "name must be 1-25 characters."
  }
}

variable "region" {
  description = "Region the ARNs in the role policy are scoped to."
  type        = string
}

variable "trusted_principal_arns" {
  description = "IAM principals allowed to assume the Bruno read-only role. Empty = any principal in this account that ALSO holds sts:AssumeRole permission (the account-root trust pattern)."
  type        = list(string)
  default     = []
}
