# R2 / R3 compensating control: the EFS file-system policy, as the REAL JSON
# string aws_efs_file_system_policy sends to AWS.
#
# Uses the REAL hashicorp/aws provider (not a mock): a mock would replace
# aws_iam_policy_document.json with a random string and we would be testing
# our own fixture. The target module (modules/efs/policy) holds only that data
# source, which the provider renders locally. Dummy keys + skip flags mean
# configure makes no STS/IMDS call, and tests/unit/run.sh runs terraform test
# with HTTP(S)_PROXY pointed at a closed local port, so any network attempt
# fails the run instead of reaching AWS.
#
# ADDRESS ASSUMPTIONS (storage child layout, fix after merge if changed):
#   module source ./modules/efs/policy, output "json", variables
#   file_system_arn, writer/reader_access_point_arn, writer/reader_role_arn.
# Wiring of that json into aws_efs_file_system_policy.this is asserted in
# tests/unit/apply/efs_wiring.tftest.hcl.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "unit-test-not-a-key"
  secret_key                  = "unit-test-not-a-key"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

variables {
  file_system_arn         = "arn:aws:elasticfilesystem:us-east-1:111122223333:file-system/fs-0123456789abcdef0"
  writer_access_point_arn = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-0aaaaaaaaaaaaaaa1"
  reader_access_point_arn = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-0bbbbbbbbbbbbbbb2"
  writer_role_arn         = "arn:aws:iam::111122223333:role/sefs-ut-writer-task"
  reader_role_arn         = "arn:aws:iam::111122223333:role/sefs-ut-reader-task"
}

run "r03_fs_policy_reader_explicit_deny" {
  command = apply
  module {
    source = "./modules/efs/policy"
  }

  assert {
    condition = anytrue([for s in jsondecode(output.json).Statement :
      s.Effect == "Deny" &&
      contains(flatten([try(s.Principal.AWS, s.Principal, [])]), var.reader_role_arn) &&
      contains(flatten([s.Action]), "elasticfilesystem:ClientWrite") &&
      contains(flatten([s.Action]), "elasticfilesystem:ClientRootAccess") &&
      contains(flatten([s.Resource]), var.file_system_arn) &&
      try(s.Condition, null) == null
    ])
    error_message = "R3: FS policy must explicitly and UNCONDITIONALLY deny the reader role ClientWrite + ClientRootAccess."
  }
}

run "r03_fs_policy_reader_mount_only" {
  command = apply
  module {
    source = "./modules/efs/policy"
  }

  assert {
    condition = anytrue([for s in jsondecode(output.json).Statement :
      s.Effect == "Allow" &&
      contains(flatten([try(s.Principal.AWS, s.Principal, [])]), var.reader_role_arn) &&
      toset(flatten([s.Action])) == toset(["elasticfilesystem:ClientMount"]) &&
      try(s.Condition.StringEquals["elasticfilesystem:AccessPointArn"], null) == var.reader_access_point_arn
    ])
    error_message = "R3: FS policy must allow the reader role ClientMount only, via the reader access point."
  }
  assert {
    condition = alltrue([for s in jsondecode(output.json).Statement :
      !(s.Effect == "Allow" && contains(flatten([try(s.Principal.AWS, s.Principal, [])]), var.reader_role_arn) &&
      anytrue([for a in flatten([s.Action]) : contains(["elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess", "elasticfilesystem:*", "*"], a)]))
    ])
    error_message = "R3: no FS policy statement may ALLOW the reader role write / root / wildcard."
  }
}

run "r02_fs_policy_writer_mount_write" {
  command = apply
  module {
    source = "./modules/efs/policy"
  }

  assert {
    condition = anytrue([for s in jsondecode(output.json).Statement :
      s.Effect == "Allow" &&
      contains(flatten([try(s.Principal.AWS, s.Principal, [])]), var.writer_role_arn) &&
      toset(flatten([s.Action])) == toset(["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]) &&
      try(s.Condition.StringEquals["elasticfilesystem:AccessPointArn"], null) == var.writer_access_point_arn
    ])
    error_message = "R2: FS policy must allow the writer role ClientMount + ClientWrite via the writer access point."
  }
}

run "fs_policy_no_anonymous_no_root_no_plaintext" {
  command = apply
  module {
    source = "./modules/efs/policy"
  }

  assert {
    condition = anytrue([for s in jsondecode(output.json).Statement :
      s.Effect == "Deny" &&
      tostring(try(s.Condition.Bool["aws:SecureTransport"], "")) == "false"
    ])
    error_message = "CONTRACTS: FS policy must deny every request with aws:SecureTransport = false."
  }
  assert {
    condition = alltrue([for s in jsondecode(output.json).Statement :
      s.Effect != "Allow" || !contains(flatten([try(s.Principal.AWS, s.Principal, [])]), "*")
    ])
    error_message = "CONTRACTS: no Allow statement may grant anonymous / * access."
  }
  assert {
    condition = alltrue([for s in jsondecode(output.json).Statement :
      s.Effect != "Allow" || !anytrue([for a in flatten([s.Action]) : contains(["elasticfilesystem:ClientRootAccess", "elasticfilesystem:*", "*"], a)])
    ])
    error_message = "CONTRACTS: nobody is allowed ClientRootAccess (or a wildcard that implies it)."
  }
}
