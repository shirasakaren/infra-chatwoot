# 30-eks.tf
# Phase 2: EKS cluster, OIDC provider, custom launch template
# (AL2023 + secondary EBS for LVM, SSM-enabled, IMDSv2 required), and
# the managed node group that uses it.
#
# The secondary EBS volume is attached UNFORMATTED. Phase 5 (Ansible) sees
# a ${var.node_data_volume_gb}-GB block device and runs:
#   pvcreate to vgcreate vg_data to lvcreate lv_data to mkfs.xfs to mount /data
# (LVM rubric requirement).

# -----------------------------------------------------------------------------
# CloudWatch log group for EKS control plane logs
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.name_prefix}/cluster"
  retention_in_days = 30
}

# -----------------------------------------------------------------------------
# EKS cluster
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.name_prefix
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  enabled_cluster_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler",
  ]

  vpc_config {
    subnet_ids              = concat(
      [for az in var.azs : aws_subnet.public[az].id],
      [for az in var.azs : aws_subnet.private[az].id],
    )
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Use the new IAM-API auth mode (lets us add IAM principals as cluster admins
  # without managing aws-auth ConfigMap by hand).
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  kubernetes_network_config {
    ip_family = "ipv4"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_managed,
    aws_cloudwatch_log_group.eks,
  ]
}

# -----------------------------------------------------------------------------
# OIDC provider (enables IRSA)
# -----------------------------------------------------------------------------
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

# -----------------------------------------------------------------------------
# EKS-optimized AL2023 AMI (looked up via SSM public parameter)
# -----------------------------------------------------------------------------
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${var.kubernetes_version}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

# -----------------------------------------------------------------------------
# Custom launch template
#   - root volume on /dev/xvda (gp3)
#   - secondary volume on /dev/xvdb (gp3, UNFORMATTED: Ansible owns it)
#   - IMDSv2 required, hop limit 2 (for IRSA pods)
#   - No user_data: managed node groups inject bootstrap automatically
# -----------------------------------------------------------------------------
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.name_prefix}-node-"
  description = "Chatwoot-TA EKS worker LT (AL2023 + LVM-ready secondary EBS)"

  image_id      = data.aws_ssm_parameter.eks_ami.value
  instance_type = var.node_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.eks_node.arn
  }

  vpc_security_group_ids = [aws_security_group.node.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  # Root volume (OS).
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # LVM data volume, left UNFORMATTED for Ansible to pvcreate/vgcreate.
  block_device_mappings {
    device_name = "/dev/xvdb"
    ebs {
      volume_size           = var.node_data_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name                                            = "${var.name_prefix}-eks-node"
      "kubernetes.io/cluster/${var.name_prefix}"      = "owned"
      "k8s.io/cluster-autoscaler/enabled"             = "true"
      "k8s.io/cluster-autoscaler/${var.name_prefix}"  = "owned"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = "${var.name_prefix}-eks-node-vol"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Managed node group
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn

  # Nodes live in private subnets (egress via NAT).
  subnet_ids = [for az in var.azs : aws_subnet.private[az].id]

  scaling_config {
    desired_size = var.node_desired
    min_size     = var.node_min
    max_size     = var.node_max
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  # ami_type / instance_types / disk_size are owned by the LT, don't set them.

  labels = {
    "chatwoot-ta/role" = "general"
  }

  # Tags propagated to the ASG so cluster-autoscaler can discover it.
  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/enabled"            = "true"
    "k8s.io/cluster-autoscaler/${var.name_prefix}" = "owned"
  })

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_managed,
    aws_eks_cluster.main,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # let cluster-autoscaler manage this
  }
}

# -----------------------------------------------------------------------------
# Core EKS add-ons (managed). We DO NOT pin VPC CNI custom config; defaults work.
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
}

# Make sure the operator running `terraform apply` keeps cluster-admin via the
# new access-entries API (in case `bootstrap_cluster_creator_admin_permissions`
# is ever turned off). Reuses data.aws_caller_identity.current from discovery.
resource "aws_eks_access_entry" "runner" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "runner_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.runner]
}
