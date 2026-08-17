# Deliberately no custom VPC/NAT gateway — a NAT alone would add ~$32/mo for
# zero benefit at this scale (see server/docs/AWS-DEPLOY-PLAN-OK.md). Use the
# account's existing default VPC/subnets instead.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
