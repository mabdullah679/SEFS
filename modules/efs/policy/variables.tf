variable "file_system_arn" {
  description = "ARN of the EFS file system the policy is attached to (statement Resource)."
  type        = string
}

variable "writer_access_point_arn" {
  description = "Writer access point ARN; writer grants are scoped to it."
  type        = string
}

variable "reader_access_point_arn" {
  description = "Reader access point ARN; reader mount grant is scoped to it."
  type        = string
}

variable "writer_role_arn" {
  description = "Writer ECS task role ARN (ClientMount + ClientWrite)."
  type        = string
}

variable "reader_role_arn" {
  description = "Reader ECS task role ARN (ClientMount only; write/root explicitly denied)."
  type        = string
}
