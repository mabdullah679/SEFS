variable "name" {
  description = "Name prefix for every resource; also the Project default tag used by teardown verification."
  type        = string
  default     = "sefs"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "az_count" {
  description = "Number of AZs (R5: at least 2)."
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.40.0.0/16"
}

variable "nat_per_az" {
  description = "One NAT gateway per AZ (true) or a single shared NAT (false)."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for EFS + Backup vault. null = AWS-managed aws/elasticfilesystem (R13)."
  type        = string
  default     = null
}

variable "transition_to_ia" {
  description = "EFS IA transition (R15)."
  type        = string
  default     = "AFTER_30_DAYS"
}

variable "backup_retention_days" {
  description = "AWS Backup retention in days (R14: at least 35)."
  type        = number
  default     = 35
}

variable "posix_gid" {
  description = "Shared POSIX group for writer and reader (R10)."
  type        = number
  default     = 1000
}

variable "writer_uid" {
  description = "POSIX UID the writer access point forces (R10)."
  type        = number
  default     = 1001
}

variable "reader_uid" {
  description = "POSIX UID the reader access point forces (R10)."
  type        = number
  default     = 1002
}

variable "shared_root_path" {
  description = "Directory inside EFS both access points are rooted at (R2/R3: same path)."
  type        = string
  default     = "/shared"
}

variable "container_mount_path" {
  description = "Path the shared volume is mounted at inside both containers."
  type        = string
  default     = "/mnt/shared"
}

variable "writer_interval_seconds" {
  description = "How often the writer writes a file."
  type        = number
  default     = 10
}

variable "reader_poll_seconds" {
  description = "How often the reader scans for new files."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Extra tags merged into provider default_tags."
  type        = map(string)
  default     = {}
}

variable "allowed_account_id" {
  description = "The ONLY AWS account Terraform may touch. Required by `make up` (set in account.auto.tfvars, git-ignored)."
  type        = string
  default     = null

  validation {
    condition     = var.allowed_account_id == null || can(regex("^[0-9]{12}$", var.allowed_account_id))
    error_message = "allowed_account_id must be a 12-digit AWS account ID."
  }
}

variable "bruno_trusted_principal_arns" {
  description = "Principals allowed to assume the Bruno read-only role. Empty = any principal in this account that also holds sts:AssumeRole (admins do)."
  type        = list(string)
  default     = []
}

variable "image_build_timeout_seconds" {
  description = "Watchdog per image build+push attempt (modules/images). CI sets a higher value for emulated builds."
  type        = number
  default     = 1200
}

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications (SNS). null = no subscription."
  type        = string
  default     = null
}

variable "activate_cost_allocation_tag" {
  description = "Activate the Project cost allocation tag (needs billing permissions; opt-in)."
  type        = bool
  default     = false
}
