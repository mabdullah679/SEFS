# CONTRACT FILE (docs/CONTRACTS.md). Names and types are fixed by the lead; do not rename/remove/add without lead approval.

variable "name" {
  description = "Name prefix."
  type        = string
}

variable "writer_context" {
  description = "Absolute path to writer Docker build context."
  type        = string
}

variable "reader_context" {
  description = "Absolute path to reader Docker build context."
  type        = string
}

variable "platform" {
  description = "Docker build platform; must match apps cpu architecture."
  type        = string
  default     = "linux/arm64"
}


variable "build_timeout_seconds" {
  description = "Watchdog per build+push attempt. A healthy push of both images takes < 7 min."
  type        = number
  default     = 1200
}

variable "build_attempts" {
  description = "Build+push attempts before the apply fails."
  type        = number
  default     = 3
}
