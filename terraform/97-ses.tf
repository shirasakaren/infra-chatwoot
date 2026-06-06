# 97-ses.tf
# Phase 4 — Amazon SES outbound: domain identity, DKIM, mail-from domain,
# and an IAM user holding SMTP credentials (used by Chatwoot Action Mailer).
#
# Sandbox note: brand-new SES accounts can only send to verified addresses.
# The infra-up gate is unaffected; production sending requires a separate
# AWS sandbox-removal request (documented in README.md).

resource "aws_ses_domain_identity" "main" {
  domain = var.cloudflare_zone
}

resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

resource "aws_ses_domain_mail_from" "main" {
  domain           = aws_ses_domain_identity.main.domain
  mail_from_domain = "mail.${var.cloudflare_zone}"

  # If MX/SPF records are missing we still accept the message — beneficial
  # while DNS propagation is in flight.
  behavior_on_mx_failure = "UseDefaultValue"
}

# Wait for SES to confirm the domain is verified (CNAME-based DKIM).
resource "aws_ses_domain_identity_verification" "main" {
  domain = aws_ses_domain_identity.main.id
  depends_on = [
    cloudflare_record.ses_dkim,
    cloudflare_record.ses_mailfrom_mx,
    cloudflare_record.ses_mailfrom_spf,
  ]
}

# -----------------------------------------------------------------------------
# SMTP user — SES SMTP credentials = IAM access key (username) + a derived
# v4-signature password. AWS provider computes `ses_smtp_password_v4`
# locally; no network call needed.
# -----------------------------------------------------------------------------
resource "aws_iam_user" "ses_smtp" {
  name = "${var.name_prefix}-ses-smtp"
  path = "/${var.name_prefix}/"
  tags = local.common_tags
}

data "aws_iam_policy_document" "ses_send" {
  statement {
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = ["*@${var.cloudflare_zone}", "*@mail.${var.cloudflare_zone}"]
    }
  }
}

resource "aws_iam_user_policy" "ses_send" {
  name   = "${var.name_prefix}-ses-send"
  user   = aws_iam_user.ses_smtp.name
  policy = data.aws_iam_policy_document.ses_send.json
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}
