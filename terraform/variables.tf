variable "region" {
  description = "AWS region. Locked to ap-southeast-1 per CLAUDE.md."
  type        = string
  default     = "ap-southeast-1"
}

variable "azs" {
  description = "Availability Zones to use (exactly 2 for HA)."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
  validation {
    condition     = length(var.azs) == 2
    error_message = "Exactly 2 AZs required for the documented HA topology."
  }
}

variable "name_prefix" {
  description = "Short, lowercase prefix used for ALL resources (3-16 chars)."
  type        = string
  default     = "cwta"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/dash, 3-16 chars, starting with a letter."
  }
}

variable "owner" {
  description = "Owner tag value (your name/handle)."
  type        = string
}

variable "tags" {
  description = "Extra tags merged into common_tags."
  type        = map(string)
  default     = {}
}

variable "domain" {
  description = "Public FQDN for Chatwoot (e.g. support.labmgm.org)."
  type        = string
}

variable "cloudflare_zone" {
  description = "Cloudflare zone name (e.g. labmgm.org)."
  type        = string
}

# -----------------------------------------------------------------------------
# Network — candidate CIDRs. Phase 0 picks the first non-overlapping one.
# Operator can pin a specific CIDR by setting var.vpc_cidr_override.
# -----------------------------------------------------------------------------
variable "vpc_cidr_candidates" {
  description = "Ordered list of candidate /16s. The first one not overlapping any existing VPC is used."
  type        = list(string)
  default = [
    "10.42.0.0/16",
    "10.43.0.0/16",
    "10.44.0.0/16",
    "10.45.0.0/16",
    "10.46.0.0/16",
  ]
}

variable "vpc_cidr_override" {
  description = "Force a specific VPC CIDR (must not overlap existing). Empty = auto-select."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# EKS / nodes
# -----------------------------------------------------------------------------
variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group."
  type        = string
  default     = "t3.large"
}

variable "node_min"     { type = number; default = 3 }
variable "node_desired" { type = number; default = 3 }
variable "node_max"     { type = number; default = 6 }

variable "node_root_volume_gb" {
  description = "Root EBS volume size on each node (GB)."
  type        = number
  default     = 30
}

variable "node_data_volume_gb" {
  description = "Secondary EBS volume size on each node, dedicated to LVM /data (GB)."
  type        = number
  default     = 10
}

# -----------------------------------------------------------------------------
# RDS / Redis
# -----------------------------------------------------------------------------
variable "rds_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "rds_multi_az" {
  type    = bool
  default = true
}

variable "rds_allocated_gb" {
  type    = number
  default = 30
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

# -----------------------------------------------------------------------------
# GitHub OIDC
# -----------------------------------------------------------------------------
variable "github_owner" {
  type    = string
  default = ""
}

variable "github_repo" {
  type    = string
  default = ""
}

# -----------------------------------------------------------------------------
# Common tags
# -----------------------------------------------------------------------------
locals {
  common_tags = merge(
    {
      Project     = "chatwoot-ta"
      Environment = "ta"
      ManagedBy   = "terraform"
      Owner       = var.owner
      Domain      = var.domain
    },
    var.tags,
  )
}
