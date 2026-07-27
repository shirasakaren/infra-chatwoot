# 20-iam.tf
# Phase 2 IAM, aka the permissions maze:
#   - "Manajemen User" rubric: IAM groups, attached policies, and a
#     configurable map of IAM users (default seeds one demo operator).
#   - Cluster + node-group IAM roles for EKS.
#   - IRSA roles for cluster add-ons + Chatwoot S3 access (trust policies are
#     wired to the OIDC provider declared in 30-eks.tf).

# =============================================================================
# Manajemen User: IAM users / groups / policies
# =============================================================================

variable "iam_users" {
  description = "Demo IAM users (Manajemen User rubric). Each user is added to the named group."
  type = map(object({
    group = string # one of: operators, developers
  }))
  default = {
    "operator-demo" = { group = "operators" }
  }
}

resource "aws_iam_group" "operators" {
  name = "${var.name_prefix}-operators"
  path = "/${var.name_prefix}/"
}

resource "aws_iam_group" "developers" {
  name = "${var.name_prefix}-developers"
  path = "/${var.name_prefix}/"
}

# Operators: read-only on EKS / S3 / ECR / CloudWatch (run-books, log review).
data "aws_iam_policy_document" "operators" {
  statement {
    sid    = "ReadOnlyOps"
    effect = "Allow"
    actions = [
      "eks:Describe*",
      "eks:List*",
      "ecr:Describe*",
      "ecr:Get*",
      "ecr:List*",
      "logs:Describe*",
      "logs:Get*",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "s3:ListBucket",
      "s3:GetObject",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "operators" {
  name   = "${var.name_prefix}-operators"
  path   = "/${var.name_prefix}/"
  policy = data.aws_iam_policy_document.operators.json
}

resource "aws_iam_group_policy_attachment" "operators" {
  group      = aws_iam_group.operators.name
  policy_arn = aws_iam_policy.operators.arn
}

# Developers: push to ECR, read EKS, exec into pods (via kubectl + AWS auth).
data "aws_iam_policy_document" "developers" {
  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeRepositories",
    ]
    resources = ["*"]
  }
  statement {
    sid    = "EksClusterAccess"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "developers" {
  name   = "${var.name_prefix}-developers"
  path   = "/${var.name_prefix}/"
  policy = data.aws_iam_policy_document.developers.json
}

resource "aws_iam_group_policy_attachment" "developers" {
  group      = aws_iam_group.developers.name
  policy_arn = aws_iam_policy.developers.arn
}

# Users + group memberships.
resource "aws_iam_user" "users" {
  for_each = var.iam_users
  name     = "${var.name_prefix}-${each.key}"
  path     = "/${var.name_prefix}/"

  tags = merge(local.common_tags, {
    GroupName = each.value.group
  })
}

resource "aws_iam_user_group_membership" "users" {
  for_each = var.iam_users
  user     = aws_iam_user.users[each.key].name
  groups   = [each.value.group == "developers" ? aws_iam_group.developers.name : aws_iam_group.operators.name]
}

# =============================================================================
# EKS cluster IAM role
# =============================================================================

data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.name_prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])
  role       = aws_iam_role.eks_cluster.name
  policy_arn = each.key
}

# =============================================================================
# Node-group IAM role (instance profile attached via launch template)
# =============================================================================

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.name_prefix}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # SSM Agent access. Ansible reaches nodes via Session Manager (no SSH),
    # because opening port 22 in 2026 is a personality trait we don't have.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    # CloudWatch metrics + logs for fluent-bit / cloudwatch-agent.
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = each.key
}

resource "aws_iam_instance_profile" "eks_node" {
  name = "${var.name_prefix}-eks-node"
  role = aws_iam_role.eks_node.name
}

# =============================================================================
# IRSA roles (trust policies use the OIDC provider declared in 30-eks.tf)
# =============================================================================
# Each role's trust policy restricts to a specific (namespace, service-account)
# pair using the StringEquals condition on the OIDC subject.

locals {
  oidc_provider_arn = aws_iam_openid_connect_provider.eks.arn
  oidc_provider_url = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")

  irsa_subjects = {
    alb_controller     = "system:serviceaccount:kube-system:aws-load-balancer-controller"
    cluster_autoscaler = "system:serviceaccount:kube-system:cluster-autoscaler"
    external_secrets   = "system:serviceaccount:external-secrets:external-secrets"
    chatwoot           = "system:serviceaccount:chatwoot:chatwoot"
  }
}

data "aws_iam_policy_document" "irsa_assume" {
  for_each = local.irsa_subjects

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = [each.value]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---- ALB controller --------------------------------------------------------
# Permissions from AWS LB Controller upstream policy (v2.7+).
resource "aws_iam_role" "alb_controller" {
  name               = "${var.name_prefix}-irsa-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["alb_controller"].json
}

data "http" "alb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.2/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.name_prefix}-alb-controller"
  policy = data.http.alb_controller_policy.response_body
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ---- cluster-autoscaler ----------------------------------------------------
data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.name_prefix}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.name_prefix}-irsa-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["cluster_autoscaler"].json
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name   = "${var.name_prefix}-cluster-autoscaler"
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# ---- External Secrets Operator --------------------------------------------
# ESO needs to read from Secrets Manager. Scope to the project secrets path.
data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name_prefix}/*",
    ]
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.name_prefix}-irsa-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["external_secrets"].json
}

resource "aws_iam_policy" "external_secrets" {
  name   = "${var.name_prefix}-external-secrets"
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

# ---- Chatwoot S3 access (ActiveStorage) -----------------------------------
data "aws_iam_policy_document" "chatwoot_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.activestorage.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:PutObjectAcl",
    ]
    resources = ["${aws_s3_bucket.activestorage.arn}/*"]
  }
}

resource "aws_iam_role" "chatwoot" {
  name               = "${var.name_prefix}-irsa-chatwoot"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["chatwoot"].json
}

resource "aws_iam_policy" "chatwoot_s3" {
  name   = "${var.name_prefix}-chatwoot-s3"
  policy = data.aws_iam_policy_document.chatwoot_s3.json
}

resource "aws_iam_role_policy_attachment" "chatwoot_s3" {
  role       = aws_iam_role.chatwoot.name
  policy_arn = aws_iam_policy.chatwoot_s3.arn
}
