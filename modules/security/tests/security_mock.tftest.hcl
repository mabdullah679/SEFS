# Mock-provider unit tests for modules/security. No AWS calls. R-IDs: R8, R9.
# "Exactly one ingress rule on sg-efs" across the whole module is a structural
# property terraform test cannot enumerate; check_sg_rules.sh proves it.

mock_provider "aws" {
}

variables {
  name   = "sefs-test"
  vpc_id = "vpc-0123456789abcdef0"
}

run "security_groups" {
  command = apply

  assert {
    condition     = aws_security_group.apps.name == "sefs-test-apps" && aws_security_group.efs.name == "sefs-test-efs"
    error_message = "SG names must be <name>-apps and <name>-efs."
  }
  assert {
    condition     = aws_security_group.apps.vpc_id == var.vpc_id && aws_security_group.efs.vpc_id == var.vpc_id
    error_message = "Both SGs must be in var.vpc_id."
  }
  assert {
    condition     = output.apps_security_group_id == aws_security_group.apps.id && output.efs_security_group_id == aws_security_group.efs.id
    error_message = "Outputs must expose the two SG ids."
  }
}

run "efs_ingress_is_2049_from_apps_only" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.security_group_id == aws_security_group.efs.id
    error_message = "R9: ingress rule must be on sg-efs."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.ip_protocol == "tcp" &&
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.from_port == 2049 &&
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.to_port == 2049
    )
    error_message = "R9: ingress must be TCP 2049 only."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.referenced_security_group_id == aws_security_group.apps.id
    error_message = "R9: ingress source must be sg-apps."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.cidr_ipv6 == null &&
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.prefix_list_id == null
    )
    error_message = "R9: no CIDR / prefix-list source on sg-efs ingress."
  }
}

run "apps_egress_all" {
  command = apply

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.apps_all.security_group_id == aws_security_group.apps.id &&
      aws_vpc_security_group_egress_rule.apps_all.ip_protocol == "-1" &&
      aws_vpc_security_group_egress_rule.apps_all.cidr_ipv4 == "0.0.0.0/0"
    )
    error_message = "sg-apps must have egress all."
  }
}
