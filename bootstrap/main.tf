# bootstrap/main.tf
# One-shot Terraform (LOCAL state) that provisions the remote backend for the
# main stack: an S3 state bucket and a DynamoDB lock table. Idempotent.
#
# Run:
#   cd bootstrap
#   terraform init
#   terraform apply -var "owner=<you>"
#
# Outputs (state_bucket, lock_table) are consumed by terraform/backend.tf.

locals {
  state_bucket_name = "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
  lock_table_name   = "${var.name_prefix}-tflock"

  base_tags = merge(
    {
      Project     = "chatwoot-ta"
      Environment = "ta"
      ManagedBy   = "terraform"
      Component   = "bootstrap"
      Owner       = var.owner
    },
    var.tags,
  )
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.base_tags
  }
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# S3: versioned, encrypted, public-access blocked
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = false # Phase 0 keeps this off so destroy.sh --purge-state works
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Deny non-TLS access
resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.state.arn,
        "${aws_s3_bucket.state.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# DynamoDB: state locking
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "lock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}
