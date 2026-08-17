output "db_endpoint" {
  description = "RDS endpoint hostname (DB_HOST)"
  value       = aws_db_instance.postgres.address
}

output "db_port" {
  value = aws_db_instance.postgres.port
}

output "db_name" {
  value = var.db_name
}

output "db_admin_username" {
  description = "RDS master username — DBA/infra use only, not the running app"
  value       = var.db_admin_username
}

output "db_app_username" {
  description = "Application role username — what the running website/server app should use as POSTGRES_USER"
  value       = var.db_app_username
}

output "admin_secret_arn" {
  value = aws_secretsmanager_secret.postgres_admin_credentials.arn
}

output "app_secret_arn" {
  value = aws_secretsmanager_secret.postgres_app_credentials.arn
}

output "security_group_id" {
  value = aws_security_group.postgres.id
}

# Passwords are deliberately never plain outputs — retrieve via
# scripts/aws-fetch-db-secret.sh, which reads directly from Secrets Manager.
