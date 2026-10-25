# Security groups for the shared-EFS path (R8, R9).
# Rules are standalone aws_vpc_security_group_*_rule resources, never inline
# blocks, so each rule is its own addressable object a test can count.

# sg-apps: attached to BOTH app services (R8). No ingress at all; the apps
# take no inbound traffic. Egress all: ECR pull via NAT, CloudWatch Logs, NFS.
resource "aws_security_group" "apps" {
  name        = "${var.name}-apps"
  description = "SEFS app tasks (writer + reader). No ingress."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-apps"
  }
}

resource "aws_vpc_security_group_egress_rule" "apps_all" {
  security_group_id = aws_security_group.apps.id
  description       = "All egress: ECR via NAT, logs, NFS to sg-efs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "${var.name}-apps-egress-all"
  }
}

# sg-efs: on the mount targets. EXACTLY ONE ingress rule: NFS 2049 from
# sg-apps (R9). No CIDR ingress, ever. No egress rules are declared: NFS
# replies are stateful return traffic and need none.
resource "aws_security_group" "efs" {
  name        = "${var.name}-efs"
  description = "SEFS EFS mount targets. Ingress 2049 from sg-apps only."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name}-efs"
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs_from_apps" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from sg-apps only (R9)"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = aws_security_group.apps.id

  tags = {
    Name = "${var.name}-efs-nfs-from-apps"
  }
}
