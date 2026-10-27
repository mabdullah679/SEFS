terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7" # zips the map API for Lambda (modules/gui)
    }
  }
}

provider "aws" {
  region = var.region

  # Account guard: Terraform errors before any change if the credentials resolve
  # to any other account. `make up` refuses to run unless this is set.
  allowed_account_ids = var.allowed_account_id == null ? null : [var.allowed_account_id]

  default_tags {
    tags = merge(var.tags, {
      Project   = var.name
      ManagedBy = "terraform"
    })
  }
}
