# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

variable "name" {
  description = "Name prefix."
  type        = string

  validation {
    # Task-role name_prefix is "<name>-writer-task-" / "<name>-reader-task-"
    # (13 extra chars); IAM role name_prefix max is 38.
    condition     = length(var.name) >= 1 && length(var.name) <= 25
    error_message = "name must be 1-25 characters so the task-role name_prefix fits IAM's 38-character limit."
  }
}

variable "region" {
  description = "Region (log config)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for services (R6)."
  type        = list(string)
}

variable "apps_security_group_id" {
  description = "sg-apps, attached to both services (R8)."
  type        = string
}

variable "file_system_id" {
  description = "EFS ID."
  type        = string
}

variable "file_system_arn" {
  description = "EFS ARN (task role IAM policy resource)."
  type        = string
}

variable "writer_access_point_id" {
  description = "Writer AP ID."
  type        = string
}

variable "writer_access_point_arn" {
  description = "Writer AP ARN."
  type        = string
}

variable "reader_access_point_id" {
  description = "Reader AP ID."
  type        = string
}

variable "reader_access_point_arn" {
  description = "Reader AP ARN."
  type        = string
}

variable "efs_dependency_ids" {
  description = "IDs (FS policy + mount targets) services must wait on before starting."
  type        = list(string)
}

variable "writer_image" {
  description = "Writer image ref."
  type        = string
}

variable "reader_image" {
  description = "Reader image ref."
  type        = string
}

variable "container_mount_path" {
  description = "Mount path in both containers."
  type        = string
}

variable "writer_interval_seconds" {
  description = "Writer interval."
  type        = number
}

variable "reader_poll_seconds" {
  description = "Reader poll interval."
  type        = number
}

