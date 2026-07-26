# 10-network.tf
# Phase 1: VPC, subnets (public/private/db across 2 AZs), IGW, 2 NAT GWs
# (one per AZ so a single AZ outage doesn't take the internet with it),
# per-AZ private route tables, and the baseline security groups.
# purely additive; the CIDR was picked in Phase 0 to avoid overlap.
#
# Subnet layout in a /16 (e.g. 10.42.0.0/16):
#   public_a    10.42.0.0/20    cidrsubnet(vpc, 4, 0)
#   public_b    10.42.16.0/20   cidrsubnet(vpc, 4, 1)
#   private_a   10.42.32.0/20   cidrsubnet(vpc, 4, 2)   # EKS nodes / pods
#   private_b   10.42.48.0/20   cidrsubnet(vpc, 4, 3)
#   db_a        10.42.128.0/20  cidrsubnet(vpc, 4, 8)   # RDS / ElastiCache
#   db_b        10.42.144.0/20  cidrsubnet(vpc, 4, 9)
# 4096 IPs per subnet, with headroom between groups for future carve-outs.

locals {
  # Convenience handles.
  vpc_cidr = local.selected_vpc_cidr

  subnet_az_index = { for i, az in var.azs : az => i }

  public_subnet_cidrs   = [for i, _ in var.azs : cidrsubnet(local.vpc_cidr, 4, i)]
  private_subnet_cidrs  = [for i, _ in var.azs : cidrsubnet(local.vpc_cidr, 4, i + 2)]
  database_subnet_cidrs = [for i, _ in var.azs : cidrsubnet(local.vpc_cidr, 4, i + 8)]

  cluster_name = var.name_prefix

  # Subnet tags required by the AWS Load Balancer Controller + EKS
  # so the controller can discover where to place ALBs/NLBs.
  eks_shared_tag = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
  public_eks_tags  = merge(local.eks_shared_tag, { "kubernetes.io/role/elb" = "1" })
  private_eks_tags = merge(local.eks_shared_tag, { "kubernetes.io/role/internal-elb" = "1" })
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-igw"
  })
}

# -----------------------------------------------------------------------------
# Public subnets (one per AZ)
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each = local.subnet_az_index

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = local.public_subnet_cidrs[each.value]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, local.public_eks_tags, {
    Name = "${var.name_prefix}-public-${each.key}"
    Tier = "public"
  })
}

# -----------------------------------------------------------------------------
# Private subnets (EKS nodes / pods, one per AZ)
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  for_each = local.subnet_az_index

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = local.private_subnet_cidrs[each.value]

  tags = merge(local.common_tags, local.private_eks_tags, {
    Name = "${var.name_prefix}-private-${each.key}"
    Tier = "private"
  })
}

# -----------------------------------------------------------------------------
# Database subnets (RDS + ElastiCache, one per AZ)
# -----------------------------------------------------------------------------
resource "aws_subnet" "database" {
  for_each = local.subnet_az_index

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = local.database_subnet_cidrs[each.value]

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-db-${each.key}"
    Tier = "database"
  })
}

# -----------------------------------------------------------------------------
# Elastic IPs for NAT (one per AZ for HA egress)
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  for_each = local.subnet_az_index

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-nat-eip-${each.key}"
  })

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# NAT Gateways (one per AZ; private subnets in AZ-x egress through NAT-x)
# -----------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  for_each = local.subnet_az_index

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-nat-${each.key}"
  })

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Public route table (shared by both public subnets)
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rt-public"
  })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each       = local.subnet_az_index
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Private route tables (one per AZ with its own NAT for AZ-local egress)
# -----------------------------------------------------------------------------
resource "aws_route_table" "private" {
  for_each = local.subnet_az_index
  vpc_id   = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rt-private-${each.key}"
  })
}

resource "aws_route" "private_default" {
  for_each               = local.subnet_az_index
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[each.key].id
}

resource "aws_route_table_association" "private" {
  for_each       = local.subnet_az_index
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# -----------------------------------------------------------------------------
# Database route tables: no default route. RDS/ElastiCache don't need
# internet egress; this keeps the data tier strictly internal. the data
# tier is an introvert and we respect that.
# -----------------------------------------------------------------------------
resource "aws_route_table" "database" {
  for_each = local.subnet_az_index
  vpc_id   = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rt-db-${each.key}"
  })
}

resource "aws_route_table_association" "database" {
  for_each       = local.subnet_az_index
  subnet_id      = aws_subnet.database[each.key].id
  route_table_id = aws_route_table.database[each.key].id
}

# =============================================================================
# Baseline Security Groups
# =============================================================================
#
# Rule of thumb:
#   ALB     <- internet on 80/443
#   Nodes   <- ALB on 80, 443, 1025-65535 (ALB target ports vary)
#   Nodes   <- self (intra-cluster pod/service traffic)
#   RDS     <- Nodes on 5432
#   Redis   <- Nodes on 6379
#
# The EKS control plane <-> nodes SG is created by the EKS module in Phase 2
# (so we don't duplicate the managed rules here).
# -----------------------------------------------------------------------------

# ALB security group
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public ALB ingress (80/443) for Chatwoot"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-alb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet (redirected to HTTPS at the listener)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "ALB → targets (any)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Node (worker) security group: additional rules layered on top of the
# EKS-managed cluster SG. Created here so RDS/Redis SGs can reference it.
resource "aws_security_group" "node" {
  name        = "${var.name_prefix}-node-extra"
  description = "Additional rules for EKS worker nodes (ALB ingress, intra-node)"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-node-extra"
  })
}

resource "aws_vpc_security_group_ingress_rule" "node_from_alb" {
  security_group_id            = aws_security_group.node.id
  description                  = "ALB → node target ports"
  from_port                    = 1025
  to_port                      = 65535
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  description                  = "Pod-to-pod / node-to-node"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.node.id
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "Nodes → anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# RDS PostgreSQL
resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds"
  description = "RDS PostgreSQL — only from EKS nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rds"
  })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from nodes"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.node.id
}

resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ElastiCache Redis
resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis"
  description = "ElastiCache Redis — only from EKS nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-redis"
  })
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_nodes" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis from nodes"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.node.id
}

resource "aws_vpc_security_group_egress_rule" "redis_all" {
  security_group_id = aws_security_group.redis.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
