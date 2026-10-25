# Remote state (D22). Partial configuration: the bucket/table/region come from backend.hcl,
# written by `make bootstrap` and git-ignored. Offline suites init with -backend=false.
terraform {
  backend "s3" {}
}
