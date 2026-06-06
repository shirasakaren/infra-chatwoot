# backend.tf
# Populated by deploy.sh from the bootstrap outputs:
#   terraform init -backend-config=bucket=... -backend-config=dynamodb_table=... \
#                  -backend-config=region=... -backend-config=key=chatwoot-ta/terraform.tfstate
#
# We declare only `backend "s3" {}` here so the same code initializes anywhere.

terraform {
  backend "s3" {
    encrypt = true
  }
}
