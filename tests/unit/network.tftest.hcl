# R5, R6 (network side). Mock provider only: no AWS calls.
# Run from repo root:  terraform test -test-directory=tests/unit
#
# ADDRESS ASSUMPTIONS (fix here after merge if the network child renames them):
#   data.aws_availability_zones.available, aws_vpc.this,
#   aws_subnet.public / aws_subnet.private (for_each keyed by AZ name),
#   aws_nat_gateway.this (for_each keyed by AZ name),
#   aws_route.private_default (for_each keyed by AZ name).

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
    }
  }
}

variables {
  name       = "sefs-ut"
  vpc_cidr   = "10.40.0.0/16"
  az_count   = 2
  nat_per_az = true
}

run "r05_multi_az" {
  command = apply
  module {
    source = "./modules/network"
  }

  assert {
    condition     = length(aws_subnet.private) == 2 && length(aws_subnet.public) == 2
    error_message = "R5: az_count=2 must give one public AND one private subnet per AZ."
  }
  assert {
    condition     = length(distinct([for s in values(aws_subnet.private) : s.availability_zone])) == 2
    error_message = "R5: private subnets must sit in 2 distinct AZs."
  }
  assert {
    condition     = length(distinct([for s in values(aws_subnet.public) : s.availability_zone])) == 2
    error_message = "R5: public subnets must sit in 2 distinct AZs."
  }
  assert {
    condition     = toset(keys(output.private_subnets_by_az)) == toset(output.azs) && length(output.private_subnet_ids) == 2
    error_message = "R5/R7: private_subnets_by_az must be keyed by the AZs used, one subnet each."
  }
  assert {
    condition     = alltrue([for s in concat(values(aws_subnet.public), values(aws_subnet.private)) : s.vpc_id == aws_vpc.this.id])
    error_message = "R5: every subnet must be in the module's VPC."
  }
  assert {
    condition     = aws_vpc.this.enable_dns_hostnames && aws_vpc.this.enable_dns_support
    error_message = "EFS DNS mounts need enable_dns_hostnames + enable_dns_support."
  }
}

run "r05_rejects_single_az" {
  command = plan
  module {
    source = "./modules/network"
  }
  variables {
    az_count = 1
  }
  expect_failures = [var.az_count]
}

run "r06_private_subnets_no_public_ip" {
  command = apply
  module {
    source = "./modules/network"
  }

  assert {
    condition     = alltrue([for s in values(aws_subnet.private) : s.map_public_ip_on_launch == false])
    error_message = "R6: private subnets must not auto-assign public IPs."
  }
  assert {
    condition     = alltrue([for az, r in aws_route.private_default : r.destination_cidr_block == "0.0.0.0/0" && r.nat_gateway_id == aws_nat_gateway.this[az].id])
    error_message = "R6: each private route table's default route must go to the same-AZ NAT gateway (not the IGW)."
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 2 && alltrue([for az, n in aws_nat_gateway.this : n.subnet_id == aws_subnet.public[az].id])
    error_message = "R6: nat_per_az=true must place one NAT in each AZ's PUBLIC subnet."
  }
}
