# outputs.tf — populated by later phases. Phase 0 publishes only discovery.

output "selected_vpc_cidr" {
  description = "VPC CIDR Phase 0 will use (auto-selected to avoid overlap, or override)."
  value       = local.selected_vpc_cidr
}

output "discovery_path" {
  description = "Path to the do-not-touch inventory written by Phase 0."
  value       = local_file.do_not_touch.filename
}

output "do_not_touch_summary" {
  description = "Compact summary of pre-existing resources Phase 0 must not modify."
  value = {
    vpc_count          = length(local.existing_vpcs)
    eks_cluster_count  = length(data.aws_eks_clusters.existing.names)
    route53_zone_count = length(data.aws_route53_zones.existing.ids)
    overlapping_cidrs  = local.overlapping_existing_cidrs
  }
}

output "name_prefix" {
  value = var.name_prefix
}

output "region" {
  value = var.region
}

# -----------------------------------------------------------------------------
# Phase 1 — Network
# -----------------------------------------------------------------------------
output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "availability_zones" {
  value = var.azs
}

output "public_subnet_ids" {
  value = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  value = [for az in var.azs : aws_subnet.private[az].id]
}

output "database_subnet_ids" {
  value = [for az in var.azs : aws_subnet.database[az].id]
}

output "nat_gateway_ids" {
  value = [for az in var.azs : aws_nat_gateway.main[az].id]
}

output "internet_gateway_id" {
  value = aws_internet_gateway.main.id
}

output "sg_alb_id"   { value = aws_security_group.alb.id }
output "sg_node_id"  { value = aws_security_group.node.id }
output "sg_rds_id"   { value = aws_security_group.rds.id }
output "sg_redis_id" { value = aws_security_group.redis.id }

# -----------------------------------------------------------------------------
# Phase 2 — Platform (EKS, IAM, ECR, S3)
# -----------------------------------------------------------------------------
output "eks_cluster_name"      { value = aws_eks_cluster.main.name }
output "eks_cluster_endpoint"  { value = aws_eks_cluster.main.endpoint }
output "eks_cluster_version"   { value = aws_eks_cluster.main.version }
output "eks_oidc_issuer"       { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
output "eks_oidc_provider_arn" { value = aws_iam_openid_connect_provider.eks.arn }
output "eks_cluster_ca_data" {
  value     = aws_eks_cluster.main.certificate_authority[0].data
  sensitive = true
}

output "eks_node_group_name" { value = aws_eks_node_group.main.node_group_name }
output "eks_node_role_arn"   { value = aws_iam_role.eks_node.arn }
output "node_launch_template_id" { value = aws_launch_template.nodes.id }

output "irsa_alb_controller_role_arn"     { value = aws_iam_role.alb_controller.arn }
output "irsa_cluster_autoscaler_role_arn" { value = aws_iam_role.cluster_autoscaler.arn }
output "irsa_external_secrets_role_arn"   { value = aws_iam_role.external_secrets.arn }
output "irsa_chatwoot_role_arn"           { value = aws_iam_role.chatwoot.arn }

output "ecr_repository_url" { value = aws_ecr_repository.chatwoot.repository_url }
output "s3_bucket_name"     { value = aws_s3_bucket.activestorage.bucket }
output "s3_bucket_arn"      { value = aws_s3_bucket.activestorage.arn }

output "iam_group_operators"  { value = aws_iam_group.operators.name }
output "iam_group_developers" { value = aws_iam_group.developers.name }
output "iam_users_created"    { value = [for u in aws_iam_user.users : u.name] }

# -----------------------------------------------------------------------------
# Phase 3 — Data
# -----------------------------------------------------------------------------
output "rds_instance_id"        { value = aws_db_instance.main.id }
output "rds_endpoint"           { value = aws_db_instance.main.endpoint }
output "rds_address"            { value = aws_db_instance.main.address }
output "rds_port"               { value = aws_db_instance.main.port }
output "rds_db_name"            { value = aws_db_instance.main.db_name }
output "rds_username"           { value = aws_db_instance.main.username }
output "rds_multi_az"           { value = aws_db_instance.main.multi_az }
output "rds_managed_secret_arn" {
  description = "AWS-managed Secrets Manager secret holding the RDS master password."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "redis_primary_endpoint" { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "redis_reader_endpoint"  { value = aws_elasticache_replication_group.redis.reader_endpoint_address }
output "redis_port"             { value = aws_elasticache_replication_group.redis.port }
output "redis_auth_secret_arn"  { value = aws_secretsmanager_secret.redis_auth.arn }

output "chatwoot_secret_arn"  { value = aws_secretsmanager_secret.chatwoot.arn }
output "chatwoot_secret_name" { value = aws_secretsmanager_secret.chatwoot.name }

# -----------------------------------------------------------------------------
# Phase 4 — Edge (ACM, Cloudflare, SES)
# -----------------------------------------------------------------------------
output "acm_certificate_arn"    { value = aws_acm_certificate.app.arn }
output "acm_certificate_status" { value = aws_acm_certificate.app.status }
output "cloudflare_zone_id"     { value = data.cloudflare_zone.main.id }

output "ses_domain"              { value = aws_ses_domain_identity.main.domain }
output "ses_mail_from_domain"    { value = aws_ses_domain_mail_from.main.mail_from_domain }
output "ses_smtp_endpoint"       { value = "email-smtp.${var.region}.amazonaws.com" }
output "ses_smtp_username" {
  value     = aws_iam_access_key.ses_smtp.id
  sensitive = true
}
output "ses_smtp_password" {
  value     = aws_iam_access_key.ses_smtp.ses_smtp_password_v4
  sensitive = true
}
