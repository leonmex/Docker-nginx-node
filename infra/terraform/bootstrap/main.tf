# One-time bootstrap: creates the S3 bucket + DynamoDB table that
# infra/terraform/environments/prod's "s3" backend depends on. Runs with local
# state (chicken-and-egg: the backend that would store this state doesn't exist
# until this applies) — see server/docs/AWS-DEPLOY-PLAN-OK.md.

terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  profile = "terraform-deploy"
  region  = "eu-central-1"

  default_tags {
    tags = {
      Project     = "blablarags"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# Terraform remote state only — NOT app object storage. Product images/docs are
# served from Cloudflare R2 (see server/src/services/MinioObjectStorage.ts); this
# bucket only ever holds Terraform's own state JSON.
resource "aws_s3_bucket" "tfstate" {
  bucket = "blablarags-prod-tfstate-${data.aws_caller_identity.current.account_id}"

  # Lets scripts/aws-teardown.sh delete this bucket in one shot even once it
  # holds multiple state versions.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State lock table. On-demand billing stays inside DynamoDB's Always-Free tier
# (25GB storage / 25 RCU-WCU) regardless of AWS account age.
resource "aws_dynamodb_table" "tflock" {
  name         = "blablarags-prod-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
