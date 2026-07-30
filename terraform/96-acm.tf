# 96-acm.tf
# Phase 4: ACM public certificate for the app FQDN. DNS-validated via
# Cloudflare (records created in 95-cloudflare.tf). The cert is bound to
# the ALB by the Helm-managed ingress in Phase 5.

resource "aws_acm_certificate" "app" {
  domain_name       = var.domain
  validation_method = "DNS"

  # Add www if you ever decide to alias it; we keep it strict for now.
  subject_alternative_names = []

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-${var.domain}"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in cloudflare_record.acm_validation : r.hostname]
}
