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
  region  = var.aws_region

  default_tags {
    tags = {
      Project     = "blablarags"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}
