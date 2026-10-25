# Bruno read-only role (modules/access) and published IDs (modules/registry). Mock provider only.
#
# ADDRESS ASSUMPTIONS: aws_iam_role.bruno_reader, aws_iam_role_policy.bruno_reader,
# aws_ssm_parameter.output (for_each). Policies are jsonencode()d, so they are REAL JSON here.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/sefs-ut-bruno-reader"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
      arn        = "arn:aws:iam::111122223333:user/ut"
      user_id    = "AIDAUNITTEST"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

variables {
  name   = "sefs-ut"
  region = "ap-southeast-2"
}

run "access_read_only_actions_only" {
  command = apply
  module {
    source = "./modules/access"
  }

  # Every allowed action must be a read verb on the allow-list. Anything that can change
  # state (Put/Create/Delete/Update/Run/Start/Attach/PassRole/AssumeRole...) fails this.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.bruno_reader.policy).Statement :
      s.Effect == "Allow" && alltrue([
        for a in flatten([s.Action]) :
        can(regex("^(ssm:Get(Parameter|Parameters|ParametersByPath)|kms:Decrypt|elasticfilesystem:Describe[A-Za-z]+|ecs:(Describe[A-Za-z]+|ListTasks)|ec2:Describe[A-Za-z]+|logs:(FilterLogEvents|GetLogEvents|DescribeLogStreams)|backup:(Get[A-Za-z]+|List[A-Za-z]+|Describe[A-Za-z]+))$", a))
      ])
    ])
    error_message = "Bruno role must hold read-only actions from the allow-list and nothing else."
  }
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.bruno_reader.policy).Statement :
      anytrue([for a in flatten([s.Action]) : can(regex("(Put|Create|Delete|Update|Run|Start|Stop|Attach|Detach|PassRole|AssumeRole|Tag|Modify|Register|Deregister|Restore|\\*)", a))])
    ])
    error_message = "No state-changing verb (or wildcard action) may appear anywhere in the Bruno policy."
  }
}

run "access_ssm_scoped_to_project_paths" {
  command = apply
  module {
    source = "./modules/access"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.bruno_reader.policy).Statement :
      !anytrue([for a in flatten([s.Action]) : startswith(a, "ssm:")]) ||
      alltrue([for r in flatten([s.Resource]) : startswith(r, "arn:aws:ssm:ap-southeast-2:111122223333:parameter/sefs-ut")])
    ])
    error_message = "SSM access must be confined to parameter/<name> and parameter/<name>/*."
  }
}

run "access_wildcard_resource_only_for_unscopable_describes" {
  command = apply
  module {
    source = "./modules/access"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.bruno_reader.policy).Statement :
      !contains(flatten([s.Resource]), "*") ||
      alltrue([for a in flatten([s.Action]) : can(regex("^(ecs:DescribeTaskDefinition|ec2:Describe[A-Za-z]+|backup:ListBackupPlans)$", a))])
    ])
    error_message = "Resource \"*\" is allowed only for describe/list calls that AWS cannot scope."
  }
}

run "access_kms_decrypt_only_via_ssm" {
  command = apply
  module {
    source = "./modules/access"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.bruno_reader.policy).Statement :
      !contains(flatten([s.Action]), "kms:Decrypt") ||
      (try(s.Condition.StringEquals["kms:ViaService"], "") == "ssm.ap-southeast-2.amazonaws.com" &&
      try(s.Condition.StringLike["kms:EncryptionContext:PARAMETER_ARN"], "") == "arn:aws:ssm:ap-southeast-2:111122223333:parameter/sefs-ut/*")
    ])
    error_message = "kms:Decrypt must be conditioned on ViaService=ssm and on this project's parameter ARN."
  }
}

run "access_trust_defaults_to_this_account_only" {
  command = apply
  module {
    source = "./modules/access"
  }

  assert {
    condition     = jsondecode(aws_iam_role.bruno_reader.assume_role_policy).Statement[0].Principal.AWS == ["arn:aws:iam::111122223333:root"]
    error_message = "With no explicit principals, trust must be this account's root and nothing else."
  }
  assert {
    condition     = aws_iam_role.bruno_reader.max_session_duration == 3600
    error_message = "Sessions must be capped at one hour."
  }
}

run "access_trust_honours_explicit_principals" {
  command = apply
  module {
    source = "./modules/access"
  }
  variables {
    trusted_principal_arns = ["arn:aws:iam::111122223333:role/Alice", "arn:aws:iam::111122223333:role/Bob"]
  }

  assert {
    condition     = jsondecode(aws_iam_role.bruno_reader.assume_role_policy).Statement[0].Principal.AWS == ["arn:aws:iam::111122223333:role/Alice", "arn:aws:iam::111122223333:role/Bob"]
    error_message = "Explicit trusted principals must replace the account-root default."
  }
}

run "access_rejects_overlong_name" {
  command = plan
  module {
    source = "./modules/access"
  }
  variables {
    name = "this-name-is-way-too-long-for-it"
  }

  expect_failures = [var.name]
}

run "registry_publishes_plain_string_params_under_prefix" {
  command = apply
  module {
    source = "./modules/registry"
  }
  variables {
    values = {
      file_system_id = "fs-0123456789abcdef0"
      region         = "ap-southeast-2"
    }
  }

  assert {
    condition     = alltrue([for k, p in aws_ssm_parameter.output : p.type == "String"])
    error_message = "Terraform must never create SecureString parameters (values would be stored in state)."
  }
  assert {
    condition     = sort([for k, p in aws_ssm_parameter.output : p.name]) == tolist(["/sefs-ut/outputs/file_system_id", "/sefs-ut/outputs/region"])
    error_message = "Parameters must be published under /<name>/outputs/<key>."
  }
  assert {
    condition     = !anytrue([for k, p in aws_ssm_parameter.output : startswith(p.name, "/sefs-ut/secrets/")])
    error_message = "Terraform must not write under /<name>/secrets/ (setup.sh owns that path)."
  }
}
