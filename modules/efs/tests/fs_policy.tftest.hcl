# R2/R3: renders the REAL file-system-policy JSON with the real hashicorp/aws
# provider (module ../policy, data source only) and asserts on the rendered
# document, i.e. exactly the string aws_efs_file_system_policy sends to AWS.
# No AWS API calls: aws_iam_policy_document is computed locally by the provider,
# and provider configure skips STS/IMDS/region checks with dummy keys.
# run_tests.sh runs this with HTTP(S)_PROXY pointed at a closed local port, so
# any attempted network call would fail the run instead of reaching AWS.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock_access_key"
  secret_key                  = "mock_secret_key"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "rendered_policy_json" {
  command = apply

  module {
    source = "./policy"
  }

  variables {
    file_system_arn         = "arn:aws:elasticfilesystem:us-east-1:111122223333:file-system/fs-0123456789abcdef0"
    writer_access_point_arn = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-0aaaaaaaaaaaaaaa1"
    reader_access_point_arn = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-0bbbbbbbbbbbbbbb2"
    writer_role_arn         = "arn:aws:iam::111122223333:role/sefs-test-writer-task"
    reader_role_arn         = "arn:aws:iam::111122223333:role/sefs-test-reader-task"
  }

  assert {
    condition     = length(jsondecode(output.json).Statement) == 4
    error_message = "Rendered policy must have exactly 4 statements."
  }

  # 1
  assert {
    condition = anytrue([for s in jsondecode(output.json).Statement :
      s.Sid == "DenyInsecureTransport" && s.Effect == "Deny" && s.Action == "*" &&
      s.Principal == { AWS = "*" } &&
      s.Resource == "arn:aws:elasticfilesystem:us-east-1:111122223333:file-system/fs-0123456789abcdef0" &&
      try(s.Condition, null) == { Bool = { "aws:SecureTransport" = "false" } }
    ])
    error_message = "Rendered JSON: missing/incorrect DenyInsecureTransport."
  }

  # 2
  assert {
    condition = anytrue([for s in jsondecode(output.json).Statement :
      s.Effect == "Allow" &&
      toset(flatten([s.Action])) == toset(["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]) &&
      s.Principal == { AWS = "arn:aws:iam::111122223333:role/sefs-test-writer-task" } &&
      try(s.Condition, null) == { StringEquals = { "elasticfilesystem:AccessPointArn" = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-0aaaaaaaaaaaaaaa1" } }
    ])
    error_message = "Rendered JSON: writer Allow must be ClientMount+ClientWrite scoped to the writer AP ARN."
  }

  # 3
  assert {
    condition = anytrue([for s in jsondecode(output.json).Statement :
      s.Effect == "Allow" &&
      s.Action == "elasticfilesystem:ClientMount" &&
      s.Principal == { AWS = "arn:aws:iam::111122223333:role/sefs-test-reader-task" } &&
      try(s.Condition, null) == { StringEquals = { "elasticfilesystem:AccessPointArn" = "arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-0bbbbbbbbbbbbbbb2" } }
    ])
    error_message = "Rendered JSON: reader Allow must be ClientMount only, scoped to the reader AP ARN."
  }

  # 4
  assert {
    condition = anytrue([for s in jsondecode(output.json).Statement :
      s.Effect == "Deny" &&
      toset(flatten([s.Action])) == toset(["elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"]) &&
      s.Principal == { AWS = "arn:aws:iam::111122223333:role/sefs-test-reader-task" } &&
      try(s.Condition, null) == null
    ])
    error_message = "Rendered JSON: reader must have an unconditional Deny on ClientWrite + ClientRootAccess."
  }

  # No Allow grants '*' or root access.
  assert {
    condition = alltrue([for s in jsondecode(output.json).Statement :
      s.Effect != "Allow" || (
        s.Principal != { AWS = "*" } &&
        !contains(flatten([s.Action]), "elasticfilesystem:ClientRootAccess")
      )
    ])
    error_message = "Rendered JSON: no Allow may target '*' or grant ClientRootAccess."
  }
}
