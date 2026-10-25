# R8 (sg-apps side), R9. Mock provider only: no AWS calls.
#
# ADDRESS ASSUMPTIONS (fix after merge if renamed):
#   aws_security_group.apps, aws_security_group.efs,
#   aws_vpc_security_group_ingress_rule.efs_nfs_from_apps
#
# Known unit-level gap: a brand-new, separately named CIDR ingress resource
# cannot be enumerated by terraform test (no "all resources of type" query).
# That case is caught live by tests/live/verify.sh (R9 counts EVERY rule on
# sg-efs). Inline ingress blocks and a mutated rule ARE caught here.

mock_provider "aws" {}

variables {
  name   = "sefs-ut"
  vpc_id = "vpc-0123456789abcdef0"
}

run "r09_sg_efs_only_2049_from_sg_apps" {
  command = apply
  module {
    source = "./modules/security"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.security_group_id == aws_security_group.efs.id
    error_message = "R9: the NFS rule must be attached to sg-efs."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.ip_protocol == "tcp" &&
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.from_port == 2049 &&
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.to_port == 2049
    )
    error_message = "R9: sg-efs ingress must be exactly TCP 2049."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.referenced_security_group_id == aws_security_group.apps.id
    error_message = "R9: sg-efs ingress source must be sg-apps."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.cidr_ipv6 == null &&
      aws_vpc_security_group_ingress_rule.efs_nfs_from_apps.prefix_list_id == null
    )
    error_message = "R9: sg-efs ingress must not use a CIDR or prefix list source."
  }
  assert {
    condition     = length(aws_security_group.efs.ingress) == 0
    error_message = "R9: sg-efs must have no inline ingress blocks (CONTRACTS: standalone rule resources only)."
  }
  assert {
    condition     = aws_security_group.efs.vpc_id == var.vpc_id && aws_security_group.apps.vpc_id == var.vpc_id
    error_message = "Both SGs must be in the given VPC."
  }
}

run "r08_sg_apps_has_no_ingress" {
  command = apply
  module {
    source = "./modules/security"
  }

  assert {
    condition     = length(aws_security_group.apps.ingress) == 0
    error_message = "R8/CONTRACTS: sg-apps takes no inbound traffic (no inline ingress)."
  }
  assert {
    condition     = output.apps_security_group_id == aws_security_group.apps.id && output.efs_security_group_id == aws_security_group.efs.id
    error_message = "Outputs must expose the real SG ids (apps gets sg-apps, mount targets get sg-efs)."
  }
}
