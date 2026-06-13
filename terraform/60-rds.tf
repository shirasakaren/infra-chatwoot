# 60-rds.tf
# Phase 3 — RDS PostgreSQL 16 Multi-AZ.
#
# Notes
# -----
# - manage_master_user_password = true → AWS creates a *separate* Secrets
#   Manager secret holding the master password. The password value NEVER
#   touches Terraform state (per CLAUDE.md §2 rule 5).
# - pgvector: AWS RDS PostgreSQL 16 ships with the `vector` extension
#   available. We surface a `vector` parameter group entry only for
#   shared_preload_libraries; the extension itself is created at runtime
#   by the Chatwoot DB migration job in Phase 5.

resource "aws_db_subnet_group" "main" {
  name        = "${var.name_prefix}-rds"
  description = "RDS subnets for ${var.name_prefix}"
  subnet_ids  = [for az in var.azs : aws_subnet.database[az].id]

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rds-subnets"
  })
}

resource "aws_db_parameter_group" "pg16" {
  name        = "${var.name_prefix}-pg16"
  family      = "postgres16"
  description = "Chatwoot-TA PG16 parameters (logs + pgvector preload)"

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements,vector"
    # shared_preload_libraries requires a reboot — pending-reboot is fine here
    # because we set it pre-creation.
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # log queries slower than 1s
  }
}

resource "aws_db_instance" "main" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_gb
  max_allocated_storage = var.rds_allocated_gb * 4
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "chatwoot"
  username = "chatwoot"

  # Password is created and rotated by RDS into its own Secrets Manager
  # secret — Terraform never sees the value.
  manage_master_user_password = true

  multi_az               = var.rds_multi_az
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.pg16.name

  backup_retention_period   = 7
  backup_window             = "16:00-17:00" # UTC; off-hours for ap-southeast-1
  maintenance_window        = "Sun:18:00-Sun:19:00"
  copy_tags_to_snapshot     = true
  delete_automated_backups  = true

  # destroy.sh handles the final snapshot via aws CLI before terraform destroy,
  # so we can skip the inline final snapshot here for cleaner teardown.
  skip_final_snapshot       = true
  deletion_protection       = false

  performance_insights_enabled = true
  enabled_cloudwatch_logs_exports = ["postgresql"]

  apply_immediately = false

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-pg"
  })

  lifecycle {
    # Don't bounce the DB on every apply if RDS auto-rotates the master secret.
    ignore_changes = [master_user_secret_kms_key_id]
  }
}
