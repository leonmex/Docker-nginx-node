# Pre-launch gate for web.blablarags.com (shop) and admin.blablarags.com
# (dashboard) — see nginx-prod-configs (repo root, docker-compose.prod.yml's
# proxy service). Deliberately NOT applied to api.blablarags.com.
#
# The htpasswd content is supplied by you (nginx_basic_auth_htpasswd in
# variables.tf), hashed locally with `openssl passwd -apr1` from
# SECRETES/Basic-Auth/users-access.md — never stored as plaintext, never
# Terraform-generated. This resource's only job is getting it into Secrets
# Manager so the EC2 deploy script (Part 3 of the CI/CD plan) can fetch it via
# the instance's IAM role and write it to nginx's auth_basic_user_file path on
# every deploy.

resource "aws_secretsmanager_secret" "nginx_basic_auth" {
  name        = "blablarags-prod-nginx-basic-auth"
  description = "htpasswd content gating web.blablarags.com and admin.blablarags.com during pre-launch"
}

resource "aws_secretsmanager_secret_version" "nginx_basic_auth" {
  secret_id     = aws_secretsmanager_secret.nginx_basic_auth.id
  secret_string = var.nginx_basic_auth_htpasswd
}
