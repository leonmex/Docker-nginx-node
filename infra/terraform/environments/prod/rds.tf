resource "aws_db_subnet_group" "postgres" {
  name       = "blablarags-prod-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "postgres" {
  identifier = "blablarags-prod-postgres"

  engine         = "postgres"
  engine_version = var.db_engine_version # 18.4 — matches local dev exactly
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name = var.db_name
  # RDS master user — DBA/infra access only. The running app uses the separate
  # db_app_username role instead (see variables.tf, roles.tf).
  username = var.db_admin_username
  password = var.db_admin_password

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.postgres.id]

  # No bastion/VPN in this scope — the security group (locked to
  # allowed_cidr_blocks) is the only gate, so the instance must be reachable.
  publicly_accessible = true
  multi_az            = false

  backup_retention_period = 7

  # Deliberately disposable: lets scripts/aws-teardown.sh run `terraform destroy`
  # unattended if the cost cap is ever breached, with no manual snapshot/protection
  # step in the way. This DB starts empty — see server/docs/AWS-DEPLOY-PLAN-OK.md.
  deletion_protection = false
  skip_final_snapshot = true

  apply_immediately = true
}
