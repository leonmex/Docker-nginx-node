# Two credential sets, per your request: an "admin" one (RDS master, DBA/infra
# access) and an "app" one (full rights on db_name, used by the running
# website/server app — see roles.tf for why the app ROLE itself is created by
# a follow-up script rather than here).
#
# Both passwords are supplied by you (db_admin_password / db_app_password in
# variables.tf), not Terraform-generated — set via TF_VAR_* env vars at
# plan/apply time. Terraform's job here is just to get them into Secrets
# Manager, not to originate them.

resource "aws_secretsmanager_secret" "postgres_admin_credentials" {
  name        = "blablarags-prod-postgres-admin-credentials"
  description = "RDS master credentials for blablarags-prod-postgres — DBA/infra use only, not the running app"
}

resource "aws_secretsmanager_secret_version" "postgres_admin_credentials" {
  secret_id = aws_secretsmanager_secret.postgres_admin_credentials.id
  secret_string = jsonencode({
    username = var.db_admin_username
    password = var.db_admin_password
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = var.db_name
    engine   = "postgres"
    role     = "admin"
  })
}

resource "aws_secretsmanager_secret" "postgres_app_credentials" {
  name        = "blablarags-prod-postgres-app-credentials"
  description = "Application credentials for blablarags-prod-postgres — used by the website/server app (POSTGRES_* env vars)"
}

resource "aws_secretsmanager_secret_version" "postgres_app_credentials" {
  secret_id = aws_secretsmanager_secret.postgres_app_credentials.id
  secret_string = jsonencode({
    username = var.db_app_username
    password = var.db_app_password
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = var.db_name
    engine   = "postgres"
    role     = "app"
  })
}
