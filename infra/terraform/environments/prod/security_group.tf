resource "aws_security_group" "postgres" {
  name        = "blablarags-prod-postgres-sg"
  description = "Postgres 5432 access restricted to allowed_cidr_blocks only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Postgres from allowed IPs (dev machine)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description     = "Postgres from the app EC2 instance"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
