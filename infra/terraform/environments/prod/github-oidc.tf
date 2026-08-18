# GitHub Actions -> AWS via OIDC, no static AWS keys in GitHub. One IAM role
# per repo, trust policy scoped to that exact repo + master branch, allowed
# only ssm:SendCommand against THAT repo's own target instance (server/
# dashboard share the app instance; shop has its own, separate instance —
# see ec2-shop.tf) — see docs/DEPLOY-TO-AWS-STEP-BY-STEP.md §5.

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

locals {
  deploy_repos = {
    server    = { repo = "leonmex/server-blablaragsandrigs", instance_arn = aws_instance.app.arn }
    dashboard = { repo = "leonmex/dashboard-blablaragsandrigs", instance_arn = aws_instance.app.arn }
    shop      = { repo = "leonmex/shop-blablarags", instance_arn = aws_instance.shop.arn }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = local.deploy_repos

  name = "blablarags-prod-deploy-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${each.value.repo}:ref:refs/heads/master"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy_ssm" {
  for_each = local.deploy_repos

  name = "blablarags-prod-deploy-${each.key}-ssm"
  role = aws_iam_role.deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:SendCommand"]
      Resource = [
        each.value.instance_arn,
        "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
      ]
    }]
  })
}

output "deploy_role_arns" {
  description = "Set as a repo variable (not secret) in each repo's GitHub Actions config"
  value       = { for k, r in aws_iam_role.deploy : k => r.arn }
}
