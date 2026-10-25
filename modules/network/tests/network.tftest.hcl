# Mock-provider tests: no AWS calls. R5 (multi-AZ, >= 2) and R6 (private subnets).

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

variables {
  name       = "sefs-test"
  vpc_cidr   = "10.40.0.0/16"
  az_count   = 2
  nat_per_az = true
}

run "az_count_1_rejected" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "two_azs_two_public_two_private" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 2 && length(aws_subnet.public) == 2
    error_message = "az_count=2 must yield 2 private + 2 public subnets."
  }

  assert {
    condition     = output.azs == tolist(["us-east-1a", "us-east-1b"])
    error_message = "azs must be the first az_count available AZs, ordered."
  }

  assert {
    condition     = toset(keys(output.private_subnets_by_az)) == toset(["us-east-1a", "us-east-1b"])
    error_message = "private_subnets_by_az must be keyed by AZ name."
  }

  assert {
    condition     = length(distinct([for s in concat(values(aws_subnet.public), values(aws_subnet.private)) : s.cidr_block])) == 4
    error_message = "subnet CIDRs must not overlap."
  }

  assert {
    condition     = aws_vpc.this.enable_dns_hostnames && aws_vpc.this.enable_dns_support
    error_message = "VPC needs DNS hostnames + support for EFS DNS mounts."
  }
}

run "private_subnets_no_public_ip" {
  command = plan

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch == false])
    error_message = "private subnets must not map public IPs (R6)."
  }
}

run "single_nat" {
  command = apply # mock provider: no real resources

  variables {
    nat_per_az = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(output.nat_gateway_ids) == 1
    error_message = "nat_per_az=false must yield exactly 1 NAT."
  }

  assert {
    condition     = aws_nat_gateway.this["us-east-1a"].subnet_id == aws_subnet.public["us-east-1a"].id
    error_message = "single NAT must live in the first public subnet."
  }

  assert {
    condition     = alltrue([for r in aws_route.private_default : r.nat_gateway_id == aws_nat_gateway.this["us-east-1a"].id])
    error_message = "all private route tables must default-route to the single NAT."
  }
}

run "nat_per_az" {
  command = apply # mock provider: no real resources

  variables {
    nat_per_az = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2 && length(output.nat_gateway_ids) == 2
    error_message = "nat_per_az=true with 2 AZs must yield 2 NATs."
  }

  assert {
    condition     = alltrue([for az, r in aws_route.private_default : r.nat_gateway_id == aws_nat_gateway.this[az].id])
    error_message = "each private route table must route to its own AZ's NAT."
  }

  assert {
    condition     = alltrue([for az, n in aws_nat_gateway.this : n.subnet_id == aws_subnet.public[az].id])
    error_message = "each NAT must sit in its own AZ's public subnet."
  }

  assert {
    condition     = length(distinct(values(output.private_subnets_by_az))) == 2
    error_message = "private_subnets_by_az must carry 2 distinct subnet IDs."
  }
}
