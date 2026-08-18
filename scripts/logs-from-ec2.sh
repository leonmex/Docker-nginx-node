#!/usr/bin/env bash
# Fetch logs from the production EC2 instance via SSM (no SSH — matches
# the instance's no-SSH security design). Runs `docker compose logs`
# remotely and prints the result.
#
# Usage:
#   scripts/logs-from-ec2.sh                # last 50 lines, all services
#   scripts/logs-from-ec2.sh server          # last 50 lines, one service
#   scripts/logs-from-ec2.sh server 200      # last 200 lines, one service
#   scripts/logs-from-ec2.sh "" 50 -f        # follow all services (Ctrl+C to stop)
set -euo pipefail

INSTANCE_ID="i-0f84cf9304e3517bc"
AWS_PROFILE="terraform-deploy"
AWS_REGION="eu-central-1"
APP_DIR="/opt/blablarags"

SERVICE="${1:-}"
TAIL="${2:-50}"
FOLLOW_FLAG="${3:-}"

CMD="cd ${APP_DIR} && docker compose -f docker-compose.prod.yml logs ${SERVICE} --tail ${TAIL}"
if [ "$FOLLOW_FLAG" = "-f" ]; then
  echo "Follow mode isn't supported over SSM send-command (it's request/response, not streaming)." >&2
  echo "Use a bounded --since instead, e.g.: scripts/logs-from-ec2.sh server 500" >&2
  exit 1
fi

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --parameters "{\"commands\":[\"${CMD}\"]}" \
  --query 'Command.CommandId' --output text)

# Poll until the command finishes.
for _ in $(seq 1 15); do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'Status' --output text 2>/dev/null || echo "Pending")
  [ "$STATUS" != "InProgress" ] && [ "$STATUS" != "Pending" ] && break
  sleep 2
done

aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query 'StandardOutputContent' --output text
