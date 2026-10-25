variable "name" {
  description = "Name prefix (dashboard, topic, alarms are <name>-*)."
  type        = string
}

variable "region" {
  description = "Region (dashboard widgets are region-bound)."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name (Container Insights metrics are keyed by it)."
  type        = string
}

variable "writer_service_name" {
  description = "Writer ECS service name."
  type        = string
}

variable "reader_service_name" {
  description = "Reader ECS service name."
  type        = string
}

variable "file_system_id" {
  description = "EFS ID."
  type        = string
}

variable "nat_gateway_ids" {
  description = "NAT gateway IDs (one alarm each on ErrorPortAllocation)."
  type        = list(string)
}

variable "writer_log_group" {
  description = "Writer log group (metric filter on WRITE_ERROR)."
  type        = string
}

variable "reader_log_group" {
  description = "Reader log group (metric filter on READ_ERROR and WRITE_PROBE ALLOWED)."
  type        = string
}

variable "backup_vault_name" {
  description = "AWS Backup vault (failed-jobs alarm)."
  type        = string
}

variable "alert_email" {
  description = "Email subscribed to the alerts topic. null = topic exists, nobody subscribed (alarms still visible in the console/GUI)."
  type        = string
  default     = null

  validation {
    condition     = var.alert_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must look like an email address."
  }
}

variable "efs_burst_credit_floor_bytes" {
  description = "Alarm when EFS BurstCreditBalance drops below this many bytes. Default 1 TiB (a new file system starts with ~2.1 TiB)."
  type        = number
  default     = 1099511627776

  validation {
    condition     = var.efs_burst_credit_floor_bytes > 0
    error_message = "efs_burst_credit_floor_bytes must be positive."
  }
}

variable "activate_cost_allocation_tag" {
  description = "Activate the `Project` cost allocation tag so Cost Explorer can group spend by it. Needs billing permissions; in an AWS Organizations member account this is often only possible from the management account, so it is opt-in."
  type        = bool
  default     = false
}
