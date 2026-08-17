resource "aws_security_group" "postgres" {
  name        = "blablarags-prod-postgres-sg"
  description = "Postgres 5432 access restricted to allowed_cidr_blocks only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Postgres from allowed IPs (dev machine / future app layer)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
