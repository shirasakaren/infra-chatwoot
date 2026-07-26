# 00-discovery.tf
# read-only snooping around the shared AWS account before we build anything.
# phase 0 uses this to:
#   1. pick a VPC CIDR that doesn't crash into anything already there.
#   2. catch name collisions (EKS cluster names, Route 53 zones).
#   3. write terraform/discovery/do-not-touch.json, the sacred "we added
#      things but we never broke yours" contract.
#
# nothing in this file creates anything billable or mutates anything.
# it's a look-but-don't-touch zone. like a museum, but with ARNs.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# Existing VPCs (and their CIDRs). we're politely asking who's already home.
# -----------------------------------------------------------------------------
data "aws_vpcs" "existing" {}

data "aws_vpc" "existing" {
  for_each = toset(data.aws_vpcs.existing.ids)
  id       = each.value
}

# -----------------------------------------------------------------------------
# Existing EKS clusters (collision check against our name_prefix)
# -----------------------------------------------------------------------------
data "aws_eks_clusters" "existing" {}

# -----------------------------------------------------------------------------
# Existing Route 53 hosted zones (informational; Cloudflare is authoritative
# for labmgm.org, but we still write down any Route 53 zones in this account
# so we never accidentally bodyslam one).
# -----------------------------------------------------------------------------
data "aws_route53_zones" "existing" {}

# -----------------------------------------------------------------------------
# Existing IAM entities (informational, used by 20-iam.tf so we don't name
# our users/groups/policies like someone else's kids).
# -----------------------------------------------------------------------------
data "aws_iam_account_alias" "current" {}

# -----------------------------------------------------------------------------
# CIDR overlap detection
#
# we compare candidate /16s against the first two octets of every existing
# CIDR. it's a strict guardrail for the documented 10.4x.0.0/16 candidates:
# anything sharing the same /16 is treated as overlapping. no exceptions,
# no "but it's only a little bit".
# -----------------------------------------------------------------------------
locals {
  existing_vpcs = {
    for id, v in data.aws_vpc.existing : id => {
      cidr_block           = v.cidr_block
      additional_cidrs     = try(v.cidr_block_associations, [])
      tags                 = v.tags
    }
  }

  # Primary CIDR for every existing VPC.
  existing_cidrs_raw = [for id, v in data.aws_vpc.existing : v.cidr_block]

  # Reduce each existing CIDR to its first-two-octet "label" (e.g. "10.42").
  existing_cidr_prefixes = toset([
    for c in local.existing_cidrs_raw :
    join(".", slice(split(".", split("/", c)[0]), 0, 2))
  ])

  # Candidate /16s with their two-octet labels.
  candidate_labels = {
    for c in var.vpc_cidr_candidates :
    c => join(".", slice(split(".", split("/", c)[0]), 0, 2))
  }

  # Candidates that do NOT collide with an existing /16-prefixed CIDR.
  non_overlapping_candidates = [
    for c, label in local.candidate_labels :
    c if !contains(local.existing_cidr_prefixes, label)
  ]

  # If override is set, trust it (the precondition below verifies it does not collide).
  selected_vpc_cidr = var.vpc_cidr_override != "" ? var.vpc_cidr_override : (
    length(local.non_overlapping_candidates) > 0
    ? local.non_overlapping_candidates[0]
    : "" # caught by check block below
  )

  # Existing CIDRs that share a /16 label with ANY candidate, useful in the report.
  overlapping_existing_cidrs = [
    for c in local.existing_cidrs_raw :
    c if contains(values(local.candidate_labels),
                  join(".", slice(split(".", split("/", c)[0]), 0, 2)))
  ]

  # EKS naming collision: our cluster will be "${name_prefix}".
  eks_name_collision = contains(data.aws_eks_clusters.existing.names, var.name_prefix)
}

# -----------------------------------------------------------------------------
# Hard checks. terraform plan fails LOUDLY with a clear message on collision.
# no silent shrugs in this file. if we crash, we crash with a readable error.
# -----------------------------------------------------------------------------
check "vpc_cidr_available" {
  assert {
    condition     = local.selected_vpc_cidr != ""
    error_message = "No non-overlapping VPC CIDR available from candidates ${jsonencode(var.vpc_cidr_candidates)}. Existing CIDRs detected: ${jsonencode(local.existing_cidrs_raw)}. Edit var.vpc_cidr_candidates or set var.vpc_cidr_override."
  }
}

check "override_cidr_does_not_overlap" {
  assert {
    condition = var.vpc_cidr_override == "" || !contains(
      local.existing_cidr_prefixes,
      join(".", slice(split(".", split("/", var.vpc_cidr_override)[0]), 0, 2)),
    )
    error_message = "vpc_cidr_override ${var.vpc_cidr_override} collides on its /16 label with an existing VPC. Pick a different range."
  }
}

check "eks_cluster_name_free" {
  assert {
    condition     = !local.eks_name_collision
    error_message = "An EKS cluster named '${var.name_prefix}' already exists in this account/region. Pick a different name_prefix."
  }
}

# -----------------------------------------------------------------------------
# Write the do-not-touch inventory to disk.
# destroy.sh reads it as a sanity check before touching anything, and
# deploy.sh prints it at the Phase 0 approval gate. it's the receipts.
# -----------------------------------------------------------------------------
resource "local_file" "do_not_touch" {
  filename        = "${path.module}/discovery/do-not-touch.json"
  file_permission = "0644"

  # No timestamp here. a timestamp would churn on every plan and break the
  # "0 drift" gate, and that gate is the one thing we refuse to negotiate.
  # The S3 state versioning of the parent stack tracks history if needed.
  content = jsonencode({
    aws = {
      account_id = data.aws_caller_identity.current.account_id
      region     = data.aws_region.current.name
      partition  = data.aws_partition.current.partition
      account_alias = try(data.aws_iam_account_alias.current.account_alias, "")
    }
    project = {
      name_prefix   = var.name_prefix
      domain        = var.domain
      vpc_cidr_used = local.selected_vpc_cidr
    }
    existing = {
      vpcs              = local.existing_vpcs
      eks_cluster_names = data.aws_eks_clusters.existing.names
      route53_zone_ids  = data.aws_route53_zones.existing.ids
    }
    guardrails = {
      candidate_vpc_cidrs        = var.vpc_cidr_candidates
      non_overlapping_candidates = local.non_overlapping_candidates
      overlapping_existing_cidrs = local.overlapping_existing_cidrs
      eks_name_collision         = local.eks_name_collision
    }
  })

  lifecycle {
    # Re-write whenever inputs change; ignore timestamp churn otherwise.
    ignore_changes = []
  }
}
