# 95-cloudflare.tf
# Phase 4: Cloudflare DNS records under the labmgm.org zone.
# We only create records this project owns:
#   - ACM validation CNAMEs
#   - SES DKIM CNAMEs + mail-from MX/TXT
#   - SPF + DMARC TXT records
# The app record (support to ALB) is created by Phase 5 Ansible AFTER the
# ALB Load Balancer Controller has materialized the ALB and produced its
# hostname. Terraform doesn't know that value at plan time.

data "cloudflare_zone" "main" {
  name = var.cloudflare_zone
}

# ----- ACM validation CNAMEs ------------------------------------------------
# One record per domain in the cert (here: support.labmgm.org).
resource "cloudflare_record" "acm_validation" {
  for_each = {
    for o in aws_acm_certificate.app.domain_validation_options : o.domain_name => {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  }

  zone_id = data.cloudflare_zone.main.id
  name    = each.value.name
  type    = each.value.type
  content = each.value.value
  ttl     = 60
  proxied = false # validation CNAMEs must NOT be proxied
  comment = "ACM DNS validation for ${var.name_prefix}"
}

# ----- SES DKIM CNAMEs ------------------------------------------------------
resource "cloudflare_record" "ses_dkim" {
  count = 3

  zone_id = data.cloudflare_zone.main.id
  name    = "${aws_ses_domain_dkim.main.dkim_tokens[count.index]}._domainkey"
  type    = "CNAME"
  content = "${aws_ses_domain_dkim.main.dkim_tokens[count.index]}.dkim.amazonses.com"
  ttl     = 600
  proxied = false
  comment = "SES DKIM for ${var.name_prefix}"
}

# ----- Mail-FROM domain MX + TXT (improves SES deliverability) --------------
resource "cloudflare_record" "ses_mailfrom_mx" {
  zone_id = data.cloudflare_zone.main.id
  name    = aws_ses_domain_mail_from.main.mail_from_domain
  type    = "MX"
  content = "feedback-smtp.${var.region}.amazonses.com"
  priority = 10
  ttl     = 600
  proxied = false
  comment = "SES mail-from MX"
}

resource "cloudflare_record" "ses_mailfrom_spf" {
  zone_id = data.cloudflare_zone.main.id
  name    = aws_ses_domain_mail_from.main.mail_from_domain
  type    = "TXT"
  content = "v=spf1 include:amazonses.com -all"
  ttl     = 600
  proxied = false
  comment = "SES mail-from SPF"
}

# ----- DMARC ----------------------------------------------------------------
resource "cloudflare_record" "dmarc" {
  zone_id = data.cloudflare_zone.main.id
  name    = "_dmarc.${var.cloudflare_zone}"
  type    = "TXT"
  content = "v=DMARC1; p=quarantine; rua=mailto:dmarc-reports@${var.cloudflare_zone}"
  ttl     = 3600
  proxied = false
  comment = "DMARC policy"
}
