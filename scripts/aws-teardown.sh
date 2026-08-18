#!/usr/bin/env bash
# Emergency "stop paying now" button for the blablarags AWS infra
# (infra/terraform/environments/prod + infra/terraform/bootstrap).
#
# Destroys, in order: everything in environments/prod's Terraform state —
# RDS instance, its security group/subnet group/secrets/budget/SNS topic,
# the app EC2 instance + shop EC2 instance (if applied) with their Elastic
# IPs/security groups, the GitHub OIDC provider + per-repo deploy IAM roles,
# the app/shop instance IAM roles + the GHCR pull-token secret — then the
# Terraform state S3 bucket + DynamoDB lock table (bootstrap). A single
# `terraform destroy` on environments/prod covers all of this since it all
# lives in that one state file; no per-resource destroy calls needed. Then
# verifies nothing blablarags-prod-* is left in the account — so "the script
# ran" and "billing actually stopped" aren't just assumed to be the same
# thing.
#
# NOT covered (different provider, not Terraform-managed here): Cloudflare
# R2 buckets (media/CDN bucket, logs-blabla) and DNS records. Clean those up
# separately in the Cloudflare dashboard if you need to zero out that spend
# too — R2 is near-free at this scale so it's usually not urgent.
#
# This is a ONE-WAY DOOR: prod.tfvars has deletion_protection=false and
# skip_final_snapshot=true specifically so this can run unattended-fast in an
# emergency — there is no last-minute snapshot. Requires an explicit --yes
# flag (or an interactive y/N prompt) before the first destroy fires.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROD_DIR="$ROOT_DIR/infra/terraform/environments/prod"
BOOTSTRAP_DIR="$ROOT_DIR/infra/terraform/bootstrap"
AWS_PROFILE="terraform-deploy"
AWS_REGION="eu-central-1"

export PATH="$HOME/.local/bin:$PATH"

CONFIRM=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) CONFIRM=1 ;;
    *)
      echo "Usage: $0 [--yes]" >&2
      exit 1
      ;;
  esac
done

echo "=============================================================="
echo " AWS TEARDOWN — this destroys the RDS database and everything"
echo " else Terraform created for blablarags-prod, permanently."
echo " No final snapshot will be taken."
echo "=============================================================="
echo

if [ "$CONFIRM" -ne 1 ]; then
  read -r -p "Type 'destroy everything' to proceed: " reply
  if [ "$reply" != "destroy everything" ]; then
    echo "Aborted — nothing was touched." >&2
    exit 1
  fi
fi

command -v terraform >/dev/null 2>&1 || { echo "terraform not found on PATH." >&2; exit 1; }

echo
echo "--- Step 1/2: destroying environments/prod (RDS, SG, secrets, budget) ---"
if [ -d "$PROD_DIR" ] && [ -f "$PROD_DIR/.terraform/terraform.tfstate" -o -f "$PROD_DIR/terraform.tfstate" ]; then
  (cd "$PROD_DIR" && terraform destroy -auto-approve)
else
  echo "  No initialized prod state found — skipping (nothing to destroy here)."
fi

echo
echo "--- Step 2/2: destroying bootstrap (state S3 bucket + DynamoDB lock table) ---"
if [ -d "$BOOTSTRAP_DIR" ]; then
  (cd "$BOOTSTRAP_DIR" && terraform destroy -auto-approve)
else
  echo "  No bootstrap directory found — skipping."
fi

echo
echo "=============================================================="
echo " Verifying nothing blablarags-prod-* remains in the account..."
echo "=============================================================="

FAILED=0

echo
echo "-- RDS instances --"
RDS_LEFT="$(aws rds describe-db-instances \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, 'blablarags-prod')].DBInstanceIdentifier" \
  --output text 2>&1 || true)"
if [ -n "$RDS_LEFT" ]; then
  echo "  STILL PRESENT: $RDS_LEFT" >&2
  FAILED=1
else
  echo "  clean."
fi

echo
echo "-- EC2 instances (app + shop) --"
EC2_LEFT="$(aws ec2 describe-instances \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=blablarags-prod-*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text 2>&1 || true)"
if [ -n "$EC2_LEFT" ]; then
  echo "  STILL PRESENT: $EC2_LEFT" >&2
  FAILED=1
else
  echo "  clean."
fi

echo
echo "-- Elastic IPs --"
EIP_LEFT="$(aws ec2 describe-addresses \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=blablarags-prod-*" \
  --query "Addresses[].AllocationId" \
  --output text 2>&1 || true)"
if [ -n "$EIP_LEFT" ]; then
  echo "  STILL PRESENT: $EIP_LEFT" >&2
  FAILED=1
else
  echo "  clean."
fi

echo
echo "-- IAM roles (app/shop instance roles + per-repo OIDC deploy roles) --"
IAM_LEFT="$(aws iam list-roles \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "Roles[?starts_with(RoleName, 'blablarags-prod')].RoleName" \
  --output text 2>&1 || true)"
if [ -n "$IAM_LEFT" ]; then
  echo "  STILL PRESENT: $IAM_LEFT" >&2
  FAILED=1
else
  echo "  clean."
fi

echo
echo "-- IAM OIDC provider (GitHub Actions) --"
OIDC_LEFT="$(aws iam list-open-id-connect-providers \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" \
  --output text 2>&1 || true)"
if [ -n "$OIDC_LEFT" ]; then
  echo "  STILL PRESENT: $OIDC_LEFT" >&2
  FAILED=1
else
  echo "  clean."
fi

echo
echo "-- Secrets Manager secrets --"
SECRETS_LEFT="$(aws secretsmanager list-secrets \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "SecretList[?starts_with(Name, 'blablarags-prod')].Name" \
  --output text 2>&1 || true)"
if [ -n "$SECRETS_LEFT" ]; then
  echo "  STILL PRESENT: $SECRETS_LEFT" >&2
  echo "  (may show for up to 30 days if scheduled-deletion instead of immediate — check recovery window)" >&2
  FAILED=1
else
  echo "  clean."
fi

echo
echo "-- S3 buckets --"
S3_LEFT="$(aws s3 ls --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 | grep 'blablarags-prod' || true)"
if [ -n "$S3_LEFT" ]; then
  echo "  STILL PRESENT: $S3_LEFT" >&2
  FAILED=1
else
  echo "  clean."
fi

echo
echo "-- DynamoDB tables --"
DDB_LEFT="$(aws dynamodb list-tables \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query "TableNames[?starts_with(@, 'blablarags-prod')]" \
  --output text 2>&1 || true)"
if [ -n "$DDB_LEFT" ]; then
  echo "  STILL PRESENT: $DDB_LEFT" >&2
  FAILED=1
else
  echo "  clean."
fi

echo
if [ "$FAILED" -eq 1 ]; then
  echo "=============================================================="
  echo " WARNING: some resources are still listed above. Billing may"
  echo " NOT have fully stopped. Investigate the items marked STILL"
  echo " PRESENT before assuming teardown is complete."
  echo "=============================================================="
  exit 1
else
  echo "=============================================================="
  echo " All blablarags-prod-* resources confirmed gone. Billing for"
  echo " this infra has stopped."
  echo "=============================================================="
fi
