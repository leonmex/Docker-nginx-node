# Non-secret values only — passwords are NOT here, see db_admin_password /
# db_app_password in variables.tf (supplied via TF_VAR_* env vars instead).
allowed_cidr_blocks = ["77.191.239.20/32"] # current dev IP (dynamic — update when it changes)

db_admin_username = "admin_dba_bla"      # RDS master — DBA/infra use only
db_app_username   = "app-dba-blablarags" # plain Postgres role — used by the running app
