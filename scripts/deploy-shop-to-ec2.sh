#!/usr/bin/env bash
# Runs ON the shop EC2 instance (via `aws ssm send-command`, never SSH —
# see infra/terraform/environments/prod/ec2-shop.tf). Much simpler than
# scripts/deploy-to-ec2.sh: shop needs no DB/runtime secrets at all (no
# direct DB access, reaches the API only via the public
# https://api.blablarags.com — see docker-compose.shop.yml) — just the
# GHCR pull token and the pre-launch basic-auth htpasswd.
#
# Idempotent — safe to re-run on every deploy. Installs `aws` CLI on first
# run if missing (not baked into the original user_data).
set -euo pipefail

AWS_REGION="eu-central-1"
APP_DIR="/opt/blablarags"

if ! command -v aws >/dev/null 2>&1; then
  echo "Installing AWS CLI v2 (not in apt's default repos on this AMI)..."
  apt-get update -y
  apt-get install -y unzip curl
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi

mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "Fetching secrets from Secrets Manager..."
GHCR_TOKEN="$(aws secretsmanager get-secret-value --secret-id blablarags-prod-ghcr-pull-token --region "$AWS_REGION" --query SecretString --output text)"

# Plain text (not JSON) — an APR1-MD5 htpasswd file, one user:hash per
# line. Gates web.blablarags.com during pre-launch.
mkdir -p "${APP_DIR}/nginx/secrets"
aws secretsmanager get-secret-value --secret-id blablarags-prod-nginx-basic-auth --region "$AWS_REGION" --query SecretString --output text > "${APP_DIR}/nginx/secrets/.htpasswd"
chmod 644 "${APP_DIR}/nginx/secrets/.htpasswd"

echo "Logging into ghcr.io..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u leonmex --password-stdin

echo "Pulling and starting the stack..."
docker compose -f "${APP_DIR}/docker-compose.shop.yml" pull
docker compose -f "${APP_DIR}/docker-compose.shop.yml" up -d

echo "Deploy complete."
docker compose -f "${APP_DIR}/docker-compose.shop.yml" ps
