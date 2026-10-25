variable "name" {
  description = "Name prefix; parameters are published under /<name>/outputs/."
  type        = string
}

variable "values" {
  description = "Deployed IDs to publish (non-secret). Keys must be known at plan time; values may not be."
  type        = map(string)
}
