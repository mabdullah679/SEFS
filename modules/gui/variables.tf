variable "name" {
  description = "Project name; prefixes every resource (bucket, pool, API, role)."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.name))
    error_message = "name must be lowercase letters, digits and dashes, 2-25 characters (it prefixes a Cognito domain and an S3 bucket)."
  }
}

variable "region" {
  description = "Region of the stack the GUI reads (the GUI itself deploys here too; CloudFront is global)."
  type        = string
}

variable "admin_email" {
  description = "E-mail of the first GUI user. Cognito e-mails a temporary password; nothing secret touches Terraform state. null = no user created (add one in the console or with the CLI)."
  type        = string
  default     = null
  validation {
    condition     = var.admin_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.admin_email))
    error_message = "admin_email must be an e-mail address or null."
  }
}

variable "ssm_prefix" {
  description = "SSM path under which the registry child publishes deployed IDs (/<name>/outputs). The API reads those instead of being told every ID."
  type        = string
}

variable "writer_log_group" {
  description = "Log group of the writer task (the API reads WROTE lines from it)."
  type        = string
}

variable "reader_log_group" {
  description = "Log group of the reader task (the API reads READ and WRITE_PROBE lines from it)."
  type        = string
}

variable "backup_vault_name" {
  description = "Backup vault whose recovery points the backup room lists."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster the compute room describes."
  type        = string
}

variable "node_image" {
  description = "Pinned Node image used to compile the TypeScript front-end during the apply (the host needs Docker, not Node)."
  type        = string
  default     = "node:22.12.0-alpine3.20"
}

variable "lambda_runtime" {
  description = "Lambda runtime for the read-only data API."
  type        = string
  default     = "python3.12"
}

variable "refresh_seconds" {
  description = "How often the page re-reads inventory and health (the API is throttled to match)."
  type        = number
  default     = 30
  validation {
    condition     = var.refresh_seconds >= 10 && var.refresh_seconds <= 600
    error_message = "refresh_seconds must be between 10 and 600."
  }
}

variable "cost_actuals" {
  description = "Also query Cost Explorer for real spend tagged Project=<name> (needs the cost allocation tag activated: activate_cost_allocation_tag on the observability child, and ~24 h for data). false = rates only."
  type        = bool
  default     = true
}

variable "build_web" {
  description = "Compile and upload the page during the apply (needs Docker). false = infrastructure only; the offline unit tests use it because terraform test runs provisioners even on overridden resources."
  type        = bool
  default     = true
}

variable "build_timeout_seconds" {
  description = "Watchdog for the front-end build + upload during the apply."
  type        = number
  default     = 900
}
