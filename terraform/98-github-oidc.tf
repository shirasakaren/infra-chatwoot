# 98-github-oidc.tf
# Phase 8 — GitHub Actions OIDC provider + IAM role that lets CI workflows
# assume short-lived credentials (no long-lived keys in the repo).
# The role is restricted to the named repo and a small set of read paths
# (plan/validate/lint). Apply via CI is gated behind an Environment in GH.

# OIDC provider for token.actions.githubusercontent.com — only one of these
# is allowed per account, so we check for a pre-existing one and reuse it.
data "aws_iam_openid_connect_provider" "github_existing" {
  count = var.github_owner != "" && var.github_repo != "" ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_enabled = var.github_owner != "" && var.github_repo != ""
  github_oidc_provider_arn = local.github_enabled ? data.aws_iam_openid_connect_provider.github_existing[0].arn : ""
}

data "aws_iam_policy_document" "gha_assume" {
  count = local.github_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  count              = local.github_enabled ? 1 : 0
  name               = "${var.name_prefix}-gha"
  assume_role_policy = data.aws_iam_policy_document.gha_assume[0].json

  tags = merge(local.common_tags, {
    Purpose = "github-actions-oidc"
  })
}

# Plan-only by default. Operators can attach AdministratorAccess to a separate
# role gated by an Environment if they want full apply via CI.
resource "aws_iam_role_policy_attachment" "github_actions_readonly" {
  count      = local.github_enabled ? 1 : 0
  role       = aws_iam_role.github_actions[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
