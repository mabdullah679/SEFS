# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

variable "name" {
  description = "Name prefix."
  type        = string
}

variable "private_subnets_by_az" {
  description = "map(AZ => private subnet ID); one mount target each (R7)."
  type        = map(string)
}

variable "efs_security_group_id" {
  description = "sg-efs ID for mount targets."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN or null for aws/elasticfilesystem (R13)."
  type        = string
  default     = null
}

variable "transition_to_ia" {
  description = "IA transition (R15)."
  type        = string
  default     = "AFTER_30_DAYS"
}

variable "shared_root_path" {
  description = "Root dir of BOTH access points."
  type        = string
}

variable "posix_gid" {
  description = "Shared GID (R10)."
  type        = number
}

variable "writer_uid" {
  description = "Writer UID (R10)."
  type        = number
}

variable "reader_uid" {
  description = "Reader UID (R10)."
  type        = number
}

variable "writer_role_arn" {
  description = "Writer ECS task role ARN; FS policy grants mount+write (R2)."
  type        = string
}

variable "reader_role_arn" {
  description = "Reader ECS task role ARN; FS policy grants mount, explicitly DENIES write (R3)."
  type        = string
}

