# EC2 compute for server (Fastify API) + dashboard (static SPA behind its
# own nginx) — see docs/DEPLOY-TO-AWS-STEP-BY-STEP.md §4. shop is
# deliberately not included yet; this instance is sized/priced for
# server+dashboard only, revisit before adding shop's workload.

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Inbound 80/443 restricted to Cloudflare's published IP ranges only — the
# origin should never be reachable except through Cloudflare's edge (same
# discipline as the RDS SG's IP-lock). List mirrors nginx/prod/00-shared.conf's
# set_real_ip_from directives exactly (cloudflare.com/ips-v4, /ips-v6) — both
# lists need updating together if Cloudflare's ranges ever change.
# Deliberately NO SSH ingress — access is via SSM only (see github-oidc.tf).
resource "aws_security_group" "app" {
  name        = "blablarags-prod-app-sg"
  description = "HTTP/HTTPS from Cloudflare only, no SSH - access via SSM"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = toset([
      "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
      "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
      "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
      "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
    ])
    content {
      description = "Cloudflare edge (IPv4)"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = toset([
      "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
      "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
      "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
      "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
    ])
    content {
      description = "Cloudflare edge (IPv4)"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = toset([
      "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32",
      "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32",
    ])
    content {
      description      = "Cloudflare edge (IPv6)"
      from_port         = 80
      to_port           = 443
      protocol          = "tcp"
      ipv6_cidr_blocks  = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM role for the instance itself (not GitHub's OIDC role — see
# github-oidc.tf for that). SSM-managed (no SSH) + read-only access to
# exactly the secrets deploy.sh needs to fetch: the app DB credentials, the
# nginx basic-auth htpasswd, and the GHCR pull token — never the RDS admin
# secret.
resource "aws_iam_role" "app_instance" {
  name = "blablarags-prod-app-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_instance_ssm" {
  role       = aws_iam_role.app_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app_instance_secrets" {
  name = "blablarags-prod-app-instance-secrets"
  role = aws_iam_role.app_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.postgres_app_credentials.arn,
        aws_secretsmanager_secret.nginx_basic_auth.arn,
        aws_secretsmanager_secret.ghcr_pull_token.arn,
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "blablarags-prod-app-instance-profile"
  role = aws_iam_role.app_instance.name
}

# Long-lived read:packages-only GitHub PAT, needed only if the app repos are
# private (docker login ghcr.io on the instance). Provided by you via
# TF_VAR_ghcr_pull_token (SECRETES/terraform/prod.auto.tfvars), same pattern
# as the DB passwords — never Terraform-generated, never committed.
resource "aws_secretsmanager_secret" "ghcr_pull_token" {
  name        = "blablarags-prod-ghcr-pull-token"
  description = "read:packages-only GitHub PAT for `docker login ghcr.io` on the app instance"
}

resource "aws_secretsmanager_secret_version" "ghcr_pull_token" {
  secret_id     = aws_secretsmanager_secret.ghcr_pull_token.id
  secret_string = var.ghcr_pull_token
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type           = "t3.micro"
  subnet_id               = data.aws_subnets.default.ids[0]
  vpc_security_group_ids  = [aws_security_group.app.id]
  iam_instance_profile    = aws_iam_instance_profile.app.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  # Installs Docker + Compose plugin. SSM agent ships preinstalled on the
  # Ubuntu 24.04 AWS AMI — no extra setup needed for SSM to reach it, as long
  # as this public subnet's route table has an IGW route (default VPC's does).
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    mkdir -p /opt/blablarags
  EOF

  tags = {
    Name = "blablarags-prod-app"
  }
}

output "app_instance_id" {
  value = aws_instance.app.id
}

output "app_public_ip" {
  description = "Elastic IP — point Cloudflare DNS (api/web/admin.blablarags.com) here"
  value       = aws_eip.app.public_ip
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}
