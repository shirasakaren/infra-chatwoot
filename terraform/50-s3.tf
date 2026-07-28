# 50-s3.tf
# Phase 2: S3 bucket for Chatwoot ActiveStorage (attachments, exports, avatars).
# Accessed by the Chatwoot pod via IRSA (chatwoot SA in the chatwoot namespace).

resource "random_id" "bucket_suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "activestorage" {
  bucket = "${var.name_prefix}-storage-${random_id.bucket_suffix.hex}"

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-storage"
    Component = "chatwoot-activestorage"
  })
}

resource "aws_s3_bucket_public_access_block" "activestorage" {
  bucket                  = aws_s3_bucket.activestorage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "activestorage" {
  bucket = aws_s3_bucket.activestorage.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "activestorage" {
  bucket = aws_s3_bucket.activestorage.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "activestorage" {
  bucket = aws_s3_bucket.activestorage.id
  versioning_configuration {
    status = "Disabled"
  }
}

# CORS for direct-from-browser uploads (Chatwoot agent file uploads via
# ActiveStorage signed URLs).
resource "aws_s3_bucket_cors_configuration" "activestorage" {
  bucket = aws_s3_bucket.activestorage.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = ["https://${var.domain}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# Bucket policy: deny non-TLS access (additive to public access block).
resource "aws_s3_bucket_policy" "activestorage_tls_only" {
  bucket = aws_s3_bucket.activestorage.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.activestorage.arn,
        "${aws_s3_bucket.activestorage.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.activestorage]
}
