# Bootstrap root: LOCAL state on purpose (this is what creates the remote state).
# Run once per account+region by the owner: `make bootstrap` (setup.sh does it).
# Its state file (bootstrap/terraform.tfstate) is git-ignored; keep it, it is tiny and it
# is the only record Terraform has of the state bucket itself.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = var.allowed_account_id == null ? null : [var.allowed_account_id]

  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform-bootstrap"
    }
  }
}

variable "name" {
  type    = string
  default = "sefs"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "allowed_account_id" {
  type    = string
  default = null
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "allow_state_destroy" {
  type    = bool
  default = false
}

variable "github_repo" {
  type    = string
  default = null
}

variable "github_branch" {
  type    = string
  default = "main"
}

variable "create_oidc_provider" {
  type    = bool
  default = true
}

module "bootstrap" {
  source = "../modules/bootstrap"

  name                 = var.name
  region               = var.region
  kms_key_arn          = var.kms_key_arn
  allow_state_destroy  = var.allow_state_destroy
  github_repo          = var.github_repo
  github_branch        = var.github_branch
  create_oidc_provider = var.create_oidc_provider
}

output "state_bucket" { value = module.bootstrap.state_bucket }
output "lock_table" { value = module.bootstrap.lock_table }
output "github_deploy_role_arn" { value = module.bootstrap.github_deploy_role_arn }
output "backend_hcl" { value = module.bootstrap.backend_hcl }
