# 70-elasticache.tf
# Phase 3 — ElastiCache Redis 7, primary + 1 replica, Multi-AZ + automatic
# failover, transit + at-rest encryption, AUTH token required.
#
# Limitation: ElastiCache requires the AUTH token at creation time, so a
# Terraform-generated random value is the only practical path. The value
# is held in state (encrypted at rest in the S3 backend) and copied into
# the chatwoot Secrets Manager container by scripts/load-secrets.sh.

resource "aws_elasticache_subnet_group" "redis" {
  name        = "${var.name_prefix}-redis"
  description = "Redis subnets for ${var.name_prefix}"
  subnet_ids  = [for az in var.azs : aws_subnet.database[az].id]
}

resource "aws_elasticache_parameter_group" "redis7" {
  name        = "${var.name_prefix}-redis7"
  family      = "redis7"
  description = "Chatwoot-TA Redis 7 defaults"
}

# Auth token (16-64 printable chars, no quotes/backslash). 40 random
# alphanumeric chars satisfies the constraint comfortably.
resource "random_password" "redis_auth" {
  length      = 40
  special     = false
  upper       = true
  lower       = true
  numeric     = true
  min_upper   = 4
  min_lower   = 4
  min_numeric = 4
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "Chatwoot-TA Redis primary + replica"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  port                 = 6379

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  parameter_group_name = aws_elasticache_parameter_group.redis7.name
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  auth_token_update_strategy = "ROTATE"

  snapshot_retention_limit = 7
  snapshot_window          = "16:00-17:00"
  maintenance_window       = "sun:18:00-sun:19:00"

  apply_immediately = false

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-redis"
  })

  lifecycle {
    ignore_changes = [auth_token] # rotation handled out-of-band via load-secrets.sh
  }
}
