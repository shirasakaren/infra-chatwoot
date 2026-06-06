provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# Cloudflare token comes from CLOUDFLARE_API_TOKEN in the environment
# (deploy.sh exports it from .env). Not a Terraform variable so it never
# lands in tfvars or state plaintext.
provider "cloudflare" {}
