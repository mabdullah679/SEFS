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

