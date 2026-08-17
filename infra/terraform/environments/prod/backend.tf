# Remote state — points at the bucket/table created by infra/terraform/bootstrap.
# See server/docs/AWS-DEPLOY-PLAN-OK.md for why bootstrap is a separate, prior step.

terraform {
  backend "s3" {
    bucket         = "blablarags-prod-tfstate-246064376952"
    key            = "prod/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "blablarags-prod-tflock"
    encrypt        = true
    profile        = "terraform-deploy"
  }
}
