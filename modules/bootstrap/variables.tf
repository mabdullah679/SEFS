variable "name" {
  description = "Project name prefix (bucket: <name>-tfstate-<account>-<region>, table: <name>-tfstate-lock, role: <name>-github-deploy)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,24}$", var.name))
    error_message = "name must be 1-25 chars, lowercase letters, digits, hyphens (it becomes part of an S3 bucket name)."
  }
}

variable "region" {
  description = "Region (part of the bucket name, so one bucket per region)."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for the bucket and table; null = AWS-managed (SSE-S3 / AWS-owned DynamoDB key)."
  type        = string
  default     = null
}

variable "allow_state_destroy" {
  description = "Must be true for `terraform destroy` to remove a non-empty, versioned state bucket. Keep false except for a deliberate full teardown."
  type        = bool
  default     = false
}

variable "github_repo" {
  description = "owner/repo allowed to deploy via GitHub Actions OIDC. null = no CI role is created."
  type        = string
  default     = null

  validation {
    condition     = var.github_repo == null || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/repo."
  }
}

variable "github_branch" {
  description = "The only branch whose workflow runs may assume the deploy role."
  type        = string
  default     = "main"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if this account already has one (AWS allows one per issuer URL); the role then references the existing one."
  type        = bool
  default     = true
}

variable "github_owner_id" {
  description = "Numeric GitHub owner (user/org) ID. GitHub's OIDC `sub` claim now carries IDs (repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:...), observed 2026-10-25; set both IDs so trust is pinned to this exact owner+repo, not just their names."
  type        = number
  default     = null
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID (see github_owner_id)."
  type        = number
  default     = null
}
