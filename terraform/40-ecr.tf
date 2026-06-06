# 40-ecr.tf
# Phase 2 — ECR repository for the Chatwoot image (optional mirror of the
# upstream image). Used by the Helm chart's `image.repository` value when the
# operator wants images served from inside the VPC.

resource "aws_ecr_repository" "chatwoot" {
  name                 = "${var.name_prefix}/chatwoot"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Retain only the most recent 10 images per repository.
resource "aws_ecr_lifecycle_policy" "chatwoot" {
  repository = aws_ecr_repository.chatwoot.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
