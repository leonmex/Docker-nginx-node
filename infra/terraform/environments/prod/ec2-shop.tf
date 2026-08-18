# EC2 compute for shop (Next.js storefront) — separate instance from
# server+dashboard, by your explicit call: shop is public-facing storefront
# traffic (heavier codebase, higher expected volume than the admin
# dashboard), worth isolating for both performance and blast-radius
# reasons. See docs/DEPLOY-TO-AWS-STEP-BY-STEP.md.
#
# shop reaches the API exclusively through the public
# https://api.blablarags.com (both server-side rendering fetches and
# nginx's /api/* proxy — see nginx/prod/web.blablarags.com.conf) — no
# private VPC networking between the two instances, by design (your
# explicit choice): avoids new security-group plumbing/exposed ports on the
# already-live app instance, and reuses the same rate-limiting/TLS already
# proven on that public origin instead of bypassing it via a private path.
#
# Reuses data.aws_ami.ubuntu from ec2.tf (same module/directory, no
# redeclaration needed).

# Same Cloudflare-only, no-SSH discipline as the app instance's SG — see
# ec2.tf's aws_security_group.app for the full IP-list rationale.
resource "aws_security_group" "shop" {
  name        = "blablarags-prod-shop-sg"
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
      from_port        = 80
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

# Simpler than the app instance's role: shop's container needs no DB/
# runtime secrets at all (no direct DB access, images served from a public
# CDN URL client-side) — just the GHCR pull token to fetch its own image,
# and the basic-auth htpasswd (pre-launch gate, same as web/admin).
resource "aws_iam_role" "shop_instance" {
  name = "blablarags-prod-shop-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "shop_instance_ssm" {
  role       = aws_iam_role.shop_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "shop_instance_secrets" {
  name = "blablarags-prod-shop-instance-secrets"
  role = aws_iam_role.shop_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.ghcr_pull_token.arn,
        aws_secretsmanager_secret.nginx_basic_auth.arn,
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "shop" {
  name = "blablarags-prod-shop-instance-profile"
  role = aws_iam_role.shop_instance.name
}

resource "aws_eip" "shop" {
  instance = aws_instance.shop.id
  domain   = "vpc"
}

resource "aws_instance" "shop" {
  ami                          = data.aws_ami.ubuntu.id
  instance_type                = "t3.micro"
  subnet_id                    = data.aws_subnets.default.ids[0]
  vpc_security_group_ids       = [aws_security_group.shop.id]
  iam_instance_profile         = aws_iam_instance_profile.shop.name
  associate_public_ip_address  = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  # Identical to the app instance's user_data — installs Docker + Compose
  # plugin. SSM agent ships preinstalled on the Ubuntu 24.04 AWS AMI.
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
    Name = "blablarags-prod-shop"
  }
}

output "shop_instance_id" {
  value = aws_instance.shop.id
}

output "shop_public_ip" {
  description = "Elastic IP — point Cloudflare DNS (web.blablarags.com) here"
  value       = aws_eip.shop.public_ip
}

output "shop_security_group_id" {
  value = aws_security_group.shop.id
}
