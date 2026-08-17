# Alert only, not auto-destroy — see server/docs/AWS-DEPLOY-PLAN-OK.md's
# "Cost guardrail & emergency teardown" section for why. On breach, run
# scripts/aws-teardown.sh yourself.

resource "aws_sns_topic" "budget_alerts" {
  name = "blablarags-prod-budget-alerts"
}

# AWS Budgets requires the topic policy to explicitly allow the Budgets
# service principal to publish — without this, notifications silently fail.
data "aws_iam_policy_document" "budget_alerts_topic_policy" {
  statement {
    sid    = "AWSBudgetsSNSPublishingPermissions"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.budget_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "budget_alerts" {
  arn    = aws_sns_topic.budget_alerts.arn
  policy = data.aws_iam_policy_document.budget_alerts_topic_policy.json
}

resource "aws_sns_topic_subscription" "budget_alerts_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
  # AWS emails a confirmation link to endpoint after apply — must be clicked
  # once or notifications never actually deliver.
}

# Account-wide (not tag-scoped): tag-based Budget filters need Cost Allocation
# Tags activated in the Billing console first (manual, up to 24h propagation
# delay), which would leave this silently inactive at the start. Account-wide
# is a strictly stronger safety net anyway, since this RDS instance is the
# only billed resource this config creates.
resource "aws_budgets_budget" "monthly_cost" {
  name         = "blablarags-prod-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_eur)
  limit_unit   = "EUR"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}
