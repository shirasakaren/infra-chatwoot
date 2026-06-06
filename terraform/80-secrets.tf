# 80-secrets.tf
# Phase 3 — Secrets Manager container that holds the Chatwoot app-level
# secrets. Terraform creates only the container (with a placeholder version);
# scripts/load-secrets.sh writes the real values via aws-cli after apply.
#
# ExternalSecretsOperator (Phase 5, namespace external-secrets) reads from
# here using the IRSA role wired in 20-iam.tf and projects into a K8s Secret
# named `chatwoot-env` in the `chatwoot` namespace.

resource "aws_secretsmanager_secret" "chatwoot" {
  name        = "${var.name_prefix}/chatwoot"
  description = "Chatwoot app secrets (synced into the cluster via ESO). Values written by load-secrets.sh."

  # Allow same-day re-creation during teardown/redeploy cycles.
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}/chatwoot"
  })
}

# Initial placeholder so the secret has a version on first apply.
# load-secrets.sh overwrites this AFTER terraform apply with the real payload
# (rds host/user/managed-password ref, redis URL+auth, S3 bucket, SES creds,
# SECRET_KEY_BASE, OAuth/SMTP/etc.). Terraform ignores future content changes
# so re-running apply does not clobber load-secrets.sh's work.
resource "aws_secretsmanager_secret_version" "placeholder" {
  secret_id     = aws_secretsmanager_secret.chatwoot.id
  secret_string = jsonencode({
    placeholder = "load-secrets.sh has not run yet"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Convenience secret containing only the redis auth token so load-secrets.sh
# can join it with the rest of the payload without re-running terraform output.
# Same ignore-changes pattern: terraform writes once, load-secrets.sh owns it.
resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "${var.name_prefix}/redis-auth"
  description             = "ElastiCache AUTH token (used by ESO to assemble REDIS_URL)."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = jsonencode({
    auth_token = random_password.redis_auth.result
    endpoint   = aws_elasticache_replication_group.redis.primary_endpoint_address
    reader     = aws_elasticache_replication_group.redis.reader_endpoint_address
    port       = aws_elasticache_replication_group.redis.port
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
